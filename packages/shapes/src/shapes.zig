//! Procedural 3D Shape Primitives (`official.shapes`).
//!
//! Generates ready-to-render 3D meshes (`Plane`, `Cuboid`, `Sphere`, `Capsule`,
//! `Cylinder`, `Torus`, `Cone`) with positions, normals, UVs, and 4-component
//! MikkTSpace-style tangents `(tx, ty, tz, handedness)` compatible with
//! `render_3d.gltf.Vertex3D` and `graphics_sdlgpu.createMesh3D`.

const std = @import("std");
const engine = @import("engine");
const render_3d = @import("render_3d");

pub const Vertex3D = render_3d.gltf.Vertex3D;
pub const MeshData = render_3d.gltf.MeshData;

/// Owner ID used when registering the `official.shapes` module.
pub const MODULE_OWNER_ID: u64 = 2041;

/// Procedural mesh output containing `Vertex3D` data, per-vertex `[4]f32`
/// tangents `(tx, ty, tz, handedness)`, triangle indices, and bounding sphere.
pub const ShapeMesh = struct {
    allocator: std.mem.Allocator,
    vertices: []Vertex3D,
    tangents: [][4]f32,
    indices: []u32,
    bounds_center: [3]f32,
    bounds_radius: f32,

    /// Frees all owned vertex, tangent, and index buffers.
    pub fn deinit(self: *ShapeMesh) void {
        self.allocator.free(self.vertices);
        self.allocator.free(self.tangents);
        self.allocator.free(self.indices);
    }

    /// Returns a cloned `render_3d.gltf.MeshData` owned by `allocator`.
    pub fn toMeshData(self: *const ShapeMesh, allocator: std.mem.Allocator) !MeshData {
        const verts = try allocator.dupe(Vertex3D, self.vertices);
        errdefer allocator.free(verts);
        const inds = try allocator.dupe(u32, self.indices);
        return .{
            .allocator = allocator,
            .vertices = verts,
            .indices = inds,
            .bounds_center = self.bounds_center,
            .bounds_radius = self.bounds_radius,
        };
    }
};

fn computeBounds(vertices: []const Vertex3D) struct { center: [3]f32, radius: f32 } {
    if (vertices.len == 0) return .{ .center = .{ 0, 0, 0 }, .radius = 0.0 };
    var min_p = [3]f32{ vertices[0].x, vertices[0].y, vertices[0].z };
    var max_p = min_p;
    for (vertices) |v| {
        min_p[0] = @min(min_p[0], v.x);
        min_p[1] = @min(min_p[1], v.y);
        min_p[2] = @min(min_p[2], v.z);
        max_p[0] = @max(max_p[0], v.x);
        max_p[1] = @max(max_p[1], v.y);
        max_p[2] = @max(max_p[2], v.z);
    }
    const cx = (min_p[0] + max_p[0]) * 0.5;
    const cy = (min_p[1] + max_p[1]) * 0.5;
    const cz = (min_p[2] + max_p[2]) * 0.5;
    var max_r2: f32 = 0.0;
    for (vertices) |v| {
        const dx = v.x - cx;
        const dy = v.y - cy;
        const dz = v.z - cz;
        max_r2 = @max(max_r2, dx * dx + dy * dy + dz * dz);
    }
    return .{ .center = .{ cx, cy, cz }, .radius = @sqrt(max_r2) };
}

