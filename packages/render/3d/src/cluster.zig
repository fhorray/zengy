//! Agnostic Clustered Forward+ Light Assignment (`packages/render/3d/src/cluster.zig`).
//!
//! Divides the view frustum into a `16 x 9 x 24` 3D grid with logarithmic Z slicing
//! and assigns `PointLight`, `SpotLight`, and `RectLight` indices per cluster.
//!
//! Hot-path callers use `buildClustersInto` with a persistent `ClusterScratch`, so the per-frame
//! work does not allocate once the buffers have grown to the scene's size.

const std = @import("std");
const pbr = @import("pbr.zig");

pub const CLUSTER_X: u32 = 16;
pub const CLUSTER_Y: u32 = 9;
pub const CLUSTER_Z: u32 = 24;
pub const CLUSTER_COUNT: usize = @as(usize, CLUSTER_X) * @as(usize, CLUSTER_Y) * @as(usize, CLUSTER_Z);
/// Maximum number of light index entries uploaded to the GPU cluster index SSBO.
pub const MAX_CLUSTER_INDICES: u32 = 65536;
/// Largest light count one cluster can reference for one light type; the packed `ClusterEntry` count is 8 bits.
pub const MAX_REFS_PER_TYPE: u32 = 255;

/// Packed per-cluster index offsets and counts (`16 bytes`, matches GLSL `uvec4`).
/// Layout: `x = (point_offset << 8) | point_count`, `y = (spot_offset << 8) | spot_count`,
/// `z = (rect_offset << 8) | rect_count`, `w = 0`. The shader decodes it with the same shifts.
pub const ClusterEntry = extern struct {
    point_packed: u32 = 0,
    spot_packed: u32 = 0,
    rect_packed: u32 = 0,
    pad: u32 = 0,
};

/// Logarithmic depth-slice factors matching `view_z_to_z_slice` in `pbr.frag`.
pub const ClusterGridFactors = struct {
    z_near: f32,
    z_far: f32,
    z_scale: f32,
    z_bias: f32,

    pub fn init(z_near: f32, z_far: f32) ClusterGridFactors {
        const zn = @max(z_near, 0.05);
        const zf = @max(z_far, zn + 1.0);
        const nz_f: f32 = @floatFromInt(CLUSTER_Z);
        const z_scale = nz_f / @log(zf / zn);
        const z_bias = (nz_f * @log(zn)) / @log(zf / zn);
        return .{ .z_near = zn, .z_far = zf, .z_scale = z_scale, .z_bias = z_bias };
    }

    /// Maps a positive view-space depth (`-view_z`) to a Z slice index in `[0, CLUSTER_Z - 1]`.
    pub fn sliceForDepth(self: ClusterGridFactors, positive_depth: f32) u32 {
        if (positive_depth <= self.z_near) return 0;
        const s = @floor(@log(positive_depth) * self.z_scale - self.z_bias);
        const si: i32 = @intFromFloat(s);
        return @intCast(std.math.clamp(si, 0, @as(i32, @intCast(CLUSTER_Z - 1))));
    }
};

/// Near and far plane distances recovered from a perspective projection.
pub const NearFar = struct { near: f32, far: f32 };

/// Recovers the near and far planes from a column-major perspective `clip_from_view` matrix.
/// Returns `null` for non-perspective projections, where the caller must supply its own range.
pub fn perspectiveNearFar(clip_from_view: [16]f32) ?NearFar {
    // Perspective matrices carry -1 in row 3, column 2 (index 11); orthographic ones carry 0.
    if (@abs(clip_from_view[11] + 1.0) > 1e-4) return null;
    const p10 = clip_from_view[10];
    const p14 = clip_from_view[14];
    if (@abs(p10) < 1e-6) return null;
    const near = p14 / p10;
    const far = p10 * near / (1.0 + p10);
    if (!(near > 0.0) or !(far > near)) return null;
    return .{ .near = near, .far = far };
}

/// Screen-space light footprint in cluster coordinates.
const ClusterBounds = struct { x0: u32, x1: u32, y0: u32, y1: u32, z0: u32, z1: u32 };

/// Per-cluster working state reused across frames.
const ClusterWork = struct {
    p_count: u32 = 0,
    s_count: u32 = 0,
    r_count: u32 = 0,
    total: u32 = 0,
    quota: u32 = 0,
    p_off: u32 = 0,
    s_off: u32 = 0,
    r_off: u32 = 0,
    p_cap: u32 = 0,
    s_cap: u32 = 0,
    r_cap: u32 = 0,
};

