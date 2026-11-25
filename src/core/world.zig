//! Generational ECS World Facade (`core/world`).
//!
//! Provides the public entity-component-system contract (`World`, `EntityHandle`,
//! `EntityGuid`, `WorldId`, `ComponentTypeId`, `Query`) without exposing any
//! third-party ECS types or raw internal pointers (ADR-007).
//!
//! Memory & Safety Guarantees:
//! - `EntityHandle` packs `(index: u32, generation: u32)`; despawning bumps generation
//!   so stale handles are deterministically rejected by `isAlive()`, `get()`, and `set()`.
//! - Each component type is stored in a dense sparse-set `ComponentPool` whose backing is
//!   `max_component_alignment` (64) aligned; larger or non-power-of-two alignments are rejected.
//! - A per-entity membership bitset records which pools hold the entity, so `despawn`
//!   visits only the pools actually present instead of every registered pool.
//! - Change tracking is opt-in per component (`enableChangeTracking`); `Query` filters
//!   `.added`/`.changed` compare against the running system's last-run tick, `.without`
//!   excludes, and `.optional` exposes `Row.optional(T)`.
//! - Pointers from `get`/`getRaw`/`Query` rows are valid only until the next structural
//!   mutation (`spawn`, `despawn`, `set` of a new component, `remove`, `CommandBuffer.apply`);
//!   never store them across stages. Mutable access marks tracked components as changed.
//! - The top 8 bits of a handle's generation carry `WorldId.index & 0xFF`, so a handle from another
//!   World is rejected by `isAlive`/`get`/`set` (worlds sharing those 8 bits cannot tell each other apart).
//! - `removedSince(T)` reports removals/despawns of tracked components per system; the scheduler prunes
//!   the log once every system has seen it.
//! - `active_queries` tracks open iterators and rejects structural mutations (`spawn`,
//!   `despawn`, `set`, `remove`) while a query is active; use `CommandBuffer` instead.

const std = @import("std");
const resources = @import("resources.zig");

/// Generational identifier distinguishing separate `World` instances.
pub const WorldId = packed struct(u64) {
    index: u32,
    generation: u32,
};

/// Generational 64-bit entity handle; `generation == 0` marks invalid/pending handles.
pub const EntityHandle = packed struct(u64) {
    index: u32,
    generation: u32,

    pub const invalid: EntityHandle = .{
        .index = std.math.maxInt(u32),
        .generation = 0,
    };

    pub fn isValid(self: EntityHandle) bool {
        return self.index != std.math.maxInt(u32) and self.generation != 0;
    }

    pub fn toU64(self: EntityHandle) u64 {
        return @bitCast(self);
    }

    pub fn fromU64(raw: u64) EntityHandle {
        return @bitCast(raw);
    }
};

/// Persistent 128-bit entity identifier preserved across scene snapshots.
pub const EntityGuid = u128;
/// Deterministic hash identifier for a component type.
pub const ComponentTypeId = u64;

const ABSENT_INDEX: u32 = std.math.maxInt(u32);

/// Largest component alignment supported by pool backing storage (bytes).
pub const max_component_alignment: usize = 64;

/// One logged component removal (see `World.removedSince`). `entity` is stale by now.
pub const RemovedRecord = struct {
    entity: EntityHandle,
    tick: u64,
};

/// Schema metadata used to register and validate component pools (name, size, alignment, version).
pub const ComponentDescriptor = struct {
    name: []const u8,
    size: usize,
    alignment: usize = 16,
    schema_version: u32 = 1,
};

