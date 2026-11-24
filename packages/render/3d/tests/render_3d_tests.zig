//! 3D Renderer Foundation Tests (`packages/render/3d/tests/render_3d_tests.zig`).
//!
//! Validates Phase 13 `official.render.3d`: `.render_extract` mesh draw extraction
//! when an active `Camera3D` exists, and zero extraction when no camera is active.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const window = @import("window");
const graphics = @import("graphics");
const render_3d = @import("render_3d");

test "Render3DService extracts meshes during render_extract when camera is active" {
    var app = engine.App.init(testing.allocator, .{ .max_frames = 1 });
    defer app.deinit();

    try app.registerModule(window.module());
    try app.registerModule(graphics.module());
    try app.registerModule(render_3d.module());

    const cam = try app.world.spawn();
    try app.world.set(cam, render_3d.Camera3D, .{ .fov_deg = 75.0, .active = true });

    const mesh1 = try app.world.spawn();
    try app.world.set(mesh1, render_3d.Transform3D, .{ .position = .{ 1, 2, 3 } });
    try app.world.set(mesh1, render_3d.MeshRef, .{ .mesh_asset = 101, .material_id = 7 });

    const mesh2 = try app.world.spawn();
    try app.world.set(mesh2, render_3d.Transform3D, .{ .position = .{ -4, 0, 8 } });
    try app.world.set(mesh2, render_3d.MeshRef, .{ .mesh_asset = 202, .material_id = 9 });

    try app.initialize();
    try app.tick(1.0 / 60.0);

    const r3d = app.resources.get(render_3d.Render3DService).?;
    try testing.expectEqual(@as(usize, 1), r3d.active_cameras);
    try testing.expectEqual(@as(usize, 2), r3d.drawCount());

    app.shutdown();
}

test "Render3D frustum culling culls meshes behind Camera3D" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(window.module());
    try app.registerModule(graphics.module());
    try app.registerModule(render_3d.module());

    const cam = try app.world.spawn();
    try app.world.set(cam, render_3d.Camera3D, .{
        .position = .{ 0, 0, 5 },
        .target = .{ 0, 0, 0 },
        .active = true,
    });

    const visible_e = try app.world.spawn();
    try app.world.set(visible_e, render_3d.Transform3D, .{ .position = .{ 0, 0, 0 } });
    try app.world.set(visible_e, render_3d.MeshRef, .{ .mesh_asset = 1, .bounds_radius = 1.0 });

    const behind_e = try app.world.spawn();
    try app.world.set(behind_e, render_3d.Transform3D, .{ .position = .{ 0, 0, 20 } });
    try app.world.set(behind_e, render_3d.MeshRef, .{ .mesh_asset = 2, .bounds_radius = 1.0 });

    try app.initialize();
    try app.tick(1.0 / 60.0);

    const r3d = app.resources.get(render_3d.Render3DService).?;
    try testing.expectEqual(@as(usize, 1), r3d.drawCount());
    try testing.expectEqual(@as(usize, 1), r3d.culled_count);
}

test "gltf.loadGltfFromMemory parses embedded base64 glTF 2.0 triangle" {
    // 3 vertices (vec3 f32) = 36 bytes + 3 u16 indices = 6 bytes -> 42 bytes total.
    var raw: [42]u8 = @splat(0);
    const coords = [_]f32{ 0, 1, 0, -1, -1, 0, 1, -1, 0 };
    for (coords, 0..) |f, i| {
        std.mem.writeInt(u32, raw[i * 4 ..][0..4], @bitCast(f), .little);
    }
    std.mem.writeInt(u16, raw[36..38], 0, .little);
    std.mem.writeInt(u16, raw[38..40], 1, .little);
    std.mem.writeInt(u16, raw[40..42], 2, .little);

    var b64_buf: [128]u8 = undefined;
    const b64 = std.base64.standard.Encoder.encode(&b64_buf, &raw);

    const gltf_json = try std.fmt.allocPrint(testing.allocator,
        \\{{
        \\  "asset": {{ "version": "2.0" }},
        \\  "buffers": [{{ "uri": "data:application/octet-stream;base64,{s}", "byteLength": 42 }}],
        \\  "bufferViews": [
        \\    {{ "buffer": 0, "byteOffset": 0, "byteLength": 36 }},
        \\    {{ "buffer": 0, "byteOffset": 36, "byteLength": 6 }}
        \\  ],
        \\  "accessors": [
        \\    {{ "bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3" }},
        \\    {{ "bufferView": 1, "componentType": 5123, "count": 3, "type": "SCALAR" }}
        \\  ],
        \\  "meshes": [{{ "primitives": [{{ "attributes": {{ "POSITION": 0 }}, "indices": 1 }}] }}]
        \\}}
    , .{b64});
    defer testing.allocator.free(gltf_json);

    var mesh = try render_3d.gltf.loadGltfFromMemory(testing.allocator, gltf_json, null);
    defer mesh.deinit();

    try testing.expectEqual(@as(usize, 3), mesh.vertices.len);
    try testing.expectEqual(@as(usize, 3), mesh.indices.len);
    try testing.expectEqual(@as(f32, 1.0), mesh.vertices[0].y);
    try testing.expect(mesh.bounds_radius > 1.0);
}
