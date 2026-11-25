//! Optional Graphics Device Package (`official.graphics`).
//!
//! Provides `GraphicsDeviceService` (`engine.graphics.device/1`) as an optional
//! `engine.Module` depending on `engine.window/1`.
//!
//! Responsibilities:
//! - Manages generational `RenderTargetHandle` surfaces bound to window handles.
//! - Records `DrawCommand` lists (`clear`, `rect`, `text`) per frame and tracks `present()`.
//! - Enables `scheduler.render_extract_enabled` only while this module is active.
//! - Reports `error.DeviceUnavailable` deterministically when the device is lost.

const std = @import("std");
const engine = @import("engine");

/// Backend-neutral GPU resource, pipeline and command contract implemented by providers.
pub const gpu = @import("gpu.zig");

pub const MODULE_OWNER_ID: u64 = 2002;

pub const RenderTargetHandle = packed struct(u64) {
    index: u32,
    generation: u32,
};

pub const DeviceCapabilities = struct {
    compute: bool = false,
    depth_texture_sampling: bool = true,
    storage_buffers: bool = false,
    timestamp_queries: bool = false,
    /// Full adapter report (features, limits, identification) when the provider exposes a `GpuDevice`.
    detected: ?gpu.Capabilities = null,
};

/// Backend-neutral 2D draw command vocabulary (defined in draw.zig).
pub const draw = @import("draw.zig");
pub const Color = draw.Color;
pub const ClipRect = draw.ClipRect;
pub const GradientKind = draw.GradientKind;
pub const IconKind = draw.IconKind;
pub const DrawCommand = draw.DrawCommand;

/// Frame renderer extension point (defined in frame.zig).
pub const frame = @import("frame.zig");

/// Shared GPU texture store (defined in textures.zig).
pub const textures = @import("textures.zig");
pub const TextureId = textures.TextureId;

const RenderTargetSlot = struct {
    window_handle: u64,
    width: u32,
    height: u32,
    generation: u32,
    alive: bool,
    frame_open: bool,
    submitted_commands: usize,
    presented_frames: u64,
};

/// Optional backend hooks for native GPU providers (e.g., `official.graphics.wgpu`).
/// When `backend` is null, `GraphicsDeviceService` operates in headless software mode.
pub const BackendVTable = struct {
    on_create_surface: ?*const fn (ctx: *anyopaque, handle: RenderTargetHandle, window_handle: u64, width: u32, height: u32) anyerror!void = null,
    on_resize_surface: ?*const fn (ctx: *anyopaque, handle: RenderTargetHandle, width: u32, height: u32) void = null,
    on_destroy_surface: ?*const fn (ctx: *anyopaque, handle: RenderTargetHandle) void = null,
    on_present: ?*const fn (ctx: *anyopaque, handle: RenderTargetHandle, commands: []const DrawCommand) anyerror!void = null,
};

