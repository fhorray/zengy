//! Stage 13.2 One-Bounce Ray-Traced Indirect GI & Radiance Cache Population (`packages/render/helios/src/ray_query/indirect_rt.zig`).
//!
//! Pure-Zig ray-traced indirect illumination built on `Bvh` and `WorldRadianceCache`:
//! - Cosine-weighted one-bounce indirect diffuse queries with normal-offset self-intersection guard
//! - Roughness-aware GGX importance-sampled indirect specular queries
//! - Geometry-aware `WorldRadianceCache` population from traced hemisphere rays
//! - Scalable per-tier `HeliosQualityBudget` controls

const std = @import("std");
const bvh_mod = @import("bvh.zig");
const ssgi_mod = @import("../hybrid/ssgi.zig");
const cache_mod = @import("../hybrid/radiance_cache.zig");
const contract = @import("../hybrid/lighting_contract.zig");

/// Minimal surface material evaluated at secondary ray hits.
pub const SurfaceMaterial = struct {
    albedo: [3]f32 = .{ 0.7, 0.7, 0.7 },
    emissive: [3]f32 = .{ 0.0, 0.0, 0.0 },
    roughness: f32 = 0.5,
    metallic: f32 = 0.0,
};

/// Result of a single secondary diffuse or specular ray query.
pub const IndirectBounceResult = struct {
    radiance_rgb: [3]f32 = .{ 0, 0, 0 },
    hit_distance: f32 = 0.0,
    hit: bool = false,
    confidence: f32 = 0.0,
};

/// Scalable per-view ray-tracing and reconstruction quality budget.
pub const HeliosQualityBudget = struct {
    rays_per_pixel: u32,
    light_candidates: u32,
    cache_update_budget: u32,
    max_bounces: u32,
    denoiser_passes: u32,
};

/// Returns deterministic quality controls for `tier`.
pub fn budgetForTier(tier: contract.HeliosQualityTier) HeliosQualityBudget {
    return switch (tier) {
        .off => .{ .rays_per_pixel = 0, .light_candidates = 0, .cache_update_budget = 0, .max_bounces = 0, .denoiser_passes = 0 },
        .low => .{ .rays_per_pixel = 1, .light_candidates = 4, .cache_update_budget = 64, .max_bounces = 1, .denoiser_passes = 1 },
        .medium => .{ .rays_per_pixel = 2, .light_candidates = 8, .cache_update_budget = 192, .max_bounces = 1, .denoiser_passes = 2 },
        .high => .{ .rays_per_pixel = 4, .light_candidates = 16, .cache_update_budget = 512, .max_bounces = 2, .denoiser_passes = 3 },
    };
}

