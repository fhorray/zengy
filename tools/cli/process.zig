//! Process and filesystem helpers shared by the CLI commands (explicit `cmd.exe` vs `sh -c` handling).

const std = @import("std");
const builtin = @import("builtin");

pub fn runShell(allocator: std.mem.Allocator, io: std.Io, shell_cmd: []const u8) !void {
    const argv = if (builtin.os.tag == .windows)
        [_][]const u8{ "cmd.exe", "/C", shell_cmd }
    else
        [_][]const u8{ "sh", "-c", shell_cmd };

    const res = try std.process.run(allocator, io, .{ .argv = &argv });
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);
    if (res.stdout.len > 0) std.debug.print("{s}", .{res.stdout});
    if (res.stderr.len > 0) std.debug.print("{s}", .{res.stderr});

    switch (res.term) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

pub fn hasCommand(allocator: std.mem.Allocator, io: std.Io, check_cmd: []const u8) bool {
    const argv = if (builtin.os.tag == .windows)
        [_][]const u8{ "cmd.exe", "/C", check_cmd }
    else
        [_][]const u8{ "sh", "-c", check_cmd };
    const res = std.process.run(allocator, io, .{ .argv = &argv }) catch return false;
    allocator.free(res.stdout);
    allocator.free(res.stderr);
    return switch (res.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

pub fn fileExists(allocator: std.mem.Allocator, io: std.Io, base_dir: []const u8, rel: []const u8) bool {
    const full = std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_dir, rel }) catch return false;
    defer allocator.free(full);
    std.Io.Dir.cwd().access(io, full, .{}) catch return false;
    return true;
}

pub fn runArgv(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const res = try std.process.run(allocator, io, .{ .argv = argv });
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);
    if (res.stdout.len > 0) std.debug.print("{s}", .{res.stdout});
    if (res.stderr.len > 0) std.debug.print("{s}", .{res.stderr});
    switch (res.term) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

pub fn cwdFileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

pub fn runArgvIn(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: []const u8) !void {
    const res = try std.process.run(allocator, io, .{ .argv = argv, .cwd = .{ .path = cwd } });
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);
    if (res.stdout.len > 0) std.debug.print("{s}", .{res.stdout});
    if (res.stderr.len > 0) std.debug.print("{s}", .{res.stderr});
    switch (res.term) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}
