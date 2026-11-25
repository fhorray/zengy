//! Portable JSON codec for `SceneSnapshot3D`.
//!
//! Format version 1 stores persistent entity GUIDs, local TRS and optional parent GUIDs.
//! Runtime handles and GPU resources are never encoded.

const std = @import("std");
const engine = @import("engine");
const scene = @import("scene.zig");
const incremental = @import("incremental.zig");

pub const FORMAT_VERSION: u32 = 1;

/// Serializes `snap` to a UTF-8 JSON document owned by `allocator`.
pub fn encodeSnapshot3D(allocator: std.mem.Allocator, snap: *const scene.SceneSnapshot3D) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.print(allocator, "{{\"format_version\":{d},\"entities\":[", .{FORMAT_VERSION});
    for (snap.records.items, 0..) |rec, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.print(allocator, "{{\"guid\":\"{d}\",\"parent\":", .{rec.guid});
        if (rec.parent_guid) |p| {
            try buf.print(allocator, "\"{d}\"", .{p});
        } else {
            try buf.appendSlice(allocator, "null");
        }
        try buf.print(
            allocator,
            ",\"local\":{{\"translation\":[{d:.9},{d:.9},{d:.9}],\"rotation\":[{d:.9},{d:.9},{d:.9},{d:.9}],\"scale\":[{d:.9},{d:.9},{d:.9}]}}}}",
            .{
                rec.local.translation[0], rec.local.translation[1], rec.local.translation[2],
                rec.local.rotation[0],     rec.local.rotation[1],     rec.local.rotation[2],     rec.local.rotation[3],
                rec.local.scale[0],        rec.local.scale[1],        rec.local.scale[2],
            },
        );
    }
    try buf.appendSlice(allocator, "]}");
    return try buf.toOwnedSlice(allocator);
}

fn parseGuid(s: []const u8) !engine.EntityGuid {
    return std.fmt.parseInt(engine.EntityGuid, s, 10);
}

fn expectArray3(v: std.json.Value) ![3]f32 {
    if (v != .array or v.array.items.len != 3) return error.InvalidSceneJson;
    return .{
        try jsonF32(v.array.items[0]),
        try jsonF32(v.array.items[1]),
        try jsonF32(v.array.items[2]),
    };
}

fn expectArray4(v: std.json.Value) ![4]f32 {
    if (v != .array or v.array.items.len != 4) return error.InvalidSceneJson;
    return .{
        try jsonF32(v.array.items[0]),
        try jsonF32(v.array.items[1]),
        try jsonF32(v.array.items[2]),
        try jsonF32(v.array.items[3]),
    };
}

fn jsonF32(v: std.json.Value) !f32 {
    const f: f32 = switch (v) {
        .float => |x| @floatCast(x),
        .integer => |i| @floatFromInt(i),
        else => return error.InvalidSceneJson,
    };
    if (!std.math.isFinite(f)) return error.InvalidSceneJson;
    return f;
}

/// Parses a versioned JSON scene into a `SceneSnapshot3D`. Rejects unknown format versions.
pub fn decodeSnapshot3D(allocator: std.mem.Allocator, source: []const u8) !scene.SceneSnapshot3D {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, source, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidSceneJson;
    const version_v = root.object.get("format_version") orelse return error.InvalidSceneJson;
    const version: u32 = switch (version_v) {
        .integer => |i| if (i < 0 or i > std.math.maxInt(u32)) return error.InvalidSceneJson else @intCast(i),
        else => return error.InvalidSceneJson,
    };
    if (version != FORMAT_VERSION) return error.UnsupportedSceneVersion;

    const entities_v = root.object.get("entities") orelse return error.InvalidSceneJson;
    if (entities_v != .array) return error.InvalidSceneJson;

    var snap = scene.SceneSnapshot3D.init(allocator);
    errdefer snap.deinit();
    var seen = std.AutoHashMapUnmanaged(engine.EntityGuid, void).empty;
    defer seen.deinit(allocator);

    for (entities_v.array.items) |ent_v| {
        if (ent_v != .object) return error.InvalidSceneJson;
        const guid_v = ent_v.object.get("guid") orelse return error.InvalidSceneJson;
        if (guid_v != .string) return error.InvalidSceneJson;
        const guid = try parseGuid(guid_v.string);
        if (guid != 0) {
            const gop = try seen.getOrPut(allocator, guid);
            if (gop.found_existing) return error.DuplicateEntityGuid;
        }

        var parent_guid: ?engine.EntityGuid = null;
        if (ent_v.object.get("parent")) |p| {
            parent_guid = switch (p) {
                .null => null,
                .string => |s| try parseGuid(s),
                else => return error.InvalidSceneJson,
            };
        }

        const local_v = ent_v.object.get("local") orelse return error.InvalidSceneJson;
        if (local_v != .object) return error.InvalidSceneJson;
        const translation = try expectArray3(local_v.object.get("translation") orelse return error.InvalidSceneJson);
        const rotation = try expectArray4(local_v.object.get("rotation") orelse return error.InvalidSceneJson);
        const scale = try expectArray3(local_v.object.get("scale") orelse return error.InvalidSceneJson);

        try snap.records.append(allocator, .{
            .guid = guid,
            .parent_guid = parent_guid,
            .local = .{
                .translation = translation,
                .rotation = rotation,
                .scale = scale,
            },
        });
    }
    return snap;
}

/// Loads a scene file from disk into `world` (fresh restore). Returns entity count.
pub fn loadSnapshot3DFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8, world: *engine.World) !usize {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(bytes);
    var snap = try decodeSnapshot3D(allocator, bytes);
    defer snap.deinit();
    return snap.restore(world);
}

test "SceneSnapshot3D JSON round trip" {
    const testing = std.testing;
    var world = engine.World.init(testing.allocator, .{ .index = 0, .generation = 1 });
    defer world.deinit();
    try world.setGuidNamespace(0x42);
    const a = try world.spawn();
    const b = try world.spawn();
    try world.set(a, incremental.LocalTransform3D, .{ .translation = .{ 1, 2, 3 }, .scale = .{ 1, 1, 1 } });
    try world.set(a, incremental.GlobalTransform3D, .{});
    try world.set(b, incremental.LocalTransform3D, .{ .translation = .{ 0, 4, 0 }, .scale = .{ 2, 2, 2 } });
    try world.set(b, incremental.GlobalTransform3D, .{});
    try world.set(b, scene.Parent, .{ .entity = a });
    try scene.graph.rebuildLinks(&world);

    var snap = try scene.SceneSnapshot3D.capture(testing.allocator, &world);
    defer snap.deinit();
    const json = try encodeSnapshot3D(testing.allocator, &snap);
    defer testing.allocator.free(json);

    var decoded = try decodeSnapshot3D(testing.allocator, json);
    defer decoded.deinit();
    try testing.expectEqual(@as(usize, 2), decoded.records.items.len);

    var dst = engine.World.init(testing.allocator, .{ .index = 1, .generation = 1 });
    defer dst.deinit();
    _ = try decoded.restore(&dst);
    const ga = world.getGuid(a).?;
    const restored = dst.findByGuid(ga).?;
    try testing.expectEqual(@as(f32, 1), dst.getConst(restored, incremental.LocalTransform3D).?.translation[0]);
}
