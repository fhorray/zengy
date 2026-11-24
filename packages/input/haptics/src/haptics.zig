//! Agnostic Haptics & Rumble contract (`official.input.haptics`).
//!
//! Provides `HapticService` (`engine.input.haptics/1`) and `HapticBackendVTable`
//! for controller rumble and adaptive trigger rumble (e.g., PS5 DualSense),
//! running deterministically in headless tests when no hardware backend is attached.

const std = @import("std");
const engine = @import("engine");

/// Module owner identifier for `official.input.haptics`.
pub const MODULE_OWNER_ID: u64 = 2018;

/// Capability identifier provided by `official.input.haptics`.
pub const CAPABILITY_ID = "engine.input.haptics";

/// Provider identifier for `official.input.haptics`.
pub const PROVIDER_ID = "official.input.haptics";

/// Target trigger side for adaptive trigger effects.
pub const TriggerSide = enum {
    left,
    right,
    both,
};

/// Agnostic adaptive trigger effect profile (e.g., PS5 DualSense L2/R2 motors).
pub const AdaptiveTriggerEffect = union(enum) {
    /// Releases trigger resistance.
    off,
    /// Continuous resistance starting at `start_position` (`0..1`) with `strength` (`0..1`).
    feedback: struct {
        start_position: f32 = 0.0,
        strength: f32 = 1.0,
    },
    /// Weapon-like wall between `start_position` and `end_position` (`0..1`) with `strength` (`0..1`).
    weapon: struct {
        start_position: f32 = 0.25,
        end_position: f32 = 0.65,
        strength: f32 = 1.0,
    },
    /// Rapid oscillating vibration starting at `start_position` (`0..1`).
    vibration: struct {
        start_position: f32 = 0.15,
        amplitude: f32 = 0.8,
        frequency_hz: u8 = 24,
    },
};

/// Dispatched haptic command record (useful for diagnostics and headless tests).
pub const HapticRequest = union(enum) {
    rumble: struct {
        gamepad_slot: usize,
        low_frequency: f32,
        high_frequency: f32,
        duration_ms: u32,
    },
    trigger_rumble: struct {
        gamepad_slot: usize,
        left_trigger: f32,
        right_trigger: f32,
        duration_ms: u32,
    },
    adaptive_trigger: struct {
        gamepad_slot: usize,
        side: TriggerSide,
        effect: AdaptiveTriggerEffect,
    },
    stop: struct {
        gamepad_slot: usize,
    },
};

/// VTable implemented by hardware haptic providers (e.g., `official.input.sdl3`).
pub const HapticBackendVTable = struct {
    ctx: ?*anyopaque = null,
    rumbleFn: *const fn (ctx: ?*anyopaque, slot: usize, low_freq: f32, high_freq: f32, duration_ms: u32) bool,
    triggerRumbleFn: *const fn (ctx: ?*anyopaque, slot: usize, left_trig: f32, right_trig: f32, duration_ms: u32) bool,
    setAdaptiveTriggerFn: ?*const fn (ctx: ?*anyopaque, slot: usize, side: TriggerSide, effect: AdaptiveTriggerEffect) bool = null,
    stopFn: *const fn (ctx: ?*anyopaque, slot: usize) void,
};

