const std = @import("std");
const engine = @import("engine");
const scene = @import("scene");
const camera = @import("camera");

test "RenderLayers bitmask operations" {
    const l0 = camera.RenderLayers.layer(0);
    const l2 = camera.RenderLayers.layer(2);
    try std.testing.expect(!l0.intersects(l2));

    const combined = l0.with(2);
    try std.testing.expect(combined.intersects(l0));
    try std.testing.expect(combined.intersects(l2));
    try std.testing.expect(!combined.without(2).intersects(l2));
    try std.testing.expect(camera.RenderLayers.all().intersects(camera.RenderLayers.layer(31)));
}

test "OrthographicProjection scaling modes update bounds" {
    var ortho = camera.OrthographicProjection{
        .scaling_mode = .{ .fixed_vertical = 10.0 },
    };
    ortho.update(1600.0, 800.0);
    try std.testing.expectApproxEqAbs(@as(f32, -10.0), ortho.area_min[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), ortho.area_max[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, -5.0), ortho.area_min[1], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), ortho.area_max[1], 1e-4);
}

test "CameraService headless update sorts active cameras, builds frustum, and supports ray picking" {
    var app = engine.App.init(std.testing.allocator, .{ .max_frames = 1 });
    defer app.deinit();

    try app.registerModule(camera.module());

    const main_cam = try app.world.spawn();
    try app.world.set(main_cam, camera.Camera, .{ .order = 0 });
    try app.world.set(main_cam, camera.Projection, .{ .perspective = .{} });
    try app.world.set(main_cam, camera.CameraPose, camera.CameraPose.lookAt(.{ 0, 0, 5 }, .{ 0, 0, 0 }, .{ 0, 1, 0 }));

    const overlay_cam = try app.world.spawn();
    try app.world.set(overlay_cam, camera.Camera, .{
        .order = 10,
        .target = .{ .image = 42 },
        .clear_color = .none,
        .viewport = .{ .physical_position = .{ 0, 0 }, .physical_size = .{ 640, 360 } },
    });
    try app.world.set(overlay_cam, camera.Projection, .{ .orthographic = .{} });

    const disabled_cam = try app.world.spawn();
    try app.world.set(disabled_cam, camera.Camera, .{ .is_active = false, .order = -5 });

    try app.initialize();
    try app.tick(1.0 / 60.0);

    const svc = app.resources.get(camera.CameraService).?;
    const sorted = svc.sortedActiveCameras();
    try std.testing.expectEqual(@as(usize, 2), sorted.len);
    try std.testing.expectEqual(main_cam.index, sorted[0].entity.index);
    try std.testing.expectEqual(overlay_cam.index, sorted[1].entity.index);

    const cam_comp = app.world.get(main_cam, camera.Camera).?;
    try std.testing.expect(cam_comp.computed.frustum.containsSphere(.{ 0, 0, 0 }, 0.5));
    try std.testing.expect(!cam_comp.computed.frustum.containsSphere(.{ 0, 0, 50 }, 0.5));

    // World origin projects to center of 1280x720 viewport and unprojects back toward -Z.
    const vp = cam_comp.worldToViewport(.{ 0, 0, 0 }).?;
    try std.testing.expectApproxEqAbs(@as(f32, 640.0), vp[0], 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 360.0), vp[1], 0.5);

    const ray = cam_comp.viewportToWorld(vp).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), ray.direction[0], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), ray.direction[1], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), ray.direction[2], 1e-3);

    app.shutdown();
}

test "Camera follows GlobalTransform3D hierarchy when attached to a parented entity" {
    var app = engine.App.init(std.testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(scene.module());
    try app.registerModule(camera.module());
    try app.initialize();

    const rig = try app.world.spawn();
    try app.world.set(rig, scene.incremental.LocalTransform3D, .{ .translation = .{ 0, 0, 10 } });
    try app.world.set(rig, scene.incremental.GlobalTransform3D, .{});

    const cam_e = try app.world.spawn();
    try app.world.set(cam_e, camera.Camera, .{});
    try app.world.set(cam_e, camera.Projection, .{ .perspective = .{} });
    try app.world.set(cam_e, scene.incremental.LocalTransform3D, .{ .translation = .{ 0, 0, 5 } });
    try app.world.set(cam_e, scene.incremental.GlobalTransform3D, .{});
    try scene.graph.reparent(&app.world, cam_e, rig, .{});

    try app.tick(1.0 / 60.0);

    const cam_comp = app.world.get(cam_e, camera.Camera).?;
    // World-from-view should be at z = 15 (10 + 5).
    try std.testing.expectApproxEqAbs(@as(f32, 15.0), cam_comp.computed.world_from_view[14], 1e-4);
    try std.testing.expect(cam_comp.computed.frustum.containsSphere(.{ 0, 0, 0 }, 0.5));

    app.shutdown();
}
