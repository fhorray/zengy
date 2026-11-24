//! Headless Camera & Projection example (`zig build run-camera`).
//!
//! Demonstrates `official.camera`:
//! - Multiple ordered cameras (`order = 0` main perspective, `order = 10` offscreen ortho minimap)
//! - `RenderLayers` visibility filtering
//! - `Frustum` sphere culling
//! - `worldToViewport` projection and `viewportToWorld` ray picking

const std = @import("std");
const engine = @import("engine");
const camera = @import("camera");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    var app = engine.App.init(gpa.allocator(), .{ .max_frames = 1 });
    defer app.deinit();

    try app.registerModule(camera.module());

    const main_cam = try app.world.spawn();
    try app.world.set(main_cam, camera.Camera, .{
        .order = 0,
        .clear_color = .{ .custom = .{ .r = 0.08, .g = 0.09, .b = 0.12, .a = 1.0 } },
    });
    try app.world.set(main_cam, camera.Projection, .{ .perspective = .{ .fov_rad = std.math.pi / 3.0 } });
    try app.world.set(main_cam, camera.CameraPose, camera.CameraPose.lookAt(.{ 0, 2, 6 }, .{ 0, 0, 0 }, .{ 0, 1, 0 }));
    try app.world.set(main_cam, camera.RenderLayers, camera.RenderLayers.layer(0));

    const minimap_cam = try app.world.spawn();
    try app.world.set(minimap_cam, camera.Camera, .{
        .order = 10,
        .target = .{ .image = 1 },
        .clear_color = .none,
        .viewport = .{ .physical_position = .{ 960, 20 }, .physical_size = .{ 300, 300 } },
    });
    try app.world.set(minimap_cam, camera.Projection, .{ .orthographic = .{ .scaling_mode = .{ .fixed_vertical = 20.0 } } });
    try app.world.set(minimap_cam, camera.CameraPose, camera.CameraPose.lookAt(.{ 0, 25, 0 }, .{ 0, 0, 0 }, .{ 0, 0, -1 }));
    try app.world.set(minimap_cam, camera.RenderLayers, camera.RenderLayers.layer(0).with(1));

    try app.initialize();
    try app.tick(1.0 / 60.0);

    const svc = app.resources.get(camera.CameraService).?;
    const sorted = svc.sortedActiveCameras();
    std.debug.print("[camera] active cameras (sorted by order): {d}\n", .{sorted.len});
    for (sorted, 0..) |entry, i| {
        std.debug.print("  #{d}: entity={d} order={d} target={s} viewport={d:.0}x{d:.0}\n", .{
            i,
            entry.entity.index,
            entry.order,
            @tagName(entry.target),
            entry.computed.viewport_size[0],
            entry.computed.viewport_size[1],
        });
    }

    if (app.world.get(main_cam, camera.Camera)) |cam| {
        const origin_vis = cam.computed.frustum.containsSphere(.{ 0, 0, 0 }, 0.5);
        const behind_vis = cam.computed.frustum.containsSphere(.{ 0, 0, 40 }, 0.5);
        std.debug.print("[camera] frustum contains origin={any}, behind={any}\n", .{ origin_vis, behind_vis });

        if (cam.worldToViewport(.{ 0, 0, 0 })) |vp| {
            std.debug.print("[camera] world(0,0,0) -> viewport({d:.1}, {d:.1})\n", .{ vp[0], vp[1] });
            if (cam.viewportToWorld(vp)) |ray| {
                std.debug.print("[camera] viewportToWorld ray origin=({d:.2},{d:.2},{d:.2}) dir=({d:.2},{d:.2},{d:.2})\n", .{
                    ray.origin[0],    ray.origin[1],    ray.origin[2],
                    ray.direction[0], ray.direction[1], ray.direction[2],
                });
            }
        }
    }

    app.shutdown();
}
