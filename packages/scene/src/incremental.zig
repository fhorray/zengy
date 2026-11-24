//! Local/Global transforms with incremental (dirty-driven) propagation.
//!
//! `LocalTransform2D/3D` are the editable, serialized source of truth; `GlobalTransform2D/3D` are
//! derived and never written by gameplay code. The propagation systems only touch entities whose
//! `Local*` or `Parent` changed since they last ran (via ECS change tracking) plus those entities'
//! descendants, so a frame where nothing moved does no transform work, and consumers can filter
//! `.changed = .{GlobalTransform2D}` to see exactly what moved.
//!
//! Descendants are found through `graph.HierarchyLinks`, so hierarchy edits must go through
//! `scene.graph` (`reparent`, `despawnNode`, or `rebuildLinks` after raw `Parent` writes).
//! A global is rewritten only when its value actually changes.

const std = @import("std");
const engine = @import("engine");
const scene = @import("scene.zig");
const graph = @import("graph.zig");

/// Editable local 2D transform (translation, rotation in radians, scale).
pub const LocalTransform2D = struct {
    x: f32 = 0,
    y: f32 = 0,
    rotation_rad: f32 = 0,
    scale_x: f32 = 1,
    scale_y: f32 = 1,
};

/// Derived world-space 2D affine matrix `[a c tx; b d ty]`.
pub const GlobalTransform2D = struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,
    tx: f32 = 0,
    ty: f32 = 0,

    pub fn toMat(self: GlobalTransform2D) scene.Mat2D {
        return .{ .a = self.a, .b = self.b, .c = self.c, .d = self.d, .tx = self.tx, .ty = self.ty };
    }

    pub fn fromMat(m: scene.Mat2D) GlobalTransform2D {
        return .{ .a = m.a, .b = m.b, .c = m.c, .d = m.d, .tx = m.tx, .ty = m.ty };
    }
};

/// Editable local 3D transform: translation, unit quaternion `(x, y, z, w)`, and scale.
pub const LocalTransform3D = struct {
    translation: [3]f32 = .{ 0, 0, 0 },
    rotation: [4]f32 = .{ 0, 0, 0, 1 },
    scale: [3]f32 = .{ 1, 1, 1 },
};

/// Derived world-space 3D matrix, column-major (`m[col * 4 + row]`).
pub const GlobalTransform3D = struct {
    m: [16]f32 = identity4,
};

pub const identity4: [16]f32 = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };

/// Column-major `a * b` (apply `b` first).
pub fn mul4(a: [16]f32, b: [16]f32) [16]f32 {
    var out: [16]f32 = undefined;
    for (0..4) |col| {
        for (0..4) |row| {
            var sum: f32 = 0;
            for (0..4) |k| sum += a[k * 4 + row] * b[col * 4 + k];
            out[col * 4 + row] = sum;
        }
    }
    return out;
}

/// Builds the TRS matrix of a local 3D transform. The quaternion is normalized; a zero quaternion
/// falls back to identity rotation.
pub fn trs4(t: LocalTransform3D) [16]f32 {
    var x = t.rotation[0];
    var y = t.rotation[1];
    var z = t.rotation[2];
    var w = t.rotation[3];
    const len = @sqrt(x * x + y * y + z * z + w * w);
    if (len > 0 and std.math.isFinite(len)) {
        x /= len;
        y /= len;
        z /= len;
        w /= len;
    } else {
        x = 0;
        y = 0;
        z = 0;
        w = 1;
    }
    const xx = x * x;
    const yy = y * y;
    const zz = z * z;
    const xy = x * y;
    const xz = x * z;
    const yz = y * z;
    const wx = w * x;
    const wy = w * y;
    const wz = w * z;
    const sx = t.scale[0];
    const sy = t.scale[1];
    const sz = t.scale[2];
    return .{
        (1 - 2 * (yy + zz)) * sx, (2 * (xy + wz)) * sx,     (2 * (xz - wy)) * sx,     0,
        (2 * (xy - wz)) * sy,     (1 - 2 * (xx + zz)) * sy, (2 * (yz + wx)) * sy,     0,
        (2 * (xz + wy)) * sz,     (2 * (yz - wx)) * sz,     (1 - 2 * (xx + yy)) * sz, 0,
        t.translation[0],         t.translation[1],         t.translation[2],         1,
    };
}

fn composeGlobal2D(parent: ?GlobalTransform2D, local: LocalTransform2D) GlobalTransform2D {
    const lm = scene.Mat2D.fromTransform(.{
        .x = local.x,
        .y = local.y,
        .rotation_rad = local.rotation_rad,
        .scale_x = local.scale_x,
        .scale_y = local.scale_y,
    });
    const m = if (parent) |p| scene.Mat2D.mul(p.toMat(), lm) else lm;
    return GlobalTransform2D.fromMat(m);
}

fn composeGlobal3D(parent: ?GlobalTransform3D, local: LocalTransform3D) GlobalTransform3D {
    const lm = trs4(local);
    return .{ .m = if (parent) |p| mul4(p.m, lm) else lm };
}

