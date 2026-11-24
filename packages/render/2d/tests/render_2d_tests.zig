//! Unit Tests for `official.render.2d` (`packages/render/2d/tests/render_2d_tests.zig`).

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const window = @import("window");
const graphics = @import("graphics");
const scene = @import("scene");
const camera = @import("camera");
const render_2d = @import("render_2d");

test "render_2d extracts visible sprites, projects official.camera, and sorts by layer then texture" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(window.module());
    try app.registerModule(graphics.module());
    try app.registerModule(scene.module());
    try app.registerModule(camera.module());
    try app.registerModule(render_2d.module());
    try app.initialize();

    const frame = app.resources.get(render_2d.Render2DFrame).?;
    frame.setViewport(800.0, 600.0);

    const cam_e = try app.world.spawn();
    try app.world.set(cam_e, camera.Camera, .{});
    try app.world.set(cam_e, camera.CameraPose, .{ .position = .{ 100.0, 50.0, 0.0 } });
    try app.world.set(cam_e, camera.Projection, .{ .orthographic = .{ .scale = 0.5 } }); // zoom = 2.0

    // Entity 1: layer 2, texture 10
    const e1 = try app.world.spawn();
    try app.world.set(e1, scene.Transform2D, .{ .x = 100.0, .y = 50.0, .rotation_rad = 0.5 });
    try app.world.set(e1, render_2d.Sprite, .{ .width = 32, .height = 32, .layer = 2, .texture_id = 10 });

    // Entity 2: layer 0, texture 20
    const e2 = try app.world.spawn();
    try app.world.set(e2, scene.Transform2D, .{ .x = 150.0, .y = 50.0 });
    try app.world.set(e2, render_2d.Sprite, .{ .width = 16, .height = 16, .layer = 0, .texture_id = 20 });

    // Entity 3: hidden
    const e3 = try app.world.spawn();
    try app.world.set(e3, scene.Transform2D, .{ .x = 0.0, .y = 0.0 });
    try app.world.set(e3, render_2d.Sprite, .{ .width = 16, .height = 16, .layer = 0, .texture_id = 1 });
    try app.world.set(e3, render_2d.Visibility, .{ .visible = false });

    try app.tick(0.016);

    // Only 2 visible sprites extracted, sorted with layer 0 first.
    try testing.expectEqual(@as(usize, 2), frame.items.items.len);
    try testing.expectEqual(@as(i32, 0), frame.items.items[0].layer);
    try testing.expectEqual(@as(i32, 2), frame.items.items[1].layer);

    // Entity 1 is at camera center (100, 50) -> screen center (400, 300), size scaled by zoom 2.0 -> 64x64.
    const s1 = frame.items.items[1];
    try testing.expectEqual(@as(f32, 64.0), s1.screen_w);
    try testing.expectEqual(@as(f32, 400.0 - 32.0), s1.screen_x);
    try testing.expectEqual(@as(f32, 300.0 - 32.0), s1.screen_y);
}

test "render_2d extracts hierarchical LocalTransform2D / GlobalTransform2D sprites" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(window.module());
    try app.registerModule(graphics.module());
    try app.registerModule(scene.module());
    try app.registerModule(camera.module());
    try app.registerModule(render_2d.module());
    try app.initialize();

    const frame = app.resources.get(render_2d.Render2DFrame).?;
    frame.setViewport(800.0, 600.0);

    const cam_e = try app.world.spawn();
    try app.world.set(cam_e, camera.Camera, .{});
    try app.world.set(cam_e, camera.CameraPose, .{ .position = .{ 0.0, 0.0, 0.0 } });
    try app.world.set(cam_e, camera.Projection, .{ .orthographic = .{ .scale = 1.0 } });

    const parent = try app.world.spawn();
    try app.world.set(parent, scene.incremental.LocalTransform2D, .{ .x = 100.0, .y = 40.0 });
    try app.world.set(parent, scene.incremental.GlobalTransform2D, .{});

    const child = try app.world.spawn();
    try app.world.set(child, scene.incremental.LocalTransform2D, .{ .x = 25.0, .y = 10.0, .scale_x = 2.0, .scale_y = 2.0 });
    try app.world.set(child, scene.incremental.GlobalTransform2D, .{});
    try app.world.set(child, render_2d.Sprite, .{ .width = 10, .height = 10 });
    try scene.graph.reparent(&app.world, child, parent, .{});

    try app.tick(0.016);

    try testing.expectEqual(@as(usize, 1), frame.items.items.len);
    const sp = frame.items.items[0];
    try testing.expectApproxEqAbs(@as(f32, 20.0), sp.screen_w, 1e-3);
    // World (125, 50) -> screen center (400+125 - 10, 300+50 - 10) = (515, 340)
    try testing.expectApproxEqAbs(@as(f32, 515.0), sp.screen_x, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 340.0), sp.screen_y, 1e-3);
}
