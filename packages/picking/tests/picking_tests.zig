//! Unified Picking & Input Focus Tests (`packages/picking/tests/picking_tests.zig`).

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const window = @import("window");
const graphics = @import("graphics");
const input = @import("input");
const scene = @import("scene");
const camera = @import("camera");
const render_3d = @import("render_3d");
const picking = @import("picking");

const EventCounts = struct {
    enter: usize = 0,
    leave: usize = 0,
    down: usize = 0,
    up: usize = 0,
    drag: usize = 0,
    last_leave_index: u32 = 0,
};

fn onEvent(user_data: ?*anyopaque, ev: engine.events.EventEnvelope) void {
    const counts: *EventCounts = @ptrCast(@alignCast(user_data.?));
    if (std.mem.eql(u8, ev.name, "picking.pointer_enter")) counts.enter += 1;
    if (std.mem.eql(u8, ev.name, "picking.pointer_leave")) {
        counts.leave += 1;
        const h: engine.EntityHandle = @bitCast(ev.entity_handle);
        counts.last_leave_index = h.index;
    }
    if (std.mem.eql(u8, ev.name, "picking.pointer_down")) counts.down += 1;
    if (std.mem.eql(u8, ev.name, "picking.pointer_up")) counts.up += 1;
    if (std.mem.eql(u8, ev.name, "picking.pointer_drag")) counts.drag += 1;
}

test "PickingService unifies UI, 2D, and 3D hits, emits pointer events, and updates InputFocus" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(window.module());
    try app.registerModule(graphics.module());
    try app.registerModule(input.module());
    try app.registerModule(scene.module());
    try app.registerModule(camera.module());
    try app.registerModule(render_3d.module());
    try app.registerModule(picking.module());
    try app.initialize();

    var counts = EventCounts{};
    _ = try app.events.subscribe(999, "picking.pointer_enter", onEvent, &counts);
    _ = try app.events.subscribe(999, "picking.pointer_leave", onEvent, &counts);
    _ = try app.events.subscribe(999, "picking.pointer_down", onEvent, &counts);
    _ = try app.events.subscribe(999, "picking.pointer_up", onEvent, &counts);
    _ = try app.events.subscribe(999, "picking.pointer_drag", onEvent, &counts);

    const cam_e = try app.world.spawn();
    try app.world.set(cam_e, camera.Camera, .{
        .order = 0,
        .viewport = .{ .physical_size = .{ 800, 600 } },
    });
    try app.world.set(cam_e, camera.Projection, .{ .perspective = .{ .fov_rad = std.math.pi / 3.0, .near = 0.1, .far = 100.0 } });
    try app.world.set(cam_e, camera.CameraPose, camera.CameraPose.lookAt(.{ 0, 0, 5 }, .{ 0, 0, 0 }, .{ 0, 1, 0 }));

    try app.tick(1.0 / 60.0);

    const box_e = try app.world.spawn();
    try app.world.set(box_e, render_3d.Transform3D, .{ .position = .{ 0, 0, 0 }, .scale = .{ 2, 2, 2 } });
    try app.world.set(box_e, picking.Pickable3D, .{ .half_extents = .{ 0.5, 0.5, 0.5 } });

    const ui_e = try app.world.spawn();
    try app.world.set(ui_e, picking.PickableUi, .{ .rect = .{ 10, 10, 120, 40 }, .z_order = 10.0 });

    const svc = app.resources.get(picking.PickingService).?;
    const focus = app.resources.get(picking.InputFocus).?;

    // Hover & press center of viewport -> hits 3D cube
    _ = try svc.updatePointer(&app.world, &app.resources, &app.events, .{ 400, 300 }, .{ 0, 0 }, true, true, false);
    try testing.expect(focus.isFocused(box_e));

    // Drag & release
    _ = try svc.updatePointer(&app.world, &app.resources, &app.events, .{ 410, 305 }, .{ 10, 5 }, true, false, false);
    _ = try svc.updatePointer(&app.world, &app.resources, &app.events, .{ 410, 305 }, .{ 0, 0 }, false, false, true);

    // Move onto UI rect -> UI priority beats 3D and emits PointerLeave on box_e
    _ = try svc.updatePointer(&app.world, &app.resources, &app.events, .{ 50, 25 }, .{ 0, 0 }, true, true, false);
    try testing.expect(focus.isFocused(ui_e));

    _ = app.events.drain();
    try testing.expectEqual(@as(usize, 2), counts.enter);
    try testing.expectEqual(@as(usize, 1), counts.leave);
    try testing.expectEqual(@as(usize, 2), counts.down);
    try testing.expectEqual(@as(usize, 1), counts.drag);
    try testing.expectEqual(@as(usize, 1), counts.up);
    try testing.expectEqual(box_e.index, counts.last_leave_index);
}
