//! SDL3 Gamepad & Haptics provider (`official.input.sdl3`).
//!
//! Feeds `official.input`'s `Gamepads` (`GamepadBackendVTable`) and
//! `official.input.haptics`'s `HapticService` (`HapticBackendVTable`) using
//! SDL3's `SDL_Gamepad` API (including PS5 DualSense D-Pad, touchpad, triggers,
//! and dual-motor / trigger rumble).

const std = @import("std");
const engine = @import("engine");
const input = @import("input");
const haptics = @import("input_haptics");
const c = @import("sdl3_c");

/// Module owner identifier for `official.input.sdl3`.
pub const MODULE_OWNER_ID: u64 = 2019;

/// Provider identifier for `official.input.sdl3`.
pub const PROVIDER_ID = "official.input.sdl3";

const SdlGamepadState = struct {
    handles: [input.MAX_GAMEPADS]?*c.SDL_Gamepad = @splat(null),
    instance_ids: [input.MAX_GAMEPADS]u32 = @splat(0),
    left_effects: [input.MAX_GAMEPADS]haptics.AdaptiveTriggerEffect = @splat(.off),
    right_effects: [input.MAX_GAMEPADS]haptics.AdaptiveTriggerEffect = @splat(.off),
    last_low_rumble: [input.MAX_GAMEPADS]u8 = @splat(0),
    last_high_rumble: [input.MAX_GAMEPADS]u8 = @splat(0),
    initialized_subsys: bool = false,

    fn closeAll(self: *SdlGamepadState) void {
        for (&self.handles, &self.instance_ids) |*h, *id| {
            if (h.*) |pad| {
                c.SDL_CloseGamepad(pad);
                h.* = null;
            }
            id.* = 0;
        }
    }
};

fn syncPadHandles(st: *SdlGamepadState) void {
    var count: c_int = 0;
    const ids_ptr = c.SDL_GetGamepads(&count);
    defer if (ids_ptr != null) c.SDL_free(@ptrCast(ids_ptr));

    const n: usize = if (ids_ptr != null and count > 0) @min(@as(usize, @intCast(count)), input.MAX_GAMEPADS) else 0;
    const ids: []const c.SDL_JoystickID = if (n > 0) ids_ptr[0..n] else &.{};

    // Close disconnected handles.
    for (0..input.MAX_GAMEPADS) |slot| {
        if (st.handles[slot] == null) continue;
        var still_present = false;
        for (ids) |jid| {
            if (jid == st.instance_ids[slot]) {
                still_present = true;
                break;
            }
        }
        if (!still_present) {
            c.SDL_CloseGamepad(st.handles[slot].?);
            st.handles[slot] = null;
            st.instance_ids[slot] = 0;
        }
    }

    // Open newly connected gamepads into free slots.
    for (ids) |jid| {
        var already_open = false;
        for (0..input.MAX_GAMEPADS) |slot| {
            if (st.handles[slot] != null and st.instance_ids[slot] == jid) {
                already_open = true;
                break;
            }
        }
        if (already_open) continue;

        for (0..input.MAX_GAMEPADS) |slot| {
            if (st.handles[slot] == null) {
                if (c.SDL_OpenGamepad(jid)) |pad| {
                    st.handles[slot] = pad;
                    st.instance_ids[slot] = jid;
                }
                break;
            }
        }
    }
}

fn normAxis(raw: i16) f32 {
    if (raw >= 0) return @as(f32, @floatFromInt(raw)) / 32767.0;
    return @as(f32, @floatFromInt(raw)) / 32768.0;
}

