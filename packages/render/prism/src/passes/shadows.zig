//! Stage 04 Advanced Shadow Planning, Cascades, PCSS & Local Atlas (`packages/render/prism/src/passes/shadows.zig`).
//!
//! Provides pure-Zig deterministic shadow policy shared across providers:
//! - Practical Split Scheme (PSSM) for 1–4 directional cascades
//! - Texel-snapping stabilization & normal-offset bias calculation
//! - Bounded PCSS contact-hardening penumbra estimation
//! - Importance-ranked local shadow atlas allocator with guard-band UVs & static cache keys

const std = @import("std");

/// Maximum supported directional shadow cascades.
pub const MAX_CASCADES: usize = 4;

/// Computes practical split distances (logarithmic/uniform blend `lambda` in `[0, 1]`)
/// for `cascade_count` in `[1..4]`.
pub fn computeCascadeSplits(
    near: f32,
    far: f32,
    max_shadow_distance: f32,
    cascade_count: u32,
    lambda: f32,
) [MAX_CASCADES]f32 {
    const count = std.math.clamp(cascade_count, 1, MAX_CASCADES);
    const n = @max(near, 0.01);
    const f = @max(n + 0.1, @min(far, max_shadow_distance));
    const lam = std.math.clamp(lambda, 0.0, 1.0);

    var splits = [MAX_CASCADES]f32{ f, f, f, f };
    const ratio = f / n;
    for (0..count) |i| {
        const p = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(count));
        const log_split = n * std.math.pow(f32, ratio, p);
        const uni_split = n + (f - n) * p;
        splits[i] = log_split * lam + uni_split * (1.0 - lam);
    }
    return splits;
}

/// Snaps a light-space XY origin to shadow-map texel increments to eliminate cascade swimming.
pub fn snapCascadeOrigin(origin_xy: [2]f32, texel_world_size: f32) [2]f32 {
    if (texel_world_size <= 1e-6) return origin_xy;
    return .{
        @floor(origin_xy[0] / texel_world_size) * texel_world_size,
        @floor(origin_xy[1] / texel_world_size) * texel_world_size,
    };
}

/// Computes world-space normal-offset bias from shadow texel size and surface slope `(1 - NdotL)`.
pub fn computeNormalOffsetBias(texel_world_size: f32, normal_bias_texels: f32, ndotl: f32) f32 {
    const slope = 1.0 - std.math.clamp(ndotl, 0.0, 1.0);
    return texel_world_size * normal_bias_texels * (0.25 + 0.75 * slope);
}

/// Estimates bounded PCSS filter radius in texels from receiver/blocker depth ratio and light angular size.
pub fn estimatePcssPenumbra(
    receiver_depth: f32,
    avg_blocker_depth: f32,
    light_angular_tan: f32,
    min_radius_texels: f32,
    max_radius_texels: f32,
) f32 {
    if (avg_blocker_depth <= 1e-6 or receiver_depth <= avg_blocker_depth) return min_radius_texels;
    const penumbra = ((receiver_depth - avg_blocker_depth) / avg_blocker_depth) * light_angular_tan * 64.0;
    return std.math.clamp(penumbra, min_radius_texels, max_radius_texels);
}

/// Golden-angle Vogel disk tap offset in `[-1, 1]^2` rotated by `rotation_rad` (e.g. interleaved gradient noise).
pub fn rotatedVogelDiskSample(sample_idx: u32, sample_count: u32, rotation_rad: f32) [2]f32 {
    const count = @max(sample_count, 1);
    const r = @sqrt((@as(f32, @floatFromInt(sample_idx)) + 0.5) / @as(f32, @floatFromInt(count)));
    const theta = @as(f32, @floatFromInt(sample_idx)) * 2.399963229728653 + rotation_rad;
    return .{ r * @cos(theta), r * @sin(theta) };
}

/// Result of a PCSS blocker search over a shadow depth map.
pub const PcssBlockerResult = struct {
    avg_blocker_depth: f32 = 0.0,
    blocker_count: u32 = 0,
};

