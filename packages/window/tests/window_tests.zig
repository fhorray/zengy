//! Window & Input Package Tests (`packages/window/tests/window_tests.zig`).
//!
//! Validates Phase 5 `WindowService` and `InputService` lifecycle, resize,
//! close requests, event emission, and clean service unregistration on shutdown.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const window = @import("window");

test "WindowService lifecycle, resize, close, and InputService state" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(window.module());
    try app.initialize();

    const w_entry = try app.services.getService("engine.window", 1);
    const win: *window.WindowService = @ptrCast(@alignCast(@constCast(w_entry.api_ptr)));

    const i_entry = try app.services.getService("engine.input", 1);
    const input: *window.InputService = @ptrCast(@alignCast(@constCast(i_entry.api_ptr)));

    const wh = try win.createWindow(.{ .title = "Window Test", .width = 800, .height = 600 });
    try testing.expectEqual(@as(u32, 800), win.getSize(wh).?.width);

    try testing.expect(win.resize(wh, 1280, 720));
    try testing.expectEqual(@as(u32, 1280), win.getSize(wh).?.width);

    try testing.expect(win.requestClose(wh));
    try testing.expect(win.shouldClose(wh));

    input.beginFrame();
    input.injectKey('A', true);
    try testing.expect(input.isKeyDown('A'));
    try testing.expect(input.wasKeyPressed('A'));

    app.shutdown();
    try testing.expectError(error.ProviderNotFound, app.services.getService("engine.window", 1));
}