const ComponentPool = struct {
    type_id: ComponentTypeId,
    name: []const u8,
    elem_size: usize,
    elem_align: usize,
    schema_version: u32,
    stride: usize,
    /// Dense index of this pool in `World.pool_list`; also its membership bit position.
    pool_index: u32 = 0,
    sparse: std.ArrayList(u32),
    dense_entities: std.ArrayList(EntityHandle),
    dense_bytes: std.array_list.Aligned(u8, .@"64"),
    /// Opt-in change tracking (`World.enableChangeTracking`): per-dense-slot tick of the last
    /// add / last mutation. Empty (and unused) while `tracked` is false.
    tracked: bool = false,
    added_ticks: std.ArrayList(u64) = .empty,
    changed_ticks: std.ArrayList(u64) = .empty,
    /// Components removed (or despawned) while tracked; consumed through `World.removedSince`.
    removed_log: std.ArrayList(RemovedRecord) = .empty,

    fn init(
        allocator: std.mem.Allocator,
        type_id: ComponentTypeId,
        name: []const u8,
        elem_size: usize,
        elem_align: usize,
        schema_version: u32,
    ) !ComponentPool {
        const safe_align = if (elem_align == 0) 1 else elem_align;
        const stride = if (elem_size == 0) 0 else blk: {
            const sum = std.math.add(usize, elem_size, safe_align - 1) catch return error.ComponentSizeOverflow;
            break :blk sum & ~(safe_align - 1);
        };
        const name_copy = try allocator.dupe(u8, name);
        return .{
            .type_id = type_id,
            .name = name_copy,
            .elem_size = elem_size,
            .elem_align = safe_align,
            .schema_version = schema_version,
            .stride = stride,
            .sparse = .empty,
            .dense_entities = .empty,
            .dense_bytes = .empty,
        };
    }

    fn deinit(self: *ComponentPool, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.sparse.deinit(allocator);
        self.dense_entities.deinit(allocator);
        self.dense_bytes.deinit(allocator);
        self.added_ticks.deinit(allocator);
        self.changed_ticks.deinit(allocator);
        self.removed_log.deinit(allocator);
    }

    /// Reserves room for one removal record so `remove` itself can never fail.
    fn reserveRemoval(self: *ComponentPool, allocator: std.mem.Allocator) !void {
        if (self.tracked) try self.removed_log.ensureUnusedCapacity(allocator, 1);
    }

    /// Starts tracking; components that already exist are stamped with tick 0 (never "new").
    fn enableTracking(self: *ComponentPool, allocator: std.mem.Allocator) !void {
        if (self.tracked) return;
        const n = self.dense_entities.items.len;
        try self.added_ticks.resize(allocator, n);
        errdefer self.added_ticks.clearRetainingCapacity();
        try self.changed_ticks.resize(allocator, n);
        @memset(self.added_ticks.items, 0);
        @memset(self.changed_ticks.items, 0);
        self.tracked = true;
    }

    /// Pre-allocates room for `extra` more components and for sparse index `max_entity_index`
    /// so the following `setBytes` calls cannot fail with OutOfMemory.
    fn reserve(self: *ComponentPool, allocator: std.mem.Allocator, extra: usize, max_entity_index: u32) !void {
        try self.ensureSparse(allocator, max_entity_index);
        const total = self.dense_entities.items.len + extra;
        try self.dense_entities.ensureTotalCapacity(allocator, total);
        if (self.stride > 0) try self.dense_bytes.ensureTotalCapacity(allocator, total * self.stride);
        if (self.tracked) {
            try self.added_ticks.ensureTotalCapacity(allocator, total);
            try self.changed_ticks.ensureTotalCapacity(allocator, total);
        }
    }

    fn ensureSparse(self: *ComponentPool, allocator: std.mem.Allocator, entity_index: u32) !void {
        const old_len = self.sparse.items.len;
        if (old_len <= entity_index) {
            const new_len = @as(usize, entity_index) + 1;
            try self.sparse.resize(allocator, new_len);
            @memset(self.sparse.items[old_len..new_len], ABSENT_INDEX);
        }
    }

    fn has(self: *const ComponentPool, entity: EntityHandle) bool {
        if (entity.index >= self.sparse.items.len) return false;
        const dense_idx = self.sparse.items[entity.index];
        if (dense_idx == ABSENT_INDEX) return false;
        return self.dense_entities.items[dense_idx].generation == entity.generation;
    }

    fn getBytes(self: *ComponentPool, entity: EntityHandle) ?[]u8 {
        if (!self.has(entity)) return null;
        const dense_idx = self.sparse.items[entity.index];
        if (self.stride == 0) return &.{};
        const start = @as(usize, dense_idx) * self.stride;
        return self.dense_bytes.items[start .. start + self.elem_size];
    }

    pub fn getBytesConst(self: *const ComponentPool, entity: EntityHandle) ?[]const u8 {
        if (!self.has(entity)) return null;
        const dense_idx = self.sparse.items[entity.index];
        if (self.stride == 0) return &.{};
        const start = @as(usize, dense_idx) * self.stride;
        return self.dense_bytes.items[start .. start + self.elem_size];
    }

    fn setBytes(self: *ComponentPool, allocator: std.mem.Allocator, entity: EntityHandle, bytes: []const u8, tick: u64) !void {
        if (bytes.len != self.elem_size) return error.ComponentSizeMismatch;
        try self.ensureSparse(allocator, entity.index);

        const existing = self.sparse.items[entity.index];
        if (existing != ABSENT_INDEX and self.dense_entities.items[existing].generation == entity.generation) {
            if (self.stride > 0) {
                const start = @as(usize, existing) * self.stride;
                @memcpy(self.dense_bytes.items[start .. start + self.elem_size], bytes);
            }
            if (self.tracked) self.changed_ticks.items[existing] = tick;
            return;
        }

        if (self.tracked) {
            try self.added_ticks.ensureUnusedCapacity(allocator, 1);
            try self.changed_ticks.ensureUnusedCapacity(allocator, 1);
        }
        const new_dense: u32 = @intCast(self.dense_entities.items.len);
        try self.dense_entities.append(allocator, entity);
        errdefer _ = self.dense_entities.pop();

        if (self.stride > 0) {
            const old_len = self.dense_bytes.items.len;
            try self.dense_bytes.resize(allocator, old_len + self.stride);
            @memset(self.dense_bytes.items[old_len .. old_len + self.stride], 0);
            @memcpy(self.dense_bytes.items[old_len .. old_len + self.elem_size], bytes);
        }

        if (self.tracked) {
            self.added_ticks.appendAssumeCapacity(tick);
            self.changed_ticks.appendAssumeCapacity(tick);
        }
        self.sparse.items[entity.index] = new_dense;
    }

    /// Removes `entity`'s component. For tracked pools a record is logged at `tick`; callers must
    /// have called `reserveRemoval` first.
    pub fn remove(self: *ComponentPool, entity: EntityHandle, tick: u64) bool {
        if (!self.has(entity)) return false;
        if (self.tracked) self.removed_log.appendAssumeCapacity(.{ .entity = entity, .tick = tick });
        const dense_idx = self.sparse.items[entity.index];
        const last_idx: u32 = @intCast(self.dense_entities.items.len - 1);

        if (dense_idx != last_idx) {
            const last_entity = self.dense_entities.items[last_idx];
            self.dense_entities.items[dense_idx] = last_entity;
            self.sparse.items[last_entity.index] = dense_idx;

            if (self.stride > 0) {
                const dst_start = @as(usize, dense_idx) * self.stride;
                const src_start = @as(usize, last_idx) * self.stride;
                @memcpy(
                    self.dense_bytes.items[dst_start .. dst_start + self.stride],
                    self.dense_bytes.items[src_start .. src_start + self.stride],
                );
            }
        }

        _ = self.dense_entities.pop();
        if (self.tracked) {
            _ = self.added_ticks.swapRemove(dense_idx);
            _ = self.changed_ticks.swapRemove(dense_idx);
        }
        if (self.stride > 0) {
            self.dense_bytes.items.len -= self.stride;
        }
        self.sparse.items[entity.index] = ABSENT_INDEX;
        return true;
    }
};

