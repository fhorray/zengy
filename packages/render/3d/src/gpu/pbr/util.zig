//! Pure math helpers for the PBR renderer: cascade matrices, projections, matrix inverse, half-float clamp.

const std = @import("std");
const render_3d = @import("render_3d");

const math3d = render_3d.math3d;

pub fn computeCascadeMatrix(ldir: math3d.Vec3, center: math3d.Vec3, half_ext: f32, tex_size: f32, depth_range: f32) math3d.Mat4 {
    const up = math3d.Vec3{ .x = 0, .y = if (@abs(ldir.y) > 0.95) 0.0 else 1.0, .z = if (@abs(ldir.y) > 0.95) 1.0 else 0.0 };
    const eye = math3d.Vec3{
        .x = center.x - ldir.x * (depth_range * 0.5),
        .y = center.y - ldir.y * (depth_range * 0.5),
        .z = center.z - ldir.z * (depth_range * 0.5),
    };
    const lview = math3d.Mat4.lookAt(eye, center, up);
    // Texel-snap the light-space origin to prevent shadow shimmering during camera motion.
    const texel_world = (half_ext * 2.0) / tex_size;
    const ox = lview.m[12];
    const oy = lview.m[13];
    const sx = @floor(ox / texel_world) * texel_world - ox;
    const sy = @floor(oy / texel_world) * texel_world - oy;
    var snapped = lview;
    snapped.m[12] += sx;
    snapped.m[13] += sy;
    const lproj = orthoMat(-half_ext, half_ext, -half_ext, half_ext, 0.5, depth_range);
    return math3d.Mat4.mul(lproj, snapped);
}

pub fn perspectiveMat(fov_rad: f32, aspect: f32, near: f32, far: f32) math3d.Mat4 {
    const f = 1.0 / @tan(fov_rad * 0.5);
    const fn_ = near - far;
    return .{ .m = .{
        f / aspect, 0, 0,                  0,
        0,          f, 0,                  0,
        0,          0, far / fn_,          -1,
        0,          0, (near * far) / fn_, 0,
    } };
}

pub fn clampToF16(v: f32) f16 {
    if (!std.math.isFinite(v)) return 0.0;
    return @floatCast(std.math.clamp(v, -65000.0, 65000.0));
}

pub fn orthoMat(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) math3d.Mat4 {
    const rl = right - left;
    const tb = top - bottom;
    const fn_ = far - near;
    return .{ .m = .{
        2.0 / rl,             0,                    0,           0,
        0,                    2.0 / tb,             0,           0,
        0,                    0,                    -1.0 / fn_,  0,
        -(right + left) / rl, -(top + bottom) / tb, -near / fn_, 1,
    } };
}

pub fn normalMatrixFromModel(m: [16]f32) [16]f32 {
    const a00 = m[0];
    const a01 = m[4];
    const a02 = m[8];
    const a10 = m[1];
    const a11 = m[5];
    const a12 = m[9];
    const a20 = m[2];
    const a21 = m[6];
    const a22 = m[10];
    const c00 = a11 * a22 - a12 * a21;
    const c01 = -(a10 * a22 - a12 * a20);
    const c02 = a10 * a21 - a11 * a20;
    const c10 = -(a01 * a22 - a02 * a21);
    const c11 = a00 * a22 - a02 * a20;
    const c12 = -(a00 * a21 - a01 * a20);
    const c20 = a01 * a12 - a02 * a11;
    const c21 = -(a00 * a12 - a02 * a10);
    const c22 = a00 * a11 - a01 * a10;
    const det = a00 * c00 + a01 * c01 + a02 * c02;
    if (@abs(det) < 1e-8) return math3d.Mat4.identity().m;
    const inv_det = 1.0 / det;
    // Column-major inverse-transpose (cofactor matrix stored row-wise into columns).
    return .{
        c00 * inv_det, c10 * inv_det, c20 * inv_det, 0,
        c01 * inv_det, c11 * inv_det, c21 * inv_det, 0,
        c02 * inv_det, c12 * inv_det, c22 * inv_det, 0,
        0,             0,             0,             1,
    };
}

