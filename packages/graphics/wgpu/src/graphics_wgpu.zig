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
const frame = graphics.frame;

pub const PROVIDER_ID = "official.graphics.wgpu";
pub const MODULE_OWNER_ID: u64 = 2099;
pub const Device = wgpu_gpu.Device;

/// Optional resource read when the provider is built (insert before `app.initialize()`).
pub const GpuConfig = struct {
    /// Background used when a frame has no `.clear` draw command.
    default_clear_color: graphics.Color = .{ .r = 0.07, .g = 0.09, .b = 0.13, .a = 1.0 },
};

extern fn zwgpu_create(window: *anyopaque) ?*anyopaque;
extern fn zwgpu_destroy(bridge: *anyopaque) void;
extern fn zwgpu_drawable_size(bridge: *anyopaque, width: *u32, height: *u32) c_int;
extern fn zwgpu_error() [*:0]const u8;
extern fn zwgpu_surface_copy_src(bridge: *anyopaque) c_int;
// libc is linked already; used only by the debug frame dump below.
extern fn SDL_GetTicksNS() u64;
extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern fn fwrite(ptr: *const anyopaque, size: usize, count: usize, file: *anyopaque) usize;
extern fn fclose(file: *anyopaque) c_int;

/// Frame number (1-based) dumped when `ZENGY_WGPU_CAPTURE_PPM` is set.
const debug_capture_frame: u64 = 20;

/// Read-back of the frame being captured; the buffer is reused across captures.
const Capture = struct {
    request: ?graphics.CaptureTarget = null,
    /// A copy was recorded for the frame currently being presented.
    scheduled: bool = false,
    buffer: ?gpu.BufferHandle = null,
    capacity: u64 = 0,
    width: u32 = 0,
    height: u32 = 0,
    pitch: u32 = 0,
    format: gpu.TextureFormat = .bgra8_unorm,
    ready: ?graphics.CaptureImage = null,
};

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
    capture: Capture = .{},
    frames_presented: u64 = 0,
    /// Debug: path from `ZENGY_WGPU_CAPTURE_PPM`; the provider dumps one presented frame there.
    debug_capture_path: ?[*:0]const u8 = null,
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

/// `.final` capture point: after the world renderers, before 2D overlays. Skipped if nothing drew yet, in
/// which case the capture happens at the end of the frame (no world means final == presented).
fn captureFinalRender(ctx: *anyopaque, input: *frame.FrameInput) anyerror!void {
    const state: *State = @ptrCast(@alignCast(ctx));
    if (state.capture.request != .final or !input.color_target_used) return;
    try scheduleCapture(state, input);
}

fn scheduleCapture(state: *State, input: *frame.FrameInput) !void {
    const cap = &state.capture;
    if (cap.scheduled) return;
    if (zwgpu_surface_copy_src(state.bridge) == 0) return error.CaptureUnsupported;
    const pitch = gpu.alignedBytesPerRow(input.target.width * input.target.color_format.bytesPerTexel());
    const bytes = @as(u64, pitch) * input.target.height;
    if (cap.buffer == null or cap.capacity < bytes) {
        if (cap.buffer) |old| input.device.destroyBuffer(old);
        cap.buffer = null;
        cap.buffer = try input.device.createBuffer(.{ .label = "capture", .size = bytes, .usage = .{ .map_read = true, .copy_dst = true } });
        cap.capacity = bytes;
    }
    try input.recorder.copySwapchainToBuffer(cap.buffer.?, .{ .bytes_per_row = pitch, .rows_per_image = input.target.height });
    cap.scheduled = true;
    cap.width = input.target.width;
    cap.height = input.target.height;
    cap.pitch = pitch;
    cap.format = input.target.color_format;
}

/// Copies a renderer-offered intermediate texture (HDR scene, AO) into the capture buffer.
fn scheduleIntermediateCapture(state: *State, input: *frame.FrameInput, source: frame.CaptureSource) !void {
    const cap = &state.capture;
    if (cap.scheduled) return;
    const pitch = gpu.alignedBytesPerRow(source.width * source.format.bytesPerTexel());
    const bytes = @as(u64, pitch) * source.height;
    if (cap.buffer == null or cap.capacity < bytes) {
        if (cap.buffer) |old| input.device.destroyBuffer(old);
        cap.buffer = null;
        cap.buffer = try input.device.createBuffer(.{ .label = "capture", .size = bytes, .usage = .{ .map_read = true, .copy_dst = true } });
        cap.capacity = bytes;
    }
    try input.recorder.copyTextureToBuffer(.{ .texture = source.texture }, cap.buffer.?, .{ .bytes_per_row = pitch, .rows_per_image = source.height }, .{ .width = source.width, .height = source.height });
    cap.scheduled = true;
    cap.width = source.width;
    cap.height = source.height;
    cap.pitch = pitch;
    cap.format = source.format;
}

