//! Unit Tests for `official.render.2d` (`packages/render-2d/tests/render_2d_tests.zig`).

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const window = @import("window");
const graphics = @import("graphics");
const scene = @import("scene");
const render_2d = @import("render_2d");

test "render_2d extracts visible sprites, projects Camera2D, and sorts by layer then texture" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(window.module());
    try app.registerModule(graphics.module());
    try app.registerModule(scene.module());
    try app.registerModule(render_2d.module());
    try app.initialize();

    const frame = app.resources.get(render_2d.Render2DFrame).?;
    frame.setViewport(800.0, 600.0);

    const cam_e = try app.world.spawn();
    try app.world.set(cam_e, render_2d.Camera2D, .{ .x = 100.0, .y = 50.0, .zoom = 2.0, .active = true });

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
