//! Per-script hook bookkeeping for `zengy-runtime` (pure logic, unit tested).
//!
//! Optional script hooks (`fixed_update`, `update`, `destroy`) that the script does not define are
//! looked up once and then skipped, and a script error that repeats every frame is reported once
//! (then every `repeat_log_interval` repeats) instead of flooding the log and costing a formatted
//! write per frame.

const std = @import("std");

pub const Hook = enum(u8) { start, fixed_update, update, destroy };

pub const HookTracker = struct {
    /// Report an unchanged repeating error again after this many occurrences.
    pub const repeat_log_interval: u32 = 600;

    missing: [4]bool = @splat(false),
    last_error: [160]u8 = undefined,
    last_len: usize = 0,
    repeats: u32 = 0,

    /// False once the hook was found to be undefined.
    pub fn shouldCall(self: *const HookTracker, hook: Hook) bool {
        return !self.missing[@intFromEnum(hook)];
    }

    pub fn markMissing(self: *HookTracker, hook: Hook) void {
        self.missing[@intFromEnum(hook)] = true;
    }

    /// Forget missing-hook knowledge (call after the script is reloaded).
    pub fn reset(self: *HookTracker) void {
        self.* = .{};
    }

    /// Records a script error; returns true when it should be printed (first occurrence, a changed
    /// message, or every `repeat_log_interval`-th repeat).
    pub fn recordError(self: *HookTracker, message: []const u8) bool {
        const n = @min(message.len, self.last_error.len);
        if (self.last_len == n and std.mem.eql(u8, self.last_error[0..n], message[0..n])) {
            self.repeats += 1;
            return self.repeats % repeat_log_interval == 0;
        }
        @memcpy(self.last_error[0..n], message[0..n]);
        self.last_len = n;
        self.repeats = 0;
        return true;
    }

    /// A successful call clears the error so a later recurrence is reported again.
    pub fn recordSuccess(self: *HookTracker) void {
        self.last_len = 0;
        self.repeats = 0;
    }
};

test "missing hooks are skipped after the first miss and reset on reload" {
    var t: HookTracker = .{};
    try std.testing.expect(t.shouldCall(.update));
    t.markMissing(.update);
    try std.testing.expect(!t.shouldCall(.update));
    try std.testing.expect(t.shouldCall(.fixed_update));
    t.reset();
    try std.testing.expect(t.shouldCall(.update));
}

test "repeating script errors are logged once, then periodically, and again after recovery" {
    var t: HookTracker = .{};
    try std.testing.expect(t.recordError("attempt to index nil"));
    var printed: u32 = 0;
    for (0..1199) |_| {
        if (t.recordError("attempt to index nil")) printed += 1;
    }
    try std.testing.expectEqual(@as(u32, 1), printed); // repeats 600 only (1199 repeats => 1 hit at 600)
    try std.testing.expect(t.recordError("a different error"));
    t.recordSuccess();
    try std.testing.expect(t.recordError("a different error"));
}
