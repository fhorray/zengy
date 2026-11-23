//! Immediate UI Backend Independence Tests (`packages/ui-immediate/tests/ui_immediate_tests.zig`).
//!
//! Validates Phase 10: `community.ui.immediate` functions using only
//! `engine.window/1`, `engine.input/1`, and `engine.graphics.device/1`,
//! with `official.ui.core` completely absent.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const window = @import("window");
const graphics = @import("graphics");
const ui_immediate = @import("ui_immediate");

test "Alternative immediate UI backend works without ui-core" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(window.module());
    try app.registerModule(graphics.module());
    try app.registerModule(ui_immediate.module());
    try app.initialize();

    try testing.expectError(error.ProviderNotFound, app.services.getService("engine.ui.tree", 1));
    try testing.expect(app.services.hasService("engine.ui.backend.immediate", 1));

    const imm_entry = try app.services.getService("engine.ui.backend.immediate", 1);
    const imm: *ui_immediate.ImmediateUiService = @ptrCast(@alignCast(@constCast(imm_entry.api_ptr)));

    const w_entry = try app.services.getService("engine.window", 1);
    const win: *window.WindowService = @ptrCast(@alignCast(@constCast(w_entry.api_ptr)));
    const i_entry = try app.services.getService("engine.input", 1);
    const input: *window.InputService = @ptrCast(@alignCast(@constCast(i_entry.api_ptr)));
    const g_entry = try app.services.getService("engine.graphics.device", 1);
    const gfx: *graphics.GraphicsDeviceService = @ptrCast(@alignCast(@constCast(g_entry.api_ptr)));

    const wh = try win.createWindow(.{});
    const rt = try gfx.createSurface(@bitCast(wh), 800, 600);

    input.beginFrame();
    input.injectMouseMove(25, 16);
    input.injectMouseButton(.left, true);

    try gfx.beginFrame(rt);
    imm.beginFrame();
    const clicked = try imm.button(input, 10, 120, 30, "Run");
    try testing.expect(clicked);
    try imm.flush(gfx, rt);
    try gfx.present(rt);
}
