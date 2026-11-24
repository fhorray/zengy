//! Configurable Logging Tests (`packages/log/tests/log_tests.zig`).

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const log = @import("log");

const SinkCapture = struct {
    count: usize = 0,
    last_subsystem: [32]u8 = @splat(0),
    last_subsystem_len: usize = 0,
};

fn testSinkWrite(ctx: ?*anyopaque, _: log.LogLevel, subsystem: []const u8, _: []const u8) void {
    const cap: *SinkCapture = @ptrCast(@alignCast(ctx.?));
    cap.count += 1;
    const n = @min(subsystem.len, cap.last_subsystem.len);
    @memcpy(cap.last_subsystem[0..n], subsystem[0..n]);
    cap.last_subsystem_len = n;
}

test "LogService filters by subsystem, invokes custom sinks, and mirrors Diagnostics" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.resources.insert(log.LogConfig, .{
        .level = .info,
        .filter = "sdlgpu=warn,picking=debug,info",
        .enable_console_sink = false,
    });
    try app.registerModule(log.module());
    try app.initialize();

    const svc = app.resources.get(log.LogService).?;
    var cap = SinkCapture{};
    try svc.registerSink(.{ .id = "test.capture", .ctx = &cap, .write = testSinkWrite });

    // Filtered out: sdlgpu=warn drops info
    svc.emit(.info, "sdlgpu.pbr", "dropped info");
    try testing.expectEqual(@as(usize, 0), cap.count);

    // Passes: sdlgpu=warn allows warn
    svc.emit(.warn, "sdlgpu.pbr", "kept warn");
    try testing.expectEqual(@as(usize, 1), cap.count);

    // Passes: picking=debug allows debug
    svc.emit(.debug, "picking.ray", "kept debug");
    try testing.expectEqual(@as(usize, 2), cap.count);

    // Diagnostics mirroring during tick
    try app.diagnostics.log(.err, "core.test", "mirrored error");
    try app.tick(1.0 / 60.0);
    try testing.expectEqual(@as(usize, 3), cap.count);
    try testing.expectEqual(@as(usize, 3), svc.recentRecords().len);
    try testing.expectEqualStrings("core.test", svc.recentRecords()[2].subsystemSlice());
}
