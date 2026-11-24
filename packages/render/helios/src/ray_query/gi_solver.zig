//! Helios Instant-Radiosity BVH Global Illumination Solver (`packages/render/helios/src/ray_query/gi_solver.zig`).
//!
//! Computes physically traced 1- and 2-bounce indirect illumination using `Bvh.traceClosest`:
//! - Traces deterministic Fibonacci-sphere rays from direct point lights and stratified sun rays
//! - Flips hit normals toward incoming rays so Virtual Point Lights (VPLs) always offset into open space
//! - Evaluates surface albedo color bleeding and optional secondary bounces
//! - Spatially clusters nearby hit points into smooth, bounded VPLs for real-time Forward+ rendering

const std = @import("std");
const bvh_mod = @import("bvh.zig");
const indirect_rt = @import("indirect_rt.zig");
const ssgi_mod = @import("../hybrid/ssgi.zig");
const contract = @import("../hybrid/lighting_contract.zig");

/// Direct point-light source feeding the GI ray tracer.
pub const DirectPointEmitter = struct {
    position: [3]f32,
    color: [3]f32 = .{ 1, 1, 1 },
    lumens: f32 = 2000.0,
    range: f32 = 14.0,
};

/// Direct directional sun source feeding the GI ray tracer.
pub const DirectSunEmitter = struct {
    direction: [3]f32 = .{ -0.45, -0.75, -0.45 },
    color: [3]f32 = .{ 1, 0.96, 0.90 },
    illuminance_lux: f32 = 0.0,
    scene_center: [3]f32 = .{ 0, 1.5, 0 },
    scene_radius: f32 = 10.0,
};

/// Traced bounce Virtual Point Light (VPL) ready for Forward+ clustered injection or probe baking.
pub const VirtualPointLight = struct {
    position: [3]f32,
    normal: [3]f32,
    color: [3]f32,
    lumens: f32,
    range: f32,
    bounce_depth: u8 = 1,
};

/// Solver configuration controlling ray budget, bounce depth, and VPL clustering.
pub const GiSolveConfig = struct {
    max_vpls: usize = 16,
    rays_per_point: u32 = 48,
    sun_grid_side: u32 = 6,
    max_bounces: u8 = 1,
    merge_radius: f32 = 1.65,
    normal_offset: f32 = 0.42,
    bounce_energy_scale: f32 = 0.65,
    vpl_range: f32 = 11.0,
};

/// Diagnostic summary returned by `solveInstantRadiosity`.
pub const GiSolveStats = struct {
    rays_cast: u64 = 0,
    primary_hits: u32 = 0,
    secondary_hits: u32 = 0,
    vpl_count: usize = 0,
};