fn normalize3(v: [3]f32) [3]f32 {
    const len = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (len < 1e-6) return .{ 1, 0, 0 };
    return .{ v[0] / len, v[1] / len, v[2] / len };
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

fn fallbackTangent(n: [3]f32) [3]f32 {
    const up: [3]f32 = if (@abs(n[1]) < 0.99) .{ 0, 1, 0 } else .{ 1, 0, 0 };
    return normalize3(cross3(up, n));
}

/// Computes orthogonalized per-vertex `[4]f32` tangents `(tx, ty, tz, handedness)`
/// from triangle positions and UV coordinates.
pub fn computeTangents(allocator: std.mem.Allocator, vertices: []const Vertex3D, indices: []const u32) ![][4]f32 {
    const tangents = try allocator.alloc([4]f32, vertices.len);
    errdefer allocator.free(tangents);

    const tan1 = try allocator.alloc([3]f32, vertices.len);
    defer allocator.free(tan1);
    const tan2 = try allocator.alloc([3]f32, vertices.len);
    defer allocator.free(tan2);
    @memset(tan1, .{ 0, 0, 0 });
    @memset(tan2, .{ 0, 0, 0 });

    var ti: usize = 0;
    while (ti + 2 < indices.len) : (ti += 3) {
        const idx0 = indices[ti];
        const idx1 = indices[ti + 1];
        const idx2 = indices[ti + 2];
        if (idx0 >= vertices.len or idx1 >= vertices.len or idx2 >= vertices.len) continue;

        const v0 = vertices[idx0];
        const v1 = vertices[idx1];
        const v2 = vertices[idx2];

        const x1 = v1.x - v0.x;
        const x2 = v2.x - v0.x;
        const y1 = v1.y - v0.y;
        const y2 = v2.y - v0.y;
        const z1 = v1.z - v0.z;
        const z2 = v2.z - v0.z;

        const s1 = v1.u - v0.u;
        const s2 = v2.u - v0.u;
        const t1 = v1.v - v0.v;
        const t2 = v2.v - v0.v;

        const denom = s1 * t2 - s2 * t1;
        if (@abs(denom) < 1e-8) continue;
        const r = 1.0 / denom;

        const sdir = [3]f32{ (t2 * x1 - t1 * x2) * r, (t2 * y1 - t1 * y2) * r, (t2 * z1 - t1 * z2) * r };
        const tdir = [3]f32{ (s1 * x2 - s2 * x1) * r, (s1 * y2 - s2 * y1) * r, (s1 * z2 - s2 * z1) * r };

        inline for ([3]u32{ idx0, idx1, idx2 }) |idx| {
            tan1[idx][0] += sdir[0];
            tan1[idx][1] += sdir[1];
            tan1[idx][2] += sdir[2];
            tan2[idx][0] += tdir[0];
            tan2[idx][1] += tdir[1];
            tan2[idx][2] += tdir[2];
        }
    }

    for (vertices, 0..) |v, idx| {
        const n = normalize3(.{ v.nx, v.ny, v.nz });
        const t_raw = tan1[idx];
        const t_dot = dot3(n, t_raw);
        const ortho = [3]f32{
            t_raw[0] - n[0] * t_dot,
            t_raw[1] - n[1] * t_dot,
            t_raw[2] - n[2] * t_dot,
        };
        const ortho_len = @sqrt(dot3(ortho, ortho));
        const t_unit = if (ortho_len > 1e-5)
            [3]f32{ ortho[0] / ortho_len, ortho[1] / ortho_len, ortho[2] / ortho_len }
        else
            fallbackTangent(n);
        const handedness: f32 = if (dot3(cross3(n, t_unit), tan2[idx]) < 0.0) -1.0 else 1.0;
        tangents[idx] = .{ t_unit[0], t_unit[1], t_unit[2], handedness };
    }

    return tangents;
}

fn finalizeMesh(
    allocator: std.mem.Allocator,
    verts: *std.ArrayList(Vertex3D),
    inds: *std.ArrayList(u32),
) !ShapeMesh {
    const owned_verts = try verts.toOwnedSlice(allocator);
    errdefer allocator.free(owned_verts);
    const owned_inds = try inds.toOwnedSlice(allocator);
    errdefer allocator.free(owned_inds);

    const tangents = try computeTangents(allocator, owned_verts, owned_inds);
    const bounds = computeBounds(owned_verts);
    return .{
        .allocator = allocator,
        .vertices = owned_verts,
        .tangents = tangents,
        .indices = owned_inds,
        .bounds_center = bounds.center,
        .bounds_radius = bounds.radius,
    };
}

/// Procedural flat XZ plane centered at origin with `+Y` normal.
pub const Plane = struct {
    size: [2]f32 = .{ 1.0, 1.0 },
    subdivisions: [2]u32 = .{ 1, 1 },

    /// Builds the `Plane` mesh with UVs and tangents.
    pub fn mesh(self: Plane, allocator: std.mem.Allocator) !ShapeMesh {
        const sx = @max(@as(u32, 1), self.subdivisions[0]);
        const sz = @max(@as(u32, 1), self.subdivisions[1]);
        const hw = self.size[0] * 0.5;
        const hd = self.size[1] * 0.5;

        var verts = std.ArrayList(Vertex3D).empty;
        errdefer verts.deinit(allocator);
        var inds = std.ArrayList(u32).empty;
        errdefer inds.deinit(allocator);

        var iz: u32 = 0;
        while (iz <= sz) : (iz += 1) {
            const v = @as(f32, @floatFromInt(iz)) / @as(f32, @floatFromInt(sz));
            const z = -hd + v * self.size[1];
            var ix: u32 = 0;
            while (ix <= sx) : (ix += 1) {
                const u = @as(f32, @floatFromInt(ix)) / @as(f32, @floatFromInt(sx));
                const x = -hw + u * self.size[0];
                try verts.append(allocator, .{ .x = x, .y = 0.0, .z = z, .nx = 0.0, .ny = 1.0, .nz = 0.0, .u = u, .v = v });
            }
        }

        const stride = sx + 1;
        iz = 0;
        while (iz < sz) : (iz += 1) {
            var ix: u32 = 0;
            while (ix < sx) : (ix += 1) {
                const a = iz * stride + ix;
                const b = a + stride;
                const c = b + 1;
                const d = a + 1;
                try inds.appendSlice(allocator, &.{ a, b, c, a, c, d });
            }
        }

        return finalizeMesh(allocator, &verts, &inds);
    }
};

/// Procedural axis-aligned box centered at origin.
pub const Cuboid = struct {
    size: [3]f32 = .{ 1.0, 1.0, 1.0 },

    /// Builds a 24-vertex `Cuboid` mesh with crisp face normals, UVs, and tangents.
    pub fn mesh(self: Cuboid, allocator: std.mem.Allocator) !ShapeMesh {
        const hx = self.size[0] * 0.5;
        const hy = self.size[1] * 0.5;
        const hz = self.size[2] * 0.5;

        var verts = std.ArrayList(Vertex3D).empty;
        errdefer verts.deinit(allocator);
        var inds = std.ArrayList(u32).empty;
        errdefer inds.deinit(allocator);

        const faces = [6]struct { n: [3]f32, p: [4][3]f32 }{
            .{ .n = .{ 0, 0, 1 }, .p = .{ .{ -hx, -hy, hz }, .{ hx, -hy, hz }, .{ hx, hy, hz }, .{ -hx, hy, hz } } },
            .{ .n = .{ 0, 0, -1 }, .p = .{ .{ hx, -hy, -hz }, .{ -hx, -hy, -hz }, .{ -hx, hy, -hz }, .{ hx, hy, -hz } } },
            .{ .n = .{ 1, 0, 0 }, .p = .{ .{ hx, -hy, hz }, .{ hx, -hy, -hz }, .{ hx, hy, -hz }, .{ hx, hy, hz } } },
            .{ .n = .{ -1, 0, 0 }, .p = .{ .{ -hx, -hy, -hz }, .{ -hx, -hy, hz }, .{ -hx, hy, hz }, .{ -hx, hy, -hz } } },
            .{ .n = .{ 0, 1, 0 }, .p = .{ .{ -hx, hy, hz }, .{ hx, hy, hz }, .{ hx, hy, -hz }, .{ -hx, hy, -hz } } },
            .{ .n = .{ 0, -1, 0 }, .p = .{ .{ -hx, -hy, -hz }, .{ hx, -hy, -hz }, .{ hx, -hy, hz }, .{ -hx, -hy, hz } } },
        };
        const uvs = [4][2]f32{ .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 } };

        for (faces, 0..) |f, fi| {
            const base: u32 = @intCast(fi * 4);
            for (0..4) |vi| {
                try verts.append(allocator, .{
                    .x = f.p[vi][0],
                    .y = f.p[vi][1],
                    .z = f.p[vi][2],
                    .nx = f.n[0],
                    .ny = f.n[1],
                    .nz = f.n[2],
                    .u = uvs[vi][0],
                    .v = uvs[vi][1],
                });
            }
            try inds.appendSlice(allocator, &.{ base, base + 1, base + 2, base, base + 2, base + 3 });
        }

        return finalizeMesh(allocator, &verts, &inds);
    }
};

