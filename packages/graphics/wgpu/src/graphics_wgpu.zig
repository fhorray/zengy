//! wgpu-native graphics provider (`official.graphics.wgpu`).
//!
//! Implements `graphics.GraphicsDeviceService` over the neutral `graphics.gpu` contract. SDL3 still owns the
//! window and input; this module owns the device, the surface and frame presentation. It draws nothing itself:
//! every presented frame runs the renderers registered with the service (`render/2d`, `render/3d`, ...).
const std = @import("std");
const engine = @import("engine");
const graphics = @import("graphics");
const window_sdl3 = @import("window_sdl3");
const wgpu_gpu = @import("wgpu_gpu");

const gpu = graphics.gpu;

pub const PROVIDER_ID = "official.graphics.wgpu";
pub const MODULE_OWNER_ID: u64 = 2099;
pub const Device = wgpu_gpu.Device;

extern fn zwgpu_create(window: *anyopaque) ?*anyopaque;
extern fn zwgpu_destroy(bridge: *anyopaque) void;
extern fn zwgpu_drawable_size(bridge: *anyopaque, width: *u32, height: *u32) c_int;
extern fn zwgpu_error() [*:0]const u8;

const State = struct {
    app: *engine.App,
    allocator: std.mem.Allocator,
    bridge: *anyopaque,
    device: *Device,
    service: graphics.GraphicsDeviceService,
    surface: ?graphics.RenderTargetHandle = null,
    /// Reused every frame so presenting does not allocate in steady state.
    recorder: gpu.CommandRecorder,
    default_clear: gpu.ClearColor = .{ .r = 0.07, .g = 0.09, .b = 0.13, .a = 1.0 },
};

/// Registry handle: State stays on the heap so `service` and `backend` pointers remain stable.
const StateRef = struct { state: *State };

fn stateOf(raw: *anyopaque) *State {
    return @ptrCast(@alignCast(raw));
}

fn same(a: graphics.RenderTargetHandle, b: graphics.RenderTargetHandle) bool {
    return @as(u64, @bitCast(a)) == @as(u64, @bitCast(b));
}

fn nativeError() error{WgpuFailure} {
    std.debug.print("[wgpu] {s}\n", .{std.mem.span(zwgpu_error())});
    return error.WgpuFailure;
}

fn createSurface(raw: *anyopaque, handle: graphics.RenderTargetHandle, window_handle: u64, _: u32, _: u32) !void {
    const state = stateOf(raw);
    if (window_handle == 0 or state.surface != null) return error.WgpuSingleWindowOnly;
    state.surface = handle;
}

fn destroySurface(raw: *anyopaque, handle: graphics.RenderTargetHandle) void {
    const state = stateOf(raw);
    if (state.surface) |current| if (same(handle, current)) {
        state.surface = null;
    };
}

/// Device-loss class errors make the service report `DeviceUnavailable`; validation errors stay recoverable.
fn isFatal(err: anyerror) bool {
    return err == error.GpuFailure or err == error.SurfaceFailure;
}

fn present(raw: *anyopaque, handle: graphics.RenderTargetHandle, commands: []const graphics.DrawCommand) !void {
    const state = stateOf(raw);
    if (state.surface == null or !same(handle, state.surface.?)) return error.InvalidSurfaceHandle;

    var width: u32 = 0;
    var height: u32 = 0;
    if (zwgpu_drawable_size(state.bridge, &width, &height) == 0) return; // minimized: skip the frame
    const dpi_scale: f32 = if (window_sdl3.pixelSize(state.app)) |px| (if (px.dpi_scale > 0.0) px.dpi_scale else 1.0) else 1.0;
    const format = state.device.surfaceFormat() orelse return error.UnsupportedSurfaceFormat;

    // The last `.clear` command of the frame decides the background; renderers never parse it themselves.
    var clear = state.default_clear;
    for (commands) |command| switch (command) {
        .clear => |c| clear = .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a },
        else => {},
    };

    const device = state.device.gpuDevice();
    const recorder = &state.recorder;
    recorder.reset();
    defer recorder.reset();

    var input: graphics.frame.FrameInput = .{
        .device = device,
        .recorder = recorder,
        .target = .{ .width = width, .height = height, .dpi_scale = dpi_scale, .color_format = format },
        .clear = clear,
        .draw_commands = commands,
    };
    try state.service.renderers.run(&input);
    if (!input.color_target_used) {
        // Nothing drew: still clear the swapchain so the window shows the background instead of stale pixels.
        const attachments = [_]gpu.ColorAttachment{input.colorAttachment()};
        try recorder.beginRenderPass(.{ .label = "clear", .color_attachments = &attachments });
        try recorder.endRenderPass();
    }
    try recorder.finish();
    device.submit(recorder.slice()) catch |err| {
        if (isFatal(err)) state.service.setDeviceAvailable(false);
        return err;
    };
    state.device.presentFrame() catch |err| {
        if (isFatal(err)) state.service.setDeviceAvailable(false);
        return err;
    };
}

