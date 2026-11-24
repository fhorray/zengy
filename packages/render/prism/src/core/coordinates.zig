//! Canonical Prism Coordinate Convention, Jitter & Motion Vectors (`packages/render/prism/src/core/coordinates.zig`).
//!
//! Stage 03 shared convention:
//! - Right-handed world space (`+X` right, `+Y` up, `-Z` forward)
//! - Column-major 4x4 matrices
//! - `[0.0, 1.0]` clip-space depth range (Vulkan / SDL_GPU)
//! - Top-left `(0, 0)` viewport & UV origin
//! - Counter-clockwise (CCW) front-face winding

const std = @import("std");

/// Halton low-discrepancy radical inverse in base `base` for 1-based `index`.
pub fn halton(index: u64, comptime base: u32) f32 {
    var f: f32 = 1.0;
    var r: f32 = 0.0;
    var i: u64 = index;
    const bf: f32 = @floatFromInt(base);
    while (i > 0) {
        f /= bf;
        r += f * @as(f32, @floatFromInt(i % base));
        i /= base;
    }
    return r;
}

/// Returns sub-pixel Halton (2, 3) jitter in pixels `[-0.5, +0.5]` and NDC offsets for TAA.
pub fn haltonJitter(frame_index: u64, width: u32, height: u32) struct { px: [2]f32, ndc: [2]f32 } {
    const seq_idx = (frame_index % 16) + 1;
    const jx = halton(seq_idx, 2) - 0.5;
    const jy = halton(seq_idx, 3) - 0.5;
    const w: f32 = @floatFromInt(@max(width, 1));
    const h: f32 = @floatFromInt(@max(height, 1));
    return .{
        .px = .{ jx, jy },
        .ndc = .{ (jx * 2.0) / w, (jy * 2.0) / h },
    };
}

/// Applies sub-pixel NDC jitter `(jx, jy)` to a column-major perspective projection matrix.
pub fn applyProjectionJitter(proj: [16]f32, jitter_ndc: [2]f32) [16]f32 {
    var out = proj;
    out[8] += jitter_ndc[0];
    out[9] += jitter_ndc[1];
    return out;
}

/// Reconstructs positive view-space linear depth from `[0..1]` perspective NDC depth.
pub fn linearizeDepth(ndc_z: f32, near: f32, far: f32) f32 {
    const z: f64 = ndc_z;
    const n: f64 = near;
    const f: f64 = far;
    const denom = f - z * (f - n);
    if (@abs(denom) < 1e-9) return far;
    return @floatCast((n * f) / denom);
}

/// Multiplies a column-major 4x4 matrix by a 4-component vector.
pub fn mat4MulVec4(m: [16]f32, v: [4]f32) [4]f32 {
    return .{
        m[0] * v[0] + m[4] * v[1] + m[8] * v[2] + m[12] * v[3],
        m[1] * v[0] + m[5] * v[1] + m[9] * v[2] + m[13] * v[3],
        m[2] * v[0] + m[6] * v[1] + m[10] * v[2] + m[14] * v[3],
        m[3] * v[0] + m[7] * v[1] + m[11] * v[2] + m[15] * v[3],
    };
}

/// Computes UV-space motion vector `(curr_uv - prev_uv)` for a local point moving between
/// `(prev_model, prev_clip_from_world)` and `(curr_model, curr_clip_from_world)`.
pub fn computeMotionVector(
    curr_clip_from_world: [16]f32,
    prev_clip_from_world: [16]f32,
    curr_model: [16]f32,
    prev_model: [16]f32,
    local_pos: [3]f32,
) ?[2]f32 {
    const lp = [4]f32{ local_pos[0], local_pos[1], local_pos[2], 1.0 };
    const curr_w = mat4MulVec4(curr_model, lp);
    const prev_w = mat4MulVec4(prev_model, lp);
    const curr_c = mat4MulVec4(curr_clip_from_world, curr_w);
    const prev_c = mat4MulVec4(prev_clip_from_world, prev_w);
    if (@abs(curr_c[3]) < 1e-6 or @abs(prev_c[3]) < 1e-6) return null;

    const curr_uv = [2]f32{
        (curr_c[0] / curr_c[3]) * 0.5 + 0.5,
        0.5 - (curr_c[1] / curr_c[3]) * 0.5,
    };
    const prev_uv = [2]f32{
        (prev_c[0] / prev_c[3]) * 0.5 + 0.5,
        0.5 - (prev_c[1] / prev_c[3]) * 0.5,
    };
    return .{ curr_uv[0] - prev_uv[0], curr_uv[1] - prev_uv[1] };
}