/// Procedural UV sphere centered at origin.
pub const Sphere = struct {
    radius: f32 = 0.5,
    rings: u32 = 16,
    sectors: u32 = 32,

    /// Builds the `Sphere` mesh with UVs and tangents.
    pub fn mesh(self: Sphere, allocator: std.mem.Allocator) !ShapeMesh {
        const rings = @max(@as(u32, 3), self.rings);
        const sectors = @max(@as(u32, 4), self.sectors);

        var verts = std.ArrayList(Vertex3D).empty;
        errdefer verts.deinit(allocator);
        var inds = std.ArrayList(u32).empty;
        errdefer inds.deinit(allocator);

        var r: u32 = 0;
        while (r <= rings) : (r += 1) {
            const v = @as(f32, @floatFromInt(r)) / @as(f32, @floatFromInt(rings));
            const phi = v * std.math.pi;
            const sp = @sin(phi);
            const cp = @cos(phi);

            var s: u32 = 0;
            while (s <= sectors) : (s += 1) {
                const u = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(sectors));
                const theta = u * 2.0 * std.math.pi;
                const nx = sp * @cos(theta);
                const ny = cp;
                const nz = sp * @sin(theta);
                try verts.append(allocator, .{
                    .x = nx * self.radius,
                    .y = ny * self.radius,
                    .z = nz * self.radius,
                    .nx = nx,
                    .ny = ny,
                    .nz = nz,
                    .u = u,
                    .v = v,
                });
            }
        }

        const stride = sectors + 1;
        r = 0;
        while (r < rings) : (r += 1) {
            var s: u32 = 0;
            while (s < sectors) : (s += 1) {
                const a = r * stride + s;
                const b = a + stride;
                const c = b + 1;
                const d = a + 1;
                if (r != 0) try inds.appendSlice(allocator, &.{ a, d, b });
                if (r != rings - 1) try inds.appendSlice(allocator, &.{ d, c, b });
            }
        }

        return finalizeMesh(allocator, &verts, &inds);
    }
};