/// Persistent CPU buffers for cluster construction. Keep one per renderer and pass it to `buildClustersInto`.
pub const ClusterScratch = struct {
    work: []ClusterWork = &.{},
    entries: []ClusterEntry = &.{},
    indices: []u32 = &.{},
    point_bounds: []?ClusterBounds = &.{},
    spot_bounds: []?ClusterBounds = &.{},
    rect_bounds: []?ClusterBounds = &.{},

    /// Releases every buffer. The scratch is empty afterwards and may be reused.
    pub fn deinit(self: *ClusterScratch, allocator: std.mem.Allocator) void {
        if (self.work.len > 0) allocator.free(self.work);
        if (self.entries.len > 0) allocator.free(self.entries);
        if (self.indices.len > 0) allocator.free(self.indices);
        if (self.point_bounds.len > 0) allocator.free(self.point_bounds);
        if (self.spot_bounds.len > 0) allocator.free(self.spot_bounds);
        if (self.rect_bounds.len > 0) allocator.free(self.rect_bounds);
        self.* = .{};
    }
};

/// Cluster grid view into `ClusterScratch`. Valid until the next build with the same scratch.
pub const ClusterView = struct {
    factors: ClusterGridFactors,
    entries: []ClusterEntry,
    indices: []u32,
    /// Light references discarded because of the index budget or the per-type limit.
    dropped_refs: u32 = 0,
};

/// CPU-built cluster grid that owns its memory (see `buildClusters`).
pub const BuiltClusters = struct {
    factors: ClusterGridFactors,
    entries: []ClusterEntry,
    indices: []u32,
    dropped_refs: u32 = 0,

    pub fn deinit(self: *BuiltClusters, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        allocator.free(self.indices);
    }
};

fn transformPointView(view: [16]f32, pos: [3]f32) [3]f32 {
    const x = pos[0];
    const y = pos[1];
    const z = pos[2];
    return .{
        view[0] * x + view[4] * y + view[8] * z + view[12],
        view[1] * x + view[5] * y + view[9] * z + view[13],
        view[2] * x + view[6] * y + view[10] * z + view[14],
    };
}

fn sphereScreenBounds(
    view_pos: [3]f32,
    radius: f32,
    proj: [16]f32,
    factors: ClusterGridFactors,
) ?ClusterBounds {
    // Camera looks down -Z in view space; positive depth is -view_pos[2].
    const depth = -view_pos[2];
    if (depth + radius < factors.z_near or depth - radius > factors.z_far) return null;

    const z0 = factors.sliceForDepth(@max(depth - radius, factors.z_near));
    const z1 = factors.sliceForDepth(@min(depth + radius, factors.z_far));

    // If sphere intersects near plane, conservatively cover full XY frustum.
    if (depth - radius <= factors.z_near) {
        return .{ .x0 = 0, .x1 = CLUSTER_X - 1, .y0 = 0, .y1 = CLUSTER_Y - 1, .z0 = z0, .z1 = z1 };
    }

    const p00 = @max(@abs(proj[0]), 1e-4);
    const p11 = @max(@abs(proj[5]), 1e-4);
    const ndc_cx = (view_pos[0] * p00) / depth;
    const ndc_cy = (view_pos[1] * p11) / depth;
    const ndc_rx = (radius * p00) / @max(depth - radius, 0.05);
    const ndc_ry = (radius * p11) / @max(depth - radius, 0.05);

    // Reject lights whose footprint lies entirely outside the screen BEFORE clamping. Clamping first
    // turns every off-screen light into an edge-cluster light, which is the wasted work this avoids.
    // SDL_GPU screen UV: y=0 at top (+1 NDC), y=1 at bottom (-1 NDC).
    const raw_min_u = (ndc_cx - ndc_rx) * 0.5 + 0.5;
    const raw_max_u = (ndc_cx + ndc_rx) * 0.5 + 0.5;
    const raw_min_v = 0.5 - (ndc_cy + ndc_ry) * 0.5;
    const raw_max_v = 0.5 - (ndc_cy - ndc_ry) * 0.5;
    if (raw_max_u < 0.0 or raw_min_u > 1.0 or raw_max_v < 0.0 or raw_min_v > 1.0) return null;

    const min_u = std.math.clamp(raw_min_u, 0.0, 0.9999);
    const max_u = std.math.clamp(raw_max_u, 0.0, 0.9999);
    const min_v = std.math.clamp(raw_min_v, 0.0, 0.9999);
    const max_v = std.math.clamp(raw_max_v, 0.0, 0.9999);

    return .{
        .x0 = @intFromFloat(min_u * @as(f32, @floatFromInt(CLUSTER_X))),
        .x1 = @intFromFloat(max_u * @as(f32, @floatFromInt(CLUSTER_X))),
        .y0 = @intFromFloat(min_v * @as(f32, @floatFromInt(CLUSTER_Y))),
        .y1 = @intFromFloat(max_v * @as(f32, @floatFromInt(CLUSTER_Y))),
        .z0 = z0,
        .z1 = z1,
    };
}