fn pollSdlGamepads(raw_ctx: ?*anyopaque, gamepads: *input.Gamepads) void {
    const st: *SdlGamepadState = @ptrCast(@alignCast(raw_ctx orelse return));
    c.SDL_UpdateGamepads();
    syncPadHandles(st);

    for (0..input.MAX_GAMEPADS) |slot| {
        const pad = st.handles[slot] orelse {
            gamepads.slots[slot].connected = false;
            gamepads.slots[slot].instance_id = 0;
            gamepads.slots[slot].name_len = 0;
            gamepads.slots[slot].axes = @splat(0.0);
            continue;
        };

        var g = &gamepads.slots[slot];
        g.connected = true;
        g.instance_id = st.instance_ids[slot];

        if (c.SDL_GetGamepadName(pad)) |cname| {
            g.setName(std.mem.span(cname));
        } else {
            g.setName("SDL3 Gamepad");
        }

        g.buttons.setDown(.south, c.SDL_GetGamepadButton(pad, c.SDL_GAMEPAD_BUTTON_SOUTH));
        g.buttons.setDown(.east, c.SDL_GetGamepadButton(pad, c.SDL_GAMEPAD_BUTTON_EAST));
        g.buttons.setDown(.west, c.SDL_GetGamepadButton(pad, c.SDL_GAMEPAD_BUTTON_WEST));
        g.buttons.setDown(.north, c.SDL_GetGamepadButton(pad, c.SDL_GAMEPAD_BUTTON_NORTH));
        g.buttons.setDown(.select, c.SDL_GetGamepadButton(pad, c.SDL_GAMEPAD_BUTTON_BACK));
        g.buttons.setDown(.mode, c.SDL_GetGamepadButton(pad, c.SDL_GAMEPAD_BUTTON_GUIDE));
        g.buttons.setDown(.start, c.SDL_GetGamepadButton(pad, c.SDL_GAMEPAD_BUTTON_START));
        g.buttons.setDown(.left_thumb, c.SDL_GetGamepadButton(pad, c.SDL_GAMEPAD_BUTTON_LEFT_STICK));
        g.buttons.setDown(.right_thumb, c.SDL_GetGamepadButton(pad, c.SDL_GAMEPAD_BUTTON_RIGHT_STICK));
        g.buttons.setDown(.left_bumper, c.SDL_GetGamepadButton(pad, c.SDL_GAMEPAD_BUTTON_LEFT_SHOULDER));
        g.buttons.setDown(.right_bumper, c.SDL_GetGamepadButton(pad, c.SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER));
        g.buttons.setDown(.dpad_up, c.SDL_GetGamepadButton(pad, c.SDL_GAMEPAD_BUTTON_DPAD_UP));
        g.buttons.setDown(.dpad_down, c.SDL_GetGamepadButton(pad, c.SDL_GAMEPAD_BUTTON_DPAD_DOWN));
        g.buttons.setDown(.dpad_left, c.SDL_GetGamepadButton(pad, c.SDL_GAMEPAD_BUTTON_DPAD_LEFT));
        g.buttons.setDown(.dpad_right, c.SDL_GetGamepadButton(pad, c.SDL_GAMEPAD_BUTTON_DPAD_RIGHT));
        g.buttons.setDown(.touchpad, c.SDL_GetGamepadButton(pad, c.SDL_GAMEPAD_BUTTON_TOUCHPAD));

        const lx = normAxis(c.SDL_GetGamepadAxis(pad, c.SDL_GAMEPAD_AXIS_LEFTX));
        const ly = -normAxis(c.SDL_GetGamepadAxis(pad, c.SDL_GAMEPAD_AXIS_LEFTY));
        const rx = normAxis(c.SDL_GetGamepadAxis(pad, c.SDL_GAMEPAD_AXIS_RIGHTX));
        const ry = -normAxis(c.SDL_GetGamepadAxis(pad, c.SDL_GAMEPAD_AXIS_RIGHTY));
        const lz = std.math.clamp(normAxis(c.SDL_GetGamepadAxis(pad, c.SDL_GAMEPAD_AXIS_LEFT_TRIGGER)), 0.0, 1.0);
        const rz = std.math.clamp(normAxis(c.SDL_GetGamepadAxis(pad, c.SDL_GAMEPAD_AXIS_RIGHT_TRIGGER)), 0.0, 1.0);

        g.axes[@intFromEnum(input.GamepadAxis.left_stick_x)] = lx;
        g.axes[@intFromEnum(input.GamepadAxis.left_stick_y)] = ly;
        g.axes[@intFromEnum(input.GamepadAxis.right_stick_x)] = rx;
        g.axes[@intFromEnum(input.GamepadAxis.right_stick_y)] = ry;
        g.axes[@intFromEnum(input.GamepadAxis.left_z)] = lz;
        g.axes[@intFromEnum(input.GamepadAxis.right_z)] = rz;

        g.buttons.setDown(.left_trigger, lz > 0.5);
        g.buttons.setDown(.right_trigger, rz > 0.5);

        g.touchpad_fingers = @splat(.{});
        g.touchpad_finger_count = 0;
        if (c.SDL_GetNumGamepadTouchpads(pad) > 0) {
            const max_f = @min(@as(usize, @intCast(@max(0, c.SDL_GetNumGamepadTouchpadFingers(pad, 0)))), 2);
            for (0..max_f) |fi| {
                var f_down: bool = false;
                var fx: f32 = 0.0;
                var fy: f32 = 0.0;
                var fp: f32 = 0.0;
                if (c.SDL_GetGamepadTouchpadFinger(pad, 0, @intCast(fi), &f_down, &fx, &fy, &fp)) {
                    g.touchpad_fingers[fi] = .{ .down = f_down, .x = fx, .y = fy, .pressure = fp };
                    if (f_down) g.touchpad_finger_count += 1;
                }
            }
        }
    }
}