fn halfToFloat(bits: u16) f32 {
    return @floatCast(@as(f16, @bitCast(bits)));
}

/// Reads one channel of a texel, normalised to float, for the formats renderers can offer.
fn readChannel(raw: []const u8, format: gpu.TextureFormat, texel: usize, channel: usize) f32 {
    switch (format) {
        .rgba16_float => {
            const o = texel * 8 + channel * 2;
            return halfToFloat(std.mem.readInt(u16, raw[o..][0..2], .little));
        },
        .r16_float => return if (channel == 0) halfToFloat(std.mem.readInt(u16, raw[texel * 2 ..][0..2], .little)) else 0,
        .r32_float => return if (channel == 0) @bitCast(std.mem.readInt(u32, raw[texel * 4 ..][0..4], .little)) else 0,
        .r8_unorm => return if (channel == 0) @as(f32, @floatFromInt(raw[texel])) / 255.0 else 0,
        .bgra8_unorm, .bgra8_unorm_srgb => {
            const order = [4]usize{ 2, 1, 0, 3 };
            return @as(f32, @floatFromInt(raw[texel * 4 + order[channel]])) / 255.0;
        },
        else => return @as(f32, @floatFromInt(raw[texel * 4 + channel])) / 255.0,
    }
}

/// Reads the copied frame back and converts it to float RGBA. Capture is a tool path, so this blocks.
fn finishCapture(state: *State) !void {
    const cap = &state.capture;
    if (!cap.scheduled) return;
    cap.scheduled = false;
    cap.request = null;
    const device = state.device.gpuDevice();
    const raw = try state.allocator.alloc(u8, @as(usize, cap.pitch) * cap.height);
    defer state.allocator.free(raw);
    try device.readBufferBlocking(cap.buffer.?, 0, raw);

    const rgba = try state.allocator.alloc(f32, @as(usize, cap.width) * cap.height * 4);
    errdefer state.allocator.free(rgba);
    const texel_bytes = cap.format.bytesPerTexel();
    for (0..cap.height) |y| {
        const row = raw[y * cap.pitch ..][0 .. cap.width * texel_bytes];
        for (0..cap.width) |x| {
            const dst = (y * cap.width + x) * 4;
            for (0..4) |c| rgba[dst + c] = readChannel(row, cap.format, x, c);
        }
    }
    if (cap.ready) |*old| old.deinit(state.allocator);
    cap.ready = .{ .width = cap.width, .height = cap.height, .rgba = rgba };
}

/// Writes a binary PPM (P6). Debug tooling only: lets CI and developers inspect a presented frame.
fn writePpm(allocator: std.mem.Allocator, path: [*:0]const u8, image: graphics.CaptureImage) !void {
    const header = try std.fmt.allocPrint(allocator, "P6\n{d} {d}\n255\n", .{ image.width, image.height });
    defer allocator.free(header);
    const pixels = try allocator.alloc(u8, @as(usize, image.width) * image.height * 3);
    defer allocator.free(pixels);
    for (0..@as(usize, image.width) * image.height) |i| {
        for (0..3) |channel| {
            const value = std.math.clamp(image.rgba[i * 4 + channel], 0.0, 1.0);
            pixels[i * 3 + channel] = @intFromFloat(value * 255.0 + 0.5);
        }
    }
    const file = fopen(path, "wb") orelse return error.CaptureWriteFailed;
    defer _ = fclose(file);
    if (fwrite(header.ptr, 1, header.len, file) != header.len) return error.CaptureWriteFailed;
    if (fwrite(pixels.ptr, 1, pixels.len, file) != pixels.len) return error.CaptureWriteFailed;
}

