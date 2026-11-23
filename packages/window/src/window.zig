//! Optional Window & Input Package (`official.window`).
//!
//! Provides `WindowService` (`engine.window/1`) and `InputService` (`engine.input/1`)
//! as an optional `engine.Module` without any dependencies inside `src/core/`.
//!
//! Features:
//! - Generational `WindowHandle` lifecycle (create, resize, requestClose, destroy).
//! - Per-frame input state tracking (mouse position, button clicks, keyboard presses, text).
//! - Emits `window.resized` and `window.close_requested` events via `EventBus`.

const std = @import("std");
const engine = @import("engine");

pub const MODULE_OWNER_ID: u64 = 2001;

pub const WindowHandle = packed struct(u64) {
    index: u32,
    generation: u32,
};

pub const WindowDescriptor = struct {
    title: []const u8 = "ZigEng Window",
    width: u32 = 1280,
    height: u32 = 720,
    dpi_scale: f32 = 1.0,
};

pub const WindowSize = struct {
    width: u32,
    height: u32,
    dpi_scale: f32,
};

const WindowSlot = struct {
    title: []const u8,
    width: u32,
    height: u32,
    dpi_scale: f32,
    generation: u32,
    alive: bool,
    close_requested: bool,
};

pub const MouseButton = enum(u8) {
    left = 0,
    right = 1,
    middle = 2,
};

pub const InputService = struct {
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    mouse_down: [3]bool = .{ false, false, false },
    mouse_clicked: [3]bool = .{ false, false, false },
    keys_down: [256]bool = @splat(false),
    keys_pressed: [256]bool = @splat(false),
    last_text: [64]u8 = @splat(0),
    last_text_len: usize = 0,

    pub fn beginFrame(self: *InputService) void {
        self.mouse_clicked = .{ false, false, false };
        @memset(&self.keys_pressed, false);
        self.last_text_len = 0;
    }

    pub fn injectMouseMove(self: *InputService, x: f32, y: f32) void {
        self.mouse_x = x;
        self.mouse_y = y;
    }

    pub fn injectMouseButton(self: *InputService, button: MouseButton, down: bool) void {
        const idx = @intFromEnum(button);
        if (down and !self.mouse_down[idx]) {
            self.mouse_clicked[idx] = true;
        }
        self.mouse_down[idx] = down;
    }

    pub fn injectKey(self: *InputService, key_code: u8, down: bool) void {
        if (down and !self.keys_down[key_code]) {
            self.keys_pressed[key_code] = true;
        }
        self.keys_down[key_code] = down;
    }

    pub fn injectText(self: *InputService, text: []const u8) void {
        const copy_len = @min(text.len, self.last_text.len);
        @memcpy(self.last_text[0..copy_len], text[0..copy_len]);
        self.last_text_len = copy_len;
    }

    pub fn isMouseDown(self: *const InputService, button: MouseButton) bool {
        return self.mouse_down[@intFromEnum(button)];
    }

    pub fn wasMouseClicked(self: *const InputService, button: MouseButton) bool {
        return self.mouse_clicked[@intFromEnum(button)];
    }

    pub fn isKeyDown(self: *const InputService, key_code: u8) bool {
        return self.keys_down[key_code];
    }

    pub fn wasKeyPressed(self: *const InputService, key_code: u8) bool {
        return self.keys_pressed[key_code];
    }
};

