//! Deferred ECS Command Buffer (`core/commands`).
//!
//! Structural ECS mutations (`spawn`, `despawn`, `set`, `remove`) and deferred events
//! recorded during active queries or system execution are queued in `CommandBuffer`
//! and flushed deterministically at scheduler stage barriers via `apply()`.
//!
//! This prevents iterator invalidation and keeps cross-language/scripting mutations
//! synchronized with the ECS world state.

const std = @import("std");
const world_mod = @import("world.zig");
const events_mod = @import("events.zig");

const World = world_mod.World;
const EntityHandle = world_mod.EntityHandle;
const ComponentTypeId = world_mod.ComponentTypeId;
const EventBus = events_mod.EventBus;
const EventEnvelope = events_mod.EventEnvelope;

const Command = union(enum) {
    spawn_empty: void,
    despawn: EntityHandle,
    set_raw: struct {
        entity: EntityHandle,
        type_id: ComponentTypeId,
        type_name: []const u8,
        alignment: usize,
        bytes: []const u8,
    },
    remove_raw: struct {
        entity: EntityHandle,
        type_id: ComponentTypeId,
    },
    emit_event: struct {
        name: []const u8,
        payload: []const u8,
        world_id: u64,
        entity_handle: u64,
    },
};

/// Deferred mutation queue applied deterministically at scheduler stage barriers.
pub const CommandBuffer = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    commands: std.ArrayList(Command),
    pending_spawns: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) CommandBuffer {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .commands = .empty,
            .pending_spawns = 0,
        };
    }

    pub fn deinit(self: *CommandBuffer) void {
        self.commands.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn clear(self: *CommandBuffer) void {
        self.commands.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
        self.pending_spawns = 0;
    }

    /// Queues an entity spawn and returns a pending handle (`generation == 0`) that can be
    /// passed to subsequent `set()`, `remove()`, or `despawn()` calls in the same buffer.
    pub fn spawn(self: *CommandBuffer) !EntityHandle {
        const pending_idx = self.pending_spawns;
        try self.commands.append(self.allocator, .{ .spawn_empty = {} });
        self.pending_spawns += 1;
        return .{ .index = pending_idx, .generation = 0 };
    }

    pub fn despawn(self: *CommandBuffer, entity: EntityHandle) !void {
        try self.commands.append(self.allocator, .{ .despawn = entity });
    }

    pub fn set(self: *CommandBuffer, entity: EntityHandle, comptime T: type, value: T) !void {
        const scratch = self.arena.allocator();
        const bytes_copy = try scratch.dupe(u8, std.mem.asBytes(&value));
        const name_copy = try scratch.dupe(u8, @typeName(T));

        try self.commands.append(self.allocator, .{
            .set_raw = .{
                .entity = entity,
                .type_id = World.comptimeTypeId(T),
                .type_name = name_copy,
                .alignment = @alignOf(T),
                .bytes = bytes_copy,
            },
        });
    }

    pub fn remove(self: *CommandBuffer, entity: EntityHandle, comptime T: type) !void {
        try self.commands.append(self.allocator, .{
            .remove_raw = .{
                .entity = entity,
                .type_id = World.comptimeTypeId(T),
            },
        });
    }

    pub fn emit(self: *CommandBuffer, envelope: EventEnvelope) !void {
        const scratch = self.arena.allocator();
        const name_copy = try scratch.dupe(u8, envelope.name);
        const payload_copy = try scratch.dupe(u8, envelope.payload);

        try self.commands.append(self.allocator, .{
            .emit_event = .{
                .name = name_copy,
                .payload = payload_copy,
                .world_id = envelope.world_id,
                .entity_handle = envelope.entity_handle,
            },
        });
    }

    pub fn pendingCount(self: *const CommandBuffer) usize {
        return self.commands.items.len;
    }

    fn resolveEntity(entity: EntityHandle, spawned: []const EntityHandle) EntityHandle {
        if (entity.generation == 0 and entity.index < spawned.len) {
            return spawned[entity.index];
        }
        return entity;
    }

    pub fn apply(self: *CommandBuffer, world: *World, events: *EventBus) !void {
        if (self.commands.items.len == 0) return;
        if (world.active_queries > 0) return error.MutationDuringActiveQuery;

        // Pre-validate component schemas against already-registered pools before mutating world.
        for (self.commands.items) |cmd| {
            switch (cmd) {
                .set_raw => |s| {
                    if (world.pools.get(s.type_id)) |pool| {
                        if (!std.mem.eql(u8, pool.name, s.type_name)) {
                            return error.ComponentNameCollision;
                        }
                        if (pool.elem_size != s.bytes.len or pool.elem_align != s.alignment) {
                            return error.ComponentLayoutMismatch;
                        }
                    }
                },
                else => {},
            }
        }

        defer self.clear();

        var spawned: std.ArrayList(EntityHandle) = .empty;
        try spawned.ensureTotalCapacity(self.arena.allocator(), self.pending_spawns);

        for (self.commands.items) |cmd| {
            switch (cmd) {
                .spawn_empty => {
                    const real = try world.spawn();
                    spawned.appendAssumeCapacity(real);
                },
                .despawn => |e| {
                    _ = try world.despawn(resolveEntity(e, spawned.items));
                },
                .set_raw => |s| {
                    const tid = try world.registerComponentDesc(.{
                        .name = s.type_name,
                        .size = s.bytes.len,
                        .alignment = s.alignment,
                    });
                    const target = resolveEntity(s.entity, spawned.items);
                    if (world.isAlive(target)) {
                        try world.setRaw(target, tid, s.bytes);
                    }
                },
                .remove_raw => |r| {
                    const target = resolveEntity(r.entity, spawned.items);
                    if (world.isAlive(target)) {
                        _ = try world.removeRaw(target, r.type_id);
                    }
                },
                .emit_event => |e| {
                    const resolved_raw = if (e.entity_handle != 0)
                        resolveEntity(EntityHandle.fromU64(e.entity_handle), spawned.items).toU64()
                    else
                        0;
                    try events.post(.{
                        .name = e.name,
                        .payload = e.payload,
                        .world_id = e.world_id,
                        .entity_handle = resolved_raw,
                    });
                },
            }
        }
    }
};
