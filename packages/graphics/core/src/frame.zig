//! Frame renderer extension point.
//!
//! Renderers (`render/2d`, `render/3d`, `render/prism`, gizmos, ...) are independent packages. They do not
//! talk to a graphics backend directly: each registers a `FrameRenderer` with `GraphicsDeviceService`, and the
//! active provider calls them in `order` once per presented frame, handing out the neutral `GpuDevice` and a
//! shared `CommandRecorder`. Replacing the provider therefore never requires touching a renderer.
//!
//! Contract:
//! - Renderers only record work; the provider submits the recorder once after every renderer ran.
//! - The first pass that targets the frame color target clears it (`FrameInput.colorAttachment`); later passes load.
//! - Renderers must keep GPU resources persistent and must not allocate per frame in steady state.

const std = @import("std");
const gpu = @import("gpu.zig");
const draw = @import("draw.zig");

/// Fixed render order bands. Lower runs first; use values in between to slot new renderers.
pub const Order = struct {
    pub const world: i32 = 0;
    pub const gizmos: i32 = 500;
    pub const overlay_2d: i32 = 1000;
    pub const ui: i32 = 2000;
};

/// Where the frame is going. Sizes are in physical pixels.
pub const FrameTarget = struct {
    width: u32,
    height: u32,
    /// Physical pixels per logical unit (HiDPI scale).
    dpi_scale: f32,
    /// Format of the swapchain attachment: pipelines targeting it must use this format.
    color_format: gpu.TextureFormat,
};

/// Per-frame data passed to every renderer. Valid only for the duration of the `render` call.
pub const FrameInput = struct {
    device: gpu.GpuDevice,
    recorder: *gpu.CommandRecorder,
    target: FrameTarget,
    /// Background color requested by the application (`DrawCommand.clear`) or the provider default.
    clear: gpu.ClearColor,
    /// 2D/UI commands submitted for this frame, in logical (DPI-independent) coordinates.
    draw_commands: []const draw.DrawCommand,
    /// Presentation surface by default; tests and tools may point it at an offscreen texture view.
    color_target: gpu.ColorTarget = .swapchain,
    /// Set once any pass wrote the color target this frame.
    color_target_used: bool = false,

    /// Color attachment for the frame target: cleared by the first pass of the frame, loaded afterwards.
    pub fn colorAttachment(self: *FrameInput) gpu.ColorAttachment {
        const load: gpu.LoadOp = if (self.color_target_used) .load else .clear;
        self.color_target_used = true;
        return .{ .target = self.color_target, .load = load, .clear_value = self.clear };
    }
};

/// A renderer registered with the graphics service.
pub const FrameRenderer = struct {
    /// Unique name, used to unregister and in diagnostics.
    name: []const u8,
    ctx: *anyopaque,
    order: i32,
    render: *const fn (ctx: *anyopaque, input: *FrameInput) anyerror!void,
    /// Called when the device is replaced or the service is torn down, so the renderer can drop GPU resources.
    release: ?*const fn (ctx: *anyopaque, device: gpu.GpuDevice) void = null,
};

/// Ordered list of renderers. Insertion keeps the list sorted so frame execution is a plain loop.
pub const RendererList = struct {
    items: std.ArrayList(FrameRenderer) = .empty,

    pub fn deinit(self: *RendererList, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
    }

    pub fn register(self: *RendererList, allocator: std.mem.Allocator, renderer: FrameRenderer) !void {
        for (self.items.items) |existing| {
            if (std.mem.eql(u8, existing.name, renderer.name)) return error.DuplicateRenderer;
        }
        // Stable insertion: equal orders keep registration order.
        var index: usize = self.items.items.len;
        for (self.items.items, 0..) |existing, i| {
            if (existing.order > renderer.order) {
                index = i;
                break;
            }
        }
        try self.items.insert(allocator, index, renderer);
    }

    pub fn unregister(self: *RendererList, name: []const u8) bool {
        for (self.items.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing.name, name)) {
                _ = self.items.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    /// Runs every renderer in order, stopping at the first error.
    pub fn run(self: *const RendererList, input: *FrameInput) !void {
        for (self.items.items) |renderer| try renderer.render(renderer.ctx, input);
    }

    /// Lets every renderer drop device-owned resources (device loss or shutdown).
    pub fn releaseAll(self: *const RendererList, device: gpu.GpuDevice) void {
        for (self.items.items) |renderer| {
            if (renderer.release) |release| release(renderer.ctx, device);
        }
    }
};

const TestState = struct {
    log: *std.ArrayList(u8),
    tag: u8,
    fail: bool = false,
    fn render(ctx: *anyopaque, input: *FrameInput) anyerror!void {
        const self: *TestState = @ptrCast(@alignCast(ctx));
        _ = input;
        try self.log.append(std.testing.allocator, self.tag);
        if (self.fail) return error.TestFailure;
    }
};

fn dummyInput(recorder: *gpu.CommandRecorder) FrameInput {
    return .{
        .device = undefined,
        .recorder = recorder,
        .target = .{ .width = 1, .height = 1, .dpi_scale = 1, .color_format = .bgra8_unorm },
        .clear = .{},
        .draw_commands = &.{},
    };
}

test "renderers run in order and stop at the first failure" {
    var list: RendererList = .{};
    defer list.deinit(std.testing.allocator);
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(std.testing.allocator);

    var ui = TestState{ .log = &log, .tag = 'u' };
    var world = TestState{ .log = &log, .tag = 'w' };
    var overlay = TestState{ .log = &log, .tag = 'o' };
    try list.register(std.testing.allocator, .{ .name = "ui", .ctx = &ui, .order = Order.ui, .render = TestState.render });
    try list.register(std.testing.allocator, .{ .name = "world", .ctx = &world, .order = Order.world, .render = TestState.render });
    try list.register(std.testing.allocator, .{ .name = "overlay", .ctx = &overlay, .order = Order.overlay_2d, .render = TestState.render });
    try std.testing.expectError(error.DuplicateRenderer, list.register(std.testing.allocator, .{ .name = "ui", .ctx = &ui, .order = 0, .render = TestState.render }));

    var rec = gpu.CommandRecorder.init(std.testing.allocator);
    defer rec.deinit();
    var input = dummyInput(&rec);
    try list.run(&input);
    try std.testing.expectEqualStrings("wou", log.items);

    overlay.fail = true;
    log.clearRetainingCapacity();
    try std.testing.expectError(error.TestFailure, list.run(&input));
    try std.testing.expectEqualStrings("wo", log.items);

    try std.testing.expect(list.unregister("overlay"));
    try std.testing.expect(!list.unregister("overlay"));
}

test "first color pass clears and later passes load" {
    var rec = gpu.CommandRecorder.init(std.testing.allocator);
    defer rec.deinit();
    var input = dummyInput(&rec);
    input.clear = .{ .r = 0.5, .g = 0.25, .b = 0, .a = 1 };

    const first = input.colorAttachment();
    const second = input.colorAttachment();
    try std.testing.expectEqual(gpu.LoadOp.clear, first.load);
    try std.testing.expectEqual(gpu.LoadOp.load, second.load);
    try std.testing.expectEqual(@as(f64, 0.5), first.clear_value.r);
}
