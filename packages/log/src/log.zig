//! Configurable Logging, Subsystem Filtering & Pluggable Sinks (`official.log`).
//!
//! Builds on `engine.diagnostics` (`LogLevel`, `Diagnostics`) to provide
//! `LogService` (`engine.log/1`) with:
//! - Global minimum level (`LogConfig.level`) and per-subsystem filter strings
//!   (e.g. `"wgpu=warn,picking=debug,info"`).
//! - Pluggable `LogSinkVTable` outputs (built-in ANSI console sink, custom UI/file
//!   sinks, and an in-memory ring buffer for `editor-shell` and `remote`).
//! - Automatic mirroring of `app.diagnostics` records during `.post_update` and an
//!   optional `stdLogBridge` for `std.Options.logFn`.

const std = @import("std");
const engine = @import("engine");

/// Owner ID used when registering `official.log` services.
pub const MODULE_OWNER_ID: u64 = 2045;

pub const LogLevel = engine.diagnostics.LogLevel;

/// Subsystem-prefix filter rule parsed from `LogConfig.filter`.
pub const LogFilterRule = struct {
    prefix: []const u8,
    level: LogLevel,
};

/// Fixed-capacity structured log entry stored in `LogService.recent`.
pub const BufferedLog = struct {
    level: LogLevel,
    subsystem: [48]u8 = @splat(0),
    subsystem_len: u8 = 0,
    message: [256]u8 = @splat(0),
    message_len: u16 = 0,

    /// Returns the subsystem slice.
    pub fn subsystemSlice(self: *const BufferedLog) []const u8 {
        return self.subsystem[0..self.subsystem_len];
    }

    /// Returns the message slice.
    pub fn messageSlice(self: *const BufferedLog) []const u8 {
        return self.message[0..self.message_len];
    }
};

/// Configuration resource for `official.log`.
pub const LogConfig = struct {
    level: LogLevel = .info,
    filter: []const u8 = "",
    ansi_colors: bool = true,
    show_subsystem: bool = true,
    enable_console_sink: bool = true,
    forward_app_diagnostics: bool = true,
    max_buffered: usize = 256,
};

/// Pluggable log sink interface.
pub const LogSinkVTable = struct {
    id: []const u8,
    ctx: ?*anyopaque = null,
    write: *const fn (ctx: ?*anyopaque, level: LogLevel, subsystem: []const u8, message: []const u8) void,
};

var active_std_log_service: ?*LogService = null;

fn levelRank(level: LogLevel) u8 {
    return switch (level) {
        .debug => 0,
        .info => 1,
        .warn => 2,
        .err => 3,
    };
}

fn levelLabel(level: LogLevel) []const u8 {
    return switch (level) {
        .debug => "DEBUG",
        .info => "INFO",
        .warn => "WARN",
        .err => "ERROR",
    };
}

fn levelColor(level: LogLevel) []const u8 {
    return switch (level) {
        .debug => "\x1b[36m",
        .info => "\x1b[32m",
        .warn => "\x1b[33m",
        .err => "\x1b[31m",
    };
}

fn parseLevel(raw: []const u8) ?LogLevel {
    const s = std.mem.trim(u8, raw, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(s, "trace") or std.ascii.eqlIgnoreCase(s, "debug")) return .debug;
    if (std.ascii.eqlIgnoreCase(s, "info")) return .info;
    if (std.ascii.eqlIgnoreCase(s, "warn") or std.ascii.eqlIgnoreCase(s, "warning")) return .warn;
    if (std.ascii.eqlIgnoreCase(s, "err") or std.ascii.eqlIgnoreCase(s, "error")) return .err;
    return null;
}