/// Returns deterministic GI solver settings for `tier`.
/// Uses broad regional VPL clustering so indirect bounce light is silky-smooth with
/// rich color bleeding and no discrete specular "glitter dots" on glossy surfaces.
pub fn configForTier(tier: contract.HeliosQualityTier) GiSolveConfig {
    return switch (tier) {
        .off => .{ .max_vpls = 0, .rays_per_point = 0, .sun_grid_side = 0, .max_bounces = 0 },
        .low => .{ .max_vpls = 4, .rays_per_point = 32, .sun_grid_side = 10, .max_bounces = 1, .merge_radius = 4.2, .normal_offset = 0.75, .bounce_energy_scale = 0.70, .vpl_range = 12.0 },
        .medium => .{ .max_vpls = 6, .rays_per_point = 48, .sun_grid_side = 14, .max_bounces = 1, .merge_radius = 3.6, .normal_offset = 0.75, .bounce_energy_scale = 0.92, .vpl_range = 13.0 },
        .high => .{ .max_vpls = 8, .rays_per_point = 64, .sun_grid_side = 18, .max_bounces = 2, .merge_radius = 3.4, .normal_offset = 0.80, .bounce_energy_scale = 1.15, .vpl_range = 14.0 },
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

/// Generates a deterministic Fibonacci-sphere unit direction for sample `i` of `n`.
fn fibonacciSphereDir(i: u32, n: u32) [3]f32 {
    const fi = @as(f32, @floatFromInt(i)) + 0.5;
    const fn_ = @as(f32, @floatFromInt(@max(n, 1)));
    const y = 1.0 - (2.0 * fi) / fn_;
    const r = @sqrt(@max(0.0, 1.0 - y * y));
    const phi = 2.399963229728653 * fi;
    return .{ @cos(phi) * r, y, @sin(phi) * r };
}

/// Appends 12 axis-aligned box triangles for an entity's bounding volume into `out_tris`.
pub fn appendBoxTriangles(
    allocator: std.mem.Allocator,
    out_tris: *std.ArrayList(bvh_mod.BvhTriangle),
    center: [3]f32,
    half_extents: [3]f32,
    instance_id: u32,
) !void {
    const x0 = center[0] - half_extents[0];
    const x1 = center[0] + half_extents[0];
    const y0 = center[1] - half_extents[1];
    const y1 = center[1] + half_extents[1];
    const z0 = center[2] - half_extents[2];
    const z1 = center[2] + half_extents[2];

    const c000 = [3]f32{ x0, y0, z0 };
    const c100 = [3]f32{ x1, y0, z0 };
    const c110 = [3]f32{ x1, y1, z0 };
    const c010 = [3]f32{ x0, y1, z0 };
    const c001 = [3]f32{ x0, y0, z1 };
    const c101 = [3]f32{ x1, y0, z1 };
    const c111 = [3]f32{ x1, y1, z1 };
    const c011 = [3]f32{ x0, y1, z1 };

    const faces = [_][3][3]f32{
        // -X, +X
        .{ c000, c001, c011 }, .{ c000, c011, c010 },
        .{ c100, c110, c111 }, .{ c100, c111, c101 },
        // -Y, +Y
        .{ c000, c100, c101 }, .{ c000, c101, c001 },
        .{ c010, c011, c111 }, .{ c010, c111, c110 },
        // -Z, +Z
        .{ c000, c010, c110 }, .{ c000, c110, c100 },
        .{ c001, c101, c111 }, .{ c001, c111, c011 },
    };
    for (faces, 0..) |f, pi| {
        try out_tris.append(allocator, .{
            .v0 = f[0],
            .v1 = f[1],
            .v2 = f[2],
            .instance_id = instance_id,
            .primitive_id = @intCast(pi),
        });
    }
}

fn addOrMergeVpl(
    allocator: std.mem.Allocator,
    vpls: *std.ArrayList(VirtualPointLight),
    cand: VirtualPointLight,
    merge_radius: f32,
) !void {
    if (cand.lumens < 0.05) return;
    const r2 = merge_radius * merge_radius;
    for (vpls.items) |*v| {
        const dx = v.position[0] - cand.position[0];
        const dy = v.position[1] - cand.position[1];
        const dz = v.position[2] - cand.position[2];
        const same_dir = dot3(v.normal, cand.normal) > 0.35;
        const col_diff = @abs(v.color[0] - cand.color[0]) + @abs(v.color[1] - cand.color[1]) + @abs(v.color[2] - cand.color[2]);
        if (dx * dx + dy * dy + dz * dz <= r2 and same_dir and col_diff < 0.45) {
            const total = v.lumens + cand.lumens;
            const w0 = v.lumens / total;
            const w1 = cand.lumens / total;
            v.position = .{
                v.position[0] * w0 + cand.position[0] * w1,
                v.position[1] * w0 + cand.position[1] * w1,
                v.position[2] * w0 + cand.position[2] * w1,
            };
            v.color = .{
                v.color[0] * w0 + cand.color[0] * w1,
                v.color[1] * w0 + cand.color[1] * w1,
                v.color[2] * w0 + cand.color[2] * w1,
            };
            v.lumens = total;
            return;
        }
    }
    try vpls.append(allocator, cand);
}

/// Traces real multi-bounce indirect GI rays against `bvh` and outputs clustered `VirtualPointLight`s.
pub fn solveInstantRadiosity(
    allocator: std.mem.Allocator,
    bvh: *const bvh_mod.Bvh,
    materials: []const indirect_rt.SurfaceMaterial,
    point_emitters: []const DirectPointEmitter,
    sun: ?DirectSunEmitter,
    config: GiSolveConfig,
    out_vpls: *std.ArrayList(VirtualPointLight),
) !GiSolveStats {
    out_vpls.clearRetainingCapacity();
    if (config.max_vpls == 0 or bvh.nodes.items.len == 0) return .{};

    var stats = GiSolveStats{};
    var qstats = bvh_mod.QueryStats{};

    var raw_vpls = std.ArrayList(VirtualPointLight).empty;
    defer raw_vpls.deinit(allocator);

    // 1. Trace Fibonacci-sphere rays from each direct point light.
    if (config.rays_per_point > 0) {
        const n_rays = config.rays_per_point;
        for (point_emitters) |em| {
            if (em.lumens <= 0.0 or em.range <= 0.0) continue;
            const per_ray_flux = (em.lumens * config.bounce_energy_scale) / @as(f32, @floatFromInt(n_rays));
            for (0..n_rays) |ri| {
                const dir = fibonacciSphereDir(@intCast(ri), n_rays);
                const ray = bvh_mod.Ray{ .origin = em.position, .direction = dir, .t_min = 0.08, .t_max = em.range };
                const hit = bvh.traceClosest(ray, &qstats);
                if (!hit.hit) continue;
                stats.primary_hits += 1;

                const mat = if (hit.instance_id < materials.len) materials[hit.instance_id] else indirect_rt.SurfaceMaterial{};
                // Orient hit normal back toward the incoming ray so the VPL sits inside the open space.
                var n = normalize3(hit.normal);
                if (dot3(n, dir) > 0.0) n = .{ -n[0], -n[1], -n[2] };

                const hit_p = [3]f32{
                    em.position[0] + dir[0] * hit.t + n[0] * config.normal_offset,
                    em.position[1] + dir[1] * hit.t + n[1] * config.normal_offset,
                    em.position[2] + dir[2] * hit.t + n[2] * config.normal_offset,
                };
                const dist_att = 1.0 / (1.0 + 0.04 * hit.t * hit.t);
                const bounce_rgb = [3]f32{
                    em.color[0] * mat.albedo[0],
                    em.color[1] * mat.albedo[1],
                    em.color[2] * mat.albedo[2],
                };
                const max_c = @max(bounce_rgb[0], @max(bounce_rgb[1], bounce_rgb[2]));
                if (max_c < 0.02) continue;
                const norm_col = [3]f32{ bounce_rgb[0] / max_c, bounce_rgb[1] / max_c, bounce_rgb[2] / max_c };
                const bounce_lumens = per_ray_flux * max_c * dist_att * 3.2;

                try addOrMergeVpl(allocator, &raw_vpls, .{
                    .position = hit_p,
                    .normal = n,
                    .color = norm_col,
                    .lumens = bounce_lumens,
                    .range = config.vpl_range,
                    .bounce_depth = 1,
                }, config.merge_radius);

                // Optional 2nd bounce on high tier.
                if (config.max_bounces >= 2 and bounce_lumens > 12.0) {
                    const b_dir = ssgi_mod.cosineHemisphereSample(
                        @mod(@as(f32, @floatFromInt(ri)) * 0.6180339 + 0.13, 1.0),
                        @mod(@as(f32, @floatFromInt(ri)) * 0.3819660 + 0.27, 1.0),
                        n,
                    );
                    const ray2 = bvh_mod.Ray{ .origin = hit_p, .direction = b_dir, .t_min = 0.08, .t_max = em.range * 0.8 };
                    const hit2 = bvh.traceClosest(ray2, &qstats);
                    if (hit2.hit) {
                        stats.secondary_hits += 1;
                        const mat2 = if (hit2.instance_id < materials.len) materials[hit2.instance_id] else indirect_rt.SurfaceMaterial{};
                        var n2 = normalize3(hit2.normal);
                        if (dot3(n2, b_dir) > 0.0) n2 = .{ -n2[0], -n2[1], -n2[2] };
                        const hit_p2 = [3]f32{
                            hit_p[0] + b_dir[0] * hit2.t + n2[0] * config.normal_offset,
                            hit_p[1] + b_dir[1] * hit2.t + n2[1] * config.normal_offset,
                            hit_p[2] + b_dir[2] * hit2.t + n2[2] * config.normal_offset,
                        };
                        const rgb2 = [3]f32{
                            norm_col[0] * mat2.albedo[0],
                            norm_col[1] * mat2.albedo[1],
                            norm_col[2] * mat2.albedo[2],
                        };
                        const max_c2 = @max(rgb2[0], @max(rgb2[1], rgb2[2]));
                        if (max_c2 >= 0.02) {
                            try addOrMergeVpl(allocator, &raw_vpls, .{
                                .position = hit_p2,
                                .normal = n2,
                                .color = .{ rgb2[0] / max_c2, rgb2[1] / max_c2, rgb2[2] / max_c2 },
                                .lumens = bounce_lumens * max_c2 * 0.42,
                                .range = config.vpl_range * 0.9,
                                .bounce_depth = 2,
                            }, config.merge_radius);
                        }
                    }
                }
            }
        }
    }

    // 2. Trace stratified directional sun rays onto the scene for outdoor bounce GI.
    if (sun) |s| {
        if (s.illuminance_lux > 50.0 and config.sun_grid_side > 0) {
            const s_dir = normalize3(s.direction);
            const up: [3]f32 = if (@abs(s_dir[1]) < 0.98) .{ 0, 1, 0 } else .{ 1, 0, 0 };
            const right = normalize3(cross3(up, s_dir));
            const fwd = normalize3(cross3(s_dir, right));
            const side = config.sun_grid_side;
            const total_rays = side * side;
            const sun_flux_per_ray = (s.illuminance_lux * 0.22 * config.bounce_energy_scale) / @as(f32, @floatFromInt(total_rays));

            for (0..side) |iy| {
                for (0..side) |ix| {
                    const u = ((@as(f32, @floatFromInt(ix)) + 0.5) / @as(f32, @floatFromInt(side)) * 2.0 - 1.0) * s.scene_radius;
                    const v = ((@as(f32, @floatFromInt(iy)) + 0.5) / @as(f32, @floatFromInt(side)) * 2.0 - 1.0) * s.scene_radius;
                    const origin = [3]f32{
                        s.scene_center[0] - s_dir[0] * (s.scene_radius * 2.0) + right[0] * u + fwd[0] * v,
                        s.scene_center[1] - s_dir[1] * (s.scene_radius * 2.0) + right[1] * u + fwd[1] * v,
                        s.scene_center[2] - s_dir[2] * (s.scene_radius * 2.0) + right[2] * u + fwd[2] * v,
                    };
                    const ray = bvh_mod.Ray{ .origin = origin, .direction = s_dir, .t_min = 0.1, .t_max = s.scene_radius * 5.0 };
                    const hit = bvh.traceClosest(ray, &qstats);
                    if (!hit.hit) continue;
                    stats.primary_hits += 1;

                    const mat = if (hit.instance_id < materials.len) materials[hit.instance_id] else indirect_rt.SurfaceMaterial{};
                    var n = normalize3(hit.normal);
                    if (dot3(n, s_dir) > 0.0) n = .{ -n[0], -n[1], -n[2] };
                    const ndotl = @max(dot3(n, .{ -s_dir[0], -s_dir[1], -s_dir[2] }), 0.05);
                    const hit_p = [3]f32{
                        origin[0] + s_dir[0] * hit.t + n[0] * (config.normal_offset + 0.25),
                        origin[1] + s_dir[1] * hit.t + n[1] * (config.normal_offset + 0.25),
                        origin[2] + s_dir[2] * hit.t + n[2] * (config.normal_offset + 0.25),
                    };
                    const rgb = [3]f32{ s.color[0] * mat.albedo[0], s.color[1] * mat.albedo[1], s.color[2] * mat.albedo[2] };
                    const max_c = @max(rgb[0], @max(rgb[1], rgb[2]));
                    if (max_c < 0.03) continue;
                    try addOrMergeVpl(allocator, &raw_vpls, .{
                        .position = hit_p,
                        .normal = n,
                        .color = .{ rgb[0] / max_c, rgb[1] / max_c, rgb[2] / max_c },
                        .lumens = sun_flux_per_ray * max_c * ndotl * 4.5,
                        .range = config.vpl_range * 1.15,
                        .bounce_depth = 1,
                    }, config.merge_radius * 1.1);
                }
            }
        }
    }

    // 3. Rank VPLs by bounced flux boosted by chromatic saturation and proximity to scene_center
    //    so vivid interior color-bleed bounces (e.g. a sunlit red floor inside a room) are never
    //    evicted by dull distant roof/ground bounces.
    const focus = if (sun) |s| s.scene_center else [3]f32{ 0, 1.5, 0 };
    const SortCtx = struct { focus: [3]f32 };
    std.mem.sort(VirtualPointLight, raw_vpls.items, SortCtx{ .focus = focus }, struct {
        fn score(v: VirtualPointLight, f: [3]f32) f32 {
            const dx = v.position[0] - f[0];
            const dy = v.position[1] - f[1];
            const dz = v.position[2] - f[2];
            const d2 = dx * dx + dy * dy + dz * dz;
            const max_c = @max(v.color[0], @max(v.color[1], v.color[2]));
            const min_c = @min(v.color[0], @min(v.color[1], v.color[2]));
            const sat = max_c - min_c;
            return (v.lumens * (1.0 + sat * 3.0)) / (1.0 + 0.04 * d2);
        }
        fn lessThan(ctx: SortCtx, a: VirtualPointLight, b: VirtualPointLight) bool {
            return score(a, ctx.focus) > score(b, ctx.focus);
        }
    }.lessThan);

    const keep = @min(raw_vpls.items.len, config.max_vpls);
    for (raw_vpls.items[0..keep]) |v| {
        if (v.lumens < 4.0) continue;
        var clamped = v;
        clamped.lumens = @min(clamped.lumens, 780.0);
        try out_vpls.append(allocator, clamped);
    }

    stats.rays_cast = qstats.rays_cast;
    stats.vpl_count = out_vpls.items.len;
    return stats;
}