pub fn invertMat4(m: [16]f32) [16]f32 {
    var inv: [16]f32 = undefined;
    inv[0] = m[5] * m[10] * m[15] - m[5] * m[11] * m[14] - m[9] * m[6] * m[15] + m[9] * m[7] * m[14] + m[13] * m[6] * m[11] - m[13] * m[7] * m[10];
    inv[4] = -m[4] * m[10] * m[15] + m[4] * m[11] * m[14] + m[8] * m[6] * m[15] - m[8] * m[7] * m[14] - m[12] * m[6] * m[11] + m[12] * m[7] * m[10];
    inv[8] = m[4] * m[9] * m[15] - m[4] * m[11] * m[13] - m[8] * m[5] * m[15] + m[8] * m[7] * m[13] + m[12] * m[5] * m[11] - m[12] * m[7] * m[9];
    inv[12] = -m[4] * m[9] * m[14] + m[4] * m[10] * m[13] + m[8] * m[5] * m[14] - m[8] * m[6] * m[13] - m[12] * m[5] * m[10] + m[12] * m[6] * m[9];
    inv[1] = -m[1] * m[10] * m[15] + m[1] * m[11] * m[14] + m[9] * m[2] * m[15] - m[9] * m[3] * m[14] - m[13] * m[2] * m[11] + m[13] * m[3] * m[10];
    inv[5] = m[0] * m[10] * m[15] - m[0] * m[11] * m[14] - m[8] * m[2] * m[15] + m[8] * m[3] * m[14] + m[12] * m[2] * m[11] - m[12] * m[3] * m[10];
    inv[9] = -m[0] * m[9] * m[15] + m[0] * m[11] * m[13] + m[8] * m[1] * m[15] - m[8] * m[3] * m[13] - m[12] * m[1] * m[11] + m[12] * m[3] * m[9];
    inv[13] = m[0] * m[9] * m[14] - m[0] * m[10] * m[13] - m[8] * m[1] * m[14] + m[8] * m[2] * m[13] + m[12] * m[1] * m[10] - m[12] * m[2] * m[9];
    inv[2] = m[1] * m[6] * m[15] - m[1] * m[7] * m[14] - m[5] * m[2] * m[15] + m[5] * m[3] * m[14] + m[13] * m[2] * m[7] - m[13] * m[3] * m[6];
    inv[6] = -m[0] * m[6] * m[15] + m[0] * m[7] * m[14] + m[4] * m[2] * m[15] - m[4] * m[3] * m[14] - m[12] * m[2] * m[7] + m[12] * m[3] * m[6];
    inv[10] = m[0] * m[5] * m[15] - m[0] * m[7] * m[13] - m[4] * m[1] * m[15] + m[4] * m[3] * m[13] + m[12] * m[1] * m[7] - m[12] * m[3] * m[5];
    inv[14] = -m[0] * m[5] * m[14] + m[0] * m[6] * m[13] + m[4] * m[1] * m[14] - m[4] * m[2] * m[13] - m[12] * m[1] * m[6] + m[12] * m[2] * m[5];
    inv[3] = -m[1] * m[6] * m[11] + m[1] * m[7] * m[10] + m[5] * m[2] * m[11] - m[5] * m[3] * m[10] - m[9] * m[2] * m[7] + m[9] * m[3] * m[6];
    inv[7] = m[0] * m[6] * m[11] - m[0] * m[7] * m[10] - m[4] * m[2] * m[11] + m[4] * m[3] * m[10] + m[8] * m[2] * m[7] - m[8] * m[3] * m[6];
    inv[11] = -m[0] * m[5] * m[11] + m[0] * m[7] * m[9] + m[4] * m[1] * m[11] - m[4] * m[3] * m[9] - m[8] * m[1] * m[7] + m[8] * m[3] * m[5];
    inv[15] = m[0] * m[5] * m[10] - m[0] * m[6] * m[9] - m[4] * m[1] * m[10] + m[4] * m[2] * m[9] + m[8] * m[1] * m[6] - m[8] * m[2] * m[5];

    var det = m[0] * inv[0] + m[1] * inv[4] + m[2] * inv[8] + m[3] * inv[12];
    if (@abs(det) < 1e-8) return math3d.Mat4.identity().m;
    det = 1.0 / det;
    for (&inv) |*v| v.* *= det;
    return inv;
}

pub fn safeClamp(v: f32, lo: f32, hi: f32, fallback: f32) f32 {
    return if (std.math.isFinite(v)) std.math.clamp(v,lo,hi) else fallback;
}

/// Cheap content fingerprint of an HDRI: samples about 256 pixels spread over the image.
/// The cache compares pointers as well, but a buffer rewritten in place keeps its pointer.
pub fn hdriSampleHash(pixels: ?[]const [4]f32) u64 {
    const px = pixels orelse return 0;
    if (px.len == 0) return 0;
    var h: u64 = 0xcbf29ce484222325;
    const stride = @max(px.len / 256, 1);
    var i: usize = 0;
    while (i < px.len) : (i += stride) {
        for (px[i]) |v| {
            h = (h ^ @as(u64, @as(u32, @bitCast(v)))) *% 0x100000001b3;
        }
    }
    return h;
}
