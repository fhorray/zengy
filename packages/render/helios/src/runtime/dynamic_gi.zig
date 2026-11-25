//! Budgeted diffuse probe transport using Helios' existing CPU BVH.
//! Grid storage is backend-neutral; the render package uploads its own grid to Forward+.
//! Each lobe stores cosine-convolved incoming radiance / pi, and directional distance moments.
const std = @import("std");
const bvh_mod = @import("../ray_query/bvh.zig");
const gi = @import("../ray_query/gi_solver.zig");
const material = @import("../ray_query/indirect_rt.zig");
const Vec = @Vector(3, f32);
const axes = [6]Vec{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } };

pub const probe_count = 64;
pub const Probe = extern struct {
    lobes: [6][4]f32 = @splat(.{ 0, 0, 0, 0 }), // RGB irradiance/pi, mean distance
    moments: [6][4]f32 = @splat(.{ 0, 0, 0, 0 }), // x=mean distance squared, y=validity
    offset_validity: [4]f32 = .{ 0, 0, 0, 0 },
};
pub const Grid = extern struct {
    origin_enabled: [4]f32 = .{ 0, 0, 0, 0 },
    spacing: [4]f32 = .{ 1, 1, 1, 0 },
    probes: [probe_count]Probe = @splat(.{}),
};

pub const SkyGradient = struct { zenith: [3]f32, horizon: [3]f32, ground: [3]f32 };

pub const Settings = struct {
    rays_per_probe: u32 = 48,
    probes_per_frame: u32 = 4,
    max_ray_queries:u32=0, // zero preserves the original caller-controlled budget
    max_distance: f32 = 16,
    hysteresis: f32 = 0.85,
    sky_radiance: [3]f32 = .{ 0.04, 0.06, 0.09 },
    indirect_feedback: f32 = 0.4,
    sky_gradient: ?SkyGradient = null,
};

fn dot(a: Vec, b: Vec) f32 { return @reduce(.Add, a * b); }
fn splat(x: f32) Vec { return @splat(x); }
fn array(v: Vec) [3]f32 { return .{ v[0], v[1], v[2] }; }
fn normalize(v: Vec) Vec { return v / splat(@sqrt(@max(dot(v, v), 1e-12))); }
fn rgb(v: [4]f32) Vec { return .{ v[0], v[1], v[2] }; }
fn safe(v: Vec) Vec {
    var result: Vec = @splat(0);
    inline for (0..3) |i| result[i] = if (std.math.isFinite(v[i])) std.math.clamp(v[i], 0, 1000) else 0;
    return result;
}
fn sector(v: Vec) usize {
    var best: usize = 0;
    for (1..6) |i| {
        if (dot(v, axes[i]) > dot(v, axes[best])) best = i;
    }
    return best;
}
fn position(grid: *const Grid, index: usize) Vec {
    const coords: Vec = .{ @floatFromInt(index % 4), @floatFromInt(index / 4 % 4), @floatFromInt(index / 16) };
    return rgb(grid.origin_enabled) + coords * rgb(grid.spacing) + rgb(grid.probes[index].offset_validity);
}
fn direction(index: u32, count: u32, rotation: f32) Vec {
    const z = 1.0 - 2.0 * (@as(f32, @floatFromInt(index)) + 0.5) / @as(f32, @floatFromInt(count));
    const phi = @as(f32, @floatFromInt(index)) * 2.39996323 + rotation;
    const radius = @sqrt(@max(0, 1 - z * z));
    return .{ radius * @cos(phi), z, radius * @sin(phi) };
}
fn momentWeight(mean: f32, square: f32, distance: f32) f32 {
    const delta = @max(distance - mean - 0.05, 0);
    const variance = @max(square - mean * mean, 0.0025);
    const weight = variance / (variance + delta * delta);
    return weight * weight * weight;
}