fn present(raw: *anyopaque, handle: graphics.RenderTargetHandle, commands: []const graphics.DrawCommand) !void {
    const state = stateOf(raw);
    if (state.surface == null or !same(handle, state.surface.?)) return error.InvalidSurfaceHandle;

    var width: u32 = 0;
    var height: u32 = 0;
    if (zwgpu_drawable_size(state.bridge, &width, &height) == 0) return; // minimized: skip the frame
    const dpi_scale: f32 = if (window_sdl3.pixelSize(state.app)) |px| (if (px.dpi_scale > 0.0) px.dpi_scale else 1.0) else 1.0;
    const acquired = state.device.beginWindowFrame(&width, &height) catch |err| {
        if (isFatal(err)) state.service.setDeviceAvailable(false);
        return err;
    };
    if (!acquired) return;
    defer state.device.discardWindowFrame();
    var submitted = false;
    defer {
        state.service.renderers.notifyFrameResult(submitted);
        if (!submitted) state.capture.scheduled = false;
    }
    const format = state.device.surfaceFormat() orelse return error.UnsupportedSurfaceFormat;

    // The last `.clear` command of the frame decides the background; renderers never parse it themselves.
    var clear = state.default_clear;
    for (commands) |command| switch (command) {
        .clear => |c| clear = .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a },
        else => {},
    };

    const t0 = SDL_GetTicksNS();
    if (state.debug_capture_path != null and state.frames_presented + 1 == debug_capture_frame and state.capture.request == null and zwgpu_surface_copy_src(state.bridge) != 0) {
        state.capture.request = .presented;
    }

    const device = state.device.gpuDevice();
    const recorder = &state.recorder;
    recorder.reset();
    defer recorder.reset();

    var input: graphics.frame.FrameInput = .{
        .requested_capture = switch (state.capture.request orelse .final) {
            .hdr => .hdr,
            .ssao => .ssao,
            else => null,
        },
        .device = device,
        .recorder = recorder,
        .textures = &state.service.textures,
        .target = .{ .width = width, .height = height, .dpi_scale = dpi_scale, .color_format = format },
        .clear = clear,
        .draw_commands = commands,
    };
    try state.service.renderers.run(&input);
    const t1 = SDL_GetTicksNS();
    if (!input.color_target_used) {
        // Nothing drew: still clear the swapchain so the window shows the background instead of stale pixels.
        const attachments = [_]gpu.ColorAttachment{input.colorAttachment()};
        try recorder.beginRenderPass(.{ .label = "clear", .color_attachments = &attachments });
        try recorder.endRenderPass();
    }
    // A capture still pending here means nothing needed the pre-overlay point: take the whole frame.
    if (state.capture.request) |request| switch (request) {
        .hdr, .ssao => if (input.captured) |source| try scheduleIntermediateCapture(state, &input, source) else {
            // No renderer owns the target this frame (e.g. no 3D scene): drop the request instead of hanging the caller.
            state.capture.request = null;
        },
        else => try scheduleCapture(state, &input),
    };
    try recorder.finish();
    const t2 = SDL_GetTicksNS();
    device.submit(recorder.slice()) catch |err| {
        if (isFatal(err)) state.service.setDeviceAvailable(false);
        return err;
    };
    submitted = true;
    state.device.presentFrame() catch |err| {
        // The GPU passes were submitted even if the surface could not present.
        state.capture.scheduled = false;
        if (isFatal(err)) state.service.setDeviceAvailable(false);
        return err;
    };
    state.frames_presented += 1;
    if (getenv("ZENGY_WGPU_TIMING") != null) {
        const t3 = SDL_GetTicksNS();
        std.debug.print("[wgpu] frame {d}: renderers={d}us submit+present={d}us commands={d}\n", .{ state.frames_presented, (t1 - t0) / 1000, (t3 - t2) / 1000, recorder.slice().len });
    }
    try finishCapture(state);
    if (state.debug_capture_path) |path| {
        if (state.frames_presented == debug_capture_frame) {
            if (state.capture.ready) |image| {
                try writePpm(state.allocator, path, image);
                std.debug.print("[wgpu] wrote frame {d} ({d}x{d}) to {s}\n", .{ state.frames_presented, image.width, image.height, path });
            }
        }
    }
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
        .debug_capture_path = getenv("ZENGY_WGPU_CAPTURE_PPM"),
    };
    if (app.resources.get(GpuConfig)) |cfg| {
        const c = cfg.default_clear_color;
        state.default_clear = .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
    }
    state.service.gpu_device = device.gpuDevice();
    errdefer {
        state.recorder.deinit();
        state.service.deinit();
    }
    try state.service.registerRenderer(.{
        .name = "official.graphics.wgpu.capture",
        .ctx = state,
        .order = frame.Order.overlay_2d - 1,
        .render = captureFinalRender,
    });
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
    if (state.capture.buffer) |buffer| state.device.gpuDevice().destroyBuffer(buffer);
    if (state.capture.ready) |*image| image.deinit(state.allocator);
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

/// Asks the next presented frame to be read back. `final` excludes 2D overlays; `presented` includes them.
/// `hdr` and `ssao` are produced by whichever renderer owns those targets; if none does, no image is produced.
pub fn requestCapture(app: *engine.App, target: graphics.CaptureTarget) bool {
    const ref = app.resources.get(StateRef) orelse return false;
    if ((target == .final or target == .presented) and zwgpu_surface_copy_src(ref.state.bridge) == 0) return false;
    if (ref.state.capture.ready) |*old| old.deinit(ref.state.allocator);
    ref.state.capture.ready = null;
    ref.state.capture.request = target;
    return true;
}

/// Takes the capture produced by `requestCapture` once its frame was presented. The caller owns the image.
pub fn takeCapture(app: *engine.App) ?graphics.CaptureImage {
    const ref = app.resources.get(StateRef) orelse return null;
    const image = ref.state.capture.ready;
    ref.state.capture.ready = null;
    return image;
}