/// Procedural Y-aligned capsule (cylinder body + two hemispherical caps).
pub const Capsule = struct {
    radius: f32 = 0.25,
    half_length: f32 = 0.5,
    rings: u32 = 8,
    sectors: u32 = 24,

    /// Builds the `Capsule` mesh with continuous normals, UVs, and tangents.
    pub fn mesh(self: Capsule, allocator: std.mem.Allocator) !ShapeMesh {
        const hemi_rings = @max(@as(u32, 2), self.rings);
        const sectors = @max(@as(u32, 4), self.sectors);
        const total_rings = hemi_rings * 2 + 1;

        var verts = std.ArrayList(Vertex3D).empty;
        errdefer verts.deinit(allocator);
        var inds = std.ArrayList(u32).empty;
        errdefer inds.deinit(allocator);

        var ring_idx: u32 = 0;
        while (ring_idx <= total_rings) : (ring_idx += 1) {
            const v = @as(f32, @floatFromInt(ring_idx)) / @as(f32, @floatFromInt(total_rings));
            var y_offset: f32 = 0.0;
            var phi: f32 = 0.0;
            if (ring_idx <= hemi_rings) {
                // Top hemisphere: phi in [0, pi/2]
                phi = (@as(f32, @floatFromInt(ring_idx)) / @as(f32, @floatFromInt(hemi_rings))) * (std.math.pi * 0.5);
                y_offset = self.half_length;
            } else {
                // Bottom hemisphere: phi in [pi/2, pi]
                const br = ring_idx - (hemi_rings + 1);
                phi = (std.math.pi * 0.5) + (@as(f32, @floatFromInt(br)) / @as(f32, @floatFromInt(hemi_rings))) * (std.math.pi * 0.5);
                y_offset = -self.half_length;
            }
            const sp = @sin(phi);
            const cp = @cos(phi);

            var s: u32 = 0;
            while (s <= sectors) : (s += 1) {
                const u = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(sectors));
                const theta = u * 2.0 * std.math.pi;
                const nx = sp * @cos(theta);
                const ny = cp;
                const nz = sp * @sin(theta);
                try verts.append(allocator, .{
                    .x = nx * self.radius,
                    .y = ny * self.radius + y_offset,
                    .z = nz * self.radius,
                    .nx = nx,
                    .ny = ny,
                    .nz = nz,
                    .u = u,
                    .v = v,
                });
            }
        }

        const stride = sectors + 1;
        ring_idx = 0;
        while (ring_idx < total_rings) : (ring_idx += 1) {
            var s: u32 = 0;
            while (s < sectors) : (s += 1) {
                const a = ring_idx * stride + s;
                const b = a + stride;
                const c = b + 1;
                const d = a + 1;
                if (ring_idx != 0) try inds.appendSlice(allocator, &.{ a, d, b });
                if (ring_idx != total_rings - 1) try inds.appendSlice(allocator, &.{ d, c, b });
            }
        }

        return finalizeMesh(allocator, &verts, &inds);
    }
};

