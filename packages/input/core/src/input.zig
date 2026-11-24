//! Bevy-inspired ergonomic Input package (`official.input`), layered over
//! `window.InputService` with agnostic Gamepad / D-Pad / Axis support.
//!
//! Provides typed `KeyCode` (USB HID scancodes), `MouseButton`, `GamepadButton`
//! (including D-Pad, face buttons, bumpers, triggers, thumbsticks, touchpad),
//! `GamepadAxis`, `Gamepads`, generic `ButtonInput(T)`, plus
//! `AccumulatedMouseMotion` and `AccumulatedMouseScroll` updated in `.pre_update`.

const std = @import("std");
const engine = @import("engine");
const window = @import("window");

/// Module owner identifier for `official.input`.
pub const MODULE_OWNER_ID: u64 = 2017;

/// Capability identifier provided by `official.input`.
pub const CAPABILITY_ID = "engine.input.state";

/// Provider identifier for `official.input`.
pub const PROVIDER_ID = "official.input";

/// Maximum simultaneous gamepads tracked by `Gamepads`.
pub const MAX_GAMEPADS: usize = 4;

/// Physical keyboard key codes aligned with USB HID / SDL3 scancodes (`0..255`).
pub const KeyCode = enum(u8) {
    key_a = 4,
    key_b = 5,
    key_c = 6,
    key_d = 7,
    key_e = 8,
    key_f = 9,
    key_g = 10,
    key_h = 11,
    key_i = 12,
    key_j = 13,
    key_k = 14,
    key_l = 15,
    key_m = 16,
    key_n = 17,
    key_o = 18,
    key_p = 19,
    key_q = 20,
    key_r = 21,
    key_s = 22,
    key_t = 23,
    key_u = 24,
    key_v = 25,
    key_w = 26,
    key_x = 27,
    key_y = 28,
    key_z = 29,

    digit_1 = 30,
    digit_2 = 31,
    digit_3 = 32,
    digit_4 = 33,
    digit_5 = 34,
    digit_6 = 35,
    digit_7 = 36,
    digit_8 = 37,
    digit_9 = 38,
    digit_0 = 39,

    enter = 40,
    escape = 41,
    backspace = 42,
    tab = 43,
    space = 44,

    f1 = 58,
    f2 = 59,
    f3 = 60,
    f4 = 61,
    f5 = 62,
    f6 = 63,
    f7 = 64,
    f8 = 65,
    f9 = 66,
    f10 = 67,
    f11 = 68,
    f12 = 69,

    home = 74,
    page_up = 75,
    delete = 76,
    end = 77,
    page_down = 78,
    arrow_right = 79,
    arrow_left = 80,
    arrow_down = 81,
    arrow_up = 82,

    control_left = 224,
    shift_left = 225,
    alt_left = 226,
    super_left = 227,
    control_right = 228,
    shift_right = 229,
    alt_right = 230,
    super_right = 231,
};

/// Mouse button identifiers matching `window.MouseButton`.
pub const MouseButton = enum(u8) {
    left = 0,
    right = 1,
    middle = 2,
};

/// Agnostic gamepad digital buttons (Xbox / PlayStation DualSense compatible).
pub const GamepadButton = enum(u8) {
    south = 0, // Cross (PS5) / A (Xbox)
    east = 1, // Circle (PS5) / B (Xbox)
    west = 2, // Square (PS5) / X (Xbox)
    north = 3, // Triangle (PS5) / Y (Xbox)
    select = 4, // Create / Share / Back
    mode = 5, // PS / Guide
    start = 6, // Options / Start
    left_thumb = 7, // L3
    right_thumb = 8, // R3
    left_bumper = 9, // L1 / LB
    right_bumper = 10, // R1 / RB
    dpad_up = 11,
    dpad_down = 12,
    dpad_left = 13,
    dpad_right = 14,
    touchpad = 15, // DualSense touchpad click
    left_trigger = 16, // L2 digital threshold
    right_trigger = 17, // R2 digital threshold
};

