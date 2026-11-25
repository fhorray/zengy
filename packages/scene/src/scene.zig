//! Optional 2D Scene & Transform Graph Package (`official.scene`).
//!
//! Provides 2D spatial hierarchy (`Transform2D`, `Parent`), automatic transform
//! propagation during `.post_update`, and headless scene snapshot/restore
//! (`SceneSnapshot`) without any dependency on editor or GPU modules.

const std = @import("std");
const engine = @import("engine");

pub const MODULE_OWNER_ID: u64 = 2007;

/// Parent/child index and reparenting operations (see `graph.zig`).
pub const graph = @import("graph.zig");

/// `LocalTransform2D/3D` + `GlobalTransform2D/3D` with incremental propagation (see `incremental.zig`).
pub const incremental = @import("incremental.zig");

/// JSON codec for `SceneSnapshot3D` (see `codec.zig`).
pub const codec = @import("codec.zig");

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

/// Serializable snapshot of a single entity's canonical 3D local transform and optional parent GUID.
pub const SceneEntityRecord3D = struct {
    guid: engine.EntityGuid,
    local: incremental.LocalTransform3D,
    parent_guid: ?engine.EntityGuid = null,
    name: []const u8 = "",
};

/// Headless 3D scene snapshot using `LocalTransform3D` (authorable) and persistent GUIDs.
/// Does not capture GPU handles, cameras owned by tools, or derived globals.
pub const SceneSnapshot3D = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(SceneEntityRecord3D),
    owned_names: std.ArrayList([]u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) SceneSnapshot3D {
        return .{ .allocator = allocator, .records = .empty };
    }

    pub fn deinit(self: *SceneSnapshot3D) void {
        for (self.owned_names.items) |n| self.allocator.free(n);
        self.owned_names.deinit(self.allocator);
        self.records.deinit(self.allocator);
    }

    /// Captures entities that have `LocalTransform3D`. Optional UTF-8 `name` slices are copied.
    pub fn capture(allocator: std.mem.Allocator, world: *engine.World) !SceneSnapshot3D {
        var snap = SceneSnapshot3D.init(allocator);
        errdefer snap.deinit();

        var q = try world.query(.{ .read = .{incremental.LocalTransform3D} });
        defer q.deinit();
        while (q.next()) |row| {
            const guid = world.getGuid(row.entity) orelse 0;
            const parent_guid: ?engine.EntityGuid = if (world.getConst(row.entity, Parent)) |p|
                world.getGuid(p.entity)
            else
                null;
            try snap.records.append(allocator, .{
                .guid = guid,
                .local = row.read(incremental.LocalTransform3D).*,
                .parent_guid = parent_guid,
            });
        }
        return snap;
    }

    /// Validates snapshot invariants without mutating `target_world`.
    pub fn validate(self: *const SceneSnapshot3D, target_world: *const engine.World) !void {
        var seen = std.AutoHashMapUnmanaged(engine.EntityGuid, void).empty;
        defer seen.deinit(self.allocator);
        try seen.ensureTotalCapacity(self.allocator, @intCast(self.records.items.len));

        for (self.records.items) |rec| {
            if (!finiteLocal(rec.local)) return error.InvalidTransform;
            if (rec.guid == 0) return error.InvalidGuid;
            if (rec.parent_guid) |p| {
                if (p == 0 or p == rec.guid) return error.InvalidParent;
            }
            const gop = seen.getOrPutAssumeCapacity(rec.guid);
            if (gop.found_existing) return error.DuplicateGuid;
            if (target_world.findByGuid(rec.guid) != null) return error.DuplicateGuid;
        }

        for (self.records.items) |rec| {
            const p_guid = rec.parent_guid orelse continue;
            if (!seen.contains(p_guid)) return error.MissingParent;
        }
    }

    /// Restores entities with persistent GUIDs and `LocalTransform3D` + `Parent` links.
    /// Validates first, then commits; on failure after any spawn, despawns every entity created
    /// by this call so the destination world is left unchanged.
    pub fn restore(self: *const SceneSnapshot3D, target_world: *engine.World) !usize {
        try self.validate(target_world);
        _ = try target_world.registerComponent(incremental.LocalTransform3D);
        _ = try target_world.registerComponent(incremental.GlobalTransform3D);
        _ = try target_world.registerComponent(Parent);

        var guid_map = std.AutoHashMapUnmanaged(engine.EntityGuid, engine.EntityHandle).empty;
        defer guid_map.deinit(self.allocator);
        try guid_map.ensureTotalCapacity(self.allocator, @intCast(self.records.items.len));

        var spawned: std.ArrayList(engine.EntityHandle) = .empty;
        defer spawned.deinit(self.allocator);
        errdefer {
            var i = spawned.items.len;
            while (i > 0) {
                i -= 1;
                _ = target_world.despawn(spawned.items[i]) catch {};
            }
        }

        for (self.records.items) |rec| {
            const e = try target_world.spawn();
            try spawned.append(self.allocator, e);
            try target_world.assignPersistentGuid(e, rec.guid);
            guid_map.putAssumeCapacity(rec.guid, e);
            try target_world.set(e, incremental.LocalTransform3D, rec.local);
            try target_world.set(e, incremental.GlobalTransform3D, .{});
        }

        for (self.records.items) |rec| {
            const p_guid = rec.parent_guid orelse continue;
            const child_e = guid_map.get(rec.guid).?;
            const parent_e = guid_map.get(p_guid).?;
            try target_world.set(child_e, Parent, .{ .entity = parent_e });
        }
        try graph.rebuildLinks(target_world);
        return self.records.items.len;
    }
};