const backend: graphics.BackendVTable = .{
    .on_create_surface = createSurface,
    .on_destroy_surface = destroySurface,
    .on_present = present,
};

fn buildModule(raw: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw));
    if (app.resources.get(StateRef) != null) return error.DuplicateWgpuProvider;
    const window = window_sdl3.sdlWindowOpaque(app) orelse return error.MissingWindowBackend;
    const bridge = zwgpu_create(window) orelse return nativeError();
    errdefer zwgpu_destroy(bridge);
    const device = try Device.initFromBridge(app.allocator, bridge, false);
    errdefer device.deinit();

    // Capabilities come from the real adapter report, not from constants.
    const detected = device.caps;
    const caps: graphics.DeviceCapabilities = .{
        .compute = detected.supportsCompute(),
        .depth_texture_sampling = true,
        .storage_buffers = detected.limits.max_storage_buffers_per_shader_stage > 0,
        .timestamp_queries = detected.features.timestamp_query,
        .detected = detected,
    };

    const state = try app.allocator.create(State);
    errdefer app.allocator.destroy(state);
    state.* = .{
        .app = app,
        .allocator = app.allocator,
        .bridge = bridge,
        .device = device,
        .service = graphics.GraphicsDeviceService.initWithBackend(app.allocator, &backend, state, caps),
        .recorder = gpu.CommandRecorder.init(app.allocator),
    };
    state.service.gpu_device = device.gpuDevice();
    errdefer {
        state.recorder.deinit();
        state.service.deinit();
    }
    try app.resources.insert(StateRef, .{ .state = state });
    errdefer _ = app.resources.remove(StateRef);
    try app.services.register(.{
        .capability = "engine.graphics.device",
        .major_version = 1,
        .provider_id = PROVIDER_ID,
        .owner_id = MODULE_OWNER_ID,
        .exclusive = true,
        .api_ptr = &state.service,
        .api_size = @sizeOf(graphics.GraphicsDeviceService),
    });
    app.scheduler.render_extract_enabled = true;
}

fn stopModule(raw: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw));
    const slot = app.resources.get(StateRef) orelse return;
    const state = slot.state;
    app.scheduler.render_extract_enabled = false;
    _ = app.services.unregisterByOwner(MODULE_OWNER_ID);
    _ = app.resources.remove(StateRef);
    // Renderers drop their GPU resources while the device is still alive.
    state.service.deinit();
    state.recorder.deinit();
    state.device.deinit();
    zwgpu_destroy(state.bridge);
    app.allocator.destroy(state);
}

pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = PROVIDER_ID,
            .version = "0.2.0",
            .provides_capabilities = &.{"engine.graphics.device/1"},
            .required_capabilities = &.{"engine.window/1"},
        },
        .build = buildModule,
        .stop = stopModule,
    };
}

/// Name of the native API in use (`vulkan`, `dx12`, `metal`, ...), for diagnostics.
pub fn driverName(app: *engine.App) ?[]const u8 {
    const ref = app.resources.get(StateRef) orelse return null;
    return @tagName(ref.state.device.caps.info.backend);
}
