//! Shadow-caster culling helpers (`render-3d` GPU renderer). Pure Zig, so they are unit-tested headlessly.

const std = @import("std");

/// Local-space bounding sphere of a mesh.
pub const Sphere = struct {
    center: [3]f32 = .{ 0, 0, 0 },
    radius: f32 = 0,
};

/// Bounding sphere of interleaved vertices with `stride` bytes and a `[3]f32` position at offset 0.
/// The center is the AABB center, so the sphere is a little loose but never misses a vertex.
pub fn sphereFromVertices(vertex_bytes: []const u8, stride: usize) Sphere {
    if (stride < 12 or vertex_bytes.len < stride) return .{};
    const count = vertex_bytes.len / stride;
    var lo: [3]f32 = .{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) };
    var hi: [3]f32 = .{ -std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };
    for (0..count) |i| {
        const p = readPos(vertex_bytes, i * stride);
        for (0..3) |k| {
            lo[k] = @min(lo[k], p[k]);
            hi[k] = @max(hi[k], p[k]);
        }
    }
    const center = [3]f32{ (lo[0] + hi[0]) * 0.5, (lo[1] + hi[1]) * 0.5, (lo[2] + hi[2]) * 0.5 };
    var r2: f32 = 0;
    for (0..count) |i| {
        const p = readPos(vertex_bytes, i * stride);
        const dx = p[0] - center[0];
        const dy = p[1] - center[1];
        const dz = p[2] - center[2];
        r2 = @max(r2, dx * dx + dy * dy + dz * dz);
    }
    return .{ .center = center, .radius = @sqrt(r2) };
}

fn readPos(bytes: []const u8, offset: usize) [3]f32 {
    var out: [3]f32 = undefined;
    for (0..3) |k| out[k] = @bitCast(std.mem.readInt(u32, bytes[offset + k * 4 ..][0..4], .little));
    return out;
}

/// Transforms a local sphere by a column-major model matrix. The radius scales by the largest axis scale.
pub fn transformSphere(model: [16]f32, s: Sphere) Sphere {
    const c = s.center;
    const center = [3]f32{
        model[0] * c[0] + model[4] * c[1] + model[8] * c[2] + model[12],
        model[1] * c[0] + model[5] * c[1] + model[9] * c[2] + model[13],
        model[2] * c[0] + model[6] * c[1] + model[10] * c[2] + model[14],
    };
    const sx = @sqrt(model[0] * model[0] + model[1] * model[1] + model[2] * model[2]);
    const sy = @sqrt(model[4] * model[4] + model[5] * model[5] + model[6] * model[6]);
    const sz = @sqrt(model[8] * model[8] + model[9] * model[9] + model[10] * model[10]);
    return .{ .center = center, .radius = s.radius * @max(sx, @max(sy, sz)) };
}

/// Returns `true` when a world-space sphere lies fully outside the left, right, bottom, top, or far plane
/// of a column-major view-projection (depth in `[0, 1]`). The near plane is deliberately not tested: casters
/// between the light and its frustum can still shadow what is inside, and clipping them is harmless.
pub fn sphereOutsideLightFrustum(view_proj: [16]f32, s: Sphere) bool {
    // Row i of a column-major matrix is m[i], m[4 + i], m[8 + i], m[12 + i].
    const rows = [4][4]f32{
        .{ view_proj[0], view_proj[4], view_proj[8], view_proj[12] },
        .{ view_proj[1], view_proj[5], view_proj[9], view_proj[13] },
        .{ view_proj[2], view_proj[6], view_proj[10], view_proj[14] },
        .{ view_proj[3], view_proj[7], view_proj[11], view_proj[15] },
    };
    var planes: [5][4]f32 = undefined;
    for (0..4) |k| {
        planes[0][k] = rows[3][k] + rows[0][k]; // left
        planes[1][k] = rows[3][k] - rows[0][k]; // right
        planes[2][k] = rows[3][k] + rows[1][k]; // bottom
        planes[3][k] = rows[3][k] - rows[1][k]; // top
        planes[4][k] = rows[3][k] - rows[2][k]; // far
    }
    for (planes) |p| {
        const len = @sqrt(p[0] * p[0] + p[1] * p[1] + p[2] * p[2]);
        if (len < 1e-8) continue;
        const dist = (p[0] * s.center[0] + p[1] * s.center[1] + p[2] * s.center[2] + p[3]) / len;
        if (dist < -s.radius) return true;
    }
    return false;
}