/// CPU reference for exactly the six-lobe weighting used by the GPU shader.
pub const ProbeSample = struct { rgb: [3]f32, confidence: f32 };
const sample_zero = ProbeSample{ .rgb = .{0,0,0}, .confidence = 0 };
pub fn sample(grid: *const Grid, pos: [3]f32, normal: [3]f32) ProbeSample {
    if (!std.math.isFinite(grid.origin_enabled[3]) or grid.origin_enabled[3] <= 0) return sample_zero;
    const p: Vec = .{ pos[0], pos[1], pos[2] };
    const raw_n: Vec = .{ normal[0], normal[1], normal[2] };
    const nlen2 = dot(raw_n, raw_n);
    if (!std.math.isFinite(nlen2) or nlen2 <= 1e-12) return .{ .rgb = .{ 0, 0, 0 }, .confidence = 0 };
    const n2 = raw_n * raw_n / splat(nlen2);
    const spacing = rgb(grid.spacing);
    for (grid.spacing[0..3]) |v| if (!std.math.isFinite(v) or v <= 0.01) return .{ .rgb = .{ 0, 0, 0 }, .confidence = 0 };
    var q = (p - rgb(grid.origin_enabled)) / spacing;
    var base: [3]usize = undefined;
    var frac: Vec = undefined;
    inline for (0..3) |i| {
        if (!std.math.isFinite(q[i]) or q[i] < -0.05 or q[i] > 3.05) return .{ .rgb = .{ 0, 0, 0 }, .confidence = 0 };
        q[i] = std.math.clamp(q[i], 0, 3);
        base[i] = @min(@as(usize, @intFromFloat(@floor(q[i]))), 2);
        frac[i] = q[i] - @as(f32, @floatFromInt(base[i]));
    }
    var accum: Vec = @splat(0);
    var weights: f32 = 0;

    for (0..8) |corner| {
        const x = corner & 1;
        const y = (corner >> 1) & 1;
        const z = (corner >> 2) & 1;
        const index = base[0] + x + 4 * (base[1] + y) + 16 * (base[2] + z);
        const w = (if (x == 0) 1-frac[0] else frac[0]) * (if (y == 0) 1-frac[1] else frac[1]) * (if (z == 0) 1-frac[2] else frac[2]);
        const probe = &grid.probes[index];
        const validity = probe.offset_validity[3];
        const weight = w * validity;
        if (weight <= 1e-5) continue;
        const delta = p - position(grid, index);
        const s = sector(delta);
        if (probe.moments[s][1] <= 0) continue;
        const visibility = momentWeight(probe.lobes[s][3], probe.moments[s][0], @sqrt(dot(delta, delta)));
        const light = rgb(probe.lobes[if (raw_n[0] >= 0) 0 else 1]) * splat(n2[0]) +
            rgb(probe.lobes[if (raw_n[1] >= 0) 2 else 3]) * splat(n2[1]) +
            rgb(probe.lobes[if (raw_n[2] >= 0) 4 else 5]) * splat(n2[2]);
        accum += light * splat(weight * visibility);
        weights += weight;
    }
    const result = accum / splat(@max(weights, 1e-5));
    return .{ .rgb = array(result), .confidence = std.math.clamp(weights, 0, 1) };
}

fn hitRadiance(grid: *const Grid, bvh: *const bvh_mod.Bvh, materials: []const material.SurfaceMaterial, emitters: []const gi.DirectPointEmitter, sun: ?gi.DirectSunEmitter, hit: bvh_mod.RayHit, origin: Vec, dir: Vec, settings: Settings, stats: *bvh_mod.QueryStats) Vec {
    if (!hit.hit) {
        if (settings.sky_gradient) |sky| {
            const horizon: Vec = sky.horizon;
            const other: Vec = if (dir[1] >= 0) sky.zenith else sky.ground;
            const t = if (dir[1] >= 0) std.math.pow(f32, @min(dir[1], 1), 0.55) else @min(-dir[1] * 4, 1);
            return safe(horizon + (other - horizon) * splat(t));
        }
        return safe(settings.sky_radiance);
    }
    if (hit.instance_id >= materials.len) return @splat(0);
    var n = normalize(.{ hit.normal[0], hit.normal[1], hit.normal[2] });
    if (dot(n, dir) > 0) n = -n;
    const p = origin + dir * splat(hit.t);
    const biased = p + n * splat(0.005);
    const mat = materials[hit.instance_id];
    var direct: Vec = @splat(0);
    for (emitters) |em| {
        const delta = @as(Vec, .{ em.position[0], em.position[1], em.position[2] }) - biased;
        const dist2 = dot(delta, delta);
        if(!std.math.isFinite(dist2) or !std.math.isFinite(em.lumens) or !std.math.isFinite(em.range) or em.lumens<=0 or em.range<=0) continue;
        const dist = @sqrt(dist2);
        if (dist < 0.05 or dist >= em.range) continue;
        const l = delta / splat(dist);
        const ndotl = @max(dot(n, l), 0);
        if (ndotl <= 0 or bvh.traceAnyHit(.{ .origin = array(biased), .direction = array(l), .t_min = 0.001, .t_max = dist - 0.005 }, stats)) continue;
        const ratio = dist / em.range;
        const window = 1 - ratio * ratio * ratio * ratio;
        direct += safe(.{ em.color[0], em.color[1], em.color[2] }) * splat(@max(em.lumens, 0) / 100.0 * window * window / (dist2 + 1) * ndotl);
    }
    if (sun) |s| {
        const raw: Vec = s.direction;
        const valid_sun = std.math.isFinite(s.illuminance_lux) and s.illuminance_lux > 0 and std.math.isFinite(dot(raw, raw));
        const l = if (valid_sun) -normalize(raw) else splat(0);
        const ndotl = @max(dot(n, l), 0);
        if (ndotl > 0 and !bvh.traceAnyHit(.{ .origin = array(biased), .direction = array(l), .t_min = 0.001, .t_max = 1000 }, stats)) {
            direct += safe(.{ s.color[0], s.color[1], s.color[2] }) * splat(@max(s.illuminance_lux, 0) / 2500.0 * ndotl);
        }
    }
    const feedback = if (std.math.isFinite(settings.indirect_feedback)) std.math.clamp(settings.indirect_feedback, 0, 0.7) else 0;
    const old = if (feedback > 0) sample(grid, array(biased), array(n)) else sample_zero;
    var albedo = safe(.{ mat.albedo[0], mat.albedo[1], mat.albedo[2] });
    inline for (0..3) |i| albedo[i] = @min(albedo[i], 0.95);
    albedo *= splat(1 - (if (std.math.isFinite(mat.metallic)) std.math.clamp(mat.metallic, 0, 1) else 0));
    return safe(safe(.{ mat.emissive[0], mat.emissive[1], mat.emissive[2] }) + albedo * (direct / splat(std.math.pi) + @as(Vec, .{ old.rgb[0], old.rgb[1], old.rgb[2] }) * splat(old.confidence * feedback)));
}