/// Per-kind propagation state (first-run bootstrap flag).
pub const PropagationState = struct {
    bootstrapped_2d: bool = false,
    bootstrapped_3d: bool = false,
};

fn Propagator(comptime Local: type, comptime Global: type, comptime compose: anytype, comptime bootstrap_field: []const u8) type {
    return struct {
        pub fn run(ctx: *engine.SystemContext) !void {
            const world = ctx.world;
            const allocator = world.allocator;
            const state = ctx.resources.get(PropagationState) orelse return;

            var dirty: std.ArrayList(engine.EntityHandle) = .empty;
            defer dirty.deinit(allocator);

            {
                var q = try ctx.query(.{ .read = .{Local}, .changed = .{Local} });
                defer q.deinit();
                while (q.next()) |row| try dirty.append(allocator, row.entity);
            }
            {
                var q = try ctx.query(.{ .read = .{ Local, scene.Parent }, .changed = .{scene.Parent} });
                defer q.deinit();
                while (q.next()) |row| try dirty.append(allocator, row.entity);
            }
            // Entities whose Parent was removed become roots and must be recomputed.
            var removed = world.removedSince(scene.Parent);
            while (removed.next()) |gone| {
                if (world.isAlive(gone) and world.has(gone, Local)) try dirty.append(allocator, gone);
            }
            // Components that existed before change tracking was enabled carry tick 0 and are never
            // "changed"; sweep them in once.
            if (!@field(state, bootstrap_field)) {
                var q = try ctx.query(.{ .read = .{Local}, .without = .{Global} });
                defer q.deinit();
                while (q.next()) |row| try dirty.append(allocator, row.entity);
                @field(state, bootstrap_field) = true;
            }
            if (dirty.items.len == 0) return;

            var dirty_set: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer dirty_set.deinit(allocator);
            try dirty_set.ensureTotalCapacity(allocator, @intCast(dirty.items.len));
            for (dirty.items) |e| dirty_set.putAssumeCapacity(e.index, {});

            var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer visited.deinit(allocator);
            var stack: std.ArrayList(engine.EntityHandle) = .empty;
            defer stack.deinit(allocator);

            for (dirty.items) |start| {
                if (!world.isAlive(start) or visited.contains(start.index)) continue;
                // Recompute from the top-most dirty ancestor so parents are always updated first.
                var root = start;
                var hops: usize = 0;
                while (hops <= world.entity_count) : (hops += 1) {
                    const p = graph.parentOf(world, root) orelse break;
                    if (!dirty_set.contains(p.index) or visited.contains(p.index)) break;
                    root = p;
                }
                try stack.append(allocator, root);
                while (stack.pop()) |node| {
                    if (visited.contains(node.index)) continue;
                    try visited.put(allocator, node.index, {});
                    const local = (world.getConst(node, Local) orelse continue).*;
                    const parent_global: ?Global = if (graph.parentOf(world, node)) |p|
                        (if (world.getConst(p, Global)) |g| g.* else null)
                    else
                        null;
                    const next = compose(parent_global, local);
                    const unchanged = if (world.getConst(node, Global)) |cur| std.meta.eql(cur.*, next) else false;
                    if (!unchanged) try world.set(node, Global, next);
                    var kids = graph.children(world, node);
                    while (kids.next()) |k| try stack.append(allocator, k);
                }
            }
        }
    };
}

pub const propagateLocal2DSystem = Propagator(LocalTransform2D, GlobalTransform2D, composeGlobal2D, "bootstrapped_2d").run;
pub const propagateLocal3DSystem = Propagator(LocalTransform3D, GlobalTransform3D, composeGlobal3D, "bootstrapped_3d").run;

/// Registers the components, enables change tracking, and installs both systems.
pub fn install(app: *engine.App) !void {
    _ = try app.registerComponent(LocalTransform2D);
    _ = try app.registerComponent(GlobalTransform2D);
    _ = try app.registerComponent(LocalTransform3D);
    _ = try app.registerComponent(GlobalTransform3D);
    try app.world.enableChangeTracking(LocalTransform2D);
    try app.world.enableChangeTracking(LocalTransform3D);
    try app.world.enableChangeTracking(scene.Parent);
    try app.resources.insert(PropagationState, .{});
    try app.addSystem(.{
        .name = "scene.propagate_local_2d",
        .stage = .post_update,
        .thread_affinity = .any,
        .reads = &.{ "LocalTransform2D", "Parent", "HierarchyLinks" },
        .writes = &.{"GlobalTransform2D"},
        .run = propagateLocal2DSystem,
    });
    try app.addSystem(.{
        .name = "scene.propagate_local_3d",
        .stage = .post_update,
        .thread_affinity = .any,
        .reads = &.{ "LocalTransform3D", "Parent", "HierarchyLinks" },
        .writes = &.{"GlobalTransform3D"},
        .run = propagateLocal3DSystem,
    });
}
