const std = @import("std");
const engine = @import("engine");
const window = @import("window");
const input = @import("input");

test "ButtonInput tracks pressed, justPressed, and justReleased transitions" {
    var keys: input.KeyInput = .{};
    try std.testing.expect(!keys.pressed(.key_w));

    keys.press(.key_w);
    try std.testing.expect(keys.pressed(.key_w));
    try std.testing.expect(keys.justPressed(.key_w));
    try std.testing.expect(!keys.justReleased(.key_w));

    keys.beginFrame();
    try std.testing.expect(keys.pressed(.key_w));
    try std.testing.expect(!keys.justPressed(.key_w));

    keys.release(.key_w);
    try std.testing.expect(!keys.pressed(.key_w));
    try std.testing.expect(keys.justReleased(.key_w));
}

test "GamepadState D-Pad and deadzone axis filtering" {
    var gp: input.GamepadState = .{ .connected = true, .deadzone = 0.15 };
    gp.setName("DualSense Wireless Controller");
    try std.testing.expectEqualStrings("DualSense Wireless Controller", gp.name());

    gp.buttons.press(.dpad_right);
    gp.buttons.press(.dpad_up);
    const dp = gp.dpad();
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), dp[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), dp[1], 1e-4);

    gp.axes[@intFromEnum(input.GamepadAxis.left_stick_x)] = 0.10; // below deadzone
    gp.axes[@intFromEnum(input.GamepadAxis.left_stick_y)] = -0.80;
    const ls = gp.leftStick();
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), ls[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, -0.80), ls[1], 1e-4);
}

test "syncInputSystem bridges window.InputService into KeyInput, MouseInput, motion, and scroll" {
    var app = engine.App.init(std.testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(window.module());
    try app.registerModule(input.module());

    try app.initialize();

    const win_entry = try app.services.getService("engine.input", 1);
    const win_input: *window.InputService = @ptrCast(@alignCast(@constCast(win_entry.api_ptr)));
    win_input.injectKey(@intFromEnum(input.KeyCode.key_w), true);
    win_input.injectMouseButton(.right, true);
    win_input.injectMouseMove(120.0, 80.0);
    win_input.injectMouseWheel(0.0, 2.0);

    try app.tick(1.0 / 60.0);

    const keys = app.resources.get(input.KeyInput).?;
    const mouse = app.resources.get(input.MouseInput).?;
    const motion = app.resources.get(input.AccumulatedMouseMotion).?;
    const scroll = app.resources.get(input.AccumulatedMouseScroll).?;

    try std.testing.expect(keys.pressed(.key_w));
    try std.testing.expect(keys.justPressed(.key_w));
    try std.testing.expect(mouse.pressed(.right));
    try std.testing.expectApproxEqAbs(@as(f32, 120.0), motion.delta[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 80.0), motion.delta[1], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), scroll.delta[1], 1e-4);

    app.shutdown();
}