/// Keep the best eight emitters by an upper-bound approximation of relevance to
/// this probe's traced neighborhood. One pass per probe, not per primary ray.
fn selectEmitters(emitters: []const gi.DirectPointEmitter, pos: Vec, max_distance: f32, selected: *[8]gi.DirectPointEmitter) usize {
    var scores: [8]f64 = @splat(-1);
    var len: usize = 0;
    for (emitters) |em| {
        if (!std.math.isFinite(em.lumens) or !std.math.isFinite(em.range) or em.lumens <= 0 or em.range <= 0) continue;
        const delta = @as(Vec, em.position) - pos;
        const dist2 = dot(delta, delta);
        if (!std.math.isFinite(dist2)) continue;
        const lower = @max(@sqrt(dist2) - max_distance, 0);
        if (lower >= em.range) continue;
        const color = safe(em.color);
        const score = @as(f64, em.lumens) * @as(f64, @reduce(.Max, color)) / (1.0 + @as(f64, dist2));
        if (!std.math.isFinite(score) or score <= 0) continue;
        var index = @min(len, 7);
        if (len == 8 and score <= scores[7]) continue;
        while (index > 0 and score > scores[index-1]) : (index -= 1) {
            selected[index] = selected[index-1];
            scores[index] = scores[index-1];
        }
        selected[index] = em;
        scores[index] = score;
        len = @min(len+1, 8);
    }
    return len;
}