pub const WindowService = struct {
    allocator: std.mem.Allocator,
    windows: std.ArrayList(WindowSlot),
    events: *engine.EventBus,

    pub fn init(allocator: std.mem.Allocator, events: *engine.EventBus) WindowService {
        return .{
            .allocator = allocator,
            .windows = .empty,
            .events = events,
        };
    }

    pub fn deinit(self: *WindowService) void {
        for (self.windows.items) |w| {
            if (w.title.len > 0) self.allocator.free(w.title);
        }
        self.windows.deinit(self.allocator);
    }

    pub fn createWindow(self: *WindowService, desc: WindowDescriptor) !WindowHandle {
        const title_copy = try self.allocator.dupe(u8, desc.title);
        errdefer self.allocator.free(title_copy);

        for (self.windows.items, 0..) |*slot, i| {
            if (!slot.alive) {
                const gen = if (slot.generation == 0) @as(u32, 1) else slot.generation;
                slot.* = .{
                    .title = title_copy,
                    .width = desc.width,
                    .height = desc.height,
                    .dpi_scale = desc.dpi_scale,
                    .generation = gen,
                    .alive = true,
                    .close_requested = false,
                };
                return .{ .index = @intCast(i), .generation = gen };
            }
        }

        const idx: u32 = @intCast(self.windows.items.len);
        try self.windows.append(self.allocator, .{
            .title = title_copy,
            .width = desc.width,
            .height = desc.height,
            .dpi_scale = desc.dpi_scale,
            .generation = 1,
            .alive = true,
            .close_requested = false,
        });
        return .{ .index = idx, .generation = 1 };
    }

    fn getSlotMut(self: *WindowService, handle: WindowHandle) ?*WindowSlot {
        if (handle.index >= self.windows.items.len) return null;
        const slot = &self.windows.items[handle.index];
        if (!slot.alive or slot.generation != handle.generation) return null;
        return slot;
    }

    fn getSlotConst(self: *const WindowService, handle: WindowHandle) ?*const WindowSlot {
        if (handle.index >= self.windows.items.len) return null;
        const slot = &self.windows.items[handle.index];
        if (!slot.alive or slot.generation != handle.generation) return null;
        return slot;
    }

    pub fn getSize(self: *const WindowService, handle: WindowHandle) ?WindowSize {
        const slot = self.getSlotConst(handle) orelse return null;
        return .{
            .width = slot.width,
            .height = slot.height,
            .dpi_scale = slot.dpi_scale,
        };
    }

    pub fn resize(self: *WindowService, handle: WindowHandle, width: u32, height: u32) bool {
        const slot = self.getSlotMut(handle) orelse return false;
        slot.width = width;
        slot.height = height;
        self.events.post(.{
            .name = "window.resized",
            .payload = "resized",
            .entity_handle = @bitCast(handle),
        }) catch {};
        return true;
    }

    pub fn requestClose(self: *WindowService, handle: WindowHandle) bool {
        const slot = self.getSlotMut(handle) orelse return false;
        slot.close_requested = true;
        self.events.post(.{
            .name = "window.close_requested",
            .payload = "close",
            .entity_handle = @bitCast(handle),
        }) catch {};
        return true;
    }

    pub fn shouldClose(self: *const WindowService, handle: WindowHandle) bool {
        const slot = self.getSlotConst(handle) orelse return true;
        return slot.close_requested;
    }

    pub fn destroyWindow(self: *WindowService, handle: WindowHandle) bool {
        const slot = self.getSlotMut(handle) orelse return false;
        if (slot.title.len > 0) {
            self.allocator.free(slot.title);
            slot.title = &.{};
        }
        slot.alive = false;
        slot.generation +%= 1;
        return true;
    }
};

const WindowModuleState = struct {
    window_svc: WindowService,
    input_svc: InputService,
};

fn buildModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));

    try app.resources.insert(WindowModuleState, .{
        .window_svc = WindowService.init(app.allocator, &app.events),
        .input_svc = .{},
    });

    const state = app.resources.get(WindowModuleState).?;

    try app.services.register(.{
        .capability = "engine.window",
        .major_version = 1,
        .provider_id = "official.window.headless",
        .owner_id = MODULE_OWNER_ID,
        .exclusive = true,
        .api_ptr = &state.window_svc,
        .api_size = @sizeOf(WindowService),
    });

    try app.services.register(.{
        .capability = "engine.input",
        .major_version = 1,
        .provider_id = "official.input.default",
        .owner_id = MODULE_OWNER_ID,
        .exclusive = true,
        .api_ptr = &state.input_svc,
        .api_size = @sizeOf(InputService),
    });
}

fn stopModule(raw_app: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    _ = app.services.unregisterByOwner(MODULE_OWNER_ID);
    if (app.resources.get(WindowModuleState)) |state| {
        state.window_svc.deinit();
        _ = app.resources.remove(WindowModuleState);
    }
}

pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = "official.window",
            .version = "0.1.0",
            .provides_capabilities = &.{ "engine.window/1", "engine.input/1" },
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
