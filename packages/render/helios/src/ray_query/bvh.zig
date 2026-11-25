//! Stage 11 Helios Software Ray Queries & Flat BVH Traversal (`packages/render/helios/src/ray_query/bvh.zig`).
//!
//! Experimental geometry query contract independent of traversal implementation:
//! - `Ray`, `RayHit` (distance, instance/primitive IDs, barycentrics, normal), `QueryStats`
//! - GPU-packable flat `BvhNode` array with bounded iterative traversal (`MAX_STACK = 64`)
//! - Robust slab AABB + Moller-Trumbore triangle intersection with explicit overflow tracking

const std = @import("std");

/// Maximum traversal stack depth for bounded iterative BVH queries.
pub const MAX_STACK: usize = 64;

/// Ray query descriptor.
pub const Ray = struct {
    origin: [3]f32,
    direction: [3]f32,
    t_min: f32 = 1e-4,
    t_max: f32 = 1e6,
    mask: u32 = 0xFFFF_FFFF,
};

/// Closest-hit or any-hit query result.
pub const RayHit = struct {
    hit: bool = false,
    t: f32 = std.math.inf(f32),
    instance_id: u32 = 0,
    primitive_id: u32 = 0,
    u: f32 = 0.0,
    v: f32 = 0.0,
    normal: [3]f32 = .{ 0, 1, 0 },
};

/// Diagnostic counters collected during ray query traversal.
pub const QueryStats = struct {
    rays_cast: u64 = 0,
    node_visits: u64 = 0,
    tri_tests: u64 = 0,
    stack_overflows: u64 = 0,
};

/// Indexed triangle primitive stored in the BVH.
pub const BvhTriangle = struct {
    v0: [3]f32,
    v1: [3]f32,
    v2: [3]f32,
    instance_id: u32 = 0,
    primitive_id: u32 = 0,
    mask: u32 = 0xFFFF_FFFF,
};

/// Compact flat BVH node (leaf when `prim_count > 0`, internal otherwise).
pub const BvhNode = extern struct {
    aabb_min: [3]f32,
    left_or_first: u32,
    aabb_max: [3]f32,
    prim_count: u32,
};

fn sub3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

fn cross3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