fn finiteLocal(t: incremental.LocalTransform3D) bool {
    inline for (.{ t.translation, t.scale }) |vec| {
        inline for (vec) |v| {
            if (!std.math.isFinite(v)) return false;
        }
    }
    inline for (t.rotation) |v| {
        if (!std.math.isFinite(v)) return false;
    }
    return true;
}

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
        try graph.rebuildLinks(target_world);
        return self.records.items.len;
    }
};

/// 2x3 affine matrix used for 2D transform composition, inversion, and decomposition.
pub const Mat2D = struct {
    // 2x3 affine matrix: [ a c tx ; b d ty ]
    a: f32,
    b: f32,
    c: f32,
    d: f32,
    tx: f32,
    ty: f32,

    /// The identity transform.
    pub const identity: Mat2D = .{ .a = 1, .b = 0, .c = 0, .d = 1, .tx = 0, .ty = 0 };

    /// Matrix of the *world-space* fields (`world_x`, `world_rotation_rad`, ...) of `t`.
    pub fn fromWorld(t: Transform2D) Mat2D {
        return fromTransform(.{
            .x = t.world_x,
            .y = t.world_y,
            .rotation_rad = t.world_rotation_rad,
            .scale_x = t.world_scale_x,
            .scale_y = t.world_scale_y,
        });
    }

    /// Returns the inverse, or null when the matrix is (near-)singular.
    pub fn inverse(m: Mat2D) ?Mat2D {
        const det = m.a * m.d - m.b * m.c;
        if (!std.math.isFinite(det) or @abs(det) < 1e-12) return null;
        const inv = 1.0 / det;
        const a = m.d * inv;
        const b = -m.b * inv;
        const c = -m.c * inv;
        const d = m.a * inv;
        return .{
            .a = a,
            .b = b,
            .c = c,
            .d = d,
            .tx = -(a * m.tx + c * m.ty),
            .ty = -(b * m.tx + d * m.ty),
        };
    }

    /// Decomposes into translation, rotation, and scale. Shear cannot be represented by
    /// `Transform2D` and is discarded (scale_y is taken from the determinant).
    pub fn decompose(m: Mat2D) Transform2D {
        const sx = std.math.hypot(m.a, m.b);
        const det = m.a * m.d - m.b * m.c;
        return .{
            .x = m.tx,
            .y = m.ty,
            .rotation_rad = std.math.atan2(m.b, m.a),
            .scale_x = sx,
            .scale_y = if (sx > 0) det / sx else 0,
        };
    }

    /// Matrix of the *local* fields (`x`, `y`, `rotation_rad`, `scale_*`) of `t`.
    pub fn fromTransform(t: Transform2D) Mat2D {
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

    /// Returns `parent_m * local_m` (apply `local_m` first, then `parent_m`).
    pub fn mul(parent_m: Mat2D, local_m: Mat2D) Mat2D {
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

/// Resolved world-space state of one node during a propagation pass.
const Resolved = struct {
    m: Mat2D,
    rot: f32,
    sx: f32,
    sy: f32,
    /// True when the node's ancestor chain loops; such nodes fall back to local-only values.
    cyclic: bool,

    fn local(t: Transform2D, cyclic: bool) Resolved {
        return .{ .m = Mat2D.fromTransform(t), .rot = t.rotation_rad, .sx = t.scale_x, .sy = t.scale_y, .cyclic = cyclic };
    }

    fn compose(base: Resolved, t: Transform2D) Resolved {
        if (base.cyclic) return local(t, true);
        return .{
            .m = Mat2D.mul(base.m, Mat2D.fromTransform(t)),
            .rot = base.rot + t.rotation_rad,
            .sx = base.sx * t.scale_x,
            .sy = base.sy * t.scale_y,
            .cyclic = false,
        };
    }
};

const node_unvisited: u8 = 0;
const node_in_progress: u8 = 1;
const node_done: u8 = 2;

/// Propagates local `Transform2D` (translation, rotation, scale) through `Parent` chains.
///
/// Each node is resolved exactly once per pass (parents before children, memoized by entity
/// slot), so cost is O(N) instead of O(N x depth). Entities whose ancestor chain contains a
/// cycle fall back to their local values. Scratch buffers are allocated per pass.
pub fn propagateTransformsSystem(ctx: *engine.SystemContext) !void {
    const allocator = ctx.world.allocator;
    const slots = ctx.world.generations.items.len;

    const state = try allocator.alloc(u8, slots);
    defer allocator.free(state);
    @memset(state, node_unvisited);
    const resolved = try allocator.alloc(Resolved, slots);
    defer allocator.free(resolved);
    var stack: std.ArrayList(engine.EntityHandle) = .empty;
    defer stack.deinit(allocator);

    var q = try ctx.query(.{ .write = .{Transform2D} });
    defer q.deinit();

    while (q.next()) |row| {
        const t = row.write(Transform2D);
        if (state[row.entity.index] != node_done) {
            try resolveChain(ctx.world, row.entity, state, resolved, &stack, allocator);
        }
        const r = resolved[row.entity.index];
        t.world_x = r.m.tx;
        t.world_y = r.m.ty;
        t.world_rotation_rad = r.rot;
        t.world_scale_x = r.sx;
        t.world_scale_y = r.sy;
    }
}

/// Walks up from `start` to the nearest resolved ancestor (or root/cycle), then resolves the
/// walked nodes top-down.
fn resolveChain(
    world: *const engine.World,
    start: engine.EntityHandle,
    state: []u8,
    resolved: []Resolved,
    stack: *std.ArrayList(engine.EntityHandle),
    allocator: std.mem.Allocator,
) !void {
    stack.clearRetainingCapacity();
    var base: ?Resolved = null;
    var cyclic = false;
    var cur = start;
    while (true) {
        const idx = cur.index;
        if (state[idx] == node_done) {
            base = resolved[idx];
            break;
        }
        if (state[idx] == node_in_progress) {
            cyclic = true;
            break;
        }
        state[idx] = node_in_progress;
        try stack.append(allocator, cur);
        const parent = world.getConst(cur, Parent) orelse break;
        // A parent without Transform2D acts as a root, matching previous behaviour.
        if (world.getConst(parent.entity, Transform2D) == null) break;
        cur = parent.entity;
    }

    while (stack.pop()) |h| {
        const t = world.getConst(h, Transform2D).?.*;
        const r = if (cyclic or (base != null and base.?.cyclic))
            Resolved.local(t, true)
        else if (base) |b|
            b.compose(t)
        else
            Resolved.local(t, false);
        resolved[h.index] = r;
        state[h.index] = node_done;
        base = r;
    }
}

fn buildModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    _ = try app.registerComponent(Transform2D);
    _ = try app.registerComponent(Parent);
    try incremental.install(app);
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
            .version = "0.3.0",
            .provides_capabilities = &.{"engine.scene.2d/1"},
        },
        .build = buildModule,
    };
}
