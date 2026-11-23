//! Graphics Device Package Tests (`packages/graphics/tests/graphics_tests.zig`).
//!
//! Validates Phase 5 `GraphicsDeviceService`: topological dependency on `official.window`,
//! `render_extract_enabled` toggle, draw command submission, `present()`, and
//! explicit `error.DeviceUnavailable` reporting when device is lost.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const window = @import("window");
const graphics = @import("graphics");

test "GraphicsDeviceService surface lifecycle, present, and device-lost error" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    // Register in reverse dependency order to verify topological resolution.
    try app.registerModule(graphics.module());
    try app.registerModule(window.module());
    try app.initialize();

    try testing.expect(app.scheduler.render_extract_enabled);

    const w_entry = try app.services.getService("engine.window", 1);
    const win: *window.WindowService = @ptrCast(@alignCast(@constCast(w_entry.api_ptr)));

    const g_entry = try app.services.getService("engine.graphics.device", 1);
    const gfx: *graphics.GraphicsDeviceService = @ptrCast(@alignCast(@constCast(g_entry.api_ptr)));

    const wh = try win.createWindow(.{ .title = "Gfx Test", .width = 800, .height = 600 });
    const rt = try gfx.createSurface(@bitCast(wh), 800, 600);

    try gfx.beginFrame(rt);
    try gfx.submitDrawCommands(rt, &.{
        .{ .clear = .{ .r = 0.1, .g = 0.1, .b = 0.12 } },
        .{ .rect = .{ .x = 10, .y = 10, .width = 100, .height = 40, .color = .{ .r = 0.2, .g = 0.6, .b = 0.9 } } },
    });
    try gfx.present(rt);
    try testing.expectEqual(@as(?u64, 1), gfx.presentedFrames(rt));

    try testing.expect(gfx.resizeSurface(rt, 1280, 720));

    // Simulate GPU device loss.
    gfx.setDeviceAvailable(false);
    try testing.expectError(error.DeviceUnavailable, gfx.beginFrame(rt));

    app.shutdown();
    try testing.expect(!app.scheduler.render_extract_enabled);
}