fn dot3(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn triCentroid(t: BvhTriangle) [3]f32 {
    return .{
        (t.v0[0] + t.v1[0] + t.v2[0]) / 3.0,
        (t.v0[1] + t.v1[1] + t.v2[1]) / 3.0,
        (t.v0[2] + t.v1[2] + t.v2[2]) / 3.0,
    };
}

fn intersectAabb(ray: Ray, inv_dir: [3]f32, bmin: [3]f32, bmax: [3]f32, cur_t_max: f32) ?f32 {
    if (!(ray.t_min <= cur_t_max)) return null;
    var tmin = ray.t_min;
    var tmax = cur_t_max;
    inline for (0..3) |i| {
        if (!std.math.isFinite(ray.origin[i]) or !std.math.isFinite(ray.direction[i])) return null;
        if (ray.direction[i] == 0.0) {
            if (ray.origin[i] < bmin[i] or ray.origin[i] > bmax[i]) return null;
        } else {
            const t1 = if (std.math.isFinite(inv_dir[i])) (bmin[i] - ray.origin[i]) * inv_dir[i] else (bmin[i] - ray.origin[i]) / ray.direction[i];
            const t2 = if (std.math.isFinite(inv_dir[i])) (bmax[i] - ray.origin[i]) * inv_dir[i] else (bmax[i] - ray.origin[i]) / ray.direction[i];
            const lo = @min(t1, t2);
            const hi = @max(t1, t2);
            tmin = @max(tmin, lo);
            tmax = @min(tmax, hi);
            if (tmin > tmax) return null;
        }
    }
    return tmin;
}

/// Moller-Trumbore ray-triangle intersection.
pub fn intersectTriangle(ray: Ray, tri: BvhTriangle, cur_t_max: f32) ?RayHit {
    if ((ray.mask & tri.mask) == 0) return null;
    const e1 = sub3(tri.v1, tri.v0);
    const e2 = sub3(tri.v2, tri.v0);
    const h = cross3(ray.direction, e2);
    const a = dot3(e1, h);
    if (@abs(a) < 1e-7) return null;

    const f = 1.0 / a;
    const s = sub3(ray.origin, tri.v0);
    const u = f * dot3(s, h);
    if (u < 0.0 or u > 1.0) return null;

    const q = cross3(s, e1);
    const v = f * dot3(ray.direction, q);
    if (v < 0.0 or u + v > 1.0) return null;

    const t = f * dot3(e2, q);
    if (t < ray.t_min or t > cur_t_max or !std.math.isFinite(t)) return null;

    const raw_n = cross3(e1, e2);
    const nlen = @max(@sqrt(dot3(raw_n, raw_n)), 1e-6);
    return .{
        .hit = true,
        .t = t,
        .instance_id = tri.instance_id,
        .primitive_id = tri.primitive_id,
        .u = u,
        .v = v,
        .normal = .{ raw_n[0] / nlen, raw_n[1] / nlen, raw_n[2] / nlen },
    };
}

/// Flat BVH acceleration structure supporting bounded iterative closest-hit and any-hit queries.
pub const Bvh = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(BvhNode),
    triangles: std.ArrayList(BvhTriangle),

    /// Initializes an empty `Bvh`.
    pub fn init(allocator: std.mem.Allocator) Bvh {
        return .{
            .allocator = allocator,
            .nodes = .empty,
            .triangles = .empty,
        };
    }

    /// Releases BVH node and triangle buffers.
    pub fn deinit(self: *Bvh) void {
        self.nodes.deinit(self.allocator);
        self.triangles.deinit(self.allocator);
    }

    /// Builds the flat BVH from `tris`.
    pub fn build(self: *Bvh, tris: []const BvhTriangle) !void {
        self.nodes.clearRetainingCapacity();
        self.triangles.clearRetainingCapacity();
        if (tris.len == 0) return;
        errdefer {
            self.nodes.clearRetainingCapacity();
            self.triangles.clearRetainingCapacity();
        }

        if (tris.len > std.math.maxInt(u32) / 2) return error.TooManyTriangles;
        for (tris) |tri| {
            for ([_][3]f32{ tri.v0, tri.v1, tri.v2 }) |vertex| {
                for (vertex) |coordinate| if (!std.math.isFinite(coordinate)) return error.InvalidTriangle;
            }
        }
        try self.triangles.appendSlice(self.allocator, tris);
        try self.nodes.append(self.allocator, .{
            .aabb_min = .{ 0, 0, 0 },
            .left_or_first = 0,
            .aabb_max = .{ 0, 0, 0 },
            .prim_count = @intCast(tris.len),
        });
        self.updateBounds(0);
        try self.subdivide(0, 0);
    }

    fn updateBounds(self: *Bvh, node_idx: u32) void {
        const node = &self.nodes.items[node_idx];
        var bmin = [3]f32{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) };
        var bmax = [3]f32{ -std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };
        const first = node.left_or_first;
        for (self.triangles.items[first .. first + node.prim_count]) |t| {
            inline for ([3][3]f32{ t.v0, t.v1, t.v2 }) |p| {
                inline for (0..3) |i| {
                    bmin[i] = @min(bmin[i], p[i]);
                    bmax[i] = @max(bmax[i], p[i]);
                }
            }
        }
        node.aabb_min = bmin;
        node.aabb_max = bmax;
    }

    fn subdivide(self: *Bvh, node_idx: u32, depth: usize) !void {
        const prim_count = self.nodes.items[node_idx].prim_count;
        if (prim_count <= 2 or depth >= MAX_STACK - 2) return;

        const first = self.nodes.items[node_idx].left_or_first;
        const bmin = self.nodes.items[node_idx].aabb_min;
        const bmax = self.nodes.items[node_idx].aabb_max;
        const ext = [3]f32{ bmax[0] - bmin[0], bmax[1] - bmin[1], bmax[2] - bmin[2] };

        var axis: usize = 0;
        if (ext[1] > ext[axis]) axis = 1;
        if (ext[2] > ext[axis]) axis = 2;
        const split_pos = bmin[axis] + ext[axis] * 0.5;

        var i: usize = first;
        var j: usize = first + prim_count - 1;
        while (i <= j) {
            if (triCentroid(self.triangles.items[i])[axis] < split_pos) {
                i += 1;
            } else {
                const tmp = self.triangles.items[i];
                self.triangles.items[i] = self.triangles.items[j];
                self.triangles.items[j] = tmp;
                if (j == 0) break;
                j -= 1;
            }
        }

        var left_count = i - first;
        if (left_count == 0 or left_count == prim_count) {
            // Identical centroids still form a balanced tree. Avoid an unbounded leaf.
            left_count = @as(usize, prim_count) / 2;
            i = @as(usize, first) + left_count;
        }

        const left_idx: u32 = @intCast(self.nodes.items.len);
        const right_idx: u32 = left_idx + 1;
        try self.nodes.append(self.allocator, .{
            .aabb_min = .{ 0, 0, 0 },
            .left_or_first = first,
            .aabb_max = .{ 0, 0, 0 },
            .prim_count = @intCast(left_count),
        });
        try self.nodes.append(self.allocator, .{
            .aabb_min = .{ 0, 0, 0 },
            .left_or_first = @intCast(i),
            .aabb_max = .{ 0, 0, 0 },
            .prim_count = @intCast(prim_count - left_count),
        });

        self.nodes.items[node_idx].left_or_first = left_idx;
        self.nodes.items[node_idx].prim_count = 0;

        self.updateBounds(left_idx);
        self.updateBounds(right_idx);
        try self.subdivide(left_idx, depth + 1);
        try self.subdivide(right_idx, depth + 1);
    }

    /// Bounded iterative closest-hit ray query.
    pub fn traceClosest(self: *const Bvh, ray: Ray, stats: ?*QueryStats) RayHit {
        if (stats) |s| s.rays_cast += 1;
        if (self.nodes.items.len == 0) return .{};

        const inv_dir = [3]f32{
            if (ray.direction[0] != 0.0) 1.0 / ray.direction[0] else 0.0,
            if (ray.direction[1] != 0.0) 1.0 / ray.direction[1] else 0.0,
            if (ray.direction[2] != 0.0) 1.0 / ray.direction[2] else 0.0,
        };

        var best = RayHit{ .t = ray.t_max };
        var stack: [MAX_STACK]u32 = undefined;
        var sp: usize = 0;
        stack[sp] = 0;
        sp += 1;

        while (sp > 0) {
            sp -= 1;
            const idx = stack[sp];
            const node = self.nodes.items[idx];
            if (stats) |s| s.node_visits += 1;

            if (intersectAabb(ray, inv_dir, node.aabb_min, node.aabb_max, best.t) == null) continue;

            if (node.prim_count > 0) {
                for (self.triangles.items[node.left_or_first .. node.left_or_first + node.prim_count]) |tri| {
                    if (stats) |s| s.tri_tests += 1;
                    if (intersectTriangle(ray, tri, best.t)) |h| {
                        best = h;
                    }
                }
            } else {
                const l = node.left_or_first;
                const r = l + 1;
                const dl = intersectAabb(ray, inv_dir, self.nodes.items[l].aabb_min, self.nodes.items[l].aabb_max, best.t);
                const dr = intersectAabb(ray, inv_dir, self.nodes.items[r].aabb_min, self.nodes.items[r].aabb_max, best.t);

                if (dl != null and dr != null) {
                    const near_c = if (dl.? <= dr.?) l else r;
                    const far_c = if (dl.? <= dr.?) r else l;
                    if (sp + 2 <= MAX_STACK) {
                        stack[sp] = far_c;
                        stack[sp + 1] = near_c;
                        sp += 2;
                    } else if (stats) |s| {
                        s.stack_overflows += 1;
                    }
                } else if (dl != null) {
                    if (sp < MAX_STACK) {
                        stack[sp] = l;
                        sp += 1;
                    } else if (stats) |s| {
                        s.stack_overflows += 1;
                    }
                } else if (dr != null) {
                    if (sp < MAX_STACK) {
                        stack[sp] = r;
                        sp += 1;
                    } else if (stats) |s| {
                        s.stack_overflows += 1;
                    }
                }
            }
        }
        return best;
    }

    /// Bounded iterative any-hit visibility query (exits on first occluder).
    pub fn traceAnyHit(self: *const Bvh, ray: Ray, stats: ?*QueryStats) bool {
        if (stats) |s| s.rays_cast += 1;
        if (self.nodes.items.len == 0) return false;

        const inv_dir = [3]f32{
            if (ray.direction[0] != 0.0) 1.0 / ray.direction[0] else 0.0,
            if (ray.direction[1] != 0.0) 1.0 / ray.direction[1] else 0.0,
            if (ray.direction[2] != 0.0) 1.0 / ray.direction[2] else 0.0,
        };

        var stack: [MAX_STACK]u32 = undefined;
        var sp: usize = 0;
        stack[sp] = 0;
        sp += 1;

        while (sp > 0) {
            sp -= 1;
            const node = self.nodes.items[stack[sp]];
            if (stats) |s| s.node_visits += 1;
            if (intersectAabb(ray, inv_dir, node.aabb_min, node.aabb_max, ray.t_max) == null) continue;

            if (node.prim_count > 0) {
                for (self.triangles.items[node.left_or_first .. node.left_or_first + node.prim_count]) |tri| {
                    if (stats) |s| s.tri_tests += 1;
                    if (intersectTriangle(ray, tri, ray.t_max) != null) return true;
                }
            } else {
                const l = node.left_or_first;
                const r = l + 1;
                if (sp + 2 <= MAX_STACK) {
                    stack[sp] = r;
                    stack[sp + 1] = l;
                    sp += 2;
                } else if (stats) |s| {
                    s.stack_overflows += 1;
                }
            }
        }
        return false;
    }
};