/// Service (`engine.input.haptics/1`) routing rumble and trigger haptic requests.
pub const HapticService = struct {
    backend: ?HapticBackendVTable = null,
    dispatched_count: usize = 0,
    last_request: ?HapticRequest = null,

    /// Registers a hardware haptic backend.
    pub fn setBackend(self: *HapticService, backend: ?HapticBackendVTable) void {
        self.backend = backend;
    }

    /// Triggers dual-motor rumble (`0.0..1.0`) for `duration_ms` on `gamepad_slot`.
    pub fn playRumble(self: *HapticService, gamepad_slot: usize, low_freq: f32, high_freq: f32, duration_ms: u32) bool {
        const lo = std.math.clamp(low_freq, 0.0, 1.0);
        const hi = std.math.clamp(high_freq, 0.0, 1.0);
        self.dispatched_count += 1;
        self.last_request = .{ .rumble = .{
            .gamepad_slot = gamepad_slot,
            .low_frequency = lo,
            .high_frequency = hi,
            .duration_ms = duration_ms,
        } };
        if (self.backend) |be| {
            return be.rumbleFn(be.ctx, gamepad_slot, lo, hi, duration_ms);
        }
        return true;
    }

    /// Triggers L2/R2 trigger rumble (`0.0..1.0`) for `duration_ms` on `gamepad_slot`.
    pub fn playTriggerRumble(self: *HapticService, gamepad_slot: usize, left_trig: f32, right_trig: f32, duration_ms: u32) bool {
        const l = std.math.clamp(left_trig, 0.0, 1.0);
        const r = std.math.clamp(right_trig, 0.0, 1.0);
        self.dispatched_count += 1;
        self.last_request = .{ .trigger_rumble = .{
            .gamepad_slot = gamepad_slot,
            .left_trigger = l,
            .right_trigger = r,
            .duration_ms = duration_ms,
        } };
        if (self.backend) |be| {
            return be.triggerRumbleFn(be.ctx, gamepad_slot, l, r, duration_ms);
        }
        return true;
    }

    /// Applies an adaptive trigger resistance/vibration profile on `gamepad_slot`.
    pub fn setAdaptiveTrigger(
        self: *HapticService,
        gamepad_slot: usize,
        side: TriggerSide,
        effect: AdaptiveTriggerEffect,
    ) bool {
        const clamped: AdaptiveTriggerEffect = switch (effect) {
            .off => .off,
            .feedback => |f| .{ .feedback = .{
                .start_position = std.math.clamp(f.start_position, 0.0, 1.0),
                .strength = std.math.clamp(f.strength, 0.0, 1.0),
            } },
            .weapon => |w| .{ .weapon = .{
                .start_position = std.math.clamp(w.start_position, 0.0, 1.0),
                .end_position = std.math.clamp(w.end_position, 0.0, 1.0),
                .strength = std.math.clamp(w.strength, 0.0, 1.0),
            } },
            .vibration => |v| .{ .vibration = .{
                .start_position = std.math.clamp(v.start_position, 0.0, 1.0),
                .amplitude = std.math.clamp(v.amplitude, 0.0, 1.0),
                .frequency_hz = v.frequency_hz,
            } },
        };
        self.dispatched_count += 1;
        self.last_request = .{ .adaptive_trigger = .{
            .gamepad_slot = gamepad_slot,
            .side = side,
            .effect = clamped,
        } };
        if (self.backend) |be| {
            if (be.setAdaptiveTriggerFn) |fn_ptr| {
                return fn_ptr(be.ctx, gamepad_slot, side, clamped);
            }
            return false;
        }
        return true;
    }

    /// Stops active rumble on `gamepad_slot`.
    pub fn stop(self: *HapticService, gamepad_slot: usize) void {
        self.dispatched_count += 1;
        self.last_request = .{ .stop = .{ .gamepad_slot = gamepad_slot } };
        if (self.backend) |be| {
            be.stopFn(be.ctx, gamepad_slot);
        }
    }
};

fn buildModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    try app.resources.insert(HapticService, .{});
    const svc = app.resources.get(HapticService).?;

    try app.services.register(.{
        .capability = CAPABILITY_ID,
        .major_version = 1,
        .provider_id = PROVIDER_ID,
        .owner_id = MODULE_OWNER_ID,
        .exclusive = true,
        .api_ptr = svc,
        .api_size = @sizeOf(HapticService),
    });
}

fn stopModule(raw_app: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    _ = app.services.unregisterByOwner(MODULE_OWNER_ID);
    _ = app.resources.remove(HapticService);
}

/// Returns the `official.input.haptics` module descriptor.
pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = PROVIDER_ID,
            .version = "0.1.0",
            .provides_capabilities = &.{"engine.input.haptics/1"},
            .required_capabilities = &.{},
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
