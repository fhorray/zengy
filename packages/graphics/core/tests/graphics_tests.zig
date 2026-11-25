//! Graphics Device Package Tests (`packages/graphics/core/tests/graphics_tests.zig`).
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
    _ = try gfx.present(rt);
    try testing.expectEqual(@as(?u64, 1), gfx.presentedFrames(rt));

    try testing.expect(gfx.resizeSurface(rt, 1280, 720));

    // Simulate GPU device loss.
    gfx.setDeviceAvailable(false);
    try testing.expectError(error.DeviceUnavailable, gfx.beginFrame(rt));

    app.shutdown();
    try testing.expect(!app.scheduler.render_extract_enabled);
}

test "GraphicsDeviceService delegates lifecycle and DrawCommands to BackendVTable" {
    const MockBackend = struct {
        created: usize = 0,
        resized_w: u32 = 0,
        resized_h: u32 = 0,
        presented: usize = 0,
        last_cmd_count: usize = 0,
        destroyed: usize = 0,

        fn onCreate(ctx: *anyopaque, _: graphics.RenderTargetHandle, _: u64, _: u32, _: u32) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.created += 1;
        }
        fn onResize(ctx: *anyopaque, _: graphics.RenderTargetHandle, w: u32, h: u32) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.resized_w = w;
            self.resized_h = h;
        }
        fn onDestroy(ctx: *anyopaque, _: graphics.RenderTargetHandle) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.destroyed += 1;
        }
        fn onPresent(ctx: *anyopaque, _: graphics.RenderTargetHandle, cmds: []const graphics.DrawCommand) !graphics.PresentResult {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.presented += 1;
            self.last_cmd_count = cmds.len;
            return .presented;
        }
    };

    var mock = MockBackend{};
    const vtable = graphics.BackendVTable{
        .on_create_surface = MockBackend.onCreate,
        .on_resize_surface = MockBackend.onResize,
        .on_destroy_surface = MockBackend.onDestroy,
        .on_present = MockBackend.onPresent,
    };

    var svc = graphics.GraphicsDeviceService.initWithBackend(testing.allocator, &vtable, &mock, .{});
    defer svc.deinit();

    const rt = try svc.createSurface(1, 800, 600);
    try testing.expectEqual(@as(usize, 1), mock.created);

    try testing.expect(svc.resizeSurface(rt, 1920, 1080));
    try testing.expectEqual(@as(u32, 1920), mock.resized_w);
    try testing.expectEqual(@as(u32, 1080), mock.resized_h);

    try svc.beginFrame(rt);
    try svc.submitDrawCommands(rt, &.{
        .{ .clear = .{ .r = 0.1, .g = 0.1, .b = 0.1 } },
        .{ .rect = .{ .x = 0, .y = 0, .width = 50, .height = 50, .color = .{ .r = 1, .g = 0, .b = 0 } } },
    });
    _ = try svc.present(rt);

    try testing.expectEqual(@as(usize, 1), mock.presented);
    try testing.expectEqual(@as(usize, 2), mock.last_cmd_count);
    try testing.expectEqual(@as(?u64, 1), svc.presentedFrames(rt));

    try testing.expect(svc.destroySurface(rt));
    try testing.expectEqual(@as(usize, 1), mock.destroyed);
}

test "skipped presents are reported and not counted as presented frames" {
    const SkipBackend = struct {
        skip: bool = false,
        fn onPresent(ctx: *anyopaque, _: graphics.RenderTargetHandle, _: []const graphics.DrawCommand) !graphics.PresentResult {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return if (self.skip) .skipped else .presented;
        }
    };
    var backend_state = SkipBackend{};
    const vtable = graphics.BackendVTable{ .on_present = SkipBackend.onPresent };
    var svc = graphics.GraphicsDeviceService.initWithBackend(testing.allocator, &vtable, &backend_state, .{});
    defer svc.deinit();
    const rt = try svc.createSurface(1, 64, 64);

    try svc.beginFrame(rt);
    try testing.expectEqual(graphics.PresentResult.presented, try svc.present(rt));
    backend_state.skip = true; // e.g. the window was minimized
    try svc.beginFrame(rt);
    try testing.expectEqual(graphics.PresentResult.skipped, try svc.present(rt));
    try svc.beginFrame(rt);
    try testing.expectEqual(graphics.PresentResult.skipped, try svc.present(rt));

    try testing.expectEqual(@as(?u64, 1), svc.presentedFrames(rt));
    try testing.expectEqual(@as(?u64, 2), svc.skippedFrames(rt));
}
