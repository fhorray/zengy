const std = @import("std");
const engine = @import("engine");
const haptics = @import("input_haptics");

test "HapticService headless dispatch clamps intensities and records requests" {
    var app = engine.App.init(std.testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(haptics.module());
    try app.initialize();

    const svc = app.resources.get(haptics.HapticService).?;
    try std.testing.expect(svc.playRumble(0, 1.5, 0.4, 250));
    try std.testing.expectEqual(@as(usize, 1), svc.dispatched_count);
    switch (svc.last_request.?) {
        .rumble => |r| {
            try std.testing.expectApproxEqAbs(@as(f32, 1.0), r.low_frequency, 1e-4);
            try std.testing.expectApproxEqAbs(@as(f32, 0.4), r.high_frequency, 1e-4);
            try std.testing.expectEqual(@as(u32, 250), r.duration_ms);
        },
        else => return error.TestUnexpectedResult,
    }

    try std.testing.expect(svc.playTriggerRumble(0, 0.8, 0.2, 120));
    try std.testing.expect(svc.setAdaptiveTrigger(0, .right, .{ .weapon = .{ .start_position = 0.2, .end_position = 0.7, .strength = 1.5 } }));
    switch (svc.last_request.?) {
        .adaptive_trigger => |at| try std.testing.expectApproxEqAbs(@as(f32, 1.0), at.effect.weapon.strength, 1e-4),
        else => return error.TestUnexpectedResult,
    }
    svc.stop(0);
    try std.testing.expectEqual(@as(usize, 4), svc.dispatched_count);

    app.shutdown();
}