/// Generational ECS container owning entity lifecycles and sparse-set component pools.
pub const World = struct {
    allocator: std.mem.Allocator,
    id: WorldId,
    generations: std.ArrayList(u32),
    alive_flags: std.ArrayList(bool),
    free_indices: std.ArrayList(u32),
    guids: std.ArrayList(EntityGuid),
    next_guid: u128,
    pools: std.AutoHashMapUnmanaged(ComponentTypeId, *ComponentPool),
    /// Pools in registration order; index == `ComponentPool.pool_index`.
    pool_list: std.ArrayList(*ComponentPool),
    /// Flat per-entity membership bitset: `membership_words` u64 words per entity slot.
    membership: std.ArrayList(u64),
    membership_words: usize,
    name_to_type: std.StringHashMapUnmanaged(ComponentTypeId),
    active_queries: u32,
    entity_count: usize,
    /// True while the scheduler runs systems concurrently: every mutating `World` API (including
    /// `set` over existing components) fails with `error.MutationDuringParallelPhase`, so parallel
    /// systems can only read, write through query rows / `get`, and record `CommandBuffer` commands.
    parallel_phase: bool = false,
    /// High 8 bits of every generation this world hands out (`WorldId.index & 0xFF`), so a handle
    /// minted by another world never validates here. World index 0 uses tag 0, which keeps its
    /// handles identical to untagged ones. Worlds whose ids differ only above 8 bits share a tag.
    gen_tag: u32,
    /// Monotonic change-detection clock; see `advanceTick`.
    tick: u64 = 1,
    /// Tick after which `.added`/`.changed` query filters match. The scheduler sets this to the
    /// running system's previous run tick; outside systems it is 0 (everything counts as new).
    query_since: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, id: WorldId) World {
        return .{
            .allocator = allocator,
            .id = id,
            .generations = .empty,
            .alive_flags = .empty,
            .free_indices = .empty,
            .guids = .empty,
            .next_guid = 1,
            .pools = .empty,
            .pool_list = .empty,
            .membership = .empty,
            .membership_words = 1,
            .name_to_type = .empty,
            .active_queries = 0,
            .entity_count = 0,
            .gen_tag = (id.index & 0xFF) << 24,
        };
    }

    pub fn deinit(self: *World) void {
        var it = self.pools.valueIterator();
        while (it.next()) |pool_ptr| {
            pool_ptr.*.deinit(self.allocator);
            self.allocator.destroy(pool_ptr.*);
        }
        self.pools.deinit(self.allocator);
        self.pool_list.deinit(self.allocator);
        self.membership.deinit(self.allocator);

        var name_it = self.name_to_type.keyIterator();
        while (name_it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.name_to_type.deinit(self.allocator);

        self.generations.deinit(self.allocator);
        self.alive_flags.deinit(self.allocator);
        self.free_indices.deinit(self.allocator);
        self.guids.deinit(self.allocator);
    }

    /// Fails when a structural mutation is not allowed right now (open query or parallel phase).
    pub fn checkMutable(self: *const World) !void {
        if (@atomicLoad(u32, &self.active_queries, .acquire) > 0) return error.MutationDuringActiveQuery;
        if (@atomicLoad(bool, &self.parallel_phase, .acquire)) return error.MutationDuringParallelPhase;
    }

    /// Sets the high 64 bits of every `EntityGuid` this world generates, so GUIDs minted by
    /// different worlds, projects, or streamed cells never collide (`guid = namespace << 64 | seq`).
    /// Must be called before the first spawn (`error.WorldNotEmpty` otherwise).
    pub fn setGuidNamespace(self: *World, namespace: u64) !void {
        if (self.generations.items.len != 0) return error.WorldNotEmpty;
        self.next_guid = (@as(u128, namespace) << 64) | 1;
    }

    pub fn comptimeTypeId(comptime T: type) ComponentTypeId {
        return dynamicTypeId(@typeName(T));
    }

    pub fn dynamicTypeId(name: []const u8) ComponentTypeId {
        return std.hash.Wyhash.hash(0x9e3779b97f4a7c15, name);
    }

    pub fn registerComponent(self: *World, comptime T: type) !ComponentTypeId {
        return self.registerComponentDesc(.{
            .name = @typeName(T),
            .size = @sizeOf(T),
            .alignment = @alignOf(T),
            .schema_version = 1,
        });
    }

    pub fn registerComponentDesc(self: *World, desc: ComponentDescriptor) !ComponentTypeId {
        const tid = dynamicTypeId(desc.name);
        const safe_align = if (desc.alignment == 0) 1 else desc.alignment;
        if (!std.math.isPowerOfTwo(safe_align)) return error.InvalidComponentAlignment;
        if (safe_align > max_component_alignment) return error.UnsupportedComponentAlignment;
        if (self.pools.get(tid)) |existing| {
            if (!std.mem.eql(u8, existing.name, desc.name)) {
                return error.ComponentNameCollision;
            }
            if (existing.elem_size != desc.size or existing.elem_align != safe_align or existing.schema_version != desc.schema_version) {
                return error.ComponentLayoutMismatch;
            }
            return tid;
        }
        try self.checkMutable();

        const pool_ptr = try self.allocator.create(ComponentPool);
        errdefer self.allocator.destroy(pool_ptr);
        pool_ptr.* = try ComponentPool.init(self.allocator, tid, desc.name, desc.size, safe_align, desc.schema_version);
        errdefer pool_ptr.deinit(self.allocator);

        try self.pools.ensureUnusedCapacity(self.allocator, 1);
        try self.pool_list.ensureUnusedCapacity(self.allocator, 1);
        try self.name_to_type.ensureUnusedCapacity(self.allocator, 1);
        try self.growMembership(self.pool_list.items.len + 1);
        const key_copy = try self.allocator.dupe(u8, desc.name);

        pool_ptr.pool_index = @intCast(self.pool_list.items.len);
        self.pool_list.appendAssumeCapacity(pool_ptr);
        self.pools.putAssumeCapacity(tid, pool_ptr);
        self.name_to_type.putAssumeCapacity(key_copy, tid);
        return tid;
    }

    pub fn registerDynamicComponent(self: *World, name: []const u8, size: usize) !ComponentTypeId {
        return self.registerComponentDesc(.{
            .name = name,
            .size = size,
            .alignment = 16,
            .schema_version = 1,
        });
    }

    /// Widens the per-entity membership rows so `pool_count` bits fit; no-op when they already do.
    fn growMembership(self: *World, pool_count: usize) !void {
        const needed = @max(1, (pool_count + 63) / 64);
        if (needed <= self.membership_words) return;
        const slots = self.generations.items.len;
        var fresh: std.ArrayList(u64) = .empty;
        errdefer fresh.deinit(self.allocator);
        try fresh.resize(self.allocator, slots * needed);
        @memset(fresh.items, 0);
        for (0..slots) |i| {
            @memcpy(fresh.items[i * needed ..][0..self.membership_words], self.membership.items[i * self.membership_words ..][0..self.membership_words]);
        }
        self.membership.deinit(self.allocator);
        self.membership = fresh;
        self.membership_words = needed;
    }

    fn membershipRow(self: *World, entity_index: u32) []u64 {
        return self.membership.items[@as(usize, entity_index) * self.membership_words ..][0..self.membership_words];
    }

    fn markMember(self: *World, entity_index: u32, pool: *const ComponentPool) void {
        self.membershipRow(entity_index)[pool.pool_index / 64] |= @as(u64, 1) << @intCast(pool.pool_index % 64);
    }

    fn clearMember(self: *World, entity_index: u32, pool: *const ComponentPool) void {
        self.membershipRow(entity_index)[pool.pool_index / 64] &= ~(@as(u64, 1) << @intCast(pool.pool_index % 64));
    }

    /// Stores bytes for `entity` in `pool`, updating membership only after the pool mutation succeeded.
    fn storeBytes(self: *World, entity: EntityHandle, pool: *ComponentPool, bytes: []const u8) !void {
        const was_member = pool.has(entity);
        try pool.setBytes(self.allocator, entity, bytes, self.tick);
        if (!was_member) self.markMember(entity.index, pool);
    }

    /// Enables `.added`/`.changed` filtering for `T` (registering it if needed). Existing
    /// components are not reported as added. Costs 16 bytes per component of this type.
    pub fn enableChangeTracking(self: *World, comptime T: type) !void {
        const tid = try self.registerComponent(T);
        try self.enableChangeTrackingRaw(tid);
    }

    /// Type-id variant of `enableChangeTracking` for dynamically registered components.
    pub fn enableChangeTrackingRaw(self: *World, tid: ComponentTypeId) !void {
        try self.checkMutable();
        const pool = self.pools.get(tid) orelse return error.ComponentNotRegistered;
        try pool.enableTracking(self.allocator);
    }

    /// Advances the change clock. The scheduler calls this around every system run and command
    /// flush; call it manually when driving the world without a scheduler.
    pub fn advanceTick(self: *World) void {
        self.tick += 1;
    }

    /// Marks `T` on `entity` as changed at the current tick (for writes made through raw pointers
    /// obtained from `getConst`/queries). No-op for untracked components.
    pub fn markChanged(self: *World, entity: EntityHandle, comptime T: type) void {
        if (!self.isAlive(entity)) return;
        const pool = self.pools.get(comptimeTypeId(T)) orelse return;
        self.touch(pool, entity);
    }

    fn touch(self: *World, pool: *ComponentPool, entity: EntityHandle) void {
        if (!pool.tracked or !pool.has(entity)) return;
        pool.changed_ticks.items[pool.sparse.items[entity.index]] = self.tick;
    }

    /// Pre-allocates room for `extra` more components of type `tid` on entities up to slot
    /// `max_entity_index`, so subsequent `setRaw` calls for them cannot hit OutOfMemory.
    pub fn reserveComponentSlots(self: *World, tid: ComponentTypeId, extra: usize, max_entity_index: u32) !void {
        const pool = self.pools.get(tid) orelse return error.ComponentNotRegistered;
        try pool.reserve(self.allocator, extra, max_entity_index);
    }

    /// Pre-allocates the free list so `n` future despawns cannot hit OutOfMemory.
    pub fn reserveDespawns(self: *World, n: usize) !void {
        try self.free_indices.ensureUnusedCapacity(self.allocator, n);
    }

    /// Iterator over entities whose tracked component `T` was removed (or whose entity was
    /// despawned) after the current query threshold. Yields stale handles: use them as ids only.
    pub const RemovedIterator = struct {
        records: []const RemovedRecord,
        since: u64,
        pos: usize = 0,

        pub fn next(self: *RemovedIterator) ?EntityHandle {
            while (self.pos < self.records.len) {
                const r = self.records[self.pos];
                self.pos += 1;
                if (r.tick > self.since) return r.entity;
            }
            return null;
        }
    };

    /// Removal events for `T` since the running system last ran (all unpruned events outside
    /// systems). Requires `enableChangeTracking(T)`; untracked or unknown types yield nothing.
    pub fn removedSince(self: *const World, comptime T: type) RemovedIterator {
        const pool = self.pools.get(comptimeTypeId(T)) orelse return .{ .records = &.{}, .since = 0 };
        return .{ .records = pool.removed_log.items, .since = self.query_since };
    }

    /// Drops removal records at or before `tick`. The scheduler calls this with the oldest
    /// `last_run_tick` of all systems after each stage; call it yourself when driving a world
    /// without a scheduler, otherwise logs of tracked pools grow without bound.
    pub fn pruneRemoved(self: *World, tick: u64) void {
        for (self.pool_list.items) |pool| {
            if (!pool.tracked) continue;
            var kept: usize = 0;
            for (pool.removed_log.items) |r| {
                if (r.tick > tick) {
                    pool.removed_log.items[kept] = r;
                    kept += 1;
                }
            }
            pool.removed_log.shrinkRetainingCapacity(kept);
        }
    }

    pub fn spawn(self: *World) !EntityHandle {
        try self.checkMutable();

        if (self.free_indices.pop()) |idx| {
            const guid = self.next_guid;
            self.next_guid += 1;
            const gen = self.generations.items[idx];
            self.alive_flags.items[idx] = true;
            self.guids.items[idx] = guid;
            self.entity_count += 1;
            return .{ .index = idx, .generation = gen };
        }

        try self.generations.ensureUnusedCapacity(self.allocator, 1);
        try self.alive_flags.ensureUnusedCapacity(self.allocator, 1);
        try self.guids.ensureUnusedCapacity(self.allocator, 1);
        try self.membership.ensureUnusedCapacity(self.allocator, self.membership_words);

        const guid = self.next_guid;
        self.next_guid += 1;
        const idx: u32 = @intCast(self.generations.items.len);
        self.membership.appendNTimesAssumeCapacity(0, self.membership_words);
        self.generations.appendAssumeCapacity(self.gen_tag | 1);
        self.alive_flags.appendAssumeCapacity(true);
        self.guids.appendAssumeCapacity(guid);
        self.entity_count += 1;
        return .{ .index = idx, .generation = self.gen_tag | 1 };
    }

    pub fn despawn(self: *World, entity: EntityHandle) !bool {
        try self.checkMutable();
        if (!self.isAlive(entity)) return false;

        try self.free_indices.ensureUnusedCapacity(self.allocator, 1);

        // Visit only the pools that actually hold this entity. Reserve removal-log space in every
        // tracked pool first so the mutation below cannot fail half-way.
        const row = self.membershipRow(entity.index);
        for (row, 0..) |word, wi| {
            var bits = word;
            while (bits != 0) {
                const bit = @ctz(bits);
                bits &= bits - 1;
                try self.pool_list.items[wi * 64 + bit].reserveRemoval(self.allocator);
            }
        }
        for (row, 0..) |*word, wi| {
            var bits = word.*;
            while (bits != 0) {
                const bit = @ctz(bits);
                bits &= bits - 1;
                _ = self.pool_list.items[wi * 64 + bit].remove(entity, self.tick);
            }
            word.* = 0;
        }

        self.alive_flags.items[entity.index] = false;
        // Only the low 24 bits count; the world tag stays put.
        var low = (self.generations.items[entity.index] +% 1) & 0x00FF_FFFF;
        if (low == 0) low = 1;
        self.generations.items[entity.index] = self.gen_tag | low;
        self.free_indices.appendAssumeCapacity(entity.index);
        self.entity_count -= 1;
        return true;
    }

    pub fn isAlive(self: *const World, entity: EntityHandle) bool {
        if (!entity.isValid()) return false;
        if (entity.index >= self.generations.items.len) return false;
        return self.alive_flags.items[entity.index] and
            self.generations.items[entity.index] == entity.generation;
    }

    pub fn getGuid(self: *const World, entity: EntityHandle) ?EntityGuid {
        if (!self.isAlive(entity)) return null;
        return self.guids.items[entity.index];
    }

    /// Looks up a live entity by persistent `EntityGuid`. Linear scan; prefer handle-based
    /// access on hot paths. Returns null when the GUID is unused or the slot is dead.
    pub fn findByGuid(self: *const World, guid: EntityGuid) ?EntityHandle {
        for (self.guids.items, 0..) |g, idx| {
            if (g != guid) continue;
            if (idx >= self.alive_flags.items.len or !self.alive_flags.items[idx]) continue;
            return .{ .index = @intCast(idx), .generation = self.generations.items[idx] };
        }
        return null;
    }

    pub fn set(self: *World, entity: EntityHandle, comptime T: type, value: T) !void {
        try self.checkMutable();
        if (!self.isAlive(entity)) return error.InvalidEntity;

        const tid = try self.registerComponent(T);
        const pool = self.pools.get(tid).?;
        try self.storeBytes(entity, pool, std.mem.asBytes(&value));
    }

    pub fn setRaw(self: *World, entity: EntityHandle, tid: ComponentTypeId, bytes: []const u8) !void {
        try self.checkMutable();
        if (!self.isAlive(entity)) return error.InvalidEntity;

        const pool = self.pools.get(tid) orelse return error.ComponentNotRegistered;
        try self.storeBytes(entity, pool, bytes);
    }

    pub fn get(self: *World, entity: EntityHandle, comptime T: type) ?*T {
        if (!self.isAlive(entity)) return null;
        const pool = self.pools.get(comptimeTypeId(T)) orelse return null;
        const bytes = pool.getBytes(entity) orelse return null;
        self.touch(pool, entity); // mutable access counts as a change; use getConst to read
        return @ptrCast(@alignCast(bytes.ptr));
    }

    pub fn getConst(self: *const World, entity: EntityHandle, comptime T: type) ?*const T {
        if (!self.isAlive(entity)) return null;
        const pool = self.pools.get(comptimeTypeId(T)) orelse return null;
        const bytes = pool.getBytesConst(entity) orelse return null;
        return @ptrCast(@alignCast(bytes.ptr));
    }

    pub fn getRaw(self: *World, entity: EntityHandle, tid: ComponentTypeId) ?[]u8 {
        if (!self.isAlive(entity)) return null;
        const pool = self.pools.get(tid) orelse return null;
        self.touch(pool, entity);
        return pool.getBytes(entity);
    }

    /// Read-only raw component bytes. Does not touch change ticks; use for inspection/serialization.
    pub fn getRawConst(self: *const World, entity: EntityHandle, tid: ComponentTypeId) ?[]const u8 {
        if (!self.isAlive(entity)) return null;
        const pool = self.pools.get(tid) orelse return null;
        return pool.getBytesConst(entity);
    }

    pub fn has(self: *const World, entity: EntityHandle, comptime T: type) bool {
        if (!self.isAlive(entity)) return false;
        const pool = self.pools.get(comptimeTypeId(T)) orelse return false;
        return pool.has(entity);
    }

    pub fn remove(self: *World, entity: EntityHandle, comptime T: type) !bool {
        try self.checkMutable();
        if (!self.isAlive(entity)) return false;
        const pool = self.pools.get(comptimeTypeId(T)) orelse return false;
        return try self.removeFromPool(entity, pool);
    }

    /// Removes the component identified by `tid` from `entity`; returns whether it was present.
    pub fn removeRaw(self: *World, entity: EntityHandle, tid: ComponentTypeId) !bool {
        try self.checkMutable();
        if (!self.isAlive(entity)) return false;
        const pool = self.pools.get(tid) orelse return false;
        return try self.removeFromPool(entity, pool);
    }

    fn removeFromPool(self: *World, entity: EntityHandle, pool: *ComponentPool) !bool {
        try pool.reserveRemoval(self.allocator);
        if (!pool.remove(entity, self.tick)) return false;
        self.clearMember(entity.index, pool);
        return true;
    }

    pub fn query(self: *World, comptime spec: anytype) !Query(spec) {
        return Query(spec).init(self);
    }
};

