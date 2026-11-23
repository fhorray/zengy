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

const std = @import("std");
const world_mod = @import("world.zig");
const commands_mod = @import("commands.zig");
const events_mod = @import("events.zig");
const resources_mod = @import("resources.zig");
const diagnostics_mod = @import("diagnostics.zig");

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

pub const ThreadAffinity = enum {
    main,
    render,
    worker,
    any,
};

pub const SystemContext = struct {
    world: *world_mod.World,
    commands: *commands_mod.CommandBuffer,
    events: *events_mod.EventBus,
    resources: *resources_mod.ResourceRegistry,
    diagnostics: *diagnostics_mod.Diagnostics,
    dt: f32,
    fixed_dt: f32,

    pub fn deltaSeconds(self: *const SystemContext) f32 {
        return self.dt;
    }

    pub fn fixedDeltaSeconds(self: *const SystemContext) f32 {
        return self.fixed_dt;
    }

    pub fn query(self: *SystemContext, comptime spec: anytype) !world_mod.Query(spec) {
        return self.world.query(spec);
    }
};

pub const SystemFn = *const fn (ctx: *SystemContext) anyerror!void;

pub const SystemDescriptor = struct {
    name: []const u8,
    stage: Stage = .update,
    run: SystemFn,
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
    reads: []const []const u8,
    writes: []const []const u8,
    before: []const []const u8,
    after: []const []const u8,
    exclusive: bool,
    thread_affinity: ThreadAffinity,
};

pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    stages: [Stage.count]std.ArrayList(StoredSystem),
    execution_order: [Stage.count]std.ArrayList(usize),
    dirty: [Stage.count]bool,
    fixed_dt: f64,
    max_fixed_steps: u32,
    accumulator: f64,
    render_extract_enabled: bool,

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
        };
        for (&self.stages) |*s| s.* = .empty;
        for (&self.execution_order) |*o| o.* = .empty;
        for (&self.dirty) |*d| d.* = false;
        return self;
    }

    pub fn deinit(self: *Scheduler) void {
        for (0..Stage.count) |i| {
            for (self.stages[i].items) |sys| {
                self.allocator.free(sys.name);
            }
            self.stages[i].deinit(self.allocator);
            self.execution_order[i].deinit(self.allocator);
        }
    }

    pub fn addSystem(self: *Scheduler, desc: SystemDescriptor) !void {
        const s_idx = @intFromEnum(desc.stage);
        const name_copy = try self.allocator.dupe(u8, desc.name);
        errdefer self.allocator.free(name_copy);

        try self.stages[s_idx].append(self.allocator, .{
            .name = name_copy,
            .stage = desc.stage,
            .run = desc.run,
            .reads = desc.reads,
            .writes = desc.writes,
            .before = desc.before,
            .after = desc.after,
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
                for (systems, 0..) |other, j| {
                    if (i != j and std.mem.eql(u8, other.name, target_name)) {
                        try adj[i].append(self.allocator, j);
                        indegree[j] += 1;
                    }
                }
            }
            for (sys.after) |dep_name| {
                for (systems, 0..) |other, j| {
                    if (i != j and std.mem.eql(u8, other.name, dep_name)) {
                        try adj[j].append(self.allocator, i);
                        indegree[i] += 1;
                    }
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

    pub fn runStage(self: *Scheduler, stage: Stage, ctx: *SystemContext) !void {
        if (stage == .render_extract and !self.render_extract_enabled) return;

        const s_idx = @intFromEnum(stage);
        if (self.dirty[s_idx]) {
            try self.buildStageSchedule(stage);
        }

        const systems = self.stages[s_idx].items;
        for (self.execution_order[s_idx].items) |sys_idx| {
            try systems[sys_idx].run(ctx);
        }
        try ctx.commands.apply(ctx.world, ctx.events);
    }

    /// Executes exactly one `.fixed_update` tick deterministically (no accumulator)
    /// and drains any events emitted during the tick.
    pub fn stepFixedTick(self: *Scheduler, ctx: *SystemContext) !void {
        ctx.dt = @floatCast(self.fixed_dt);
        ctx.fixed_dt = @floatCast(self.fixed_dt);
        try self.runStage(.fixed_update, ctx);
        _ = ctx.events.drain();
    }

    pub fn stepFrame(self: *Scheduler, frame_dt: f64, ctx: *SystemContext) !u32 {
        ctx.dt = @floatCast(frame_dt);
        ctx.fixed_dt = @floatCast(self.fixed_dt);

        try self.runStage(.pre_update, ctx);

        self.accumulator += frame_dt;
        var fixed_steps: u32 = 0;
        while (self.accumulator >= self.fixed_dt and fixed_steps < self.max_fixed_steps) {
            try self.runStage(.fixed_update, ctx);
            self.accumulator -= self.fixed_dt;
            fixed_steps += 1;
        }
        if (fixed_steps == self.max_fixed_steps and self.accumulator > self.fixed_dt) {
            // Prevent spiral of death by clamping excess accumulator
            self.accumulator = 0.0;
        }

        try self.runStage(.update, ctx);
        try self.runStage(.post_update, ctx);
        if (self.render_extract_enabled) {
            try self.runStage(.render_extract, ctx);
        }
        _ = ctx.events.drain();
        return fixed_steps;
    }
};