fn consoleSinkWrite(ctx: ?*anyopaque, level: LogLevel, subsystem: []const u8, message: []const u8) void {
    const svc: *const LogService = @ptrCast(@alignCast(ctx.?));
    const lbl = levelLabel(level);
    if (svc.config.ansi_colors) {
        const col = levelColor(level);
        if (svc.config.show_subsystem and subsystem.len > 0) {
            std.debug.print("{s}[{s}]\x1b[0m [{s}] {s}\n", .{ col, lbl, subsystem, message });
        } else {
            std.debug.print("{s}[{s}]\x1b[0m {s}\n", .{ col, lbl, message });
        }
    } else {
        if (svc.config.show_subsystem and subsystem.len > 0) {
            std.debug.print("[{s}] [{s}] {s}\n", .{ lbl, subsystem, message });
        } else {
            std.debug.print("[{s}] {s}\n", .{ lbl, message });
        }
    }
}

/// Manages subsystem log filtering, pluggable sinks, and buffered records (`engine.log/1`).
pub const LogService = struct {
    allocator: std.mem.Allocator,
    config: LogConfig,
    rules: std.ArrayList(LogFilterRule),
    sinks: std.ArrayList(LogSinkVTable),
    recent: std.ArrayList(BufferedLog),
    diag_cursor: usize = 0,

    /// Initializes `LogService` from `config` and parses `config.filter`.
    pub fn init(allocator: std.mem.Allocator, config: LogConfig) !LogService {
        var svc = LogService{
            .allocator = allocator,
            .config = config,
            .rules = .empty,
            .sinks = .empty,
            .recent = .empty,
        };
        errdefer svc.deinit();
        try svc.parseFilter(config.filter);
        return svc;
    }

    /// Releases owned filter rules, sink list, and buffered records.
    pub fn deinit(self: *LogService) void {
        if (active_std_log_service == self) active_std_log_service = null;
        for (self.rules.items) |r| self.allocator.free(r.prefix);
        self.rules.deinit(self.allocator);
        self.sinks.deinit(self.allocator);
        self.recent.deinit(self.allocator);
    }

    /// Parses a comma-separated filter string such as `"wgpu=warn,picking=debug,info"`.
    pub fn parseFilter(self: *LogService, filter_str: []const u8) !void {
        for (self.rules.items) |r| self.allocator.free(r.prefix);
        self.rules.clearRetainingCapacity();

        var it = std.mem.splitScalar(u8, filter_str, ',');
        while (it.next()) |token_raw| {
            const token = std.mem.trim(u8, token_raw, " \t\r\n");
            if (token.len == 0) continue;
            if (std.mem.indexOfScalar(u8, token, '=')) |eq| {
                const prefix = std.mem.trim(u8, token[0..eq], " \t");
                const lvl = parseLevel(token[eq + 1 ..]) orelse continue;
                const copy = try self.allocator.dupe(u8, prefix);
                errdefer self.allocator.free(copy);
                try self.rules.append(self.allocator, .{ .prefix = copy, .level = lvl });
            } else if (parseLevel(token)) |lvl| {
                self.config.level = lvl;
            }
        }
    }

    /// Registers a custom `LogSinkVTable` to receive emitted log records.
    pub fn registerSink(self: *LogService, sink: LogSinkVTable) !void {
        try self.sinks.append(self.allocator, sink);
    }

    /// Returns `true` if a record with `(subsystem, level)` passes active filters.
    pub fn shouldLog(self: *const LogService, subsystem: []const u8, level: LogLevel) bool {
        var threshold = self.config.level;
        var best_len: usize = 0;
        var matched = false;
        for (self.rules.items) |r| {
            if (r.prefix.len == 0) {
                if (!matched) {
                    threshold = r.level;
                    matched = true;
                }
                continue;
            }
            if (std.mem.startsWith(u8, subsystem, r.prefix) and r.prefix.len >= best_len) {
                best_len = r.prefix.len;
                threshold = r.level;
                matched = true;
            }
        }
        return levelRank(level) >= levelRank(threshold);
    }

    /// Emits a log record if it passes filtering, buffering it and notifying all sinks.
    pub fn emit(self: *LogService, level: LogLevel, subsystem: []const u8, message: []const u8) void {
        if (!self.shouldLog(subsystem, level)) return;

        var entry = BufferedLog{ .level = level };
        const slen = @min(subsystem.len, entry.subsystem.len);
        @memcpy(entry.subsystem[0..slen], subsystem[0..slen]);
        entry.subsystem_len = @intCast(slen);
        const mlen = @min(message.len, entry.message.len);
        @memcpy(entry.message[0..mlen], message[0..mlen]);
        entry.message_len = @intCast(mlen);

        if (self.config.max_buffered > 0) {
            if (self.recent.items.len >= self.config.max_buffered) {
                _ = self.recent.orderedRemove(0);
            }
            self.recent.append(self.allocator, entry) catch {};
        }

        if (self.config.enable_console_sink) {
            consoleSinkWrite(self, level, subsystem, message);
        }
        for (self.sinks.items) |s| {
            s.write(s.ctx, level, subsystem, message);
        }
    }

    /// Formats and emits a log record using a stack buffer.
    pub fn emitFmt(self: *LogService, level: LogLevel, subsystem: []const u8, comptime fmt: []const u8, args: anytype) void {
        if (!self.shouldLog(subsystem, level)) return;
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
        self.emit(level, subsystem, msg);
    }

    /// Returns the buffered recent log records.
    pub fn recentRecords(self: *const LogService) []const BufferedLog {
        return self.recent.items;
    }

    /// Clears the buffered recent log records.
    pub fn clearRecent(self: *LogService) void {
        self.recent.clearRetainingCapacity();
    }

    /// Installs this `LogService` as the target for `stdLogBridge`.
    pub fn setAsStdLogTarget(self: *LogService) void {
        active_std_log_service = self;
    }
};