/// Performs a bounded PCSS blocker search over a single-channel depth map (`width * height`),
/// sampling `sample_count` rotated Vogel taps within `search_radius_texels` around `uv`.
pub fn pcssBlockerSearch(
    depth_map: []const f32,
    width: u32,
    height: u32,
    uv: [2]f32,
    receiver_depth: f32,
    search_radius_texels: f32,
    sample_count: u32,
    rotation_rad: f32,
) PcssBlockerResult {
    if (width == 0 or height == 0 or depth_map.len < @as(usize, width) * @as(usize, height)) return .{};
    const w_f: f32 = @floatFromInt(width);
    const h_f: f32 = @floatFromInt(height);
    const count = std.math.clamp(sample_count, 1, 32);

    var sum_depth: f32 = 0.0;
    var blockers: u32 = 0;
    for (0..count) |i| {
        const tap = rotatedVogelDiskSample(@intCast(i), count, rotation_rad);
        const su = std.math.clamp(uv[0] + (tap[0] * search_radius_texels) / w_f, 0.0, 0.999999);
        const sv = std.math.clamp(uv[1] + (tap[1] * search_radius_texels) / h_f, 0.0, 0.999999);
        const px: usize = @intFromFloat(su * w_f);
        const py: usize = @intFromFloat(sv * h_f);
        const sample_d = depth_map[py * @as(usize, width) + px];
        if (sample_d < receiver_depth) {
            sum_depth += sample_d;
            blockers += 1;
        }
    }
    if (blockers == 0) return .{};
    return .{
        .avg_blocker_depth = sum_depth / @as(f32, @floatFromInt(blockers)),
        .blocker_count = blockers,
    };
}

/// Bounding sphere of a shadow-casting object for per-cascade / per-light frustum culling.
pub const ShadowCasterSphere = struct {
    caster_id: u64,
    center: [3]f32,
    radius: f32,
    casts_shadows: bool = true,
};

/// Culls `casters` against 6 normalized light-frustum planes `[nx, ny, nz, d]` (`dot(n, p) + d >= -r`),
/// writing surviving caster indices into `out_indices`.
pub fn cullShadowCasters(
    allocator: std.mem.Allocator,
    casters: []const ShadowCasterSphere,
    frustum_planes: [6][4]f32,
    out_indices: *std.ArrayList(usize),
) !usize {
    out_indices.clearRetainingCapacity();
    var culled: usize = 0;
    outer: for (casters, 0..) |c, idx| {
        if (!c.casts_shadows or c.radius <= 0.0) {
            culled += 1;
            continue;
        }
        for (frustum_planes) |p| {
            const dist = p[0] * c.center[0] + p[1] * c.center[1] + p[2] * c.center[2] + p[3];
            if (dist < -c.radius) {
                culled += 1;
                continue :outer;
            }
        }
        try out_indices.append(allocator, idx);
    }
    return culled;
}

/// Candidate local light competing for shadow atlas tiles.
pub const ShadowLightCandidate = struct {
    light_id: u64,
    is_point: bool = false,
    distance_to_camera: f32,
    intensity_lumens: f32,
    range: f32,
};

/// Single allocated tile region inside a square shadow atlas.
pub const AtlasTileAllocation = struct {
    light_id: u64,
    first_tile: u32,
    tile_count: u32,
    tile_resolution: u32,
    importance: f32,
};

/// Result of deterministic local shadow atlas planning.
pub const AtlasPlanStats = struct {
    allocated_lights: usize = 0,
    evicted_lights: usize = 0,
    used_tiles: u32 = 0,
    max_tiles: u32 = 0,
};

