//! Project scaffolding, Python typings and the `zengy run` launcher (spawns the `zengy-runtime` executable).

const std = @import("std");
const builtin = @import("builtin");

pub fn writeFileRelative(io: std.Io, path: []const u8, content: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

pub const PY_ZENGY_INIT_PYI = @embedFile("py_zengy_init_pyi");

pub const PY_ZENGY_INPUT_PYI = @embedFile("py_zengy_input_pyi");

pub const PY_ZENGY_KEY_PYI = @embedFile("py_zengy_key_pyi");

pub const PYRIGHT_CONFIG_JSON =
    \\{
    \\  "include": ["scripts"],
    \\  "extraPaths": ["typings"]
    \\}
    \\
;

pub const STARTER_MAIN_PY =
    \\import zengy
    \\from zengy import Key
    \\
    \\x = 600.0
    \\y = 320.0
    \\
    \\
    \\def start():
    \\    zengy.log("zengy game started!")
    \\
    \\
    \\def update(dt):
    \\    global x, y
    \\    speed = 300.0 * float(dt)
    \\    if zengy.input.is_key_down(Key.A) or zengy.input.is_key_down(Key.LEFT):
    \\        x -= speed
    \\    if zengy.input.is_key_down(Key.D) or zengy.input.is_key_down(Key.RIGHT):
    \\        x += speed
    \\    if zengy.input.is_key_down(Key.W) or zengy.input.is_key_down(Key.UP):
    \\        y -= speed
    \\    if zengy.input.is_key_down(Key.S) or zengy.input.is_key_down(Key.DOWN):
    \\        y += speed
    \\    zengy.draw_rect(x, y, 64.0, 64.0, 0.25, 0.75, 1.0, 1.0)
    \\
;

pub fn writePythonTypings(allocator: std.mem.Allocator, io: std.Io, base_dir: []const u8) !void {
    const typings_zengy_dir = try std.fmt.allocPrint(allocator, "{s}/typings/zengy", .{base_dir});
    defer allocator.free(typings_zengy_dir);
    try std.Io.Dir.cwd().createDirPath(io, typings_zengy_dir);

    const files = [_]struct { rel: []const u8, content: []const u8 }{
        .{ .rel = "typings/zengy/__init__.pyi", .content = PY_ZENGY_INIT_PYI },
        .{ .rel = "typings/zengy/input.pyi", .content = PY_ZENGY_INPUT_PYI },
        .{ .rel = "typings/zengy/Key.pyi", .content = PY_ZENGY_KEY_PYI },
        .{ .rel = "pyrightconfig.json", .content = PYRIGHT_CONFIG_JSON },
    };
    for (files) |f| {
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_dir, f.rel });
        defer allocator.free(path);
        try writeFileRelative(io, path, f.content);
    }
}

pub fn scaffoldProject(allocator: std.mem.Allocator, io: std.Io, name: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, name);

    const scripts_dir = try std.fmt.allocPrint(allocator, "{s}/scripts", .{name});
    defer allocator.free(scripts_dir);
    try std.Io.Dir.cwd().createDirPath(io, scripts_dir);

    const toml_path = try std.fmt.allocPrint(allocator, "{s}/game.toml", .{name});
    defer allocator.free(toml_path);
    const toml_src = try std.fmt.allocPrint(allocator,
        \\[game]
        \\title = "{s}"
        \\width = 1280
        \\height = 720
        \\mode = "2d"
        \\entry_script = "scripts/main.py"
        \\plugins = []
        \\
    , .{name});
    defer allocator.free(toml_src);
    try writeFileRelative(io, toml_path, toml_src);

    const main_py_path = try std.fmt.allocPrint(allocator, "{s}/scripts/main.py", .{name});
    defer allocator.free(main_py_path);
    try writeFileRelative(io, main_py_path, STARTER_MAIN_PY);

    try writePythonTypings(allocator, io, name);

    std.debug.print("Created zengy project '{s}/' (with scripts/main.py + Python typings):\n  cd {s}\n  zengy run\n", .{ name, name });
}

pub fn runProject(allocator: std.mem.Allocator, io: std.Io, args_it: anytype) !void {
    const runtime_bin = if (builtin.os.tag == .windows) "zengy-runtime.exe" else "zengy-runtime";
    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(allocator);
    try argv_list.append(allocator, runtime_bin);
    while (args_it.next()) |arg| {
        try argv_list.append(allocator, arg);
    }

    var child = try std.process.spawn(io, .{ .argv = argv_list.items });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.RuntimeExitedWithError,
        else => return error.RuntimeExitedWithError,
    }
}