/// Procedural Y-aligned cylinder centered at origin.
pub const Cylinder = struct {
    radius: f32 = 0.5,
    height: f32 = 1.0,
    radial_segments: u32 = 24,
    cap_top: bool = true,
    cap_bottom: bool = true,

    /// Builds the `Cylinder` mesh with UVs and tangents.
    pub fn mesh(self: Cylinder, allocator: std.mem.Allocator) !ShapeMesh {
        const segs = @max(@as(u32, 3), self.radial_segments);
        const hy = self.height * 0.5;

        var verts = std.ArrayList(Vertex3D).empty;
        errdefer verts.deinit(allocator);
        var inds = std.ArrayList(u32).empty;
        errdefer inds.deinit(allocator);

        // Side wall (2 rings: top and bottom)
        const side_base: u32 = 0;
        var s: u32 = 0;
        while (s <= segs) : (s += 1) {
            const u = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(segs));
            const theta = u * 2.0 * std.math.pi;
            const nx = @cos(theta);
            const nz = @sin(theta);
            try verts.append(allocator, .{ .x = nx * self.radius, .y = hy, .z = nz * self.radius, .nx = nx, .ny = 0, .nz = nz, .u = u, .v = 0 });
            try verts.append(allocator, .{ .x = nx * self.radius, .y = -hy, .z = nz * self.radius, .nx = nx, .ny = 0, .nz = nz, .u = u, .v = 1 });
        }
        s = 0;
        while (s < segs) : (s += 1) {
            const t0 = side_base + s * 2;
            const b0 = t0 + 1;
            const t1 = t0 + 2;
            const b1 = t0 + 3;
            try inds.appendSlice(allocator, &.{ t0, t1, b0, t1, b1, b0 });
        }

        if (self.cap_top) {
            const center_idx: u32 = @intCast(verts.items.len);
            try verts.append(allocator, .{ .x = 0, .y = hy, .z = 0, .nx = 0, .ny = 1, .nz = 0, .u = 0.5, .v = 0.5 });
            var i: u32 = 0;
            while (i <= segs) : (i += 1) {
                const theta = (@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segs))) * 2.0 * std.math.pi;
                const cx = @cos(theta);
                const cz = @sin(theta);
                try verts.append(allocator, .{ .x = cx * self.radius, .y = hy, .z = cz * self.radius, .nx = 0, .ny = 1, .nz = 0, .u = cx * 0.5 + 0.5, .v = cz * 0.5 + 0.5 });
            }
            i = 0;
            while (i < segs) : (i += 1) {
                try inds.appendSlice(allocator, &.{ center_idx, center_idx + 1 + i + 1, center_idx + 1 + i });
            }
        }

        if (self.cap_bottom) {
            const center_idx: u32 = @intCast(verts.items.len);
            try verts.append(allocator, .{ .x = 0, .y = -hy, .z = 0, .nx = 0, .ny = -1, .nz = 0, .u = 0.5, .v = 0.5 });
            var i: u32 = 0;
            while (i <= segs) : (i += 1) {
                const theta = (@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segs))) * 2.0 * std.math.pi;
                const cx = @cos(theta);
                const cz = @sin(theta);
                try verts.append(allocator, .{ .x = cx * self.radius, .y = -hy, .z = cz * self.radius, .nx = 0, .ny = -1, .nz = 0, .u = cx * 0.5 + 0.5, .v = cz * 0.5 + 0.5 });
            }
            i = 0;
            while (i < segs) : (i += 1) {
                try inds.appendSlice(allocator, &.{ center_idx, center_idx + 1 + i, center_idx + 1 + i + 1 });
            }
        }

        return finalizeMesh(allocator, &verts, &inds);
    }
};

