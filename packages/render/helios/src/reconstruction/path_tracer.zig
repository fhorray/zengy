//! Stage 13.2 & 13.3 Reference Progressive Path Tracer & A-Trous Spatial Denoiser (`packages/render/helios/src/reconstruction/path_tracer.zig`).
//!
//! Provides:
//! - Deterministic CPU progressive reference path tracer (`ReferencePathTracer`) over `helios.ray_query.Bvh`
//!   for stationary ground-truth comparisons and baked-GI validation.
//! - Edge-aware A-Trous wavelet spatial denoiser (`atrousDenoisePass`) using depth, normal, and luminance weights.

const std = @import("std");
const bvh_mod = @import("../ray_query/bvh.zig");
const ssgi = @import("../hybrid/ssgi.zig");

/// Diffuse/emissive surface properties indexed by `instance_id` for reference path tracing.
pub const PathTraceMaterial = struct {
    albedo: [3]f32 = .{ 0.7, 0.7, 0.7 },
    emissive: [3]f32 = .{ 0, 0, 0 },
};

/// Configuration for the progressive reference path tracer.
pub const PathTracerConfig = struct {
    width: u32 = 32,
    height: u32 = 32,
    max_bounces: u32 = 3,
    seed: u64 = 0x5A45_4E47_5950,
    sky_color: [3]f32 = .{ 0.35, 0.55, 0.85 },
};

/// Progressive CPU reference path tracer accumulating linear RGB radiance per pixel.
pub const ReferencePathTracer = struct {
    allocator: std.mem.Allocator,
    config: PathTracerConfig,
    accum_rgb: [][3]f32,
    sample_count: u32 = 0,
    prng: std.Random.DefaultPrng,

    /// Allocates accumulation buffer for `config.width * config.height` pixels.
    pub fn init(allocator: std.mem.Allocator, config: PathTracerConfig) !ReferencePathTracer {
        const n = @as(usize, config.width) * @as(usize, config.height);
        const buf = try allocator.alloc([3]f32, n);
        @memset(buf, .{ 0, 0, 0 });
        return .{
            .allocator = allocator,
            .config = config,
            .accum_rgb = buf,
            .prng = std.Random.DefaultPrng.init(config.seed),
        };
    }

    /// Frees the accumulation buffer.
    pub fn deinit(self: *ReferencePathTracer) void {
        self.allocator.free(self.accum_rgb);
    }

    /// Resets progressive accumulation (e.g. on camera move or scene edit).
    pub fn reset(self: *ReferencePathTracer) void {
        @memset(self.accum_rgb, .{ 0, 0, 0 });
        self.sample_count = 0;
        self.prng = std.Random.DefaultPrng.init(self.config.seed);
    }

    /// Traces 1 sample per pixel from a pinhole camera at `cam_pos` looking down `-Z` and accumulates radiance.
    pub fn accumulatePass(
        self: *ReferencePathTracer,
        bvh: *const bvh_mod.Bvh,
        materials: []const PathTraceMaterial,
        cam_pos: [3]f32,
    ) void {
        const rand = self.prng.random();
        const fw: f32 = @floatFromInt(@max(self.config.width, 1));
        const fh: f32 = @floatFromInt(@max(self.config.height, 1));
        const aspect = fw / fh;

        var py: u32 = 0;
        while (py < self.config.height) : (py += 1) {
            var px: u32 = 0;
            while (px < self.config.width) : (px += 1) {
                const u = ((@as(f32, @floatFromInt(px)) + rand.float(f32)) / fw) * 2.0 - 1.0;
                const v = 1.0 - ((@as(f32, @floatFromInt(py)) + rand.float(f32)) / fh) * 2.0;
                const raw_d = [3]f32{ u * aspect * 0.6, v * 0.6, -1.0 };
                const dlen = @sqrt(raw_d[0] * raw_d[0] + raw_d[1] * raw_d[1] + raw_d[2] * raw_d[2]);
                var ray = bvh_mod.Ray{
                    .origin = cam_pos,
                    .direction = .{ raw_d[0] / dlen, raw_d[1] / dlen, raw_d[2] / dlen },
                };

                var throughput = [3]f32{ 1, 1, 1 };
                var radiance = [3]f32{ 0, 0, 0 };

                var bounce: u32 = 0;
                while (bounce <= self.config.max_bounces) : (bounce += 1) {
                    const hit = bvh.traceClosest(ray, null);
                    if (!hit.hit) {
                        radiance[0] += throughput[0] * self.config.sky_color[0];
                        radiance[1] += throughput[1] * self.config.sky_color[1];
                        radiance[2] += throughput[2] * self.config.sky_color[2];
                        break;
                    }
                    const mat = if (hit.instance_id < materials.len) materials[hit.instance_id] else PathTraceMaterial{};
                    radiance[0] += throughput[0] * mat.emissive[0];
                    radiance[1] += throughput[1] * mat.emissive[1];
                    radiance[2] += throughput[2] * mat.emissive[2];

                    throughput[0] *= mat.albedo[0];
                    throughput[1] *= mat.albedo[1];
                    throughput[2] *= mat.albedo[2];

                    // Russian roulette after bounce 1
                    if (bounce >= 1) {
                        const p = std.math.clamp(@max(throughput[0], @max(throughput[1], throughput[2])), 0.05, 0.95);
                        if (rand.float(f32) > p) break;
                        throughput[0] /= p;
                        throughput[1] /= p;
                        throughput[2] /= p;
                    }

                    const n = hit.normal;
                    const hit_p = [3]f32{
                        ray.origin[0] + ray.direction[0] * hit.t + n[0] * 1e-3,
                        ray.origin[1] + ray.direction[1] * hit.t + n[1] * 1e-3,
                        ray.origin[2] + ray.direction[2] * hit.t + n[2] * 1e-3,
                    };
                    const next_dir = ssgi.cosineHemisphereSample(rand.float(f32), rand.float(f32), n);
                    ray = .{ .origin = hit_p, .direction = next_dir };
                }

                const idx = @as(usize, py) * self.config.width + px;
                self.accum_rgb[idx][0] += radiance[0];
                self.accum_rgb[idx][1] += radiance[1];
                self.accum_rgb[idx][2] += radiance[2];
            }
        }
        self.sample_count += 1;
    }

    /// Returns the resolved average RGB radiance at `(x, y)`.
    pub fn resolvedPixel(self: *const ReferencePathTracer, x: u32, y: u32) [3]f32 {
        if (self.sample_count == 0 or x >= self.config.width or y >= self.config.height) return .{ 0, 0, 0 };
        const inv = 1.0 / @as(f32, @floatFromInt(self.sample_count));
        const p = self.accum_rgb[@as(usize, y) * self.config.width + x];
        return .{ p[0] * inv, p[1] * inv, p[2] * inv };
    }
};

