//! Frame & Simulation Timing (`core/time`).
//!
//! Provides Bevy-inspired `Time` resource, `Timer`, and `Stopwatch` utilities
//! with zero external dependencies.

const std = @import("std");

/// Core timing resource updated automatically on every `App.tick()` / `App.tickFixed()`.
pub const Time = struct {
    /// Unscaled duration of the current frame in seconds.
    raw_delta_s: f32 = 0.0,
    /// Scaled duration of the current frame in seconds (`0.0` while `paused` is true).
    delta_s: f32 = 0.0,
    /// Fixed timestep duration in seconds (`Scheduler.fixed_dt`).
    fixed_delta_s: f32 = 1.0 / 60.0,
    /// Total scaled elapsed simulation time in seconds.
    elapsed_s: f64 = 0.0,
    /// Total unscaled elapsed time in seconds.
    real_elapsed_s: f64 = 0.0,
    /// Multiplier applied to `raw_delta_s` to compute `delta_s`.
    time_scale: f32 = 1.0,
    /// When `true`, `delta_s` is `0.0` and `elapsed_s` does not advance.
    paused: bool = false,
    /// Number of frames/ticks advanced so far.
    frame_count: u64 = 0,

    /// Advances `Time` by `raw_dt` seconds and records `fixed_dt`.
    pub fn advance(self: *Time, raw_dt: f32, fixed_dt: f32) void {
        const clamped_raw = if (std.math.isFinite(raw_dt) and raw_dt > 0.0) raw_dt else 0.0;
        const scale = if (std.math.isFinite(self.time_scale) and self.time_scale >= 0.0) self.time_scale else 0.0;
        self.raw_delta_s = clamped_raw;
        self.fixed_delta_s = fixed_dt;
        self.real_elapsed_s += @as(f64, clamped_raw);
        if (self.paused) {
            self.delta_s = 0.0;
        } else {
            self.delta_s = clamped_raw * scale;
            self.elapsed_s += @as(f64, self.delta_s);
        }
        self.frame_count += 1;
    }
};

/// Tracks elapsed time with pause and reset support.
pub const Stopwatch = struct {
    elapsed_s: f32 = 0.0,
    paused: bool = false,

    /// Advances the stopwatch by `dt` seconds unless paused.
    pub fn tick(self: *Stopwatch, dt: f32) void {
        if (self.paused or !std.math.isFinite(dt) or dt <= 0.0) return;
        self.elapsed_s += dt;
    }

    /// Resets elapsed time to zero while preserving `paused`.
    pub fn reset(self: *Stopwatch) void {
        self.elapsed_s = 0.0;
    }
};

/// Behavior of a `Timer` when it reaches its target duration.
pub const TimerMode = enum {
    once,
    repeating,
};

/// Countdown/interval timer supporting `.once` and `.repeating` modes.
pub const Timer = struct {
    duration_s: f32,
    mode: TimerMode = .once,
    elapsed_s: f32 = 0.0,
    paused: bool = false,
    finished_flag: bool = false,
    times_finished_this_tick: u32 = 0,

    /// Creates a new `Timer` with `duration_s` and `mode`.
    pub fn init(duration_s: f32, mode: TimerMode) Timer {
        return .{
            .duration_s = @max(0.0, duration_s),
            .mode = mode,
        };
    }

    /// Advances the timer by `dt` seconds and updates completion state for this tick.
    pub fn tick(self: *Timer, dt: f32) void {
        self.times_finished_this_tick = 0;
        if (self.paused or !std.math.isFinite(dt) or dt <= 0.0) return;

        if (self.duration_s <= 0.0) {
            self.finished_flag = true;
            self.times_finished_this_tick = 1;
            return;
        }

        if (self.mode == .once and self.finished_flag) return;

        self.elapsed_s += dt;
        if (self.elapsed_s >= self.duration_s) {
            switch (self.mode) {
                .once => {
                    self.elapsed_s = self.duration_s;
                    self.finished_flag = true;
                    self.times_finished_this_tick = 1;
                },
                .repeating => {
                    const count: u32 = @intFromFloat(@floor(self.elapsed_s / self.duration_s));
                    self.elapsed_s = @mod(self.elapsed_s, self.duration_s);
                    self.finished_flag = true;
                    self.times_finished_this_tick = count;
                },
            }
        }
    }

    /// Returns `true` if the timer has reached its duration at least once since creation/reset.
    pub fn finished(self: *const Timer) bool {
        return self.finished_flag;
    }

    /// Returns `true` if the timer completed during the most recent `tick()`.
    pub fn justFinished(self: *const Timer) bool {
        return self.times_finished_this_tick > 0;
    }

    /// Returns how many times the timer completed during the most recent `tick()`.
    pub fn timesFinishedThisTick(self: *const Timer) u32 {
        return self.times_finished_this_tick;
    }

    /// Returns normalized progress in `[0.0, 1.0]`.
    pub fn fraction(self: *const Timer) f32 {
        if (self.duration_s <= 0.0) return if (self.finished_flag) 1.0 else 0.0;
        return std.math.clamp(self.elapsed_s / self.duration_s, 0.0, 1.0);
    }

    /// Resets elapsed time and completion flags while keeping `duration_s`, `mode`, and `paused`.
    pub fn reset(self: *Timer) void {
        self.elapsed_s = 0.0;
        self.finished_flag = false;
        self.times_finished_this_tick = 0;
    }
};