pub const GraphicsDeviceService = struct {
    allocator: std.mem.Allocator,
    targets: std.ArrayList(RenderTargetSlot),
    last_frame_commands: std.ArrayList(DrawCommand),
    device_available: bool,
    caps: DeviceCapabilities,
    backend: ?*const BackendVTable = null,
    backend_ctx: ?*anyopaque = null,
    /// Resource and command interface of the active provider; null for the headless software service.
    gpu_device: ?gpu.GpuDevice = null,
    /// Renderers (2D, 3D, gizmos, ...) that draw into every presented frame, sorted by `frame.Order`.
    renderers: frame.RendererList = .{},
    /// Textures shared by every renderer (sprites, meshes, materials).
    textures: textures.TextureStore,

    pub fn init(allocator: std.mem.Allocator) GraphicsDeviceService {
        return .{
            .allocator = allocator,
            .targets = .empty,
            .last_frame_commands = .empty,
            .device_available = true,
            .caps = .{},
            .textures = textures.TextureStore.init(allocator),
        };
    }

    pub fn initWithBackend(
        allocator: std.mem.Allocator,
        backend: *const BackendVTable,
        backend_ctx: *anyopaque,
        caps: DeviceCapabilities,
    ) GraphicsDeviceService {
        return .{
            .allocator = allocator,
            .targets = .empty,
            .last_frame_commands = .empty,
            .device_available = true,
            .caps = caps,
            .backend = backend,
            .backend_ctx = backend_ctx,
            .textures = textures.TextureStore.init(allocator),
        };
    }

    pub fn deinit(self: *GraphicsDeviceService) void {
        // Renderers first: their bind groups reference texture views owned by the store.
        if (self.gpu_device) |device| self.renderers.releaseAll(device);
        self.renderers.deinit(self.allocator);
        self.textures.deinit(self.gpu_device);
        self.targets.deinit(self.allocator);
        self.last_frame_commands.deinit(self.allocator);
    }

    pub fn capabilities(self: *const GraphicsDeviceService) DeviceCapabilities {
        return self.caps;
    }

    /// Destroys a shared texture after telling every renderer to drop bindings that reference it.
    pub fn destroyTexture(self: *GraphicsDeviceService, id: TextureId) void {
        const device = self.gpu_device orelse return;
        self.renderers.forgetTexture(device, id);
        self.textures.destroy(device, id);
    }

    /// Registers a renderer that records GPU work into every presented frame (see `frame.zig`).
    pub fn registerRenderer(self: *GraphicsDeviceService, renderer: frame.FrameRenderer) !void {
        try self.renderers.register(self.allocator, renderer);
    }

    pub fn unregisterRenderer(self: *GraphicsDeviceService, name: []const u8) bool {
        return self.renderers.unregister(name);
    }

    /// Returns the provider's GPU resource interface, or `error.GpuUnavailable` for the software service.
    pub fn gpuDevice(self: *const GraphicsDeviceService) !gpu.GpuDevice {
        return self.gpu_device orelse error.GpuUnavailable;
    }

    pub fn setDeviceAvailable(self: *GraphicsDeviceService, available: bool) void {
        self.device_available = available;
    }

    pub fn createSurface(self: *GraphicsDeviceService, window_handle: u64, width: u32, height: u32) !RenderTargetHandle {
        if (!self.device_available) return error.DeviceUnavailable;
        for (self.targets.items, 0..) |*slot, i| {
            if (!slot.alive) {
                const gen = if (slot.generation == 0) @as(u32, 1) else slot.generation;
                slot.* = .{
                    .window_handle = window_handle,
                    .width = width,
                    .height = height,
                    .generation = gen,
                    .alive = true,
                    .frame_open = false,
                    .submitted_commands = 0,
                    .presented_frames = 0,
                };
                const handle: RenderTargetHandle = .{ .index = @intCast(i), .generation = gen };
                if (self.backend) |vt| {
                    if (vt.on_create_surface) |cb| {
                        errdefer slot.alive = false;
                        try cb(self.backend_ctx.?, handle, window_handle, width, height);
                    }
                }
                return handle;
            }
        }
        const idx: u32 = @intCast(self.targets.items.len);
        try self.targets.append(self.allocator, .{
            .window_handle = window_handle,
            .width = width,
            .height = height,
            .generation = 1,
            .alive = true,
            .frame_open = false,
            .submitted_commands = 0,
            .presented_frames = 0,
        });
        const handle: RenderTargetHandle = .{ .index = idx, .generation = 1 };
        if (self.backend) |vt| {
            if (vt.on_create_surface) |cb| {
                errdefer self.targets.items[idx].alive = false;
                try cb(self.backend_ctx.?, handle, window_handle, width, height);
            }
        }
        return handle;
    }

    fn getSlotMut(self: *GraphicsDeviceService, handle: RenderTargetHandle) ?*RenderTargetSlot {
        if (handle.index >= self.targets.items.len) return null;
        const slot = &self.targets.items[handle.index];
        if (!slot.alive or slot.generation != handle.generation) return null;
        return slot;
    }

    pub fn resizeSurface(self: *GraphicsDeviceService, handle: RenderTargetHandle, width: u32, height: u32) bool {
        const slot = self.getSlotMut(handle) orelse return false;
        slot.width = width;
        slot.height = height;
        if (self.backend) |vt| {
            if (vt.on_resize_surface) |cb| cb(self.backend_ctx.?, handle, width, height);
        }
        return true;
    }

    pub fn destroySurface(self: *GraphicsDeviceService, handle: RenderTargetHandle) bool {
        const slot = self.getSlotMut(handle) orelse return false;
        if (self.backend) |vt| {
            if (vt.on_destroy_surface) |cb| cb(self.backend_ctx.?, handle);
        }
        slot.alive = false;
        slot.generation +%= 1;
        return true;
    }

    pub fn beginFrame(self: *GraphicsDeviceService, handle: RenderTargetHandle) !void {
        if (!self.device_available) return error.DeviceUnavailable;
        const slot = self.getSlotMut(handle) orelse return error.InvalidSurfaceHandle;
        slot.frame_open = true;
        slot.submitted_commands = 0;
        self.last_frame_commands.clearRetainingCapacity();
    }

    pub fn submitDrawCommands(self: *GraphicsDeviceService, handle: RenderTargetHandle, cmds: []const DrawCommand) !void {
        if (!self.device_available) return error.DeviceUnavailable;
        const slot = self.getSlotMut(handle) orelse return error.InvalidSurfaceHandle;
        if (!slot.frame_open) return error.FrameNotStarted;

        try self.last_frame_commands.appendSlice(self.allocator, cmds);
        slot.submitted_commands += cmds.len;
    }

    pub fn present(self: *GraphicsDeviceService, handle: RenderTargetHandle) !void {
        if (!self.device_available) return error.DeviceUnavailable;
        const slot = self.getSlotMut(handle) orelse return error.InvalidSurfaceHandle;
        if (!slot.frame_open) return error.FrameNotStarted;
        defer slot.frame_open = false;
        if (self.backend) |vt| {
            if (vt.on_present) |cb| {
                try cb(self.backend_ctx.?, handle, self.last_frame_commands.items);
            }
        }
        slot.presented_frames += 1;
    }

    pub fn presentedFrames(self: *const GraphicsDeviceService, handle: RenderTargetHandle) ?u64 {
        if (handle.index >= self.targets.items.len) return null;
        const slot = &self.targets.items[handle.index];
        if (!slot.alive or slot.generation != handle.generation) return null;
        return slot.presented_frames;
    }

    pub fn getTargetWindowHandle(self: *const GraphicsDeviceService, handle: RenderTargetHandle) ?u64 {
        if (handle.index >= self.targets.items.len) return null;
        const slot = &self.targets.items[handle.index];
        if (!slot.alive or slot.generation != handle.generation) return null;
        return slot.window_handle;
    }
};