fn toU16Intensity(v: f32) u16 {
    return @intFromFloat(std.math.clamp(v, 0.0, 1.0) * 65535.0);
}

fn sdlRumble(raw_ctx: ?*anyopaque, slot: usize, low_freq: f32, high_freq: f32, duration_ms: u32) bool {
    const st: *SdlGamepadState = @ptrCast(@alignCast(raw_ctx orelse return false));
    if (slot >= input.MAX_GAMEPADS) return false;
    const pad = st.handles[slot] orelse return false;
    st.last_low_rumble[slot] = @intFromFloat(std.math.clamp(low_freq, 0.0, 1.0) * 255.0);
    st.last_high_rumble[slot] = @intFromFloat(std.math.clamp(high_freq, 0.0, 1.0) * 255.0);
    return c.SDL_RumbleGamepad(pad, toU16Intensity(low_freq), toU16Intensity(high_freq), duration_ms);
}

fn sdlTriggerRumble(raw_ctx: ?*anyopaque, slot: usize, left_trig: f32, right_trig: f32, duration_ms: u32) bool {
    const st: *SdlGamepadState = @ptrCast(@alignCast(raw_ctx orelse return false));
    if (slot >= input.MAX_GAMEPADS) return false;
    const pad = st.handles[slot] orelse return false;
    return c.SDL_RumbleGamepadTriggers(pad, toU16Intensity(left_trig), toU16Intensity(right_trig), duration_ms);
}

fn encodeDs5TriggerEffect(eff: haptics.AdaptiveTriggerEffect, out_mode: *u8, out_params: *[10]u8) void {
    @memset(out_params, 0);
    switch (eff) {
        .off => {
            out_mode.* = 0x05;
        },
        .feedback => |f| {
            out_mode.* = 0x01;
            out_params[0] = @intFromFloat(std.math.clamp(f.start_position, 0.0, 1.0) * 255.0);
            out_params[1] = @intFromFloat(std.math.clamp(f.strength, 0.0, 1.0) * 255.0);
        },
        .weapon => |w| {
            out_mode.* = 0x02;
            out_params[0] = @intFromFloat(std.math.clamp(w.start_position, 0.0, 1.0) * 255.0);
            out_params[1] = @intFromFloat(std.math.clamp(w.end_position, 0.0, 1.0) * 255.0);
            out_params[2] = @intFromFloat(std.math.clamp(w.strength, 0.0, 1.0) * 255.0);
        },
        .vibration => |v| {
            out_mode.* = 0x06;
            out_params[0] = v.frequency_hz;
            out_params[1] = @intFromFloat(std.math.clamp(v.amplitude, 0.0, 1.0) * 255.0);
            out_params[2] = @intFromFloat(std.math.clamp(v.start_position, 0.0, 1.0) * 255.0);
        },
    }
}