/// Agnostic gamepad analog axes (`[-1..1]` for sticks, `[0..1]` for triggers).
pub const GamepadAxis = enum(u8) {
    left_stick_x = 0,
    left_stick_y = 1,
    right_stick_x = 2,
    right_stick_y = 3,
    left_z = 4, // L2 analog
    right_z = 5, // R2 analog
};

/// Generic per-frame button state tracker (`pressed`, `justPressed`, `justReleased`),
/// inspired by `bevy_input::ButtonInput<T>`.
pub fn ButtonInput(comptime T: type) type {
    const cap: usize = if (T == KeyCode) 256 else std.enums.values(T).len;
    return struct {
        const Self = @This();

        down: [cap]bool = @splat(false),
        just_pressed: [cap]bool = @splat(false),
        just_released: [cap]bool = @splat(false),

        /// Clears single-frame `just_pressed` and `just_released` flags.
        pub fn beginFrame(self: *Self) void {
            @memset(&self.just_pressed, false);
            @memset(&self.just_released, false);
        }

        /// Records a press transition for `item`.
        pub fn press(self: *Self, item: T) void {
            const idx: usize = @intFromEnum(item);
            if (idx >= cap) return;
            if (!self.down[idx]) self.just_pressed[idx] = true;
            self.down[idx] = true;
        }

        /// Records a release transition for `item`.
        pub fn release(self: *Self, item: T) void {
            const idx: usize = @intFromEnum(item);
            if (idx >= cap) return;
            if (self.down[idx]) self.just_released[idx] = true;
            self.down[idx] = false;
        }

        /// Synchronizes `down` state for `item` from an external boolean source.
        pub fn setDown(self: *Self, item: T, is_down: bool) void {
            if (is_down) self.press(item) else self.release(item);
        }

        /// Returns `true` while `item` is held down.
        pub fn pressed(self: *const Self, item: T) bool {
            const idx: usize = @intFromEnum(item);
            return idx < cap and self.down[idx];
        }

        /// Returns `true` on the frame `item` transitioned from up to down.
        pub fn justPressed(self: *const Self, item: T) bool {
            const idx: usize = @intFromEnum(item);
            return idx < cap and self.just_pressed[idx];
        }

        /// Returns `true` on the frame `item` transitioned from down to up.
        pub fn justReleased(self: *const Self, item: T) bool {
            const idx: usize = @intFromEnum(item);
            return idx < cap and self.just_released[idx];
        }

        /// Returns `true` if any item in `items` is currently held down.
        pub fn anyPressed(self: *const Self, items: []const T) bool {
            for (items) |item| {
                if (self.pressed(item)) return true;
            }
            return false;
        }

        /// Returns `true` if any item in `items` was just pressed this frame.
        pub fn anyJustPressed(self: *const Self, items: []const T) bool {
            for (items) |item| {
                if (self.justPressed(item)) return true;
            }
            return false;
        }
    };
}

/// Resource alias for keyboard `ButtonInput(KeyCode)`.
pub const KeyInput = ButtonInput(KeyCode);

/// Resource alias for mouse `ButtonInput(MouseButton)`.
pub const MouseInput = ButtonInput(MouseButton);

/// Resource alias for gamepad `ButtonInput(GamepadButton)`.
pub const GamepadButtonInput = ButtonInput(GamepadButton);

/// Normalized finger contact on a controller touchpad (e.g., PS5 DualSense central touchpad).
pub const TouchpadFinger = struct {
    down: bool = false,
    x: f32 = 0.0,
    y: f32 = 0.0,
    pressure: f32 = 0.0,
};

