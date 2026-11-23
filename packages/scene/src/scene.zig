//! Optional 2D Scene & Transform Graph Package (`official.scene`).
//!
//! Provides 2D spatial hierarchy (`Transform2D`, `Parent`), automatic transform
//! propagation during `.post_update`, and headless scene snapshot/restore
//! (`SceneSnapshot`) without any dependency on editor or GPU modules.

const std = @import("std");
const engine = @import("engine");

pub const MODULE_OWNER_ID: u64 = 2007;

/// Local and computed world-space 2D transform component.
pub const Transform2D = struct {
    x: f32 = 0,
    y: f32 = 0,
    rotation_rad: f32 = 0,
    scale_x: f32 = 1,
    scale_y: f32 = 1,
    world_x: f32 = 0,
    world_y: f32 = 0,
};

/// Parent link component forming a 2D scene hierarchy.
pub const Parent = struct {
    entity: engine.EntityHandle,
};

/// Serializable snapshot of a single entity's 2D transform.
pub const SceneEntityRecord = struct {
    guid: engine.EntityGuid,
    transform: Transform2D,
};

/// Portable scene snapshot that can be saved/restored across Worlds.
pub const SceneSnapshot = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(SceneEntityRecord),

    pub fn init(allocator: std.mem.Allocator) SceneSnapshot {
        return .{
            .allocator = allocator,
            .records = .empty,
        };
    }

    pub fn deinit(self: *SceneSnapshot) void {
        self.records.deinit(self.allocator);
    }

    /// Captures all entities carrying `Transform2D` from `world`.
    pub fn capture(allocator: std.mem.Allocator, world: *engine.World) !SceneSnapshot {
        var snap = SceneSnapshot.init(allocator);
        errdefer snap.deinit();

        var q = try world.query(.{ .read = .{Transform2D} });
        defer q.deinit();

        while (q.next()) |row| {
            const guid = world.getGuid(row.entity) orelse 0;
            try snap.records.append(allocator, .{
                .guid = guid,
                .transform = row.read(Transform2D).*,
            });
        }
        return snap;
    }

    /// Restores captured entities and transforms into `target_world`.
    pub fn restore(self: *const SceneSnapshot, target_world: *engine.World) !usize {
        _ = try target_world.registerComponent(Transform2D);
        for (self.records.items) |rec| {
            const e = try target_world.spawn();
            try target_world.set(e, Transform2D, rec.transform);
        }
        return self.records.items.len;
    }
};

/// Propagates local `Transform2D` coordinates through arbitrary-depth `Parent` chains.
pub fn propagateTransformsSystem(ctx: *engine.SystemContext) !void {
    var q = try ctx.query(.{ .write = .{Transform2D} });
    defer q.deinit();

    while (q.next()) |row| {
        const t = row.write(Transform2D);
        var wx = t.x;
        var wy = t.y;

        var curr = row.entity;
        var depth: u32 = 0;
        while (depth < 64) : (depth += 1) {
            const parent_comp = ctx.world.getConst(curr, Parent) orelse break;
            const parent_t = ctx.world.getConst(parent_comp.entity, Transform2D) orelse break;
            wx += parent_t.x;
            wy += parent_t.y;
            curr = parent_comp.entity;
        }

        t.world_x = wx;
        t.world_y = wy;
    }
}

fn buildModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    _ = try app.registerComponent(Transform2D);
    _ = try app.registerComponent(Parent);
    try app.addSystem(.{
        .name = "scene.propagate_transforms_2d",
        .stage = .post_update,
        .run = propagateTransformsSystem,
    });
}

pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = "official.scene",
            .version = "0.1.0",
            .provides_capabilities = &.{"engine.scene.2d/1"},
        },
        .build = buildModule,
    };
}
