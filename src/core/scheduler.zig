//! Deterministic Stage Scheduler (`core/scheduler`).
//!
//! Organizes systems into ordered execution stages:
//! `startup -> pre_update -> fixed_update -> update -> post_update -> render_extract -> shutdown`.
//!
//! Features:
//! - Topological sorting of systems per stage using `before` / `after` constraints
//!   with Kahn's algorithm (preserving insertion order as deterministic tie-breaker).
//! - Explicit `DependencyCycle` detection at schedule build time.
//! - Read/write conflict detection helper (`hasWriteConflict`).
//! - Fixed-timestep accumulator for `.fixed_update` with `max_fixed_steps` clamping.
//! - Automatic `CommandBuffer.apply()` barrier after every stage and `EventBus.drain()` per frame.
//! - Opt-in parallel execution (`Scheduler.setParallel`): systems marked `.worker`/`.any` that the
//!   conflict analysis (`parallelBatches`) proves independent run concurrently on a `std.Io`
//!   thread pool. Each gets its own change-detection tick and `CommandBuffer`; buffers merge in
//!   schedule order, so results equal serial execution. While a parallel run is active the world
//!   rejects structural mutation (`error.MutationDuringParallelPhase`).

const std = @import("std");
const world_mod = @import("world.zig");
const commands_mod = @import("commands.zig");
const events_mod = @import("events.zig");
const resources_mod = @import("resources.zig");
const diagnostics_mod = @import("diagnostics.zig");

/// Execution phase within a single frame or lifecycle transition.
pub const Stage = enum(usize) {
    startup = 0,
    pre_update = 1,
    fixed_update = 2,
    update = 3,
    post_update = 4,
    render_extract = 5,
    shutdown = 6,

    pub const count = 7;
};

/// Execution thread affinity hint for future parallel stage scheduling.
pub const ThreadAffinity = enum {
    main,
    render,
    worker,
    any,
};

/// Per-invocation view passed to every system function, exposing world, commands, events,
/// resources, diagnostics, and current/fixed delta time.
pub const SystemContext = struct {
    world: *world_mod.World,
    commands: *commands_mod.CommandBuffer,
    events: *events_mod.EventBus,
    resources: *resources_mod.ResourceRegistry,
    diagnostics: *diagnostics_mod.Diagnostics,
    dt: f32,
    fixed_dt: f32,
    /// Change-detection clock value of this system's run (0 outside scheduled runs).
    tick: u64 = 0,
    /// `.added`/`.changed` threshold: the tick at which this system last ran.
    query_since: u64 = 0,

    pub fn deltaSeconds(self: *const SystemContext) f32 {
        return self.dt;
    }

    pub fn fixedDeltaSeconds(self: *const SystemContext) f32 {
        return self.fixed_dt;
    }

    pub fn query(self: *SystemContext, comptime spec: anytype) !world_mod.Query(spec) {
        // Inside a scheduled run `tick != 0` and the system's own change-detection state applies.
        if (self.tick != 0) return world_mod.Query(spec).initWith(self.world, self.query_since, self.tick);
        return self.world.query(spec);
    }
};

/// Signature implemented by all ECS system callbacks.
pub const SystemFn = *const fn (ctx: *SystemContext) anyerror!void;

/// Optional predicate gating whether a system executes on a given frame/tick.
pub const RunConditionFn = *const fn (ctx: *const SystemContext) bool;

/// Registration metadata controlling stage placement, ordering constraints, and access hints.
pub const SystemDescriptor = struct {
    name: []const u8,
    stage: Stage = .update,
    run: SystemFn,
    run_if: ?RunConditionFn = null,
    reads: []const []const u8 = &.{},
    writes: []const []const u8 = &.{},
    before: []const []const u8 = &.{},
    after: []const []const u8 = &.{},
    exclusive: bool = false,
    thread_affinity: ThreadAffinity = .main,
};

const StoredSystem = struct {
    name: []const u8,
    stage: Stage,
    run: SystemFn,
    run_if: ?RunConditionFn,
    reads: []const []const u8,
    writes: []const []const u8,
    before: []const []const u8,
    after: []const []const u8,
    exclusive: bool,
    thread_affinity: ThreadAffinity,
    /// World tick at which this system last ran; drives `.added`/`.changed` query filters.
    last_run_tick: u64 = 0,
};

