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
    world_rotation_rad: f32 = 0,
    world_scale_x: f32 = 1,
    world_scale_y: f32 = 1,
};

/// Parent link component forming a 2D scene hierarchy.
pub const Parent = struct {
    entity: engine.EntityHandle,
};

/// Serializable snapshot of a single entity's 2D transform and optional parent GUID.
pub const SceneEntityRecord = struct {
    guid: engine.EntityGuid,
    transform: Transform2D,
    parent_guid: ?engine.EntityGuid = null,
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

    /// Captures all entities carrying `Transform2D` and their `Parent` relationships from `world`.
    pub fn capture(allocator: std.mem.Allocator, world: *engine.World) !SceneSnapshot {
        var snap = SceneSnapshot.init(allocator);
        errdefer snap.deinit();

        var q = try world.query(.{ .read = .{Transform2D} });
        defer q.deinit();

        while (q.next()) |row| {
            const guid = world.getGuid(row.entity) orelse 0;
            const parent_guid: ?engine.EntityGuid = if (world.getConst(row.entity, Parent)) |p|
                world.getGuid(p.entity)
            else
                null;
            try snap.records.append(allocator, .{
                .guid = guid,
                .transform = row.read(Transform2D).*,
                .parent_guid = parent_guid,
            });
        }
        return snap;
    }

    /// Restores captured entities, persistent GUIDs, transforms, and `Parent` hierarchy into `target_world`.
    pub fn restore(self: *const SceneSnapshot, target_world: *engine.World) !usize {
        _ = try target_world.registerComponent(Transform2D);
        _ = try target_world.registerComponent(Parent);

        var guid_map = std.AutoHashMapUnmanaged(engine.EntityGuid, engine.EntityHandle).empty;
        defer guid_map.deinit(self.allocator);
        try guid_map.ensureTotalCapacity(self.allocator, @intCast(self.records.items.len));

        for (self.records.items) |rec| {
            const e = try target_world.spawn();
            if (rec.guid != 0) {
                target_world.guids.items[e.index] = rec.guid;
                if (target_world.next_guid <= rec.guid) {
                    target_world.next_guid = rec.guid + 1;
                }
                guid_map.putAssumeCapacity(rec.guid, e);
            }
            try target_world.set(e, Transform2D, rec.transform);
        }

        for (self.records.items) |rec| {
            const p_guid = rec.parent_guid orelse continue;
            const child_e = guid_map.get(rec.guid) orelse continue;
            const parent_e = guid_map.get(p_guid) orelse continue;
            if (!std.meta.eql(child_e, parent_e)) {
                try target_world.set(child_e, Parent, .{ .entity = parent_e });
            }
        }
        return self.records.items.len;
    }
};

const Mat2D = struct {
    // 2x3 affine matrix: [ a c tx ; b d ty ]
    a: f32,
    b: f32,
    c: f32,
    d: f32,
    tx: f32,
    ty: f32,

    fn fromTransform(t: Transform2D) Mat2D {
        const cos_r = @cos(t.rotation_rad);
        const sin_r = @sin(t.rotation_rad);
        return .{
            .a = cos_r * t.scale_x,
            .b = sin_r * t.scale_x,
            .c = -sin_r * t.scale_y,
            .d = cos_r * t.scale_y,
            .tx = t.x,
            .ty = t.y,
        };
    }

    fn mul(parent_m: Mat2D, local_m: Mat2D) Mat2D {
        return .{
            .a = parent_m.a * local_m.a + parent_m.c * local_m.b,
            .b = parent_m.b * local_m.a + parent_m.d * local_m.b,
            .c = parent_m.a * local_m.c + parent_m.c * local_m.d,
            .d = parent_m.b * local_m.c + parent_m.d * local_m.d,
            .tx = parent_m.a * local_m.tx + parent_m.c * local_m.ty + parent_m.tx,
            .ty = parent_m.b * local_m.tx + parent_m.d * local_m.ty + parent_m.ty,
        };
    }
};

fn hasParentCycle(world: *const engine.World, start: engine.EntityHandle) bool {
    var slow = start;
    var fast = start;
    while (true) {
        const f1 = world.getConst(fast, Parent) orelse return false;
        const f2 = world.getConst(f1.entity, Parent) orelse return false;
        fast = f2.entity;
        const s1 = world.getConst(slow, Parent) orelse return false;
        slow = s1.entity;
        if (std.meta.eql(slow, fast)) return true;
    }
}

/// Propagates local `Transform2D` (translation, rotation, scale) through `Parent` chains
/// with cycle protection.
pub fn propagateTransformsSystem(ctx: *engine.SystemContext) !void {
    var chain: std.ArrayList(Transform2D) = .empty;
    defer chain.deinit(ctx.world.allocator);

    var q = try ctx.query(.{ .write = .{Transform2D} });
    defer q.deinit();

    while (q.next()) |row| {
        const t = row.write(Transform2D);
        if (hasParentCycle(ctx.world, row.entity)) {
            const local_m = Mat2D.fromTransform(t.*);
            t.world_x = local_m.tx;
            t.world_y = local_m.ty;
            t.world_rotation_rad = t.rotation_rad;
            t.world_scale_x = t.scale_x;
            t.world_scale_y = t.scale_y;
            continue;
        }

        chain.clearRetainingCapacity();
        var curr = row.entity;
        while (ctx.world.getConst(curr, Parent)) |parent_comp| {
            const parent_t = ctx.world.getConst(parent_comp.entity, Transform2D) orelse break;
            try chain.append(ctx.world.allocator, parent_t.*);
            curr = parent_comp.entity;
        }

        var world_m = Mat2D{ .a = 1, .b = 0, .c = 0, .d = 1, .tx = 0, .ty = 0 };
        var world_rot: f32 = 0;
        var world_sx: f32 = 1;
        var world_sy: f32 = 1;

        var i = chain.items.len;
        while (i > 0) {
            i -= 1;
            const pt = chain.items[i];
            world_m = Mat2D.mul(world_m, Mat2D.fromTransform(pt));
            world_rot += pt.rotation_rad;
            world_sx *= pt.scale_x;
            world_sy *= pt.scale_y;
        }

        world_m = Mat2D.mul(world_m, Mat2D.fromTransform(t.*));
        t.world_x = world_m.tx;
        t.world_y = world_m.ty;
        t.world_rotation_rad = world_rot + t.rotation_rad;
        t.world_scale_x = world_sx * t.scale_x;
        t.world_scale_y = world_sy * t.scale_y;
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