fn sdlSetAdaptiveTrigger(
    raw_ctx: ?*anyopaque,
    slot: usize,
    side: haptics.TriggerSide,
    effect: haptics.AdaptiveTriggerEffect,
) bool {
    const st: *SdlGamepadState = @ptrCast(@alignCast(raw_ctx orelse return false));
    if (slot >= input.MAX_GAMEPADS) return false;
    const pad = st.handles[slot] orelse return false;
    if (c.SDL_GetGamepadType(pad) != c.SDL_GAMEPAD_TYPE_PS5) return false;

    const prev_l = st.left_effects[slot];
    const prev_r = st.right_effects[slot];
    if (side == .left or side == .both) st.left_effects[slot] = effect;
    if (side == .right or side == .both) st.right_effects[slot] = effect;
    if (std.meta.eql(prev_l, st.left_effects[slot]) and std.meta.eql(prev_r, st.right_effects[slot])) {
        return true;
    }

    // Standard 47-byte Sony DualSense DS5EffectsState payload for SDL_SendGamepadEffect.
    var payload: [47]u8 = @splat(0);
    payload[0] = 0x03 | 0x04 | 0x08; // Keep compatible rumble active + right/left trigger effects
    payload[2] = st.last_high_rumble[slot];
    payload[3] = st.last_low_rumble[slot];

    encodeDs5TriggerEffect(st.right_effects[slot], &payload[10], payload[11..21]);
    encodeDs5TriggerEffect(st.left_effects[slot], &payload[21], payload[22..32]);

    return c.SDL_SendGamepadEffect(pad, &payload, payload.len);
}

fn sdlStopRumble(raw_ctx: ?*anyopaque, slot: usize) void {
    _ = sdlRumble(raw_ctx, slot, 0.0, 0.0, 0);
    _ = sdlTriggerRumble(raw_ctx, slot, 0.0, 0.0, 0);
    _ = sdlSetAdaptiveTrigger(raw_ctx, slot, .both, .off);
}

fn attachSdl3HapticsSystem(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(SdlGamepadState) orelse return;
    if (ctx.resources.get(haptics.HapticService)) |hap| {
        if (hap.backend == null) {
            hap.setBackend(.{
                .ctx = st,
                .rumbleFn = sdlRumble,
                .triggerRumbleFn = sdlTriggerRumble,
                .setAdaptiveTriggerFn = sdlSetAdaptiveTrigger,
                .stopFn = sdlStopRumble,
            });
        }
    }
}

fn buildModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    _ = c.SDL_SetHint(c.SDL_HINT_JOYSTICK_HIDAPI_PS5, "1");
    const ok = c.SDL_InitSubSystem(c.SDL_INIT_GAMEPAD);
    try app.resources.insert(SdlGamepadState, .{ .initialized_subsys = ok });
    const st = app.resources.get(SdlGamepadState).?;

    if (app.resources.get(input.Gamepads)) |gps| {
        gps.setBackend(.{
            .ctx = st,
            .pollFn = pollSdlGamepads,
        });
    }
    if (app.resources.get(haptics.HapticService)) |hap| {
        hap.setBackend(.{
            .ctx = st,
            .rumbleFn = sdlRumble,
            .triggerRumbleFn = sdlTriggerRumble,
            .setAdaptiveTriggerFn = sdlSetAdaptiveTrigger,
            .stopFn = sdlStopRumble,
        });
    }
    try app.scheduler.addSystem(.{
        .name = "input_sdl3.attach_haptics",
        .stage = .startup,
        .run = attachSdl3HapticsSystem,
    });
}

fn stopModule(raw_app: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    if (app.resources.get(input.Gamepads)) |gps| gps.setBackend(null);
    if (app.resources.get(haptics.HapticService)) |hap| hap.setBackend(null);
    if (app.resources.get(SdlGamepadState)) |st| {
        st.closeAll();
        if (st.initialized_subsys) c.SDL_QuitSubSystem(c.SDL_INIT_GAMEPAD);
    }
    _ = app.resources.remove(SdlGamepadState);
}

/// Returns the `official.input.sdl3` module descriptor.
pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = PROVIDER_ID,
            .version = "0.1.0",
            .provides_capabilities = &.{"engine.input.gamepad_provider/1"},
            .required_capabilities = &.{"engine.input.state/1"},
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
