//! Agnostic Clustered Forward+ Light & Probe Assignment (`packages/render/3d/src/cluster.zig`).
//!
//! Divides the view frustum into a `16 x 9 x 24` 3D grid with logarithmic Z slicing
//! and assigns `PointLight`, `SpotLight`, and `RectLight` indices per cluster.

const std = @import("std");
const pbr = @import("pbr.zig");

pub const CLUSTER_X: u32 = 16;
pub const CLUSTER_Y: u32 = 9;
pub const CLUSTER_Z: u32 = 24;
pub const CLUSTER_COUNT: usize = @as(usize, CLUSTER_X) * @as(usize, CLUSTER_Y) * @as(usize, CLUSTER_Z);
/// Maximum number of light index entries uploaded to the GPU cluster index SSBO.
pub const MAX_CLUSTER_INDICES: u32 = 65536;

/// Packed per-cluster index offsets and counts (`16 bytes`, matches GLSL `uvec4`).
/// Layout: `x = (point_offset << 12) | point_count`, `y = (spot_offset << 12) | spot_count`,
/// `z = (rect_offset << 12) | rect_count`, `w = 0`.
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

/// CPU-built cluster grid ready for GPU SSBO upload.
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
    return .{
        view[0] * pos[0] + view[4] * pos[1] + view[8] * pos[2] + view[12],
        view[1] * pos[0] + view[5] * pos[1] + view[9] * pos[2] + view[13],
        view[2] * pos[0] + view[6] * pos[1] + view[10] * pos[2] + view[14],
    };
}

fn sphereScreenBounds(
    view_pos: [3]f32,
    radius: f32,
    proj: [16]f32,
    factors: ClusterGridFactors,
) ?struct { x0: u32, x1: u32, y0: u32, y1: u32, z0: u32, z1: u32 } {
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

    const min_u = std.math.clamp((ndc_cx - ndc_rx) * 0.5 + 0.5, 0.0, 0.9999);
    const max_u = std.math.clamp((ndc_cx + ndc_rx) * 0.5 + 0.5, 0.0, 0.9999);
    // SDL_GPU screen UV: y=0 at top (+1 NDC), y=1 at bottom (-1 NDC).
    const min_v = std.math.clamp(0.5 - (ndc_cy + ndc_ry) * 0.5, 0.0, 0.9999);
    const max_v = std.math.clamp(0.5 - (ndc_cy - ndc_ry) * 0.5, 0.0, 0.9999);

    if (max_u < 0.0 or min_u > 1.0 or max_v < 0.0 or min_v > 1.0) return null;

    return .{
        .x0 = @intFromFloat(min_u * @as(f32, @floatFromInt(CLUSTER_X))),
        .x1 = @intFromFloat(max_u * @as(f32, @floatFromInt(CLUSTER_X))),
        .y0 = @intFromFloat(min_v * @as(f32, @floatFromInt(CLUSTER_Y))),
        .y1 = @intFromFloat(max_v * @as(f32, @floatFromInt(CLUSTER_Y))),
        .z0 = z0,
        .z1 = z1,
    };
}

