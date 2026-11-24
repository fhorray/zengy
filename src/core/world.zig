//! Generational ECS World Facade (`core/world`).
//!
//! Provides the public entity-component-system contract (`World`, `EntityHandle`,
//! `EntityGuid`, `WorldId`, `ComponentTypeId`, `Query`) without exposing any
//! third-party ECS types or raw internal pointers (ADR-007).
//!
//! Memory & Safety Guarantees:
//! - `EntityHandle` packs `(index: u32, generation: u32)`; despawning bumps generation
//!   so stale handles are deterministically rejected by `isAlive()`, `get()`, and `set()`.
//! - Each component type is stored in a 16-byte-aligned dense sparse-set `ComponentPool`.
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
    sparse: std.ArrayList(u32),
    dense_entities: std.ArrayList(EntityHandle),
    dense_bytes: std.array_list.Aligned(u8, .@"64"),

    fn init(
        allocator: std.mem.Allocator,
        type_id: ComponentTypeId,
        name: []const u8,
        elem_size: usize,
        elem_align: usize,
        schema_version: u32,
    ) !ComponentPool {
        const name_copy = try allocator.dupe(u8, name);
        const safe_align = if (elem_align == 0) 1 else elem_align;
        const stride = if (elem_size == 0) 0 else std.mem.alignForward(usize, elem_size, safe_align);
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

    fn getBytesConst(self: *const ComponentPool, entity: EntityHandle) ?[]const u8 {
        if (!self.has(entity)) return null;
        const dense_idx = self.sparse.items[entity.index];
        if (self.stride == 0) return &.{};
        const start = @as(usize, dense_idx) * self.stride;
        return self.dense_bytes.items[start .. start + self.elem_size];
    }

    fn setBytes(self: *ComponentPool, allocator: std.mem.Allocator, entity: EntityHandle, bytes: []const u8) !void {
        if (bytes.len != self.elem_size) return error.ComponentSizeMismatch;
        try self.ensureSparse(allocator, entity.index);

        const existing = self.sparse.items[entity.index];
        if (existing != ABSENT_INDEX and self.dense_entities.items[existing].generation == entity.generation) {
            if (self.stride > 0) {
                const start = @as(usize, existing) * self.stride;
                @memcpy(self.dense_bytes.items[start .. start + self.elem_size], bytes);
            }
            return;
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

        self.sparse.items[entity.index] = new_dense;
    }

    pub fn remove(self: *ComponentPool, entity: EntityHandle) bool {
        if (!self.has(entity)) return false;
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
    name_to_type: std.StringHashMapUnmanaged(ComponentTypeId),
    active_queries: u32,
    entity_count: usize,

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
            .name_to_type = .empty,
            .active_queries = 0,
            .entity_count = 0,
        };
    }

    pub fn deinit(self: *World) void {
        var it = self.pools.valueIterator();
        while (it.next()) |pool_ptr| {
            pool_ptr.*.deinit(self.allocator);
            self.allocator.destroy(pool_ptr.*);
        }
        self.pools.deinit(self.allocator);

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
        if (self.pools.get(tid)) |existing| {
            if (!std.mem.eql(u8, existing.name, desc.name)) {
                return error.ComponentNameCollision;
            }
            if (existing.elem_size != desc.size or existing.elem_align != safe_align or existing.schema_version != desc.schema_version) {
                return error.ComponentLayoutMismatch;
            }
            return tid;
        }
        if (self.active_queries > 0) return error.MutationDuringActiveQuery;

        const pool_ptr = try self.allocator.create(ComponentPool);
        errdefer self.allocator.destroy(pool_ptr);
        pool_ptr.* = try ComponentPool.init(self.allocator, tid, desc.name, desc.size, safe_align, desc.schema_version);
        errdefer pool_ptr.deinit(self.allocator);

        try self.pools.ensureUnusedCapacity(self.allocator, 1);
        try self.name_to_type.ensureUnusedCapacity(self.allocator, 1);
        const key_copy = try self.allocator.dupe(u8, desc.name);

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

    pub fn spawn(self: *World) !EntityHandle {
        if (self.active_queries > 0) return error.MutationDuringActiveQuery;

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

        const guid = self.next_guid;
        self.next_guid += 1;
        const idx: u32 = @intCast(self.generations.items.len);
        self.generations.appendAssumeCapacity(1);
        self.alive_flags.appendAssumeCapacity(true);
        self.guids.appendAssumeCapacity(guid);
        self.entity_count += 1;
        return .{ .index = idx, .generation = 1 };
    }

    pub fn despawn(self: *World, entity: EntityHandle) !bool {
        if (self.active_queries > 0) return error.MutationDuringActiveQuery;
        if (!self.isAlive(entity)) return false;

        try self.free_indices.ensureUnusedCapacity(self.allocator, 1);

        var it = self.pools.valueIterator();
        while (it.next()) |pool_ptr| {
            _ = pool_ptr.*.remove(entity);
        }

        self.alive_flags.items[entity.index] = false;
        self.generations.items[entity.index] +%= 1;
        if (self.generations.items[entity.index] == 0) {
            self.generations.items[entity.index] = 1;
        }
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

    pub fn set(self: *World, entity: EntityHandle, comptime T: type, value: T) !void {
        if (self.active_queries > 0) return error.MutationDuringActiveQuery;
        if (!self.isAlive(entity)) return error.InvalidEntity;

        const tid = try self.registerComponent(T);
        const pool = self.pools.get(tid).?;
        try pool.setBytes(self.allocator, entity, std.mem.asBytes(&value));
    }

    pub fn setRaw(self: *World, entity: EntityHandle, tid: ComponentTypeId, bytes: []const u8) !void {
        if (self.active_queries > 0) return error.MutationDuringActiveQuery;
        if (!self.isAlive(entity)) return error.InvalidEntity;

        const pool = self.pools.get(tid) orelse return error.ComponentNotRegistered;
        try pool.setBytes(self.allocator, entity, bytes);
    }

    pub fn get(self: *World, entity: EntityHandle, comptime T: type) ?*T {
        if (!self.isAlive(entity)) return null;
        const pool = self.pools.get(comptimeTypeId(T)) orelse return null;
        const bytes = pool.getBytes(entity) orelse return null;
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
        return pool.getBytes(entity);
    }

    pub fn has(self: *const World, entity: EntityHandle, comptime T: type) bool {
        if (!self.isAlive(entity)) return false;
        const pool = self.pools.get(comptimeTypeId(T)) orelse return false;
        return pool.has(entity);
    }

    pub fn remove(self: *World, entity: EntityHandle, comptime T: type) !bool {
        if (self.active_queries > 0) return error.MutationDuringActiveQuery;
        if (!self.isAlive(entity)) return false;
        const pool = self.pools.get(comptimeTypeId(T)) orelse return false;
        return pool.remove(entity);
    }

    pub fn query(self: *World, comptime spec: anytype) !Query(spec) {
        return Query(spec).init(self);
    }
};

pub fn Query(comptime spec: anytype) type {
    const write_types = if (@hasField(@TypeOf(spec), "write")) spec.write else .{};
    const read_types = if (@hasField(@TypeOf(spec), "read")) spec.read else .{};
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
        cursor: usize,

        pub fn init(world: *World) !Self {
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

            world.active_queries += 1;
            return .{
                .world = world,
                .driver_pool = if (missing) null else smallest,
                .write_pools = w_pools,
                .read_pools = r_pools,
                .cursor = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.world.active_queries > 0) {
                self.world.active_queries -= 1;
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