fn identity() [16]f32 {
    var m: [16]f32 = @splat(0);
    m[0] = 1;
    m[5] = 1;
    m[10] = 1;
    m[15] = 1;
    return m;
}

test "sphereFromVertices encloses every vertex" {
    var bytes: [64]u8 = undefined;
    const verts = [2][8]f32{
        .{ -1, 0, 0, 0, 0, 0, 0, 0 },
        .{ 3, 2, 0, 0, 0, 0, 0, 0 },
    };
    for (verts, 0..) |v, i| {
        for (v, 0..) |f, k| std.mem.writeInt(u32, bytes[i * 32 + k * 4 ..][0..4], @bitCast(f), .little);
    }
    const s = sphereFromVertices(&bytes, 32);
    try std.testing.expectApproxEqAbs(@as(f32, 1), s.center[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), s.center[1], 1e-6);
    try std.testing.expectApproxEqAbs(@sqrt(@as(f32, 5)), s.radius, 1e-5);
}

test "transformSphere moves the center and scales the radius" {
    var m = identity();
    m[0] = 2;
    m[5] = 3;
    m[12] = 10;
    const t = transformSphere(m, .{ .center = .{ 1, 0, 0 }, .radius = 1 });
    try std.testing.expectApproxEqAbs(@as(f32, 12), t.center[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 3), t.radius, 1e-6);
}

test "light frustum test culls spheres outside an identity clip volume and keeps those inside or straddling" {
    const vp = identity();
    try std.testing.expect(!sphereOutsideLightFrustum(vp, .{ .center = .{ 0, 0, 0.5 }, .radius = 0.1 }));
    try std.testing.expect(sphereOutsideLightFrustum(vp, .{ .center = .{ 5, 0, 0.5 }, .radius = 0.5 }));
    try std.testing.expect(sphereOutsideLightFrustum(vp, .{ .center = .{ 0, -5, 0.5 }, .radius = 0.5 }));
    try std.testing.expect(sphereOutsideLightFrustum(vp, .{ .center = .{ 0, 0, 5 }, .radius = 0.5 }));
    // Straddling the right plane must be kept.
    try std.testing.expect(!sphereOutsideLightFrustum(vp, .{ .center = .{ 1.2, 0, 0.5 }, .radius = 0.5 }));
    // In front of the near plane is not culled.
    try std.testing.expect(!sphereOutsideLightFrustum(vp, .{ .center = .{ 0, 0, -3 }, .radius = 0.5 }));
}

/// A sphere inside which a light can put shadows on something visible (a point/spot light's range, or the fog
/// volume around the camera for the sun), restricted to the layers the light affects.
pub const Reach = struct {
    center: [3]f32,
    radius: f32,
    layers: u32,
};

/// True when `s` touches the reach sphere. Used to hash only the casters that can change a temporal result.
pub fn sphereWithinReach(s: Sphere, reach: Reach) bool {
    const dx = s.center[0] - reach.center[0];
    const dy = s.center[1] - reach.center[1];
    const dz = s.center[2] - reach.center[2];
    const r = reach.radius + s.radius;
    return dx * dx + dy * dy + dz * dz <= r * r;
}

test "reach spheres keep nearby casters and drop distant ones" {
    const reach: Reach = .{ .center = .{ 0, 0, 0 }, .radius = 10, .layers = 1 };
    try std.testing.expect(sphereWithinReach(.{ .center = .{ 5, 0, 0 }, .radius = 1 }, reach));
    try std.testing.expect(sphereWithinReach(.{ .center = .{ 12, 0, 0 }, .radius = 2.5 }, reach)); // touches the edge
    try std.testing.expect(!sphereWithinReach(.{ .center = .{ 40, 0, 0 }, .radius = 3 }, reach));
}
