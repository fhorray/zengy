const std = @import("std");
const engine = @import("engine");
const camera = @import("camera");
const gizmos = @import("gizmos");

test {
    std.testing.refAllDecls(gizmos.manipulator);
}

const MockState = struct {
    submits: usize = 0,
    depth_count: usize = 0,
    xray_count: usize = 0,
    line_width: f32 = 0,
};

fn mockSubmit(
    raw: *anyopaque,
    params: gizmos.GizmoSubmitParams,
    depth_lines: []const gizmos.GizmoVertex,
    xray_lines: []const gizmos.GizmoVertex,
    _: []const gizmos.GizmoVertex,
) anyerror!void {
    const st: *MockState = @ptrCast(@alignCast(raw));
    st.submits += 1;
    st.depth_count = depth_lines.len;
    st.xray_count = xray_lines.len;
    st.line_width = params.line_width;
}

test "gizmos primitives emit expected vertex counts and clear per frame" {
    const allocator = std.testing.allocator;
    var app = engine.App.init(allocator, .{});
    defer app.deinit();

    try app.registerModule(camera.module());
    try app.registerModule(gizmos.module());
    try app.initialize();
    app.scheduler.render_extract_enabled = true;

    const cam_e = try app.world.spawn();
    try app.world.set(cam_e, camera.Camera, .{ .order = 0 });
    try app.world.set(cam_e, camera.Projection, .{ .perspective = .{ .fov_rad = 1.0, .near = 0.1, .far = 100.0 } });
    try app.world.set(cam_e, camera.CameraPose, camera.CameraPose.lookAt(.{ 0, 2, 5 }, .{ 0, 0, 0 }, .{ 0, 1, 0 }));

    var mock: MockState = .{};
    const svc = app.resources.get(gizmos.GizmoService).?;
    svc.config.line.width = 3.5;
    svc.setBackend(.{ .ctx = &mock, .submitGizmos = mockSubmit });

    svc.line(.{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 1, 1, 1, 1 });
    svc.cuboid(.{ 0, 0, 0 }, .{ 2, 2, 2 }, .{ 0, 1, 0, 1 });
    svc.lineXray(.{ 0, 0, 0 }, .{ 0, 3, 0 }, .{ 1, 0, 0, 1 });

    // line = 2 verts, cuboid = 24 verts -> 26 depth verts; lineXray = 2 xray verts.
    try app.tick(0.016);
    try std.testing.expectEqual(@as(usize, 1), mock.submits);
    try std.testing.expectEqual(@as(usize, 26), mock.depth_count);
    try std.testing.expectEqual(@as(usize, 2), mock.xray_count);
    try std.testing.expectEqual(@as(f32, 3.5), mock.line_width);
    try std.testing.expectEqual(@as(usize, 26), svc.last_frame_depth_vertices);
    try std.testing.expectEqual(@as(usize, 2), svc.last_frame_xray_vertices);

    // Next frame with no gizmos submitted should not invoke backend.
    try app.tick(0.016);
    try std.testing.expectEqual(@as(usize, 1), mock.submits);
    try std.testing.expectEqual(@as(usize, 0), svc.last_frame_depth_vertices);
}

test "gizmos axes, sphere, grid, dashed lines, and arrow styles work headlessly" {
    const allocator = std.testing.allocator;
    var svc = gizmos.GizmoService.init(allocator);
    defer svc.deinit();

    svc.axes(.{ 0, 0, 0 }, 1.0); // 3 cone arrows * 17 lines * 2 = 102 verts
    svc.sphere(.{ 0, 1, 0 }, 1.0, 12, .{ 1, 1, 0, 1 }); // 3 circles * 12 segs * 2 = 72 verts
    svc.grid(.{ 0, 0, 0 }, .{ 4, 4 }, .{ 1.0, 1.0 }, .{ 0.5, 0.5, 0.5, 1 }); // (5 + 5) * 2 = 20 verts
    try std.testing.expectEqual(@as(usize, 102 + 72 + 20), svc.depth_vertices.items.len);

    svc.pushConfig(.{
        .line = .{ .width = 2.0, .style = .{ .dashed = .{ .gap_scale = 1.0, .line_scale = 2.0 } } },
        .arrow = .{ .style = .cone, .double_ended = true },
    });
    const before = svc.depth_vertices.items.len;
    svc.arrow(.{ 0, 0, 0 }, .{ 2, 0, 0 }, .{ 1, 0, 0, 1 });
    try std.testing.expect(svc.depth_vertices.items.len > before + 2);
    svc.popConfig();
    try std.testing.expectEqual(gizmos.ArrowStyle.cone, svc.config.arrow.style);
}