/// Assigns point, spot, and rect lights to `16 x 9 x 24` frustum clusters using a 2-pass flat prefix sum.
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
    const factors = ClusterGridFactors.init(z_near, z_far);
    const entries = try allocator.alloc(ClusterEntry, CLUSTER_COUNT);
    errdefer allocator.free(entries);

    var p_counts: [CLUSTER_COUNT]u8 = @splat(0);
    var s_counts: [CLUSTER_COUNT]u8 = @splat(0);
    var r_counts: [CLUSTER_COUNT]u8 = @splat(0);

    const Bounds = struct { x0: u32, x1: u32, y0: u32, y1: u32, z0: u32, z1: u32 };
    var p_bounds = try allocator.alloc(?Bounds, points.len);
    defer allocator.free(p_bounds);
    var s_bounds = try allocator.alloc(?Bounds, spots.len);
    defer allocator.free(s_bounds);
    var r_bounds = try allocator.alloc(?Bounds, rects.len);
    defer allocator.free(r_bounds);

    // Pass 1: count per-cluster hits.
    for (points, 0..) |pl, li| {
        const vp = transformPointView(view_matrix, pl.position);
        const sb = sphereScreenBounds(vp, pl.range, proj_matrix, factors);
        p_bounds[li] = if (sb) |b| .{ .x0 = b.x0, .x1 = b.x1, .y0 = b.y0, .y1 = b.y1, .z0 = b.z0, .z1 = b.z1 } else null;
        if (p_bounds[li]) |b| {
            for (b.y0..b.y1 + 1) |y| {
                for (b.x0..b.x1 + 1) |x| {
                    for (b.z0..b.z1 + 1) |z| {
                        const cid = (y * CLUSTER_X + x) * CLUSTER_Z + z;
                        if (p_counts[cid] < 64) p_counts[cid] += 1;
                    }
                }
            }
        }
    }

    for (spots, 0..) |sl, li| {
        const vp = transformPointView(view_matrix, sl.position);
        const sb = sphereScreenBounds(vp, sl.range, proj_matrix, factors);
        s_bounds[li] = if (sb) |b| .{ .x0 = b.x0, .x1 = b.x1, .y0 = b.y0, .y1 = b.y1, .z0 = b.z0, .z1 = b.z1 } else null;
        if (s_bounds[li]) |b| {
            for (b.y0..b.y1 + 1) |y| {
                for (b.x0..b.x1 + 1) |x| {
                    for (b.z0..b.z1 + 1) |z| {
                        const cid = (y * CLUSTER_X + x) * CLUSTER_Z + z;
                        if (s_counts[cid] < 64) s_counts[cid] += 1;
                    }
                }
            }
        }
    }

    for (rects, 0..) |rl, li| {
        const vp = transformPointView(view_matrix, rl.position);
        const bound_r = rl.range + @max(rl.half_extents[0], rl.half_extents[1]);
        const sb = sphereScreenBounds(vp, bound_r, proj_matrix, factors);
        r_bounds[li] = if (sb) |b| .{ .x0 = b.x0, .x1 = b.x1, .y0 = b.y0, .y1 = b.y1, .z0 = b.z0, .z1 = b.z1 } else null;
        if (r_bounds[li]) |b| {
            for (b.y0..b.y1 + 1) |y| {
                for (b.x0..b.x1 + 1) |x| {
                    for (b.z0..b.z1 + 1) |z| {
                        const cid = (y * CLUSTER_X + x) * CLUSTER_Z + z;
                        if (r_counts[cid] < 64) r_counts[cid] += 1;
                    }
                }
            }
        }
    }

    // Prefix sum offsets bounded by MAX_CLUSTER_INDICES so GPU reads never go out of bounds.
    var p_offs: [CLUSTER_COUNT]u32 = undefined;
    var s_offs: [CLUSTER_COUNT]u32 = undefined;
    var r_offs: [CLUSTER_COUNT]u32 = undefined;
    var p_caps: [CLUSTER_COUNT]u8 = @splat(0);
    var s_caps: [CLUSTER_COUNT]u8 = @splat(0);
    var r_caps: [CLUSTER_COUNT]u8 = @splat(0);
    var dropped_refs: u32 = 0;
    var cursor: u32 = 0;
    for (0..CLUSTER_COUNT) |cid| {
        const avail_p = MAX_CLUSTER_INDICES - @min(cursor, MAX_CLUSTER_INDICES);
        const pc: u32 = @min(@as(u32, p_counts[cid]), avail_p);
        dropped_refs += @as(u32, p_counts[cid]) - pc;
        p_offs[cid] = cursor;
        cursor += pc;
        p_caps[cid] = @intCast(pc);

        const avail_s = MAX_CLUSTER_INDICES - @min(cursor, MAX_CLUSTER_INDICES);
        const sc: u32 = @min(@as(u32, s_counts[cid]), avail_s);
        dropped_refs += @as(u32, s_counts[cid]) - sc;
        s_offs[cid] = cursor;
        cursor += sc;
        s_caps[cid] = @intCast(sc);

        const avail_r = MAX_CLUSTER_INDICES - @min(cursor, MAX_CLUSTER_INDICES);
        const rc: u32 = @min(@as(u32, r_counts[cid]), avail_r);
        dropped_refs += @as(u32, r_counts[cid]) - rc;
        r_offs[cid] = cursor;
        cursor += rc;
        r_caps[cid] = @intCast(rc);

        entries[cid] = .{
            .point_packed = (p_offs[cid] << 8) | pc,
            .spot_packed = (s_offs[cid] << 8) | sc,
            .rect_packed = (r_offs[cid] << 8) | rc,
        };
    }

    const total_len: usize = @max(@as(usize, cursor), 1);
    const indices = try allocator.alloc(u32, total_len);
    if (cursor == 0) indices[0] = 0;

    // Pass 2: scatter light indices directly into flat array.
    @memset(&p_counts, 0);
    @memset(&s_counts, 0);
    @memset(&r_counts, 0);

    for (p_bounds, 0..) |maybe_b, li| {
        const b = maybe_b orelse continue;
        for (b.y0..b.y1 + 1) |y| {
            for (b.x0..b.x1 + 1) |x| {
                for (b.z0..b.z1 + 1) |z| {
                    const cid = (y * CLUSTER_X + x) * CLUSTER_Z + z;
                    const c_idx = p_counts[cid];
                    if (c_idx < p_caps[cid]) {
                        indices[p_offs[cid] + c_idx] = @intCast(li);
                        p_counts[cid] = c_idx + 1;
                    }
                }
            }
        }
    }

    for (s_bounds, 0..) |maybe_b, li| {
        const b = maybe_b orelse continue;
        for (b.y0..b.y1 + 1) |y| {
            for (b.x0..b.x1 + 1) |x| {
                for (b.z0..b.z1 + 1) |z| {
                    const cid = (y * CLUSTER_X + x) * CLUSTER_Z + z;
                    const c_idx = s_counts[cid];
                    if (c_idx < s_caps[cid]) {
                        indices[s_offs[cid] + c_idx] = @intCast(li);
                        s_counts[cid] = c_idx + 1;
                    }
                }
            }
        }
    }

    for (r_bounds, 0..) |maybe_b, li| {
        const b = maybe_b orelse continue;
        for (b.y0..b.y1 + 1) |y| {
            for (b.x0..b.x1 + 1) |x| {
                for (b.z0..b.z1 + 1) |z| {
                    const cid = (y * CLUSTER_X + x) * CLUSTER_Z + z;
                    const c_idx = r_counts[cid];
                    if (c_idx < r_caps[cid]) {
                        indices[r_offs[cid] + c_idx] = @intCast(li);
                        r_counts[cid] = c_idx + 1;
                    }
                }
            }
        }
    }

    return .{
        .factors = factors,
        .entries = entries,
        .indices = indices,
        .dropped_refs = dropped_refs,
    };
}