/// Updates a bounded number of probes. Reads a stable snapshot for feedback, then publishes the batch.
/// Ray generation is CPU-based; Forward+ consumes the resulting grid on the GPU.
pub fn update(grid: *Grid, bvh: *const bvh_mod.Bvh, materials: []const material.SurfaceMaterial, emitters: []const gi.DirectPointEmitter, sun: ?gi.DirectSunEmitter, settings: Settings, cursor: *usize, epoch: u64) bvh_mod.QueryStats {
    var stats: bvh_mod.QueryStats = .{};
    if (grid.origin_enabled[3] <= 0 or settings.probes_per_frame == 0 or settings.rays_per_probe == 0) return stats;
    for (grid.origin_enabled[0..3]) |v| if (!std.math.isFinite(v)) return stats;
    for (grid.spacing[0..3]) |v| if (!std.math.isFinite(v) or v <= 0.01) return stats;
    const snapshot = grid.*; // Immutable feedback snapshot for this bounded batch.
    const configured_count = std.math.clamp(settings.rays_per_probe, 12, 128);
    const max_dist = if (std.math.isFinite(settings.max_distance)) std.math.clamp(settings.max_distance, 0.1, 100) else 16;
    const rotation = @as(f32, @floatFromInt(epoch % 1024)) * 2.39996323;
    for (0..@min(settings.probes_per_frame, probe_count)) |_| {
        var count=configured_count;
        if(settings.max_ray_queries>0){
            const remaining=@as(u64,settings.max_ray_queries)-|stats.rays_cast;
            const worst_per_ray=1+@min(emitters.len,8)+@as(usize,if(sun!=null) 1 else 0);
            const affordable=(remaining-|6)/@as(u64,worst_per_ray);
            if(affordable<12)break;
            count=@min(count,@as(u32,@intCast(@min(affordable,128))));
        }
        const index = cursor.* % probe_count;
        cursor.* = (index + 1) % probe_count;
        const previous = &snapshot.probes[index];
        var probe: Probe = .{};
        var pos = position(&snapshot, index);
        // Relocate only away from very close surfaces. In a closed solid, backface classification rejects the probe.
        var shift: Vec = @splat(0);
        const clearance = @min(@reduce(.Min, rgb(grid.spacing)) * 0.15, 0.2);
        for (axes) |axis| {
            const h = bvh.traceClosest(.{ .origin = array(pos), .direction = array(axis), .t_max = clearance }, &stats);
            if (h.hit) shift -= axis * splat(clearance - h.t);
        }
        const old_offset = rgb(previous.offset_validity);
        var next_offset = old_offset + shift;
        inline for (0..3) |i| next_offset[i] = std.math.clamp(next_offset[i], -grid.spacing[i]*0.3, grid.spacing[i]*0.3);
        pos += next_offset - old_offset;
        var selected: [8]gi.DirectPointEmitter = undefined;
        const selected_count = selectEmitters(emitters, pos, max_dist, &selected);
        var sums: [6]Vec = @splat(@splat(0));
        var distances: [6]f32 = @splat(0);
        var squares: [6]f32 = @splat(0);
        var weights: [6]f32 = @splat(0);
        var visibility_counts: [6]u32 = @splat(0);
        var backfaces: u32 = 0;
        for (0..count) |i| {
            const dir = direction(@intCast(i), count, rotation);
            const hit = bvh.traceClosest(.{ .origin = array(pos), .direction = array(dir), .t_max = max_dist }, &stats);
            if (hit.hit and dot(hit.normal, dir) > 0) backfaces += 1;
            const radiance = hitRadiance(&snapshot, bvh, materials, selected[0..selected_count], sun, hit, pos, dir, settings, &stats);
            const distance = if (hit.hit) hit.t else max_dist;
            for (axes, 0..) |axis, a| {
                const w = @max(dot(dir, axis), 0);
                sums[a] += radiance * splat(w);
                weights[a] += w;
            }
            // Distance statistics use the same dominant-axis partition as lookup.
            const sector_index = sector(dir);
            distances[sector_index] += distance;
            squares[sector_index] += distance * distance;
            visibility_counts[sector_index] += 1;
        }
        const valid: f32 = if (backfaces * 2 > count) 0 else 1;
        const moved = dot(next_offset - old_offset, next_offset - old_offset) > 0.0025;
        const h = if (previous.offset_validity[3] > 0 and valid > 0 and !moved) (if (std.math.isFinite(settings.hysteresis)) std.math.clamp(settings.hysteresis, 0, 0.98) else 0) else 0;
        for (0..6) |a| {
            const inv = 1 / @max(weights[a], 1e-6);
            const light = sums[a] * splat(inv);
            inline for (0..3) |c| probe.lobes[a][c] = light[c] * (1-h) + previous.lobes[a][c] * h;
            if (visibility_counts[a] > 0) {
                const count_inv = 1.0 / @as(f32, @floatFromInt(visibility_counts[a]));
                const vh = if (previous.moments[a][1] > 0) h else 0;
                probe.lobes[a][3] = distances[a] * count_inv * (1-vh) + previous.lobes[a][3] * vh;
                probe.moments[a] = .{ squares[a] * count_inv * (1-vh) + previous.moments[a][0] * vh, valid, 0, 0 };
            } else if (h > 0) {
                probe.lobes[a][3] = previous.lobes[a][3];
                probe.moments[a] = previous.moments[a];
            }
        }
        probe.offset_validity = .{ next_offset[0], next_offset[1], next_offset[2], valid };
        grid.probes[index] = probe;
    }
    return stats;
}


/// Mark nearby probes dirty while retaining the rest of the grid. Returns the closest index.
pub fn invalidateNear(grid:*Grid,center:[3]f32,radius:f32) usize {
    const p:Vec=center;
    var best:usize=0;
    var best_distance:f32=std.math.inf(f32);
    for(&grid.probes,0..) |*probe,i| {
        const d=p-position(grid,i);
        const distance=dot(d,d);
        if(distance<best_distance){best=i;best_distance=distance;}
        if(distance<=radius*radius)probe.offset_validity[3]=0;
    }
    return best;
}
