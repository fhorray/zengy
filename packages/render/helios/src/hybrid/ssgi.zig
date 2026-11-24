//! Helios Screen-Space Global Illumination (SSGI) Hi-Z Traversal (`packages/render/helios/src/hybrid/ssgi.zig`).
//!
//! Consumes Prism's `HiZPyramid` for bounded screen-space ray traversal and
//! cosine-weighted hemisphere sampling.

const std = @import("std");
const prism = @import("prism");

/// Result of a bounded Hi-Z screen-space ray trace.
pub const SsgiTraceResult = struct {
    hit: bool = false,
    hit_uv: [2]f32 = .{ 0, 0 },
    hit_depth: f32 = 1.0,
    steps: u32 = 0,
    confidence: f32 = 0.0,
};

/// Generates a cosine-weighted hemisphere unit direction around `normal` from `(xi1, xi2)` in `[0, 1)`.
pub fn cosineHemisphereSample(xi1: f32, xi2: f32, normal: [3]f32) [3]f32 {
    const r = @sqrt(std.math.clamp(xi1, 0.0, 1.0));
    const phi = 2.0 * std.math.pi * xi2;
    const lx = r * @cos(phi);
    const ly = r * @sin(phi);
    const lz = @sqrt(@max(0.0, 1.0 - xi1));

    const up: [3]f32 = if (@abs(normal[1]) < 0.99) .{ 0, 1, 0 } else .{ 1, 0, 0 };
    const tx = up[1] * normal[2] - up[2] * normal[1];
    const ty = up[2] * normal[0] - up[0] * normal[2];
    const tz = up[0] * normal[1] - up[1] * normal[0];
    const tlen = @max(@sqrt(tx * tx + ty * ty + tz * tz), 1e-6);
    const t = [3]f32{ tx / tlen, ty / tlen, tz / tlen };
    const b = [3]f32{
        normal[1] * t[2] - normal[2] * t[1],
        normal[2] * t[0] - normal[0] * t[2],
        normal[0] * t[1] - normal[1] * t[0],
    };

    const out = [3]f32{
        t[0] * lx + b[0] * ly + normal[0] * lz,
        t[1] * lx + b[1] * ly + normal[1] * lz,
        t[2] * lx + b[2] * ly + normal[2] * lz,
    };
    const olen = @max(@sqrt(out[0] * out[0] + out[1] * out[1] + out[2] * out[2]), 1e-6);
    return .{ out[0] / olen, out[1] / olen, out[2] / olen };
}

/// Traces a bounded screen-space ray `(start_uv, start_depth)` along `step_uvz` against `hiz`.
/// Uses conservative thickness checks and screen-edge confidence falloff.
pub fn traceHiZScreenSpace(
    hiz: *const prism.HiZPyramid,
    start_uv: [2]f32,
    start_depth: f32,
    step_uvz: [3]f32,
    max_steps: u32,
    thickness: f32,
) SsgiTraceResult {
    if (hiz.mipCount() == 0 or hiz.base_width == 0 or hiz.base_height == 0) return .{};

    var uv = start_uv;
    var depth = start_depth;
    const fw: f32 = @floatFromInt(hiz.base_width);
    const fh: f32 = @floatFromInt(hiz.base_height);

    var s: u32 = 0;
    while (s < max_steps) : (s += 1) {
        uv[0] += step_uvz[0];
        uv[1] += step_uvz[1];
        depth += step_uvz[2];

        if (uv[0] < 0.0 or uv[0] > 1.0 or uv[1] < 0.0 or uv[1] > 1.0 or depth <= 0.0 or depth >= 1.0) {
            return .{ .hit = false, .steps = s + 1, .confidence = 0.0 };
        }

        const px: u32 = @intFromFloat(std.math.clamp(uv[0] * (fw - 1.0), 0.0, fw - 1.0));
        const py: u32 = @intFromFloat(std.math.clamp(uv[1] * (fh - 1.0), 0.0, fh - 1.0));
        const scene_d = hiz.sampleMip(0, px, py) orelse continue;

        const diff = depth - scene_d;
        if (diff >= 0.0 and diff <= thickness) {
            const edge_x = @min(uv[0], 1.0 - uv[0]) / 0.1;
            const edge_y = @min(uv[1], 1.0 - uv[1]) / 0.1;
            const edge_w = std.math.clamp(@min(edge_x, edge_y), 0.0, 1.0);
            const dist_w = 1.0 - (@as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(@max(max_steps, 1))));
            return .{
                .hit = true,
                .hit_uv = uv,
                .hit_depth = scene_d,
                .steps = s + 1,
                .confidence = std.math.clamp(edge_w * (0.35 + 0.65 * dist_w), 0.0, 1.0),
            };
        }
    }
    return .{ .hit = false, .steps = max_steps, .confidence = 0.0 };
}
