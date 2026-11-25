//! Real-window test: opens an SDL window, runs the full provider + Render2D stack through
//! `GraphicsDeviceService.present`, and verifies the pixels of the actual swapchain frame.
//! Skipped (not failed) when no window or adapter can be created, for example on a headless CI runner.
extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
fn requireGpu() bool {
    const value = getenv("ZENGY_REQUIRE_GPU") orelse return false;
    return value[0] == '1' and value[1] == 0;
}

const std = @import("std");
const engine = @import("engine");
const graphics = @import("graphics");
const window_sdl3 = @import("window_sdl3");
const wgpu = @import("graphics_wgpu");
const draw_2d = @import("draw_2d");

const gpu = graphics.gpu;
const frame = graphics.frame;

/// Last renderer in the frame: copies the finished swapchain image into a buffer for inspection.
const Capture = struct {
    allocator: std.mem.Allocator,
    buffer: ?gpu.BufferHandle = null,
    width: u32 = 0,
    height: u32 = 0,
    pitch: u32 = 0,
    dpi: f32 = 1,
    format: gpu.TextureFormat = .bgra8_unorm,
    captured: bool = false,

    fn render(ctx: *anyopaque, input: *frame.FrameInput) anyerror!void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        if (self.buffer == null) {
            self.width = input.target.width;
            self.height = input.target.height;
            self.dpi = input.target.dpi_scale;
            self.format = input.target.color_format;
            self.pitch = gpu.alignedBytesPerRow(self.width * 4);
            self.buffer = try input.device.createBuffer(.{ .size = @as(u64, self.pitch) * self.height, .usage = .{ .map_read = true, .copy_dst = true } });
        }
        if (!input.color_target_used) return; // nothing drew: there is no frame to copy
        try input.recorder.copySwapchainToBuffer(self.buffer.?, .{ .bytes_per_row = self.pitch, .rows_per_image = self.height });
        self.captured = true;
    }

    fn pixel(self: *const Capture, rows: []const u8, x: u32, y: u32) [4]u8 {
        const i = @as(usize, y) * self.pitch + @as(usize, x) * 4;
        // Normalize to RGBA regardless of the surface byte order.
        return switch (self.format) {
            .bgra8_unorm, .bgra8_unorm_srgb => .{ rows[i + 2], rows[i + 1], rows[i], rows[i + 3] },
            else => .{ rows[i], rows[i + 1], rows[i + 2], rows[i + 3] },
        };
    }
};

fn close(a: [4]u8, b: [4]u8, tol: u8) bool {
    for (a, b) |x, y| {
        if ((if (x > y) x - y else y - x) > tol) return false;
    }
    return true;
}

test "provider presents Render2D output to a real swapchain" {
    var app = engine.App.init(std.testing.allocator, .{});
    defer app.deinit();
    try app.registerModule(window_sdl3.module());
    try app.registerModule(wgpu.module());
    try app.registerModule(draw_2d.module());
    try app.resources.insert(window_sdl3.WindowConfig, .{ .title = "zengy gpu test", .width = 320, .height = 200, .resizable = false });
    app.initialize() catch |err| {
        if (requireGpu()) return err;
        return error.SkipZigTest;
    };

    const entry = try app.services.getService("engine.graphics.device", 1);
    const service: *graphics.GraphicsDeviceService = @ptrCast(@alignCast(@constCast(entry.api_ptr)));
    const px = window_sdl3.pixelSize(&app) orelse return error.SkipZigTest;
    const target = try service.createSurface(1, px.width, px.height);
    defer _ = service.destroySurface(target);

    // The provider must report what the real adapter supports.
    const caps = service.capabilities();
    try std.testing.expect(caps.detected != null);
    try std.testing.expect(caps.detected.?.info.name().len > 0);

    var capture: Capture = .{ .allocator = std.testing.allocator };
    try service.registerRenderer(.{ .name = "test.capture", .ctx = &capture, .order = frame.Order.ui + 1000, .render = Capture.render });
    defer if (capture.buffer) |b| (service.gpuDevice() catch unreachable).destroyBuffer(b);

    // Present several frames: swapchain acquire/present must stay balanced across frames.
    for (0..4) |_| {
        try service.beginFrame(target);
        try service.submitDrawCommands(target, &.{
            .{ .clear = .{ .r = 0, .g = 0, .b = 1 } },
            .{ .rect = .{ .x = 20, .y = 20, .width = 60, .height = 40, .color = .{ .r = 1, .g = 0, .b = 0 } } },
        });
        try service.present(target);
    }
    try std.testing.expect(capture.captured);

    const device = try service.gpuDevice();
    const rows = try std.testing.allocator.alloc(u8, @as(usize, capture.pitch) * capture.height);
    defer std.testing.allocator.free(rows);
    try device.readBufferBlocking(capture.buffer.?, 0, rows);

    // `dpi_scale` is the UI content scale (SDL display scale), not a framebuffer ratio: the window has exactly
    // the requested pixels and Render2D multiplies logical units by it. Logical (50, 40) is inside the red
    // rect and (150, 100) is background; both stay inside a 320x200 target for scales up to 2.0.
    const inside = capture.pixel(rows, @intFromFloat(50 * capture.dpi), @intFromFloat(40 * capture.dpi));
    const outside = capture.pixel(rows, @intFromFloat(150 * capture.dpi), @intFromFloat(100 * capture.dpi));
    if (!close(inside, .{ 255, 0, 0, 255 }, 2) or !close(outside, .{ 0, 0, 255, 255 }, 2)) {
        std.debug.print("swapchain pixels: inside={any} outside={any} format={s} dpi={d}\n", .{ inside, outside, @tagName(capture.format), capture.dpi });
        return error.SwapchainPixelMismatch;
    }
}