/// Guard-band clamped UV bounds `[u_min, v_min, u_max, v_max]` preventing atlas edge bleed during PCF.
pub fn computeGuardedTileUv(
    tile_col: u32,
    tile_row: u32,
    tile_res: u32,
    atlas_res: u32,
    guard_texels: f32,
) [4]f32 {
    const a: f32 = @floatFromInt(@max(atlas_res, 1));
    const x0: f32 = @as(f32, @floatFromInt(tile_col * tile_res)) + guard_texels;
    const y0: f32 = @as(f32, @floatFromInt(tile_row * tile_res)) + guard_texels;
    const x1: f32 = @as(f32, @floatFromInt((tile_col + 1) * tile_res)) - guard_texels;
    const y1: f32 = @as(f32, @floatFromInt((tile_row + 1) * tile_res)) - guard_texels;
    return .{ x0 / a, y0 / a, x1 / a, y1 / a };
}

/// Ranks `candidates` deterministically by importance (`intensity / (1 + dist^2)`) and allocates
/// tiles up to `max_tiles` without silently dropping overflow (reported in `AtlasPlanStats.evicted_lights`).
pub fn planLocalShadowAtlas(
    allocator: std.mem.Allocator,
    candidates: []const ShadowLightCandidate,
    max_tiles: u32,
    base_tile_res: u32,
    out_allocs: *std.ArrayList(AtlasTileAllocation),
) !AtlasPlanStats {
    out_allocs.clearRetainingCapacity();

    const Ranked = struct {
        cand: ShadowLightCandidate,
        importance: f32,
    };
    const ranked = try allocator.alloc(Ranked, candidates.len);
    defer allocator.free(ranked);

    for (candidates, 0..) |c, i| {
        const d = @max(c.distance_to_camera, 0.25);
        const imp = (c.intensity_lumens * @max(c.range, 0.5)) / (1.0 + d * d);
        ranked[i] = .{ .cand = c, .importance = imp };
    }

    std.mem.sort(Ranked, ranked, {}, struct {
        fn lessThan(_: void, a: Ranked, b: Ranked) bool {
            if (a.importance != b.importance) return a.importance > b.importance;
            return a.cand.light_id < b.cand.light_id;
        }
    }.lessThan);

    var stats = AtlasPlanStats{ .max_tiles = max_tiles };
    var cursor: u32 = 0;

    for (ranked) |r| {
        const needed: u32 = if (r.cand.is_point) 6 else 1;
        if (cursor + needed > max_tiles) {
            stats.evicted_lights += 1;
            continue;
        }
        const res: u32 = if (r.cand.distance_to_camera > 25.0) @max(128, base_tile_res / 2) else base_tile_res;
        try out_allocs.append(allocator, .{
            .light_id = r.cand.light_id,
            .first_tile = cursor,
            .tile_count = needed,
            .tile_resolution = res,
            .importance = r.importance,
        });
        cursor += needed;
        stats.allocated_lights += 1;
    }

    stats.used_tiles = cursor;
    return stats;
}

/// Static shadow map cache tracking per-light revision hashes to skip redundant shadow renders.
pub const ShadowCacheTable = struct {
    allocator: std.mem.Allocator,
    hashes: std.AutoHashMapUnmanaged(u64, u64),

    /// Initializes an empty `ShadowCacheTable`.
    pub fn init(allocator: std.mem.Allocator) ShadowCacheTable {
        return .{
            .allocator = allocator,
            .hashes = .empty,
        };
    }

    /// Releases cache storage.
    pub fn deinit(self: *ShadowCacheTable) void {
        self.hashes.deinit(self.allocator);
    }

    /// Returns `true` if `light_id` can reuse its cached shadow map (`fingerprint` unchanged),
    /// otherwise records the new `fingerprint` and returns `false`.
    pub fn canReuse(self: *ShadowCacheTable, light_id: u64, fingerprint: u64) !bool {
        const gop = try self.hashes.getOrPut(self.allocator, light_id);
        if (gop.found_existing and gop.value_ptr.* == fingerprint) return true;
        gop.value_ptr.* = fingerprint;
        return false;
    }

    /// Clears all cached shadow fingerprints (e.g. on atlas resize or scene reload).
    pub fn invalidateAll(self: *ShadowCacheTable) void {
        self.hashes.clearRetainingCapacity();
    }
};
