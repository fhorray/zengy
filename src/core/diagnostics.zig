//! Structured Diagnostics Subsystem (`core/diagnostics`).
//!
//! Provides a bounded ring-buffer log store and frame/profiler counters.
//! Finite retention ensures that long-running headless simulations or noisy plugins
//! cannot exhaust host memory via unbounded log accumulation.

const std = @import("std");

/// Severity levels for structured log records.
pub const LogLevel = enum(u32) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,
};

/// Single retained log entry owned by `Diagnostics`.
pub const LogRecord = struct {
    sequence: u64,
    level: LogLevel,
    subsystem: []const u8,
    message: []const u8,
};

/// Bounded ring-buffer logger and frame telemetry container.
pub const Diagnostics = struct {
    allocator: std.mem.Allocator,
    capacity: usize,
    entries: std.ArrayList(LogRecord),
    /// Index of the oldest entry once the ring buffer reaches `capacity`.
    head: usize,
    total_logs: u64,
    evicted_logs: u64,
    frame_count: u64,
    last_frame_ns: u64,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) Diagnostics {
        return .{
            .allocator = allocator,
            .capacity = if (capacity == 0) 1 else capacity,
            .entries = .empty,
            .head = 0,
            .total_logs = 0,
            .evicted_logs = 0,
            .frame_count = 0,
            .last_frame_ns = 0,
        };
    }

    pub fn deinit(self: *Diagnostics) void {
        for (self.entries.items) |rec| {
            self.allocator.free(rec.subsystem);
            self.allocator.free(rec.message);
        }
        self.entries.deinit(self.allocator);
    }

    /// Appends a log record, copying `subsystem` and `message`.
    /// When full, evicts the oldest record and increments `evicted_logs`.
    pub fn log(self: *Diagnostics, level: LogLevel, subsystem: []const u8, message: []const u8) !void {
        const sub_copy = try self.allocator.dupe(u8, subsystem);
        errdefer self.allocator.free(sub_copy);
        const msg_copy = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(msg_copy);

        self.total_logs += 1;
        const record = LogRecord{
            .sequence = self.total_logs,
            .level = level,
            .subsystem = sub_copy,
            .message = msg_copy,
        };

        if (self.entries.items.len < self.capacity) {
            try self.entries.append(self.allocator, record);
        } else {
            const old = self.entries.items[self.head];
            self.allocator.free(old.subsystem);
            self.allocator.free(old.message);
            self.entries.items[self.head] = record;
            self.head = (self.head + 1) % self.capacity;
            self.evicted_logs += 1;
        }
    }

    /// Returns the number of currently retained log records.
    pub fn count(self: *const Diagnostics) usize {
        return self.entries.items.len;
    }

    /// Returns the log record at chronological index `idx` (0 = oldest retained).
    pub fn get(self: *const Diagnostics, idx: usize) ?LogRecord {
        if (idx >= self.entries.items.len) return null;
        if (self.entries.items.len < self.capacity) {
            return self.entries.items[idx];
        }
        const physical = (self.head + idx) % self.capacity;
        return self.entries.items[physical];
    }

    /// Frees all retained records while keeping allocated ring capacity.
    pub fn clear(self: *Diagnostics) void {
        for (self.entries.items) |rec| {
            self.allocator.free(rec.subsystem);
            self.allocator.free(rec.message);
        }
        self.entries.clearRetainingCapacity();
        self.head = 0;
    }
};
