//! Developer Tools & Per-Pass Frame Profiler (`official.dev_tools`).
//!
//! Provides a backend-agnostic `FrameProfilerService` (`engine.dev_tools.profiler/1`)
//! that tracks per-pass GPU/CPU timings (`Shadow`, `SSAO`, `Volumetric`, `Forward+`,
//! `Bloom`, `PostFX`, `Gizmos`, `UI`) and rolling frame history for editor tooling
//! and `remote` inspection.

const std = @import("std");
const engine = @import("engine");

/// Owner ID used when registering `official.dev_tools` services.
pub const MODULE_OWNER_ID: u64 = 2042;

/// Maximum number of render passes recorded per frame.
pub const MAX_PASSES: usize = 24;

/// Number of recent frame durations retained in the rolling history buffer.
pub const HISTORY_CAP: usize = 120;

/// Logical render pass category for grouping and summary metrics.
pub const PassCategory = enum(u8) {
    shadow = 0,
    ssao = 1,
    volumetric = 2,
    forward_plus = 3,
    bloom = 4,
    postfx = 5,
    gizmos = 6,
    ui = 7,
    other = 8,
};

/// Single pass timing entry for one frame.
pub const PassTiming = struct {
    name: [32]u8 = @splat(0),
    name_len: u8 = 0,
    category: PassCategory = .other,
    duration_ms: f64 = 0.0,
    ema_ms: f64 = 0.0,

    /// Returns the pass name as a slice.
    pub fn nameSlice(self: *const PassTiming) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Snapshot of all pass timings for one completed frame.
pub const FrameTimingSnapshot = struct {
    frame_index: u64 = 0,
    total_ms: f64 = 0.0,
    passes: [MAX_PASSES]PassTiming = @splat(.{}),
    pass_count: usize = 0,

    /// Returns the recorded passes for this frame.
    pub fn passSlice(self: *const FrameTimingSnapshot) []const PassTiming {
        return self.passes[0..self.pass_count];
    }
};

/// Collects per-pass timings and rolling frame-time metrics.
pub const FrameProfilerService = struct {
    enabled: bool = true,
    frame_active: bool = false,
    frame_start_ns: u64 = 0,
    frame_counter: u64 = 0,
    current_passes: [MAX_PASSES]PassTiming = @splat(.{}),
    current_pass_count: usize = 0,
    latest_snapshot: FrameTimingSnapshot = .{},
    history: [HISTORY_CAP]f64 = @splat(0.0),
    history_head: usize = 0,
    history_len: usize = 0,
    ema_total_ms: f64 = 0.0,
    ema_by_category: [9]f64 = @splat(0.0),

    /// Starts a new profiling frame at `now_ns`.
    pub fn beginFrame(self: *FrameProfilerService, now_ns: u64) void {
        if (!self.enabled) return;
        self.frame_active = true;
        self.frame_start_ns = now_ns;
        self.current_pass_count = 0;
    }

    /// Records a render pass duration in nanoseconds under `name` and `category`.
    pub fn recordPass(self: *FrameProfilerService, name: []const u8, category: PassCategory, duration_ns: u64) void {
        if (!self.enabled or self.current_pass_count >= MAX_PASSES) return;
        const ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
        const cat_idx = @intFromEnum(category);
        const prev_ema = self.ema_by_category[cat_idx];
        const next_ema = if (self.frame_counter == 0 or prev_ema == 0.0) ms else (prev_ema * 0.9 + ms * 0.1);
        self.ema_by_category[cat_idx] = next_ema;

        var entry = PassTiming{
            .category = category,
            .duration_ms = ms,
            .ema_ms = next_ema,
        };
        const copy_len = @min(name.len, entry.name.len);
        @memcpy(entry.name[0..copy_len], name[0..copy_len]);
        entry.name_len = @intCast(copy_len);

        self.current_passes[self.current_pass_count] = entry;
        self.current_pass_count += 1;
    }

    /// Finalizes the active frame at `now_ns` and publishes `latest_snapshot`.
    pub fn endFrame(self: *FrameProfilerService, now_ns: u64) void {
        if (!self.enabled or !self.frame_active) return;
        self.frame_active = false;
        self.frame_counter += 1;

        const total_ns: u64 = if (now_ns >= self.frame_start_ns) now_ns - self.frame_start_ns else 0;
        var total_ms: f64 = @as(f64, @floatFromInt(total_ns)) / 1_000_000.0;
        if (total_ms == 0.0 and self.current_pass_count > 0) {
            var sum_ms: f64 = 0.0;
            for (self.current_passes[0..self.current_pass_count]) |p| sum_ms += p.duration_ms;
            total_ms = sum_ms;
        }

        self.ema_total_ms = if (self.frame_counter == 1) total_ms else (self.ema_total_ms * 0.9 + total_ms * 0.1);
        self.history[self.history_head] = total_ms;
        self.history_head = (self.history_head + 1) % HISTORY_CAP;
        if (self.history_len < HISTORY_CAP) self.history_len += 1;

        self.latest_snapshot = .{
            .frame_index = self.frame_counter,
            .total_ms = total_ms,
            .passes = self.current_passes,
            .pass_count = self.current_pass_count,
        };
    }

    /// Returns the pass timings from the most recently completed frame.
    pub fn latestPasses(self: *const FrameProfilerService) []const PassTiming {
        return self.latest_snapshot.passSlice();
    }

    /// Returns the smoothed total frame duration in milliseconds.
    pub fn totalFrameMs(self: *const FrameProfilerService) f64 {
        return if (self.ema_total_ms > 0.0) self.ema_total_ms else self.latest_snapshot.total_ms;
    }

    /// Returns estimated frames per second from the smoothed frame duration.
    pub fn fps(self: *const FrameProfilerService) f64 {
        const ms = self.totalFrameMs();
        if (ms <= 1e-6) return 0.0;
        return 1000.0 / ms;
    }

    /// Returns the smoothed duration (ms) for a specific `PassCategory`.
    pub fn passMs(self: *const FrameProfilerService, category: PassCategory) f64 {
        return self.ema_by_category[@intFromEnum(category)];
    }

    /// Clears recorded pass history and counters.
    pub fn reset(self: *FrameProfilerService) void {
        self.frame_active = false;
        self.frame_counter = 0;
        self.current_pass_count = 0;
        self.latest_snapshot = .{};
        @memset(&self.history, 0.0);
        self.history_head = 0;
        self.history_len = 0;
        self.ema_total_ms = 0.0;
        @memset(&self.ema_by_category, 0.0);
    }
};

fn buildModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    try app.resources.insert(FrameProfilerService, .{});
    const svc = app.resources.get(FrameProfilerService).?;
    try app.services.register(.{
        .capability = "engine.dev_tools.profiler",
        .major_version = 1,
        .provider_id = "official.dev_tools",
        .owner_id = MODULE_OWNER_ID,
        .exclusive = true,
        .api_ptr = svc,
        .api_size = @sizeOf(FrameProfilerService),
    });
}

fn stopModule(raw_app: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    _ = app.services.unregisterByOwner(MODULE_OWNER_ID);
    _ = app.resources.remove(FrameProfilerService);
}

/// Returns the `official.dev_tools` module descriptor.
pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = "official.dev_tools",
            .version = "0.1.0",
            .provides_capabilities = &.{"engine.dev_tools.profiler/1"},
            .required_capabilities = &.{},
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