/// Grows `buf` to at least `n` elements, keeping existing capacity when it is already large enough.
fn ensureLen(comptime T: type, allocator: std.mem.Allocator, buf: *[]T, n: usize) !void {
    if (buf.len >= n) return;
    if (buf.len > 0) allocator.free(buf.*);
    buf.* = try allocator.alloc(T, n);
}

/// Largest per-cluster level `L` such that `sum(min(total_c, L)) <= budget`, found by binary search.
fn waterLevel(work: []const ClusterWork, budget: u64) u32 {
    var max_total: u32 = 0;
    for (work) |w| max_total = @max(max_total, w.total);
    var lo: u32 = 0;
    var hi: u32 = max_total;
    while (lo < hi) {
        const mid = lo + (hi - lo + 1) / 2;
        var sum: u64 = 0;
        for (work) |w| sum += @min(w.total, mid);
        if (sum <= budget) lo = mid else hi = mid - 1;
    }
    return lo;
}

/// Assigns point, spot, and rect lights to clusters, writing the result into `scratch`.
///
/// Budget policy: the `MAX_CLUSTER_INDICES` budget is split by water-filling. Every cluster that has
/// lights receives the same per-cluster level, so a crowded cluster cannot starve the clusters that
/// come after it in index order. Leftover budget goes to the clusters that still have unreferenced
/// lights, in index order. Within a cluster the types are filled in point, spot, rect order.
pub fn buildClustersInto(
    scratch: *ClusterScratch,
    allocator: std.mem.Allocator,
    view_matrix: [16]f32,
    proj_matrix: [16]f32,
    z_near: f32,
    z_far: f32,
    points: []const pbr.ExtractedPointLight,
    spots: []const pbr.ExtractedSpotLight,
    rects: []const pbr.ExtractedRectLight,
) !ClusterView {
    const factors = ClusterGridFactors.init(z_near, z_far);
    try ensureLen(ClusterWork, allocator, &scratch.work, CLUSTER_COUNT);
    try ensureLen(ClusterEntry, allocator, &scratch.entries, CLUSTER_COUNT);
    try ensureLen(?ClusterBounds, allocator, &scratch.point_bounds, points.len);
    try ensureLen(?ClusterBounds, allocator, &scratch.spot_bounds, spots.len);
    try ensureLen(?ClusterBounds, allocator, &scratch.rect_bounds, rects.len);
    const work = scratch.work[0..CLUSTER_COUNT];
    @memset(work, .{});

    // Pass 1: count references per cluster. Counts are exact; the 8-bit limit is applied later.
    for (points, 0..) |pl, li| {
        const vp = transformPointView(view_matrix, pl.position);
        scratch.point_bounds[li] = sphereScreenBounds(vp, pl.range, proj_matrix, factors);
        if (scratch.point_bounds[li]) |b| markBounds(work, b, .point);
    }
    for (spots, 0..) |sl, li| {
        const vp = transformPointView(view_matrix, sl.position);
        scratch.spot_bounds[li] = sphereScreenBounds(vp, sl.range, proj_matrix, factors);
        if (scratch.spot_bounds[li]) |b| markBounds(work, b, .spot);
    }
    for (rects, 0..) |rl, li| {
        const vp = transformPointView(view_matrix, rl.position);
        const bound_r = rl.range + @max(rl.half_extents[0], rl.half_extents[1]);
        scratch.rect_bounds[li] = sphereScreenBounds(vp, bound_r, proj_matrix, factors);
        if (scratch.rect_bounds[li]) |b| markBounds(work, b, .rect);
    }

    // Per-type counts are limited by the packed format; anything above the limit is dropped and counted.
    var raw_refs: u64 = 0;
    for (work) |*w| {
        raw_refs += @as(u64, w.p_count) + w.s_count + w.r_count;
        w.p_count = @min(w.p_count, MAX_REFS_PER_TYPE);
        w.s_count = @min(w.s_count, MAX_REFS_PER_TYPE);
        w.r_count = @min(w.r_count, MAX_REFS_PER_TYPE);
        w.total = w.p_count + w.s_count + w.r_count;
    }

    // Water-filling: each cluster gets min(total, level), then leftover budget tops up clusters in index order.
    const level = waterLevel(work, MAX_CLUSTER_INDICES);
    var used: u64 = 0;
    for (work) |*w| {
        w.quota = @min(w.total, level);
        used += w.quota;
    }
    var leftover: u64 = MAX_CLUSTER_INDICES - used;
    for (work) |*w| {
        if (leftover == 0) break;
        if (w.total > level) {
            w.quota += 1;
            leftover -= 1;
        }
    }

    // Split each cluster's quota across types in point, spot, rect order and lay out contiguous ranges.
    var cursor: u32 = 0;
    var kept: u64 = 0;
    for (work, 0..) |*w, cid| {
        const pc = @min(w.p_count, w.quota);
        const sc = @min(w.s_count, w.quota - pc);
        const rc = @min(w.r_count, w.quota - pc - sc);
        w.p_cap = pc;
        w.s_cap = sc;
        w.r_cap = rc;
        w.p_off = cursor;
        w.s_off = cursor + pc;
        w.r_off = cursor + pc + sc;
        cursor += pc + sc + rc;
        kept += @as(u64, pc) + sc + rc;
        scratch.entries[cid] = .{
            .point_packed = (w.p_off << 8) | pc,
            .spot_packed = (w.s_off << 8) | sc,
            .rect_packed = (w.r_off << 8) | rc,
        };
    }

    const total_len: usize = @max(@as(usize, cursor), 1);
    try ensureLen(u32, allocator, &scratch.indices, total_len);
    const indices = scratch.indices[0..total_len];
    if (cursor == 0) indices[0] = 0;

    // Pass 2: write the kept light indices into the flat array, in the same order as the counts.
    for (work) |*w| {
        w.p_count = 0;
        w.s_count = 0;
        w.r_count = 0;
    }
    for (scratch.point_bounds[0..points.len], 0..) |maybe_b, li| {
        const b = maybe_b orelse continue;
        scatterBounds(work, indices, b, li, .point);
    }
    for (scratch.spot_bounds[0..spots.len], 0..) |maybe_b, li| {
        const b = maybe_b orelse continue;
        scatterBounds(work, indices, b, li, .spot);
    }
    for (scratch.rect_bounds[0..rects.len], 0..) |maybe_b, li| {
        const b = maybe_b orelse continue;
        scatterBounds(work, indices, b, li, .rect);
    }

    const raw_clamped: u32 = @intCast(@min(raw_refs, std.math.maxInt(u32)));
    return .{
        .factors = factors,
        .entries = scratch.entries[0..CLUSTER_COUNT],
        .indices = indices,
        .dropped_refs = raw_clamped - @as(u32, @intCast(@min(kept, raw_clamped))),
    };
}

