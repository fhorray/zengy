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
};

pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32 = 1.0,
};

pub const DrawCommand = union(enum) {
    clear: Color,
    rect: struct {
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        color: Color,
    },
    text: struct {
        x: f32,
        y: f32,
        content: []const u8,
        color: Color,
    },
};

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

pub const GraphicsDeviceService = struct {
    allocator: std.mem.Allocator,
    targets: std.ArrayList(RenderTargetSlot),
    last_frame_commands: std.ArrayList(DrawCommand),
    device_available: bool,
    caps: DeviceCapabilities,

    pub fn init(allocator: std.mem.Allocator) GraphicsDeviceService {
        return .{
            .allocator = allocator,
            .targets = .empty,
            .last_frame_commands = .empty,
            .device_available = true,
            .caps = .{},
        };
    }

    pub fn deinit(self: *GraphicsDeviceService) void {
        self.targets.deinit(self.allocator);
        self.last_frame_commands.deinit(self.allocator);
    }

    pub fn capabilities(self: *const GraphicsDeviceService) DeviceCapabilities {
        return self.caps;
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
                return .{ .index = @intCast(i), .generation = gen };
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
        return .{ .index = idx, .generation = 1 };
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
        return true;
    }

    pub fn destroySurface(self: *GraphicsDeviceService, handle: RenderTargetHandle) bool {
        const slot = self.getSlotMut(handle) orelse return false;
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
        slot.frame_open = false;
        slot.presented_frames += 1;
    }

    pub fn presentedFrames(self: *const GraphicsDeviceService, handle: RenderTargetHandle) ?u64 {
        if (handle.index >= self.targets.items.len) return null;
        const slot = &self.targets.items[handle.index];
        if (!slot.alive or slot.generation != handle.generation) return null;
        return slot.presented_frames;
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
    if (app.resources.get(GraphicsDeviceService)) |svc| {
        svc.deinit();
        _ = app.resources.remove(GraphicsDeviceService);
    }
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
