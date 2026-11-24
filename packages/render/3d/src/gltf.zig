//! Minimal glTF 2.0 Mesh Importer & Procedural 3D Primitives (`packages/render/3d/src/gltf.zig`).
//!
//! Parses glTF 2.0 JSON (`meshes`, `primitives`, `accessors`, `bufferViews`, `buffers`)
//! supporting embedded `data:...;base64,` URIs and external `.bin` buffers, and computes
//! bounding spheres for frustum culling.

const std = @import("std");

pub const Vertex3D = extern struct {
    x: f32,
    y: f32,
    z: f32,
    nx: f32,
    ny: f32,
    nz: f32,
    u: f32,
    v: f32,
};

pub const MeshData = struct {
    allocator: std.mem.Allocator,
    vertices: []Vertex3D,
    indices: []u32,
    bounds_center: [3]f32,
    bounds_radius: f32,

    pub fn deinit(self: *MeshData) void {
        self.allocator.free(self.vertices);
        self.allocator.free(self.indices);
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

fn readF32(bytes: []const u8, offset: usize) f32 {
    const bits = std.mem.readInt(u32, bytes[offset..][0..4], .little);
    return @bitCast(bits);
}

fn decodeBase64DataUri(allocator: std.mem.Allocator, uri: []const u8) ![]u8 {
    const marker = ";base64,";
    const pos = std.mem.indexOf(u8, uri, marker) orelse return error.UnsupportedBufferUri;
    const b64 = uri[pos + marker.len ..];
    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(b64);
    const buf = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(buf);
    try std.base64.standard.Decoder.decode(buf, b64);
    return buf;
}

/// Loads the first mesh primitive from a glTF 2.0 JSON document.
/// If `external_bin` is null, buffer 0 must be an embedded `;base64,` data URI.
pub fn loadGltfFromMemory(
    allocator: std.mem.Allocator,
    gltf_json: []const u8,
    external_bin: ?[]const u8,
) !MeshData {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, gltf_json, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const buffers_arr = (root.get("buffers") orelse return error.InvalidGltf).array;
    if (buffers_arr.items.len == 0) return error.InvalidGltf;

    var owned_bin: ?[]u8 = null;
    defer if (owned_bin) |b| allocator.free(b);

    const bin_bytes: []const u8 = if (external_bin) |ext|
        ext
    else blk: {
        const buf_obj = buffers_arr.items[0].object;
        const uri_val = buf_obj.get("uri") orelse return error.MissingGltfBufferUri;
        owned_bin = try decodeBase64DataUri(allocator, uri_val.string);
        break :blk owned_bin.?;
    };

    const buffer_views = (root.get("bufferViews") orelse return error.InvalidGltf).array;
    const accessors = (root.get("accessors") orelse return error.InvalidGltf).array;
    const meshes = (root.get("meshes") orelse return error.InvalidGltf).array;
    if (meshes.items.len == 0) return error.InvalidGltf;

    const primitives = (meshes.items[0].object.get("primitives") orelse return error.InvalidGltf).array;
    if (primitives.items.len == 0) return error.InvalidGltf;
    const prim = primitives.items[0].object;
    const attrs = (prim.get("attributes") orelse return error.InvalidGltf).object;

    const pos_acc_idx: usize = @intCast((attrs.get("POSITION") orelse return error.MissingPositionAttribute).integer);
    const pos_acc = accessors.items[pos_acc_idx].object;
    const vert_count: usize = @intCast(pos_acc.get("count").?.integer);
    const pos_bv = buffer_views.items[@intCast(pos_acc.get("bufferView").?.integer)].object;
    const pos_off: usize = @intCast((pos_bv.get("byteOffset") orelse std.json.Value{ .integer = 0 }).integer +
        (pos_acc.get("byteOffset") orelse std.json.Value{ .integer = 0 }).integer);
    const pos_stride: usize = if (pos_bv.get("byteStride")) |s| @intCast(s.integer) else 12;

    const norm_acc_opt: ?std.json.ObjectMap = if (attrs.get("NORMAL")) |nv| accessors.items[@intCast(nv.integer)].object else null;
    const uv_acc_opt: ?std.json.ObjectMap = if (attrs.get("TEXCOORD_0")) |tv| accessors.items[@intCast(tv.integer)].object else null;

    const vertices = try allocator.alloc(Vertex3D, vert_count);
    errdefer allocator.free(vertices);

    for (0..vert_count) |vi| {
        const p_base = pos_off + vi * pos_stride;
        var v = Vertex3D{
            .x = readF32(bin_bytes, p_base + 0),
            .y = readF32(bin_bytes, p_base + 4),
            .z = readF32(bin_bytes, p_base + 8),
            .nx = 0,
            .ny = 1,
            .nz = 0,
            .u = 0,
            .v = 0,
        };
        if (norm_acc_opt) |na| {
            const bv = buffer_views.items[@intCast(na.get("bufferView").?.integer)].object;
            const off: usize = @intCast((bv.get("byteOffset") orelse std.json.Value{ .integer = 0 }).integer +
                (na.get("byteOffset") orelse std.json.Value{ .integer = 0 }).integer);
            const stride: usize = if (bv.get("byteStride")) |s| @intCast(s.integer) else 12;
            const base = off + vi * stride;
            v.nx = readF32(bin_bytes, base + 0);
            v.ny = readF32(bin_bytes, base + 4);
            v.nz = readF32(bin_bytes, base + 8);
        }
        if (uv_acc_opt) |ta| {
            const bv = buffer_views.items[@intCast(ta.get("bufferView").?.integer)].object;
            const off: usize = @intCast((bv.get("byteOffset") orelse std.json.Value{ .integer = 0 }).integer +
                (ta.get("byteOffset") orelse std.json.Value{ .integer = 0 }).integer);
            const stride: usize = if (bv.get("byteStride")) |s| @intCast(s.integer) else 8;
            const base = off + vi * stride;
            v.u = readF32(bin_bytes, base + 0);
            v.v = readF32(bin_bytes, base + 4);
        }
        vertices[vi] = v;
    }

    var indices: []u32 = undefined;
    if (prim.get("indices")) |idx_val| {
        const idx_acc = accessors.items[@intCast(idx_val.integer)].object;
        const idx_count: usize = @intCast(idx_acc.get("count").?.integer);
        const comp_type: i64 = idx_acc.get("componentType").?.integer;
        const idx_bv = buffer_views.items[@intCast(idx_acc.get("bufferView").?.integer)].object;
        const idx_off: usize = @intCast((idx_bv.get("byteOffset") orelse std.json.Value{ .integer = 0 }).integer +
            (idx_acc.get("byteOffset") orelse std.json.Value{ .integer = 0 }).integer);

        indices = try allocator.alloc(u32, idx_count);
        for (0..idx_count) |ii| {
            indices[ii] = switch (comp_type) {
                5123 => std.mem.readInt(u16, bin_bytes[idx_off + ii * 2 ..][0..2], .little), // UNSIGNED_SHORT
                5125 => std.mem.readInt(u32, bin_bytes[idx_off + ii * 4 ..][0..4], .little), // UNSIGNED_INT
                5121 => bin_bytes[idx_off + ii], // UNSIGNED_BYTE
                else => return error.UnsupportedIndexType,
            };
        }
    } else {
        indices = try allocator.alloc(u32, vert_count);
        for (0..vert_count) |ii| indices[ii] = @intCast(ii);
    }

    const bounds = computeBounds(vertices);
    return .{
        .allocator = allocator,
        .vertices = vertices,
        .indices = indices,
        .bounds_center = bounds.center,
        .bounds_radius = bounds.radius,
    };
}

/// Generates a unit cube mesh centered at the origin with half-extent `h`.
pub fn createCubeMesh(allocator: std.mem.Allocator, h: f32) !MeshData {
    const verts = try allocator.dupe(Vertex3D, &.{
        // Front (+Z)
        .{ .x = -h, .y = -h, .z = h, .nx = 0, .ny = 0, .nz = 1, .u = 0, .v = 1 },
        .{ .x = h, .y = -h, .z = h, .nx = 0, .ny = 0, .nz = 1, .u = 1, .v = 1 },
        .{ .x = h, .y = h, .z = h, .nx = 0, .ny = 0, .nz = 1, .u = 1, .v = 0 },
        .{ .x = -h, .y = h, .z = h, .nx = 0, .ny = 0, .nz = 1, .u = 0, .v = 0 },
        // Back (-Z)
        .{ .x = h, .y = -h, .z = -h, .nx = 0, .ny = 0, .nz = -1, .u = 0, .v = 1 },
        .{ .x = -h, .y = -h, .z = -h, .nx = 0, .ny = 0, .nz = -1, .u = 1, .v = 1 },
        .{ .x = -h, .y = h, .z = -h, .nx = 0, .ny = 0, .nz = -1, .u = 1, .v = 0 },
        .{ .x = h, .y = h, .z = -h, .nx = 0, .ny = 0, .nz = -1, .u = 0, .v = 0 },
        // Top (+Y)
        .{ .x = -h, .y = h, .z = h, .nx = 0, .ny = 1, .nz = 0, .u = 0, .v = 1 },
        .{ .x = h, .y = h, .z = h, .nx = 0, .ny = 1, .nz = 0, .u = 1, .v = 1 },
        .{ .x = h, .y = h, .z = -h, .nx = 0, .ny = 1, .nz = 0, .u = 1, .v = 0 },
        .{ .x = -h, .y = h, .z = -h, .nx = 0, .ny = 1, .nz = 0, .u = 0, .v = 0 },
        // Bottom (-Y)
        .{ .x = -h, .y = -h, .z = -h, .nx = 0, .ny = -1, .nz = 0, .u = 0, .v = 1 },
        .{ .x = h, .y = -h, .z = -h, .nx = 0, .ny = -1, .nz = 0, .u = 1, .v = 1 },
        .{ .x = h, .y = -h, .z = h, .nx = 0, .ny = -1, .nz = 0, .u = 1, .v = 0 },
        .{ .x = -h, .y = -h, .z = h, .nx = 0, .ny = -1, .nz = 0, .u = 0, .v = 0 },
        // Right (+X)
        .{ .x = h, .y = -h, .z = h, .nx = 1, .ny = 0, .nz = 0, .u = 0, .v = 1 },
        .{ .x = h, .y = -h, .z = -h, .nx = 1, .ny = 0, .nz = 0, .u = 1, .v = 1 },
        .{ .x = h, .y = h, .z = -h, .nx = 1, .ny = 0, .nz = 0, .u = 1, .v = 0 },
        .{ .x = h, .y = h, .z = h, .nx = 1, .ny = 0, .nz = 0, .u = 0, .v = 0 },
        // Left (-X)
        .{ .x = -h, .y = -h, .z = -h, .nx = -1, .ny = 0, .nz = 0, .u = 0, .v = 1 },
        .{ .x = -h, .y = -h, .z = h, .nx = -1, .ny = 0, .nz = 0, .u = 1, .v = 1 },
        .{ .x = -h, .y = h, .z = h, .nx = -1, .ny = 0, .nz = 0, .u = 1, .v = 0 },
        .{ .x = -h, .y = h, .z = -h, .nx = -1, .ny = 0, .nz = 0, .u = 0, .v = 0 },
    });
    errdefer allocator.free(verts);

    const inds = try allocator.dupe(u32, &.{
        0,  1,  2,  0,  2,  3,
        4,  5,  6,  4,  6,  7,
        8,  9,  10, 8,  10, 11,
        12, 13, 14, 12, 14, 15,
        16, 17, 18, 16, 18, 19,
        20, 21, 22, 20, 22, 23,
    });
    const bounds = computeBounds(verts);
    return .{
        .allocator = allocator,
        .vertices = verts,
        .indices = inds,
        .bounds_center = bounds.center,
        .bounds_radius = bounds.radius,
    };
}