pub fn Query(comptime spec: anytype) type {
    const write_types = if (@hasField(@TypeOf(spec), "write")) spec.write else .{};
    const read_types = if (@hasField(@TypeOf(spec), "read")) spec.read else .{};
    // `.without = .{T, ...}` excludes entities that currently hold any listed component.
    const without_types = if (@hasField(@TypeOf(spec), "without")) spec.without else .{};
    // `.added` / `.changed` keep only entities whose component was added / modified since the
    // query's `since` tick (requires `World.enableChangeTracking`). `.optional` terms are read
    // through `Row.optional`.
    const added_types = if (@hasField(@TypeOf(spec), "added")) spec.added else .{};
    const changed_types = if (@hasField(@TypeOf(spec), "changed")) spec.changed else .{};
    const optional_types = if (@hasField(@TypeOf(spec), "optional")) spec.optional else .{};
    const total_terms = write_types.len + read_types.len;

    return struct {
        const Self = @This();

        pub const Row = struct {
            query_ptr: *const Self,
            entity: EntityHandle,
            w_dense: [write_types.len]u32,
            r_dense: [read_types.len]u32,

            pub fn read(self: Row, comptime T: type) *const T {
                inline for (read_types, 0..) |RT, idx| {
                    if (RT == T) {
                        if (@sizeOf(T) == 0) {
                            const Zst = struct {
                                var dummy: T = undefined;
                            };
                            return &Zst.dummy;
                        }
                        const pool = self.query_ptr.read_pools[idx].?;
                        const start = @as(usize, self.r_dense[idx]) * pool.stride;
                        return @ptrCast(@alignCast(pool.dense_bytes.items[start .. start + pool.elem_size].ptr));
                    }
                }
                inline for (write_types, 0..) |WT, idx| {
                    if (WT == T) {
                        if (@sizeOf(T) == 0) {
                            const Zst = struct {
                                var dummy: T = undefined;
                            };
                            return &Zst.dummy;
                        }
                        const pool = self.query_ptr.write_pools[idx].?;
                        const start = @as(usize, self.w_dense[idx]) * pool.stride;
                        return @ptrCast(@alignCast(pool.dense_bytes.items[start .. start + pool.elem_size].ptr));
                    }
                }
                @compileError("Component type not present in Query spec");
            }

            /// Returns the optional component `T` of this row's entity, or null when absent.
            pub fn optional(self: Row, comptime T: type) ?*const T {
                inline for (optional_types, 0..) |OT, idx| {
                    if (OT == T) {
                        const pool = self.query_ptr.optional_pools[idx] orelse return null;
                        const bytes = pool.getBytesConst(self.entity) orelse return null;
                        if (@sizeOf(T) == 0) {
                            const Zst = struct {
                                var dummy: T = undefined;
                            };
                            return &Zst.dummy;
                        }
                        return @ptrCast(@alignCast(bytes.ptr));
                    }
                }
                @compileError("Component type not declared as optional in Query spec");
            }

            pub fn write(self: Row, comptime T: type) *T {
                inline for (write_types, 0..) |WT, idx| {
                    if (WT == T) {
                        if (@sizeOf(T) == 0) {
                            const Zst = struct {
                                var dummy: T = undefined;
                            };
                            return &Zst.dummy;
                        }
                        const pool = self.query_ptr.write_pools[idx].?;
                        if (pool.tracked) pool.changed_ticks.items[self.w_dense[idx]] = self.query_ptr.write_tick;
                        const start = @as(usize, self.w_dense[idx]) * pool.stride;
                        return @ptrCast(@alignCast(pool.dense_bytes.items[start .. start + pool.elem_size].ptr));
                    }
                }
                @compileError("Component type not declared as write in Query spec");
            }
        };

        world: *World,
        driver_pool: ?*ComponentPool,
        write_pools: [write_types.len]?*ComponentPool,
        read_pools: [read_types.len]?*ComponentPool,
        /// Pools of excluded types; null when the type is not registered (nothing to exclude).
        without_pools: [without_types.len]?*ComponentPool,
        added_pools: [added_types.len]?*ComponentPool,
        changed_pools: [changed_types.len]?*ComponentPool,
        optional_pools: [optional_types.len]?*ComponentPool,
        /// Change-detection threshold (`World.query_since` for `init`, the system's for `initWith`).
        since: u64,
        /// Tick stamped on components written through `Row.write`.
        write_tick: u64,
        cursor: usize,

        pub fn init(world: *World) !Self {
            return initWith(world, world.query_since, world.tick);
        }

        /// Like `init` but with explicit change-detection state, so concurrently running systems
        /// each use their own threshold and write tick instead of the shared world values.
        pub fn initWith(world: *World, since: u64, write_tick: u64) !Self {
            var smallest: ?*ComponentPool = null;
            var w_pools: [write_types.len]?*ComponentPool = @splat(null);
            var r_pools: [read_types.len]?*ComponentPool = @splat(null);
            var missing = false;

            inline for (write_types, 0..) |T, idx| {
                const pool = world.pools.get(World.comptimeTypeId(T));
                w_pools[idx] = pool;
                if (pool == null) {
                    missing = true;
                } else if (smallest == null or pool.?.dense_entities.items.len < smallest.?.dense_entities.items.len) {
                    smallest = pool;
                }
            }
            inline for (read_types, 0..) |T, idx| {
                const pool = world.pools.get(World.comptimeTypeId(T));
                r_pools[idx] = pool;
                if (pool == null) {
                    missing = true;
                } else if (smallest == null or pool.?.dense_entities.items.len < smallest.?.dense_entities.items.len) {
                    smallest = pool;
                }
            }

            var x_pools: [without_types.len]?*ComponentPool = @splat(null);
            inline for (without_types, 0..) |T, idx| {
                x_pools[idx] = world.pools.get(World.comptimeTypeId(T));
            }

            var ad_pools: [added_types.len]?*ComponentPool = @splat(null);
            var ch_pools: [changed_types.len]?*ComponentPool = @splat(null);
            var op_pools: [optional_types.len]?*ComponentPool = @splat(null);
            inline for (added_types, 0..) |T, idx| {
                if (world.pools.get(World.comptimeTypeId(T))) |pool| {
                    if (!pool.tracked) return error.ChangeTrackingNotEnabled;
                    ad_pools[idx] = pool;
                } else {
                    missing = true;
                }
            }
            inline for (changed_types, 0..) |T, idx| {
                if (world.pools.get(World.comptimeTypeId(T))) |pool| {
                    if (!pool.tracked) return error.ChangeTrackingNotEnabled;
                    ch_pools[idx] = pool;
                } else {
                    missing = true;
                }
            }
            inline for (optional_types, 0..) |T, idx| {
                op_pools[idx] = world.pools.get(World.comptimeTypeId(T));
            }

            _ = @atomicRmw(u32, &world.active_queries, .Add, 1, .acq_rel);
            return .{
                .world = world,
                .driver_pool = if (missing) null else smallest,
                .write_pools = w_pools,
                .read_pools = r_pools,
                .without_pools = x_pools,
                .added_pools = ad_pools,
                .changed_pools = ch_pools,
                .optional_pools = op_pools,
                .since = since,
                .write_tick = write_tick,
                .cursor = 0,
            };
        }

        fn addedMatches(self: *const Self, idx: usize, entity: EntityHandle) bool {
            const pool = self.added_pools[idx] orelse return false;
            if (entity.index >= pool.sparse.items.len) return false;
            const d = pool.sparse.items[entity.index];
            if (d == ABSENT_INDEX or pool.dense_entities.items[d].generation != entity.generation) return false;
            return pool.added_ticks.items[d] > self.since;
        }

        fn changedMatches(self: *const Self, idx: usize, entity: EntityHandle) bool {
            const pool = self.changed_pools[idx] orelse return false;
            if (entity.index >= pool.sparse.items.len) return false;
            const d = pool.sparse.items[entity.index];
            if (d == ABSENT_INDEX or pool.dense_entities.items[d].generation != entity.generation) return false;
            return pool.changed_ticks.items[d] > self.since;
        }

        pub fn deinit(self: *Self) void {
            if (@atomicLoad(u32, &self.world.active_queries, .acquire) > 0) {
                _ = @atomicRmw(u32, &self.world.active_queries, .Sub, 1, .acq_rel);
            }
        }

        pub fn next(self: *Self) ?Row {
            if (total_terms == 0) return null;
            const driver = self.driver_pool orelse return null;

            while (self.cursor < driver.dense_entities.items.len) {
                const driver_dense: u32 = @intCast(self.cursor);
                const entity = driver.dense_entities.items[self.cursor];
                self.cursor += 1;

                var w_dense: [write_types.len]u32 = undefined;
                var r_dense: [read_types.len]u32 = undefined;
                var matches = true;

                inline for (0..without_types.len) |idx| {
                    if (self.without_pools[idx]) |pool| {
                        if (pool.has(entity)) matches = false;
                    }
                }
                if (!matches) continue;

                inline for (0..added_types.len) |idx| {
                    if (!self.addedMatches(idx, entity)) matches = false;
                }
                if (!matches) continue;
                inline for (0..changed_types.len) |idx| {
                    if (!self.changedMatches(idx, entity)) matches = false;
                }
                if (!matches) continue;

                inline for (0..write_types.len) |idx| {
                    const pool = self.write_pools[idx].?;
                    if (pool == driver) {
                        w_dense[idx] = driver_dense;
                    } else if (entity.index < pool.sparse.items.len) {
                        const d = pool.sparse.items[entity.index];
                        if (d == ABSENT_INDEX or pool.dense_entities.items[d].generation != entity.generation) {
                            matches = false;
                            break;
                        }
                        w_dense[idx] = d;
                    } else {
                        matches = false;
                        break;
                    }
                }
                if (matches) {
                    inline for (0..read_types.len) |idx| {
                        const pool = self.read_pools[idx].?;
                        if (pool == driver) {
                            r_dense[idx] = driver_dense;
                        } else if (entity.index < pool.sparse.items.len) {
                            const d = pool.sparse.items[entity.index];
                            if (d == ABSENT_INDEX or pool.dense_entities.items[d].generation != entity.generation) {
                                matches = false;
                                break;
                            }
                            r_dense[idx] = d;
                        } else {
                            matches = false;
                            break;
                        }
                    }
                }
                if (matches) {
                    return .{
                        .query_ptr = self,
                        .entity = entity,
                        .w_dense = w_dense,
                        .r_dense = r_dense,
                    };
                }
            }
            return null;
        }
    };
}