/// State of a single connected or virtual gamepad slot.
pub const GamepadState = struct {
    connected: bool = false,
    instance_id: u32 = 0,
    name_buf: [96]u8 = @splat(0),
    name_len: usize = 0,
    buttons: GamepadButtonInput = .{},
    axes: [6]f32 = @splat(0.0),
    deadzone: f32 = 0.12,
    touchpad_fingers: [2]TouchpadFinger = @splat(.{}),
    touchpad_finger_count: u8 = 0,

    /// Returns the controller display name (e.g., `"DualSense Wireless Controller"`).
    pub fn name(self: *const GamepadState) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    /// Sets the controller display name.
    pub fn setName(self: *GamepadState, label: []const u8) void {
        const n = @min(label.len, self.name_buf.len);
        @memcpy(self.name_buf[0..n], label[0..n]);
        self.name_len = n;
    }

    /// Returns `true` while `btn` is held down.
    pub fn pressed(self: *const GamepadState, btn: GamepadButton) bool {
        return self.buttons.pressed(btn);
    }

    /// Returns `true` on the frame `btn` was pressed.
    pub fn justPressed(self: *const GamepadState, btn: GamepadButton) bool {
        return self.buttons.justPressed(btn);
    }

    /// Returns `true` on the frame `btn` was released.
    pub fn justReleased(self: *const GamepadState, btn: GamepadButton) bool {
        return self.buttons.justReleased(btn);
    }

    /// Returns deadzone-filtered analog axis value.
    pub fn axis(self: *const GamepadState, ax: GamepadAxis) f32 {
        const v = self.axes[@intFromEnum(ax)];
        return if (@abs(v) < self.deadzone) 0.0 else v;
    }

    /// Returns deadzone-filtered `[x, y]` for the left analog stick.
    pub fn leftStick(self: *const GamepadState) [2]f32 {
        return .{ self.axis(.left_stick_x), self.axis(.left_stick_y) };
    }

    /// Returns deadzone-filtered `[x, y]` for the right analog stick.
    pub fn rightStick(self: *const GamepadState) [2]f32 {
        return .{ self.axis(.right_stick_x), self.axis(.right_stick_y) };
    }

    /// Returns D-Pad vector `[x, y]` in `[-1..1]`.
    pub fn dpad(self: *const GamepadState) [2]f32 {
        var x: f32 = 0.0;
        var y: f32 = 0.0;
        if (self.pressed(.dpad_left)) x -= 1.0;
        if (self.pressed(.dpad_right)) x += 1.0;
        if (self.pressed(.dpad_up)) y += 1.0;
        if (self.pressed(.dpad_down)) y -= 1.0;
        return .{ x, y };
    }

    /// Returns the active touchpad finger at `idx` (`0..1`), or `null` if not touching.
    pub fn touchpadFinger(self: *const GamepadState, idx: usize) ?TouchpadFinger {
        if (idx >= self.touchpad_fingers.len) return null;
        const f = self.touchpad_fingers[idx];
        return if (f.down) f else null;
    }
};

/// VTable implemented by optional hardware gamepad providers (e.g., `official.input.sdl3`).
pub const GamepadBackendVTable = struct {
    ctx: ?*anyopaque = null,
    pollFn: *const fn (ctx: ?*anyopaque, gamepads: *Gamepads) void,
};

/// Resource managing up to `MAX_GAMEPADS` connected or simulated gamepads.
pub const Gamepads = struct {
    slots: [MAX_GAMEPADS]GamepadState = @splat(.{}),
    backend: ?GamepadBackendVTable = null,

    /// Registers a hardware gamepad polling backend.
    pub fn setBackend(self: *Gamepads, backend: ?GamepadBackendVTable) void {
        self.backend = backend;
    }

    /// Returns the slot for `idx` if valid and connected.
    pub fn get(self: *const Gamepads, idx: usize) ?*const GamepadState {
        if (idx >= MAX_GAMEPADS or !self.slots[idx].connected) return null;
        return &self.slots[idx];
    }

    /// Returns the first connected gamepad slot, if any.
    pub fn firstConnected(self: *const Gamepads) ?*const GamepadState {
        for (&self.slots) |*s| {
            if (s.connected) return s;
        }
        return null;
    }

    /// Returns the number of currently connected gamepads.
    pub fn connectedCount(self: *const Gamepads) usize {
        var n: usize = 0;
        for (self.slots) |s| {
            if (s.connected) n += 1;
        }
        return n;
    }
};

/// Accumulated mouse pointer movement delta for the current frame.
pub const AccumulatedMouseMotion = struct {
    delta: [2]f32 = .{ 0.0, 0.0 },
    position: [2]f32 = .{ 0.0, 0.0 },
};

