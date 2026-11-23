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

pub const CommandBuffer = struct {
    allocator: std.mem.Allocator,
    commands: std.ArrayList(Command),

    pub fn init(allocator: std.mem.Allocator) CommandBuffer {
        return .{
            .allocator = allocator,
            .commands = .empty,
        };
    }

    pub fn deinit(self: *CommandBuffer) void {
        self.clear();
        self.commands.deinit(self.allocator);
    }

    pub fn clear(self: *CommandBuffer) void {
        for (self.commands.items) |cmd| {
            switch (cmd) {
                .set_raw => |s| {
                    self.allocator.free(s.type_name);
                    self.allocator.free(s.bytes);
                },
                .emit_event => |e| {
                    self.allocator.free(e.name);
                    self.allocator.free(e.payload);
                },
                else => {},
            }
        }
        self.commands.clearRetainingCapacity();
    }

    pub fn spawn(self: *CommandBuffer) !void {
        try self.commands.append(self.allocator, .{ .spawn_empty = {} });
    }

    pub fn despawn(self: *CommandBuffer, entity: EntityHandle) !void {
        try self.commands.append(self.allocator, .{ .despawn = entity });
    }

    pub fn set(self: *CommandBuffer, entity: EntityHandle, comptime T: type, value: T) !void {
        const bytes_copy = try self.allocator.dupe(u8, std.mem.asBytes(&value));
        errdefer self.allocator.free(bytes_copy);
        const name_copy = try self.allocator.dupe(u8, @typeName(T));
        errdefer self.allocator.free(name_copy);

        try self.commands.append(self.allocator, .{
            .set_raw = .{
                .entity = entity,
                .type_id = World.comptimeTypeId(T),
                .type_name = name_copy,
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
        const name_copy = try self.allocator.dupe(u8, envelope.name);
        errdefer self.allocator.free(name_copy);
        const payload_copy = try self.allocator.dupe(u8, envelope.payload);
        errdefer self.allocator.free(payload_copy);

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

    pub fn apply(self: *CommandBuffer, world: *World, events: *EventBus) !void {
        defer self.clear();

        for (self.commands.items) |cmd| {
            switch (cmd) {
                .spawn_empty => {
                    _ = try world.spawn();
                },
                .despawn => |e| {
                    _ = try world.despawn(e);
                },
                .set_raw => |s| {
                    if (!world.pools.contains(s.type_id)) {
                        // Ensure dynamic/comptime pool exists if command arrived before explicit registerComponent
                        const tid = try world.registerDynamicComponent(s.type_name, s.bytes.len);
                        _ = tid;
                    }
                    if (world.isAlive(s.entity)) {
                        try world.setRaw(s.entity, s.type_id, s.bytes);
                    }
                },
                .remove_raw => |r| {
                    if (world.isAlive(r.entity)) {
                        if (world.pools.getPtr(r.type_id)) |pool| {
                            _ = pool.remove(r.entity);
                        }
                    }
                },
                .emit_event => |e| {
                    try events.post(.{
                        .name = e.name,
                        .payload = e.payload,
                        .world_id = e.world_id,
                        .entity_handle = e.entity_handle,
                    });
                },
            }
        }
    }
};