/// `std.Options.logFn`-compatible bridge that forwards `std.log` calls into `LogService`.
pub fn stdLogBridge(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const lvl: LogLevel = switch (message_level) {
        .err => .err,
        .warn => .warn,
        .info => .info,
        .debug => .debug,
    };
    const sub = @tagName(scope);
    if (active_std_log_service) |svc| {
        svc.emitFmt(lvl, sub, format, args);
    } else {
        std.debug.print("[{s}] [{s}] " ++ format ++ "\n", .{ levelLabel(lvl), sub } ++ args);
    }
}

fn mirrorDiagnosticsSystem(ctx: *engine.SystemContext) !void {
    const svc = ctx.resources.get(LogService) orelse return;
    if (!svc.config.forward_app_diagnostics) return;

    const total = ctx.diagnostics.count();
    if (total < svc.diag_cursor) svc.diag_cursor = 0;
    while (svc.diag_cursor < total) : (svc.diag_cursor += 1) {
        if (ctx.diagnostics.get(svc.diag_cursor)) |rec| {
            svc.emit(rec.level, rec.subsystem, rec.message);
        }
    }
}

fn buildModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    const cfg = if (app.resources.get(LogConfig)) |c| c.* else LogConfig{};
    try app.resources.insert(LogService, try LogService.init(app.allocator, cfg));
    const svc = app.resources.get(LogService).?;
    svc.setAsStdLogTarget();

    try app.services.register(.{
        .capability = "engine.log",
        .major_version = 1,
        .provider_id = "official.log",
        .owner_id = MODULE_OWNER_ID,
        .exclusive = true,
        .api_ptr = svc,
        .api_size = @sizeOf(LogService),
    });

    try app.addSystem(.{
        .name = "log.mirror_diagnostics",
        .stage = .post_update,
        .run = mirrorDiagnosticsSystem,
    });
}

fn stopModule(raw_app: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    _ = app.services.unregisterByOwner(MODULE_OWNER_ID);
    _ = app.resources.remove(LogService);
}

/// Returns the `official.log` module descriptor.
pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = "official.log",
            .version = "0.1.0",
            .provides_capabilities = &.{"engine.log/1"},
            .required_capabilities = &.{},
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