/// Accumulated mouse wheel scroll delta for the current frame.
pub const AccumulatedMouseScroll = struct {
    delta: [2]f32 = .{ 0.0, 0.0 },
};

/// Service (`engine.input.state/1`) holding pointers to the active input resources.
pub const BevyInputService = struct {
    keys: *KeyInput,
    mouse: *MouseInput,
    motion: *AccumulatedMouseMotion,
    scroll: *AccumulatedMouseScroll,
    gamepads: *Gamepads,
    win_input: ?*const window.InputService = null,
};

/// `.pre_update` system that synchronizes `KeyInput`, `MouseInput`,
/// `AccumulatedMouseMotion`, `AccumulatedMouseScroll`, and `Gamepads`.
pub fn syncInputSystem(ctx: *engine.SystemContext) !void {
    const svc = ctx.resources.get(BevyInputService) orelse return;
    const keys = svc.keys;
    const mouse = svc.mouse;
    const motion = svc.motion;
    const scroll = svc.scroll;

    keys.beginFrame();
    mouse.beginFrame();
    for (&svc.gamepads.slots) |*slot| {
        slot.buttons.beginFrame();
    }

    if (svc.gamepads.backend) |be| {
        be.pollFn(be.ctx, svc.gamepads);
    }

    const win_input = svc.win_input orelse return;

    for (std.enums.values(KeyCode)) |kc| {
        keys.setDown(kc, win_input.isKeyDown(@intFromEnum(kc)));
    }

    mouse.setDown(.left, win_input.isMouseDown(.left));
    mouse.setDown(.right, win_input.isMouseDown(.right));
    mouse.setDown(.middle, win_input.isMouseDown(.middle));

    motion.delta = .{ win_input.mouse_delta_x, win_input.mouse_delta_y };
    motion.position = .{ win_input.mouse_x, win_input.mouse_y };
    scroll.delta = .{ win_input.scroll_x, win_input.scroll_y };
}

fn buildModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    try app.resources.insert(KeyInput, .{});
    try app.resources.insert(MouseInput, .{});
    try app.resources.insert(AccumulatedMouseMotion, .{});
    try app.resources.insert(AccumulatedMouseScroll, .{});
    try app.resources.insert(Gamepads, .{});

    const win_entry = try app.services.getService("engine.input", 1);
    const win_input: *const window.InputService = @ptrCast(@alignCast(win_entry.api_ptr));

    try app.resources.insert(BevyInputService, .{
        .keys = app.resources.get(KeyInput).?,
        .mouse = app.resources.get(MouseInput).?,
        .motion = app.resources.get(AccumulatedMouseMotion).?,
        .scroll = app.resources.get(AccumulatedMouseScroll).?,
        .gamepads = app.resources.get(Gamepads).?,
        .win_input = win_input,
    });
    const svc = app.resources.get(BevyInputService).?;

    try app.services.register(.{
        .capability = CAPABILITY_ID,
        .major_version = 1,
        .provider_id = PROVIDER_ID,
        .owner_id = MODULE_OWNER_ID,
        .exclusive = true,
        .api_ptr = svc,
        .api_size = @sizeOf(BevyInputService),
    });

    try app.scheduler.addSystem(.{
        .name = "input.sync",
        .stage = .pre_update,
        .run = syncInputSystem,
    });
}

fn stopModule(raw_app: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    _ = app.services.unregisterByOwner(MODULE_OWNER_ID);
    _ = app.resources.remove(BevyInputService);
    _ = app.resources.remove(Gamepads);
    _ = app.resources.remove(AccumulatedMouseScroll);
    _ = app.resources.remove(AccumulatedMouseMotion);
    _ = app.resources.remove(MouseInput);
    _ = app.resources.remove(KeyInput);
}

/// Returns the `official.input` module descriptor.
pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = PROVIDER_ID,
            .version = "0.2.0",
            .provides_capabilities = &.{"engine.input.state/1"},
            .required_capabilities = &.{"engine.input/1"},
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