/// Edge-stopping A-Trous wavelet spatial denoising pass (`step_width = 1, 2, 4, ...`).
pub fn atrousDenoisePass(
    src_rgb: []const [3]f32,
    depth: []const f32,
    normals: []const [3]f32,
    dst_rgb: [][3]f32,
    width: u32,
    height: u32,
    step_width: i32,
    phi_depth: f32,
    phi_normal: f32,
    phi_luma: f32,
) void {
    const kernel = [3]f32{ 0.25, 0.5, 0.25 };
    const iw: i32 = @intCast(width);
    const ih: i32 = @intCast(height);

    var y: i32 = 0;
    while (y < ih) : (y += 1) {
        var x: i32 = 0;
        while (x < iw) : (x += 1) {
            const cidx = @as(usize, @intCast(y)) * width + @as(usize, @intCast(x));
            const c_rgb = src_rgb[cidx];
            const c_d = depth[cidx];
            const c_n = normals[cidx];
            const c_luma = 0.2126 * c_rgb[0] + 0.7152 * c_rgb[1] + 0.0722 * c_rgb[2];

            var sum_rgb = [3]f32{ 0, 0, 0 };
            var sum_w: f32 = 0.0;

            var ky: i32 = -1;
            while (ky <= 1) : (ky += 1) {
                var kx: i32 = -1;
                while (kx <= 1) : (kx += 1) {
                    const nx = std.math.clamp(x + kx * step_width, 0, iw - 1);
                    const ny = std.math.clamp(y + ky * step_width, 0, ih - 1);
                    const nidx = @as(usize, @intCast(ny)) * width + @as(usize, @intCast(nx));

                    const s_rgb = src_rgb[nidx];
                    const s_d = depth[nidx];
                    const s_n = normals[nidx];
                    const s_luma = 0.2126 * s_rgb[0] + 0.7152 * s_rgb[1] + 0.0722 * s_rgb[2];

                    const w_k = kernel[@intCast(kx + 1)] * kernel[@intCast(ky + 1)];
                    const w_d = @exp(-@abs(c_d - s_d) / @max(phi_depth, 1e-4));
                    const ndot = std.math.clamp(c_n[0] * s_n[0] + c_n[1] * s_n[1] + c_n[2] * s_n[2], 0.0, 1.0);
                    const w_n = std.math.pow(f32, ndot, @max(phi_normal, 1.0));
                    const w_l = @exp(-@abs(c_luma - s_luma) / @max(phi_luma, 1e-4));

                    const w = w_k * w_d * w_n * w_l;
                    sum_rgb[0] += s_rgb[0] * w;
                    sum_rgb[1] += s_rgb[1] * w;
                    sum_rgb[2] += s_rgb[2] * w;
                    sum_w += w;
                }
            }

            if (sum_w > 1e-6) {
                dst_rgb[cidx] = .{ sum_rgb[0] / sum_w, sum_rgb[1] / sum_w, sum_rgb[2] / sum_w };
            } else {
                dst_rgb[cidx] = c_rgb;
            }
        }
    }
}
