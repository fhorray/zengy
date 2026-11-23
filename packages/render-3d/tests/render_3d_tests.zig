//! 3D Renderer Foundation Tests (`packages/render-3d/tests/render_3d_tests.zig`).
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