/// Errors returned when adding systems, resolving stage schedules, or stepping frames.
pub const SchedulerError = error{
    DuplicateSystem,
    DependencyCycle,
    UnknownSystemDependency,
    InvalidSelfDependency,
    InvalidCrossStageDependency,
    InvalidDeltaTime,
    InvalidFixedTimestep,
    OutOfMemory,
};

/// Deterministic stage-based system scheduler with fixed-timestep accumulator.
pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    stages: [Stage.count]std.ArrayList(StoredSystem),
    execution_order: [Stage.count]std.ArrayList(usize),
    dirty: [Stage.count]bool,
    fixed_dt: f64,
    max_fixed_steps: u32,
    accumulator: f64,
    render_extract_enabled: bool,
    /// When set, conflict-free systems that opted in (`thread_affinity` `.worker` or `.any`) run
    /// concurrently on this `Io`'s thread pool (see `setParallel`). Null keeps execution serial.
    io: ?std.Io = null,
    /// Cached `parallelBatches` plan per stage, rebuilt whenever the stage's schedule changes.
    batch_plans: [Stage.count]?BatchPlan = @splat(null),

    pub fn init(allocator: std.mem.Allocator) Scheduler {
        var self = Scheduler{
            .allocator = allocator,
            .stages = undefined,
            .execution_order = undefined,
            .dirty = undefined,
            .fixed_dt = 1.0 / 60.0,
            .max_fixed_steps = 8,
            .accumulator = 0.0,
            .render_extract_enabled = false,
            .io = null,
            .batch_plans = @splat(null),
        };
        for (&self.stages) |*s| s.* = .empty;
        for (&self.execution_order) |*o| o.* = .empty;
        for (&self.dirty) |*d| d.* = false;
        return self;
    }

    fn dupeStringSlice(allocator: std.mem.Allocator, src: []const []const u8) ![]const []const u8 {
        if (src.len == 0) return &.{};
        const out = try allocator.alloc([]const u8, src.len);
        var initialized: usize = 0;
        errdefer {
            for (out[0..initialized]) |s| allocator.free(s);
            allocator.free(out);
        }
        for (src, 0..) |s, i| {
            out[i] = try allocator.dupe(u8, s);
            initialized += 1;
        }
        return out;
    }

    fn freeStringSlice(allocator: std.mem.Allocator, slice: []const []const u8) void {
        if (slice.len == 0) return;
        for (slice) |s| allocator.free(s);
        allocator.free(slice);
    }

    pub fn deinit(self: *Scheduler) void {
        for (&self.batch_plans) |*p| {
            if (p.*) |*plan| plan.deinit();
            p.* = null;
        }
        for (0..Stage.count) |i| {
            for (self.stages[i].items) |sys| {
                self.allocator.free(sys.name);
                freeStringSlice(self.allocator, sys.reads);
                freeStringSlice(self.allocator, sys.writes);
                freeStringSlice(self.allocator, sys.before);
                freeStringSlice(self.allocator, sys.after);
            }
            self.stages[i].deinit(self.allocator);
            self.execution_order[i].deinit(self.allocator);
        }
    }

    pub fn addSystem(self: *Scheduler, desc: SystemDescriptor) !void {
        const s_idx = @intFromEnum(desc.stage);
        for (self.stages[s_idx].items) |existing| {
            if (std.mem.eql(u8, existing.name, desc.name)) {
                return error.DuplicateSystem;
            }
        }
        const name_copy = try self.allocator.dupe(u8, desc.name);
        errdefer self.allocator.free(name_copy);

        const reads_copy = try dupeStringSlice(self.allocator, desc.reads);
        errdefer freeStringSlice(self.allocator, reads_copy);
        const writes_copy = try dupeStringSlice(self.allocator, desc.writes);
        errdefer freeStringSlice(self.allocator, writes_copy);
        const before_copy = try dupeStringSlice(self.allocator, desc.before);
        errdefer freeStringSlice(self.allocator, before_copy);
        const after_copy = try dupeStringSlice(self.allocator, desc.after);
        errdefer freeStringSlice(self.allocator, after_copy);

        try self.stages[s_idx].append(self.allocator, .{
            .name = name_copy,
            .stage = desc.stage,
            .run = desc.run,
            .run_if = desc.run_if,
            .reads = reads_copy,
            .writes = writes_copy,
            .before = before_copy,
            .after = after_copy,
            .exclusive = desc.exclusive,
            .thread_affinity = desc.thread_affinity,
        });
        self.dirty[s_idx] = true;
    }

    pub fn buildStageSchedule(self: *Scheduler, stage: Stage) !void {
        const s_idx = @intFromEnum(stage);
        const systems = self.stages[s_idx].items;
        const n = systems.len;

        self.execution_order[s_idx].clearRetainingCapacity();
        if (n == 0) {
            self.dirty[s_idx] = false;
            return;
        }

        // Adjacency matrix / edges: u -> v means u runs before v
        var adj = try self.allocator.alloc(std.ArrayList(usize), n);
        defer {
            for (adj) |*list| list.deinit(self.allocator);
            self.allocator.free(adj);
        }
        for (adj) |*list| list.* = .empty;

        var indegree = try self.allocator.alloc(usize, n);
        defer self.allocator.free(indegree);
        @memset(indegree, 0);

        for (systems, 0..) |sys, i| {
            for (sys.before) |target_name| {
                if (std.mem.eql(u8, target_name, sys.name)) return error.InvalidSelfDependency;
                var found = false;
                for (systems, 0..) |other, j| {
                    if (i != j and std.mem.eql(u8, other.name, target_name)) {
                        try adj[i].append(self.allocator, j);
                        indegree[j] += 1;
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    for (0..Stage.count) |other_stage| {
                        if (other_stage == s_idx) continue;
                        for (self.stages[other_stage].items) |other| {
                            if (std.mem.eql(u8, other.name, target_name)) {
                                return error.InvalidCrossStageDependency;
                            }
                        }
                    }
                    return error.UnknownSystemDependency;
                }
            }
            for (sys.after) |dep_name| {
                if (std.mem.eql(u8, dep_name, sys.name)) return error.InvalidSelfDependency;
                var found = false;
                for (systems, 0..) |other, j| {
                    if (i != j and std.mem.eql(u8, other.name, dep_name)) {
                        try adj[j].append(self.allocator, i);
                        indegree[i] += 1;
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    for (0..Stage.count) |other_stage| {
                        if (other_stage == s_idx) continue;
                        for (self.stages[other_stage].items) |other| {
                            if (std.mem.eql(u8, other.name, dep_name)) {
                                return error.InvalidCrossStageDependency;
                            }
                        }
                    }
                    return error.UnknownSystemDependency;
                }
            }
        }

        // Kahn's algorithm preserving insertion order for zero-indegree nodes
        var visited = try self.allocator.alloc(bool, n);
        defer self.allocator.free(visited);
        @memset(visited, false);

        var processed: usize = 0;
        while (processed < n) {
            var picked: ?usize = null;
            for (0..n) |i| {
                if (!visited[i] and indegree[i] == 0) {
                    picked = i;
                    break;
                }
            }
            const u = picked orelse return error.DependencyCycle;
            visited[u] = true;
            try self.execution_order[s_idx].append(self.allocator, u);
            processed += 1;

            for (adj[u].items) |v| {
                indegree[v] -= 1;
            }
        }

        self.dirty[s_idx] = false;
    }

    pub fn buildAll(self: *Scheduler) !void {
        for (0..Stage.count) |i| {
            try self.buildStageSchedule(@enumFromInt(i));
        }
    }

    pub fn hasWriteConflict(a: SystemDescriptor, b: SystemDescriptor) bool {
        if (a.exclusive or b.exclusive) return true;
        for (a.writes) |wa| {
            for (b.writes) |wb| {
                if (std.mem.eql(u8, wa, wb)) return true;
            }
            for (b.reads) |rb| {
                if (std.mem.eql(u8, wa, rb)) return true;
            }
        }
        for (b.writes) |wb| {
            for (a.reads) |ra| {
                if (std.mem.eql(u8, wb, ra)) return true;
            }
        }
        return false;
    }

    /// Execution order of a stage grouped into batches whose members have no read/write conflicts
    /// and no ordering edges between them, so each batch could run concurrently and still produce
    /// the serial result. Batches are contiguous slices of the serial order, which keeps serial
    /// execution a valid fallback. See `parallelBatches`.
    pub const BatchPlan = struct {
        allocator: std.mem.Allocator,
        /// System indices in serial execution order.
        order: []usize,
        /// Exclusive end offset of each batch within `order`.
        batch_ends: []usize,

        pub fn deinit(self: *BatchPlan) void {
            self.allocator.free(self.order);
            self.allocator.free(self.batch_ends);
        }

        pub fn batchCount(self: *const BatchPlan) usize {
            return self.batch_ends.len;
        }

        /// System indices (into the stage's system list) of batch `i`.
        pub fn batch(self: *const BatchPlan, i: usize) []const usize {
            const start = if (i == 0) 0 else self.batch_ends[i - 1];
            return self.order[start..self.batch_ends[i]];
        }
    };

    fn asDescriptor(sys: StoredSystem) SystemDescriptor {
        return .{
            .name = sys.name,
            .stage = sys.stage,
            .run = sys.run,
            .reads = sys.reads,
            .writes = sys.writes,
            .before = sys.before,
            .after = sys.after,
            .exclusive = sys.exclusive,
            .thread_affinity = sys.thread_affinity,
        };
    }

    fn hasOrderEdge(a: StoredSystem, b: StoredSystem) bool {
        for (a.before) |n| if (std.mem.eql(u8, n, b.name)) return true;
        for (b.after) |n| if (std.mem.eql(u8, n, a.name)) return true;
        for (b.before) |n| if (std.mem.eql(u8, n, a.name)) return true;
        for (a.after) |n| if (std.mem.eql(u8, n, b.name)) return true;
        return false;
    }

    /// Plans safe concurrency for `stage` (building the schedule first if needed). This is analysis
    /// only: `runStage` still executes serially until a worker pool consumes the plan.
    pub fn parallelBatches(self: *Scheduler, stage: Stage) !BatchPlan {
        const s_idx = @intFromEnum(stage);
        if (self.dirty[s_idx]) try self.buildStageSchedule(stage);
        const systems = self.stages[s_idx].items;
        const order = try self.allocator.dupe(usize, self.execution_order[s_idx].items);
        errdefer self.allocator.free(order);
        var ends: std.ArrayList(usize) = .empty;
        errdefer ends.deinit(self.allocator);

        var batch_start: usize = 0;
        for (order, 0..) |sys_idx, pos| {
            var fits = true;
            for (order[batch_start..pos]) |member| {
                if (hasWriteConflict(asDescriptor(systems[member]), asDescriptor(systems[sys_idx])) or
                    hasOrderEdge(systems[member], systems[sys_idx]))
                {
                    fits = false;
                    break;
                }
            }
            if (!fits) {
                try ends.append(self.allocator, pos);
                batch_start = pos;
            }
        }
        if (order.len > 0) try ends.append(self.allocator, order.len);
        return .{ .allocator = self.allocator, .order = order, .batch_ends = try ends.toOwnedSlice(self.allocator) };
    }

    /// Snapshot of per-stage system counts, used to roll back systems added by a failed module.
    pub const Checkpoint = [Stage.count]usize;

    pub fn checkpoint(self: *const Scheduler) Checkpoint {
        var cp: Checkpoint = undefined;
        for (0..Stage.count) |i| cp[i] = self.stages[i].items.len;
        return cp;
    }

    /// Removes every system registered after `cp` was taken and marks affected stages for rebuild.
    pub fn rollbackTo(self: *Scheduler, cp: Checkpoint) void {
        for (0..Stage.count) |i| {
            while (self.stages[i].items.len > cp[i]) {
                const sys = self.stages[i].pop().?;
                self.allocator.free(sys.name);
                freeStringSlice(self.allocator, sys.reads);
                freeStringSlice(self.allocator, sys.writes);
                freeStringSlice(self.allocator, sys.before);
                freeStringSlice(self.allocator, sys.after);
                self.dirty[i] = true;
            }
        }
    }

    /// Rejects non-finite or non-positive fixed timesteps before they can poison the accumulator.
    fn validateFixedTimestep(self: *const Scheduler) !void {
        if (!std.math.isFinite(self.fixed_dt) or self.fixed_dt <= 0.0) return error.InvalidFixedTimestep;
    }

    /// Enables (non-null) or disables (null) concurrent execution of eligible systems on `io`'s
    /// thread pool (for example a `std.Io.Threaded`). Results are identical to serial execution as
    /// long as every system truthfully declares its `reads`/`writes` and parallel systems only
    /// touch the world through queries, `get`, and their own `CommandBuffer` (structural mutation
    /// during a parallel phase fails with `error.MutationDuringParallelPhase`). `ctx.events`,
    /// `ctx.diagnostics`, and resources are not synchronized: parallel systems must not share them.
    pub fn setParallel(self: *Scheduler, io: ?std.Io) void {
        self.io = io;
    }

    fn dropBatchPlan(self: *Scheduler, s_idx: usize) void {
        if (self.batch_plans[s_idx]) |*p| p.deinit();
        self.batch_plans[s_idx] = null;
    }

    fn isParallelEligible(sys: StoredSystem) bool {
        return !sys.exclusive and (sys.thread_affinity == .worker or sys.thread_affinity == .any);
    }

    /// Runs one system serially with its own change-detection tick.
    fn runOne(ctx: *SystemContext, sys: *StoredSystem) !void {
        if (sys.run_if) |cond| {
            if (!cond(ctx)) return;
        }
        // Each system gets its own tick so it sees changes made by others since it last ran,
        // but not its own writes from that run.
        ctx.world.advanceTick();
        ctx.world.query_since = sys.last_run_tick;
        const run_tick = ctx.world.tick;
        ctx.tick = run_tick;
        ctx.query_since = sys.last_run_tick;
        try sys.run(ctx);
        sys.last_run_tick = run_tick;
    }

    fn runTask(run: SystemFn, c: *SystemContext, err: *?anyerror) void {
        run(c) catch |e| {
            err.* = e;
        };
    }

    /// Walks the stage's batches; consecutive eligible systems inside a batch run concurrently, all
    /// others run serially in their original position.
    fn runStageParallel(self: *Scheduler, stage: Stage, ctx: *SystemContext) !void {
        const s_idx = @intFromEnum(stage);
        if (self.batch_plans[s_idx] == null) self.batch_plans[s_idx] = try self.parallelBatches(stage);
        const plan = &self.batch_plans[s_idx].?;
        const systems = self.stages[s_idx].items;
        for (0..plan.batchCount()) |b| {
            const members = plan.batch(b);
            var i: usize = 0;
            while (i < members.len) {
                var j = i;
                while (j < members.len and isParallelEligible(systems[members[j]])) j += 1;
                if (j - i >= 2) {
                    try self.runParallelRun(members[i..j], systems, ctx);
                    i = j;
                } else {
                    try runOne(ctx, &systems[members[i]]);
                    i += 1;
                }
            }
        }
    }

    fn runParallelRun(self: *Scheduler, idxs: []const usize, systems: []StoredSystem, ctx: *SystemContext) !void {
        const io = self.io.?;
        const n = idxs.len;
        const ctxs = try self.allocator.alloc(SystemContext, n);
        defer self.allocator.free(ctxs);
        const bufs = try self.allocator.alloc(commands_mod.CommandBuffer, n);
        defer self.allocator.free(bufs);
        const errs = try self.allocator.alloc(?anyerror, n);
        defer self.allocator.free(errs);
        const ticks = try self.allocator.alloc(u64, n);
        defer self.allocator.free(ticks);
        const active = try self.allocator.alloc(bool, n);
        defer self.allocator.free(active);

        var made: usize = 0;
        defer for (bufs[0..made]) |*bf| bf.deinit();
        for (idxs, 0..) |sys_idx, k| {
            active[k] = if (systems[sys_idx].run_if) |cond| cond(ctx) else true;
            if (!active[k]) {
                errs[k] = null;
                continue;
            }
            ctx.world.advanceTick();
            ticks[k] = ctx.world.tick;
            bufs[k] = commands_mod.CommandBuffer.init(self.allocator);
            made += 1;
            errs[k] = null;
            ctxs[k] = ctx.*;
            ctxs[k].commands = &bufs[k];
            ctxs[k].tick = ticks[k];
            ctxs[k].query_since = systems[sys_idx].last_run_tick;
        }

        @atomicStore(bool, &ctx.world.parallel_phase, true, .release);
        var group: std.Io.Group = .init;
        for (idxs, 0..) |sys_idx, k| {
            if (!active[k]) continue;
            group.async(io, runTask, .{ systems[sys_idx].run, &ctxs[k], &errs[k] });
        }
        const awaited = group.await(io);
        @atomicStore(bool, &ctx.world.parallel_phase, false, .release);
        awaited catch return error.Canceled;

        // Deterministic outcome: the first failing system in schedule order wins; commands are
        // merged in schedule order, so results never depend on thread timing.
        for (errs) |e| if (e) |err| return err;
        for (idxs, 0..) |sys_idx, k| {
            if (!active[k]) continue;
            systems[sys_idx].last_run_tick = ticks[k];
            try ctx.commands.append(&ctxs[k].commands.*);
        }
    }

    pub fn runStage(self: *Scheduler, stage: Stage, ctx: *SystemContext) !void {
        if (stage == .render_extract and !self.render_extract_enabled) return;

        const s_idx = @intFromEnum(stage);
        const was_dirty = self.dirty[s_idx];
        if (was_dirty) {
            try self.buildStageSchedule(stage);
        }

        {
            errdefer ctx.commands.clear();
            // Outside systems, queries see every change.
            defer ctx.world.query_since = 0;
            defer {
                ctx.tick = 0;
                ctx.query_since = 0;
            }
            if (was_dirty) self.dropBatchPlan(s_idx);
            if (self.io != null) {
                try self.runStageParallel(stage, ctx);
            } else {
                const systems = self.stages[s_idx].items;
                for (self.execution_order[s_idx].items) |sys_idx| try runOne(ctx, &systems[sys_idx]);
            }
        }
        // Give out-of-system writes and the command flush fresh ticks of their own.
        ctx.world.advanceTick();
        try ctx.commands.apply(ctx.world, ctx.events);
        ctx.world.advanceTick();
        // Removal events older than every system's last run can no longer be observed.
        var oldest: u64 = std.math.maxInt(u64);
        var any = false;
        for (self.stages) |stage_systems| {
            for (stage_systems.items) |sys| {
                oldest = @min(oldest, sys.last_run_tick);
                any = true;
            }
        }
        if (any) ctx.world.pruneRemoved(oldest);
    }

    /// Executes exactly one `.fixed_update` tick deterministically (no accumulator)
    /// and drains any events emitted during the tick.
    pub fn stepFixedTick(self: *Scheduler, ctx: *SystemContext) !void {
        try self.validateFixedTimestep();
        ctx.dt = @floatCast(self.fixed_dt);
        ctx.fixed_dt = @floatCast(self.fixed_dt);
        try self.runStage(.fixed_update, ctx);
        _ = ctx.events.drain();
    }

    pub fn stepFrame(self: *Scheduler, frame_dt: f64, ctx: *SystemContext) !u32 {
        if (!std.math.isFinite(frame_dt) or frame_dt < 0.0) {
            return error.InvalidDeltaTime;
        }
        try self.validateFixedTimestep();
        ctx.dt = @floatCast(frame_dt);
        ctx.fixed_dt = @floatCast(self.fixed_dt);

        // A failing stage aborts the frame; drop accumulated time so a retry cannot replay it.
        errdefer self.accumulator = 0.0;
        try self.runStage(.pre_update, ctx);

        self.accumulator += frame_dt;
        var fixed_steps: u32 = 0;
        ctx.dt = @floatCast(self.fixed_dt);
        while (self.accumulator >= self.fixed_dt and fixed_steps < self.max_fixed_steps) {
            try self.runStage(.fixed_update, ctx);
            self.accumulator -= self.fixed_dt;
            fixed_steps += 1;
        }
        if (fixed_steps == self.max_fixed_steps and self.accumulator >= self.fixed_dt) {
            // Prevent spiral of death by clamping excess accumulator
            self.accumulator = 0.0;
        }

        ctx.dt = @floatCast(frame_dt);
        try self.runStage(.update, ctx);
        try self.runStage(.post_update, ctx);
        if (self.render_extract_enabled) {
            try self.runStage(.render_extract, ctx);
        }
        _ = ctx.events.drain();
        return fixed_steps;
    }
};