const LightType = enum { point, spot, rect };

fn clusterId(x: u32, y: u32, z: u32) usize {
    return (y * CLUSTER_X + x) * CLUSTER_Z + z;
}

fn markBounds(work: []ClusterWork, b: ClusterBounds, kind: LightType) void {
    for (b.y0..b.y1 + 1) |y| {
        for (b.x0..b.x1 + 1) |x| {
            for (b.z0..b.z1 + 1) |z| {
                const w = &work[clusterId(@intCast(x), @intCast(y), @intCast(z))];
                switch (kind) {
                    .point => w.p_count += 1,
                    .spot => w.s_count += 1,
                    .rect => w.r_count += 1,
                }
            }
        }
    }
}

fn scatterBounds(work: []ClusterWork, indices: []u32, b: ClusterBounds, light_index: usize, kind: LightType) void {
    for (b.y0..b.y1 + 1) |y| {
        for (b.x0..b.x1 + 1) |x| {
            for (b.z0..b.z1 + 1) |z| {
                const cid = clusterId(@intCast(x), @intCast(y), @intCast(z));
                const w = &work[cid];
                switch (kind) {
                    .point => {
                        if (w.p_count < w.p_cap) {
                            indices[w.p_off + w.p_count] = @intCast(light_index);
                            w.p_count += 1;
                        }
                    },
                    .spot => {
                        if (w.s_count < w.s_cap) {
                            indices[w.s_off + w.s_count] = @intCast(light_index);
                            w.s_count += 1;
                        }
                    },
                    .rect => {
                        if (w.r_count < w.r_cap) {
                            indices[w.r_off + w.r_count] = @intCast(light_index);
                            w.r_count += 1;
                        }
                    },
                }
            }
        }
    }
}

/// Owning convenience wrapper around `buildClustersInto` for callers that do not keep a scratch.
pub fn buildClusters(
    allocator: std.mem.Allocator,
    view_matrix: [16]f32,
    proj_matrix: [16]f32,
    z_near: f32,
    z_far: f32,
    points: []const pbr.ExtractedPointLight,
    spots: []const pbr.ExtractedSpotLight,
    rects: []const pbr.ExtractedRectLight,
) !BuiltClusters {
    var scratch: ClusterScratch = .{};
    defer scratch.deinit(allocator);
    const view = try buildClustersInto(&scratch, allocator, view_matrix, proj_matrix, z_near, z_far, points, spots, rects);

    const entries = try allocator.dupe(ClusterEntry, view.entries);
    errdefer allocator.free(entries);
    const indices = try allocator.dupe(u32, view.indices);
    return .{
        .factors = view.factors,
        .entries = entries,
        .indices = indices,
        .dropped_refs = view.dropped_refs,
    };
}