fn buildModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));

    try app.resources.insert(GraphicsDeviceService, GraphicsDeviceService.init(app.allocator));
    const svc = app.resources.get(GraphicsDeviceService).?;

    app.scheduler.render_extract_enabled = true;

    try app.services.register(.{
        .capability = "engine.graphics.device",
        .major_version = 1,
        .provider_id = "official.graphics.software",
        .owner_id = MODULE_OWNER_ID,
        .exclusive = true,
        .api_ptr = svc,
        .api_size = @sizeOf(GraphicsDeviceService),
    });
}

fn stopModule(raw_app: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    app.scheduler.render_extract_enabled = false;
    _ = app.services.unregisterByOwner(MODULE_OWNER_ID);
    _ = app.resources.remove(GraphicsDeviceService);
}

pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = "official.graphics",
            .version = "0.1.0",
            .provides_capabilities = &.{"engine.graphics.device/1"},
            .required_capabilities = &.{"engine.window/1"},
        },
        .build = buildModule,
        .stop = stopModule,
    };
}

/// Which render target a capture request reads back. `final` is the post-processed scene frame without 2D
/// overlays; `presented` is the frame exactly as shown, overlays included. `hdr` and `ssao` need the 3D
/// renderer and are rejected by providers that cannot produce them.
pub const CaptureTarget = enum { final, hdr, ssao, presented };

/// A captured render target as float RGBA. `final` captures hold display values in `[0, 1]`; `hdr` captures
/// hold scene-linear radiance. Providers fill it; `official.testing` turns it into PNGs, statistics and diffs.
pub const CaptureImage = struct {
    width: u32,
    height: u32,
    /// `width * height * 4` floats, row-major, top row first. Owned by the image.
    rgba: []f32,

    pub fn deinit(self: *CaptureImage, allocator: std.mem.Allocator) void {
        allocator.free(self.rgba);
        self.* = undefined;
    }
};

fn serviceOf(app: *engine.App) !*GraphicsDeviceService {
    const entry = try app.services.getService("engine.graphics.device", 1);
    return @ptrCast(@alignCast(@constCast(entry.api_ptr)));
}

/// Uploads tightly packed linear RGBA8 pixels (normals, roughness, UI) with a full mip chain.
/// The returned id is valid for every renderer; 0 is reserved for the built-in white texture.
pub fn createTextureRgba8(app: *engine.App, width: u32, height: u32, pixels: []const u8) !TextureId {
    const service = try serviceOf(app);
    return service.textures.createRgba8(try service.gpuDevice(), width, height, pixels, false);
}

/// Uploads sRGB-encoded RGBA8 pixels (albedo, emissive) with a full mip chain.
pub fn createTextureSrgbRgba8(app: *engine.App, width: u32, height: u32, pixels: []const u8) !TextureId {
    const service = try serviceOf(app);
    return service.textures.createRgba8(try service.gpuDevice(), width, height, pixels, true);
}

/// Destroys a texture created with `createTextureRgba8`/`createTextureSrgbRgba8`.
pub fn destroyTexture(app: *engine.App, id: TextureId) void {
    const service = serviceOf(app) catch return;
    service.destroyTexture(id);
}