fn dot3(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn normalize3(v: [3]f32) [3]f32 {
    const l = @sqrt(dot3(v, v));
    if (l < 1e-6) return .{ 0, 1, 0 };
    return .{ v[0] / l, v[1] / l, v[2] / l };
}

fn cross3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

fn tangentBasis(n: [3]f32) struct { t: [3]f32, b: [3]f32 } {
    const up: [3]f32 = if (@abs(n[1]) < 0.999) .{ 0, 1, 0 } else .{ 1, 0, 0 };
    const t = normalize3(cross3(up, n));
    const b = cross3(n, t);
    return .{ .t = t, .b = b };
}

/// Traces a single one-bounce cosine-weighted diffuse ray from `world_pos` along `normal`.
/// Evaluates emissive + ambient-lit albedo on hit, or `sky_miss_rgb` on miss.
pub fn traceIndirectDiffuse(
    bvh: *const bvh_mod.Bvh,
    materials: []const SurfaceMaterial,
    world_pos: [3]f32,
    normal: [3]f32,
    xi1: f32,
    xi2: f32,
    max_distance: f32,
    sky_miss_rgb: [3]f32,
    stats: *bvh_mod.QueryStats,
) IndirectBounceResult {
    const n = normalize3(normal);
    const dir = ssgi_mod.cosineHemisphereSample(xi1, xi2, n);
    const origin = [3]f32{
        world_pos[0] + n[0] * 1e-3,
        world_pos[1] + n[1] * 1e-3,
        world_pos[2] + n[2] * 1e-3,
    };
    const ray = bvh_mod.Ray{ .origin = origin, .direction = dir, .t_min = 1e-3, .t_max = max_distance };
    const hit = bvh.traceClosest(ray, stats);
    if (hit.hit) {
        const mat = if (hit.instance_id < materials.len) materials[hit.instance_id] else SurfaceMaterial{};
        // Direct emissive + diffuse bounce approximation (avoids double-counting direct sky IBL).
        return .{
            .radiance_rgb = .{
                mat.emissive[0] + mat.albedo[0] * sky_miss_rgb[0] * 0.35,
                mat.emissive[1] + mat.albedo[1] * sky_miss_rgb[1] * 0.35,
                mat.emissive[2] + mat.albedo[2] * sky_miss_rgb[2] * 0.35,
            },
            .hit_distance = hit.t,
            .hit = true,
            .confidence = 1.0,
        };
    }
    return .{
        .radiance_rgb = sky_miss_rgb,
        .hit_distance = max_distance,
        .hit = false,
        .confidence = 0.75,
    };
}

/// Traces a roughness-aware GGX importance-sampled one-bounce indirect specular ray.
pub fn traceIndirectSpecular(
    bvh: *const bvh_mod.Bvh,
    materials: []const SurfaceMaterial,
    world_pos: [3]f32,
    normal: [3]f32,
    view_dir: [3]f32,
    roughness: f32,
    xi1: f32,
    xi2: f32,
    max_distance: f32,
    sky_miss_rgb: [3]f32,
    stats: *bvh_mod.QueryStats,
) IndirectBounceResult {
    const n = normalize3(normal);
    const v = normalize3(view_dir);
    const a = std.math.clamp(roughness, 0.045, 1.0);
    const a2 = a * a;

    // Sample GGX microfacet half-vector H in tangent space.
    const phi = 2.0 * std.math.pi * std.math.clamp(xi1, 0.0, 0.999999);
    const r2 = std.math.clamp(xi2, 0.0, 0.999999);
    const cos_theta = @sqrt((1.0 - r2) / (1.0 + (a2 - 1.0) * r2));
    const sin_theta = @sqrt(@max(0.0, 1.0 - cos_theta * cos_theta));
    const basis = tangentBasis(n);
    const h = normalize3(.{
        basis.t[0] * (sin_theta * @cos(phi)) + basis.b[0] * (sin_theta * @sin(phi)) + n[0] * cos_theta,
        basis.t[1] * (sin_theta * @cos(phi)) + basis.b[1] * (sin_theta * @sin(phi)) + n[1] * cos_theta,
        basis.t[2] * (sin_theta * @cos(phi)) + basis.b[2] * (sin_theta * @sin(phi)) + n[2] * cos_theta,
    });
    const vdoth = dot3(v, h);
    const l = normalize3(.{
        2.0 * vdoth * h[0] - v[0],
        2.0 * vdoth * h[1] - v[1],
        2.0 * vdoth * h[2] - v[2],
    });
    if (dot3(l, n) <= 0.0) {
        return .{ .radiance_rgb = sky_miss_rgb, .hit_distance = max_distance, .hit = false, .confidence = 0.0 };
    }

    const origin = [3]f32{
        world_pos[0] + n[0] * 1e-3,
        world_pos[1] + n[1] * 1e-3,
        world_pos[2] + n[2] * 1e-3,
    };
    const ray = bvh_mod.Ray{ .origin = origin, .direction = l, .t_min = 1e-3, .t_max = max_distance };
    const hit = bvh.traceClosest(ray, stats);
    if (hit.hit) {
        const mat = if (hit.instance_id < materials.len) materials[hit.instance_id] else SurfaceMaterial{};
        return .{
            .radiance_rgb = .{
                mat.emissive[0] + mat.albedo[0] * sky_miss_rgb[0] * 0.4,
                mat.emissive[1] + mat.albedo[1] * sky_miss_rgb[1] * 0.4,
                mat.emissive[2] + mat.albedo[2] * sky_miss_rgb[2] * 0.4,
            },
            .hit_distance = hit.t,
            .hit = true,
            .confidence = 1.0 - a * 0.4,
        };
    }
    return .{
        .radiance_rgb = sky_miss_rgb,
        .hit_distance = max_distance,
        .hit = false,
        .confidence = 0.65,
    };
}

/// Populates `cache` at `world_pos` by tracing `sample_count` stratified cosine-weighted rays
/// against `bvh`, returning the averaged indirect irradiance RGB.
pub fn populateRadianceCacheFromRays(
    bvh: *const bvh_mod.Bvh,
    materials: []const SurfaceMaterial,
    cache: *cache_mod.WorldRadianceCache,
    world_pos: [3]f32,
    normal: [3]f32,
    sample_count: u32,
    max_distance: f32,
    sky_miss_rgb: [3]f32,
    frame_index: u64,
    stats: *bvh_mod.QueryStats,
) ![3]f32 {
    const count = @max(sample_count, 1);
    var sum = [3]f32{ 0, 0, 0 };
    for (0..count) |i| {
        const fi: f32 = @floatFromInt(i);
        const fc: f32 = @floatFromInt(count);
        const xi1 = (fi + 0.5) / fc;
        const xi2 = @mod(fi * 0.61803398875 + 0.25, 1.0);
        const res = traceIndirectDiffuse(bvh, materials, world_pos, normal, xi1, xi2, max_distance, sky_miss_rgb, stats);
        sum[0] += res.radiance_rgb[0];
        sum[1] += res.radiance_rgb[1];
        sum[2] += res.radiance_rgb[2];
    }
    const inv = 1.0 / @as(f32, @floatFromInt(count));
    const avg = [3]f32{ sum[0] * inv, sum[1] * inv, sum[2] * inv };
    try cache.accumulate(world_pos, 0, avg, frame_index);
    return avg;
}