/// Procedural torus lying in the XZ plane around the Y axis.
pub const Torus = struct {
    major_radius: f32 = 0.5,
    minor_radius: f32 = 0.2,
    major_segments: u32 = 32,
    minor_segments: u32 = 16,

    /// Builds the `Torus` mesh with UVs and tangents.
    pub fn mesh(self: Torus, allocator: std.mem.Allocator) !ShapeMesh {
        const maj = @max(@as(u32, 3), self.major_segments);
        const min_s = @max(@as(u32, 3), self.minor_segments);

        var verts = std.ArrayList(Vertex3D).empty;
        errdefer verts.deinit(allocator);
        var inds = std.ArrayList(u32).empty;
        errdefer inds.deinit(allocator);

        var i: u32 = 0;
        while (i <= maj) : (i += 1) {
            const u = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(maj));
            const theta = u * 2.0 * std.math.pi;
            const ct = @cos(theta);
            const st = @sin(theta);

            var j: u32 = 0;
            while (j <= min_s) : (j += 1) {
                const v = @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(min_s));
                const phi = v * 2.0 * std.math.pi;
                const cp = @cos(phi);
                const sp = @sin(phi);

                const r = self.major_radius + self.minor_radius * cp;
                const nx = ct * cp;
                const ny = sp;
                const nz = st * cp;
                try verts.append(allocator, .{
                    .x = r * ct,
                    .y = self.minor_radius * sp,
                    .z = r * st,
                    .nx = nx,
                    .ny = ny,
                    .nz = nz,
                    .u = u,
                    .v = v,
                });
            }
        }

        const stride = min_s + 1;
        i = 0;
        while (i < maj) : (i += 1) {
            var j: u32 = 0;
            while (j < min_s) : (j += 1) {
                const a = i * stride + j;
                const b = a + stride;
                const c = b + 1;
                const d = a + 1;
                try inds.appendSlice(allocator, &.{ a, d, b, d, c, b });
            }
        }

        return finalizeMesh(allocator, &verts, &inds);
    }
};

/// Procedural Y-aligned cone centered at origin (tip at `+height/2`).
pub const Cone = struct {
    radius: f32 = 0.5,
    height: f32 = 1.0,
    radial_segments: u32 = 24,
    cap_bottom: bool = true,

    /// Builds the `Cone` mesh with UVs and tangents.
    pub fn mesh(self: Cone, allocator: std.mem.Allocator) !ShapeMesh {
        const segs = @max(@as(u32, 3), self.radial_segments);
        const hy = self.height * 0.5;
        const slope_len = @sqrt(self.radius * self.radius + self.height * self.height);
        const ny_slope = if (slope_len > 1e-6) self.radius / slope_len else 0.0;
        const nr_slope = if (slope_len > 1e-6) self.height / slope_len else 1.0;

        var verts = std.ArrayList(Vertex3D).empty;
        errdefer verts.deinit(allocator);
        var inds = std.ArrayList(u32).empty;
        errdefer inds.deinit(allocator);

        var i: u32 = 0;
        while (i <= segs) : (i += 1) {
            const u = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segs));
            const theta = u * 2.0 * std.math.pi;
            const ct = @cos(theta);
            const st = @sin(theta);
            const n = normalize3(.{ ct * nr_slope, ny_slope, st * nr_slope });

            // Tip vertex per segment for smooth shading & clean UV interpolation
            try verts.append(allocator, .{ .x = 0, .y = hy, .z = 0, .nx = n[0], .ny = n[1], .nz = n[2], .u = u, .v = 0 });
            try verts.append(allocator, .{ .x = ct * self.radius, .y = -hy, .z = st * self.radius, .nx = n[0], .ny = n[1], .nz = n[2], .u = u, .v = 1 });
        }

        i = 0;
        while (i < segs) : (i += 1) {
            const t0 = i * 2;
            const b0 = t0 + 1;
            const b1 = t0 + 3;
            try inds.appendSlice(allocator, &.{ t0, b1, b0 });
        }

        if (self.cap_bottom) {
            const center_idx: u32 = @intCast(verts.items.len);
            try verts.append(allocator, .{ .x = 0, .y = -hy, .z = 0, .nx = 0, .ny = -1, .nz = 0, .u = 0.5, .v = 0.5 });
            i = 0;
            while (i <= segs) : (i += 1) {
                const theta = (@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segs))) * 2.0 * std.math.pi;
                const cx = @cos(theta);
                const cz = @sin(theta);
                try verts.append(allocator, .{ .x = cx * self.radius, .y = -hy, .z = cz * self.radius, .nx = 0, .ny = -1, .nz = 0, .u = cx * 0.5 + 0.5, .v = cz * 0.5 + 0.5 });
            }
            i = 0;
            while (i < segs) : (i += 1) {
                try inds.appendSlice(allocator, &.{ center_idx, center_idx + 1 + i, center_idx + 1 + i + 1 });
            }
        }

        return finalizeMesh(allocator, &verts, &inds);
    }
};

fn buildModule(_: *anyopaque) !void {}

fn stopModule(_: *anyopaque) void {}

/// Returns the `official.shapes` module descriptor.
pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = "official.shapes",
            .version = "0.1.0",
            .provides_capabilities = &.{"engine.shapes/1"},
            .required_capabilities = &.{},
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
