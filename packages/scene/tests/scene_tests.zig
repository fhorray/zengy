//! 2D Scene & Transform Graph Tests (`packages/scene/tests/scene_tests.zig`).
//!
//! Validates Phase 11 `official.scene`: parent-child `Transform2D` propagation
//! during `.post_update` and headless `SceneSnapshot` capture/restore across Worlds.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const scene = @import("scene");

test "Transform2D parent-child propagation and SceneSnapshot restore" {
    var app = engine.App.init(testing.allocator, .{ .max_frames = 1 });
    defer app.deinit();

    try app.registerModule(scene.module());

    const parent = try app.world.spawn();
    try app.world.set(parent, scene.Transform2D, .{ .x = 100, .y = 50 });

    const child = try app.world.spawn();
    try app.world.set(child, scene.Transform2D, .{ .x = 25, .y = -10 });
    try app.world.set(child, scene.Parent, .{ .entity = parent });

    try app.run();

    const ct = app.world.getConst(child, scene.Transform2D).?;
    try testing.expectApproxEqAbs(@as(f32, 125.0), ct.world_x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 40.0), ct.world_y, 0.001);

    // Capture and restore into an independent World without editor dependencies.
    var snap = try scene.SceneSnapshot.capture(testing.allocator, &app.world);
    defer snap.deinit();
    try testing.expectEqual(@as(usize, 2), snap.records.items.len);

    var restored_world = engine.World.init(testing.allocator, .{ .index = 1, .generation = 1 });
    defer restored_world.deinit();
    const count = try snap.restore(&restored_world);
    try testing.expectEqual(@as(usize, 2), count);
}
