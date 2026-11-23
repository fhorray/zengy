//! Engine Diagnostic, Scenario Runner & Package Installer CLI (`tools/cli`).
//!
//! Commands:
//! - `doctor`: validates ABI version, module graph resolution, and service count.
//! - `packages`: prints resolved topological module order and registered providers.
//! - `test-scenario`: runs a deterministic TOML scenario and outputs a structured JSON report.
//! - `list-official`: lists all official packages available from `fhorray/zigeng`.
//! - `add <pkg>`: downloads an official package from GitHub into `./packages/<pkg>/`
//!   (and any required `third_party/` dependency such as `pocketpy` or `sdl3`).
//!
//! Usage:
//!   zig build run-cli
//!   zig build run-cli -Dcli-cmd=packages
//!   zig build run-cli -Dcli-cmd=list-official
//!   engine-cli add scripting-python

const std = @import("std");
const builtin = @import("builtin");
const engine = @import("engine");
const window = @import("window");
const graphics = @import("graphics");
const ui_core = @import("ui_core");
const scripting_host = @import("scripting_host");
const assets = @import("assets");
const testing_sdk = @import("testing_sdk");

const OfficialPackageInfo = struct {
    name: []const u8,
    entry: []const u8,
    summary: []const u8,
    third_party: ?[]const u8 = null,
};

const OFFICIAL_PACKAGES = [_]OfficialPackageInfo{
    .{ .name = "window", .entry = "src/window.zig", .summary = "Headless window & input service" },
    .{ .name = "window-sdl3", .entry = "src/window_sdl3.zig", .summary = "Native SDL3 window & input", .third_party = "sdl3" },
    .{ .name = "graphics", .entry = "src/graphics.zig", .summary = "Headless graphics device & DrawCommand" },
    .{ .name = "graphics-sdlgpu", .entry = "src/graphics_sdlgpu.zig", .summary = "SDL_GPU (Vulkan/SPIR-V) 2D/3D backend", .third_party = "sdl3" },
    .{ .name = "scene", .entry = "src/scene.zig", .summary = "2D transform hierarchy & SceneSnapshot" },
    .{ .name = "render-2d", .entry = "src/render_2d.zig", .summary = "Camera2D, Sprite, Visibility & batch extract" },
    .{ .name = "render-3d", .entry = "src/render_3d.zig", .summary = "3D math, Camera3D, glTF 2.0 & frustum culling" },
    .{ .name = "text", .entry = "src/text.zig", .summary = "Embedded 8x8 ASCII bitmap font atlas" },
    .{ .name = "ui-core", .entry = "src/ui_core.zig", .summary = "Retained UiTree, flex layout & hit testing" },
    .{ .name = "ui-markup", .entry = "src/ui_markup.zig", .summary = "HTML-like UI markup parser" },
    .{ .name = "ui-novaui", .entry = "src/novaui.zig", .summary = "NovaUI DSL frontend" },
    .{ .name = "ui-immediate", .entry = "src/ui_immediate.zig", .summary = "Immediate-mode UI backend" },
    .{ .name = "scripting-host", .entry = "src/scripting_host.zig", .summary = "Language-agnostic scripting host & bridge" },
    .{ .name = "scripting-lua", .entry = "src/scripting_lua.zig", .summary = "Embedded Lua 5.4 runtime" },
    .{ .name = "scripting-python", .entry = "src/scripting_python.zig", .summary = "Embedded PocketPy (Python) runtime", .third_party = "pocketpy" },
    .{ .name = "assets", .entry = "src/assets.zig", .summary = "URI-cached asset registry" },
    .{ .name = "editor-shell", .entry = "src/editor_shell.zig", .summary = "Dockable editor shell & undo/redo" },
    .{ .name = "testing", .entry = "src/testing_sdk.zig", .summary = "Deterministic TestDriver & CaptureService" },
    .{ .name = "default-plugins", .entry = "src/default_plugins.zig", .summary = "Curated bundle of official modules" },
};

fn findOfficialPackage(name: []const u8) ?OfficialPackageInfo {
    for (OFFICIAL_PACKAGES) |pkg| {
        if (std.mem.eql(u8, pkg.name, name)) return pkg;
    }
    return null;
}

fn installOfficialPackage(allocator: std.mem.Allocator, io: std.Io, pkg: OfficialPackageInfo) !void {
    const shell_cmd = if (pkg.third_party) |tp|
        try std.fmt.allocPrint(
            allocator,
            "mkdir -p packages third_party && curl -sL https://github.com/fhorray/zigeng/archive/refs/heads/main.tar.gz | tar -xz --strip-components=1 -C . zigeng-main/packages/{s} zigeng-main/third_party/{s}",
            .{ pkg.name, tp },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "mkdir -p packages && curl -sL https://github.com/fhorray/zigeng/archive/refs/heads/main.tar.gz | tar -xz --strip-components=1 -C . zigeng-main/packages/{s}",
            .{pkg.name},
        );
    defer allocator.free(shell_cmd);

    const argv = if (builtin.os.tag == .windows)
        [_][]const u8{ "cmd.exe", "/C", shell_cmd }
    else
        [_][]const u8{ "sh", "-c", shell_cmd };

    const res = try std.process.run(allocator, io, .{ .argv = &argv });
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);

    switch (res.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("Failed to download '{s}' (exit {d}):\n{s}\n", .{ pkg.name, code, res.stderr });
            return error.PackageDownloadFailed;
        },
        else => return error.PackageDownloadFailed,
    }

    std.debug.print("Installed official package into ./packages/{s}/\n", .{pkg.name});
    if (pkg.third_party) |tp| {
        std.debug.print("Installed required dependency into ./third_party/{s}/\n", .{tp});
    }
    std.debug.print("\nAdd to your build.zig:\n  const pkg_mod = b.addModule(\"{s}\", .{{\n      .root_source_file = b.path(\"packages/{s}/{s}\"),\n      .target = target,\n      .optimize = optimize,\n  }});\n", .{
        pkg.name,
        pkg.name,
        pkg.entry,
    });
}

fn writeFileRelative(io: std.Io, path: []const u8, content: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

fn scaffoldProject(allocator: std.mem.Allocator, io: std.Io, name: []const u8) !void {
    const dirs = [_][]const u8{ "", "/scripts", "/ui", "/assets" };
    for (dirs) |sub| {
        const p = try std.fmt.allocPrint(allocator, "{s}{s}", .{ name, sub });
        defer allocator.free(p);
        try std.Io.Dir.cwd().createDirPath(io, p);
    }

    const toml_path = try std.fmt.allocPrint(allocator, "{s}/game.toml", .{name});
    defer allocator.free(toml_path);
    const toml_src = try std.fmt.allocPrint(allocator,
        \\[game]
        \\title = "{s}"
        \\width = 1280
        \\height = 720
        \\mode = "2d"
        \\entry_script = "scripts/main.py"
        \\ui = "ui/hud.html"
        \\
    , .{name});
    defer allocator.free(toml_src);
    try writeFileRelative(io, toml_path, toml_src);

    const py_path = try std.fmt.allocPrint(allocator, "{s}/scripts/main.py", .{name});
    defer allocator.free(py_path);
    try writeFileRelative(io, py_path,
        \\import engine
        \\
        \\px = 600.0
        \\py = 340.0
        \\color_idx = 0
        \\
        \\def on_ui_action(action):
        \\    global color_idx
        \\    if action == "game.cycle_color":
        \\        color_idx = (color_idx + 1) % 3
        \\        engine.log("Color changed!")
        \\
        \\def on_frame(dt_str):
        \\    global px, py
        \\    dt = float(dt_str)
        \\    speed = 280.0 * dt
        \\    # WASD scancodes: A=4, D=7, S=22, W=26
        \\    if engine.is_key_down(4): px = px - speed
        \\    if engine.is_key_down(7): px = px + speed
        \\    if engine.is_key_down(26): py = py - speed
        \\    if engine.is_key_down(22): py = py + speed
        \\
        \\    colors = [
        \\        (0.25, 0.85, 0.65),
        \\        (0.95, 0.45, 0.35),
        \\        (0.35, 0.65, 0.98),
        \\    ]
        \\    r, g, b = colors[color_idx]
        \\    engine.draw_rect(px, py, 64.0, 64.0, r, g, b, 1.0)
        \\
    );

    const ui_path = try std.fmt.allocPrint(allocator, "{s}/ui/hud.html", .{name});
    defer allocator.free(ui_path);
    try writeFileRelative(io, ui_path,
        \\<panel id="hud">
        \\  <label id="title">WASD to move</label>
        \\  <button id="color_btn" action="game.cycle_color">Change Color</button>
        \\</panel>
        \\
    );

    std.debug.print("Created zigeng game project '{s}/':\n  cd {s}\n  zigeng run\n", .{ name, name });
}

fn runProject(allocator: std.mem.Allocator, io: std.Io) !void {
    const runtime_bin = if (builtin.os.tag == .windows) "zigeng-runtime.exe" else "zigeng-runtime";
    const res = try std.process.run(allocator, io, .{ .argv = &.{runtime_bin} });
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);
    if (res.stdout.len > 0) std.debug.print("{s}", .{res.stdout});
    if (res.stderr.len > 0) std.debug.print("{s}", .{res.stderr});
    switch (res.term) {
        .exited => |code| if (code != 0) return error.RuntimeExitedWithError,
        else => return error.RuntimeExitedWithError,
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args_it = try init.minimal.args.iterateAllocator(allocator);
    defer args_it.deinit();
    _ = args_it.next(); // skip executable name
    const cmd = args_it.next() orelse "doctor";

    if (std.mem.eql(u8, cmd, "new")) {
        const proj_name = args_it.next() orelse {
            std.debug.print("Usage: zigeng new <project-name>\n", .{});
            return;
        };
        try scaffoldProject(allocator, init.io, proj_name);
        return;
    }

    if (std.mem.eql(u8, cmd, "run")) {
        try runProject(allocator, init.io);
        return;
    }

    if (std.mem.eql(u8, cmd, "list-official")) {
        std.debug.print("Official zigeng packages (install with: zigeng add <name>):\n", .{});
        for (OFFICIAL_PACKAGES) |pkg| {
            std.debug.print("  - {s:<18} {s}\n", .{ pkg.name, pkg.summary });
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "add")) {
        const pkg_name = args_it.next() orelse {
            std.debug.print("Usage: zigeng add <package-name>\nRun 'zigeng list-official' to see available packages.\n", .{});
            return;
        };
        const pkg = findOfficialPackage(pkg_name) orelse {
            std.debug.print("Unknown official package '{s}'. Run 'zigeng list-official' to see available packages.\n", .{pkg_name});
            return error.UnknownPackage;
        };
        try installOfficialPackage(allocator, init.io, pkg);
        return;
    }

    if (std.mem.eql(u8, cmd, "test-scenario")) {
        var scen_app = engine.App.init(allocator, .{ .fixed_dt = 1.0 / 60.0 });
        defer scen_app.deinit();

        try scen_app.registerModule(window.module());
        try scen_app.registerModule(graphics.module());
        try scen_app.registerModule(ui_core.module());
        try scen_app.registerModule(testing_sdk.module());
        try scen_app.initialize();

        const tree = scen_app.resources.get(ui_core.UiTree).?;
        const panel = try tree.createNode(null, .{ .id = "root", .kind = .panel });
        _ = try tree.createNode(panel, .{ .id = "btn", .kind = .button, .text = "Play", .action = "game.play" });
        tree.layoutTree(128, 128);

        const sample_toml =
            \\[scenario]
            \\name = "cli_smoke"
            \\ticks = 10
            \\
            \\[[actions]]
            \\at_tick = 2
            \\type = "ui_click"
            \\target = "btn"
        ;

        var scen = try testing_sdk.TestDriver.parseScenarioToml(allocator, sample_toml);
        defer scen.deinit();

        const i_entry = try scen_app.services.getService("engine.input", 1);
        const input: *window.InputService = @ptrCast(@alignCast(@constCast(i_entry.api_ptr)));
        const drv = scen_app.resources.get(testing_sdk.TestDriver).?;
        try drv.runScenario(&scen, &scen_app, input, tree);

        var cmds: std.ArrayList(graphics.DrawCommand) = .empty;
        defer cmds.deinit(allocator);
        try cmds.append(allocator, .{ .clear = .{ .r = 0.05, .g = 0.05, .b = 0.08 } });
        try tree.paint(allocator, &cmds);

        const cap = scen_app.resources.get(testing_sdk.CaptureService).?;
        cap.rasterize(cmds.items);

        std.debug.print(
            "{{\"scenario\":\"{s}\",\"zig_version\":\"{s}\",\"ticks\":{d},\"entities\":{d},\"framebuffer_hash\":{d},\"status\":\"ok\"}}\n",
            .{
                scen.name,
                builtin.zig_version_string,
                drv.current_tick,
                scen_app.world.entity_count,
                cap.computeHash(),
            },
        );
        return;
    }

    // Compose a representative application graph to inspect resolution & ABI health.
    var app = engine.App.init(allocator, .{});
    defer app.deinit();

    try app.registerModule(window.module());
    try app.registerModule(graphics.module());
    try app.registerModule(ui_core.module());
    try app.registerModule(scripting_host.module());
    try app.registerModule(assets.module());
    try app.initialize();

    if (std.mem.eql(u8, cmd, "doctor")) {
        std.debug.print(
            "zigeng doctor:\n  ABI version: {d}.{d}\n  App state: {s}\n  Modules resolved: {d}\n  Services registered: {d}\n  Status: OK\n",
            .{
                engine.abi.ABI_MAJOR,
                engine.abi.ABI_MINOR,
                @tagName(app.state),
                app.modules.modules.items.len,
                app.services.count(),
            },
        );
    } else if (std.mem.eql(u8, cmd, "packages")) {
        std.debug.print("Resolved Module Topological Order:\n", .{});
        for (app.modules.resolved_order.items, 0..) |mod_idx, step| {
            const mod = app.modules.modules.items[mod_idx].module;
            std.debug.print("  {d}. {s} ({s})\n", .{
                step + 1,
                mod.descriptor.id,
                mod.descriptor.version,
            });
        }
        std.debug.print("Registered Service Providers:\n", .{});
        for (app.services.services.items) |svc| {
            std.debug.print("  - {s}/{d} -> {s} (exclusive={})\n", .{
                svc.capability,
                svc.major_version,
                svc.provider_id,
                svc.exclusive,
            });
        }
    } else {
        std.debug.print("Unknown command '{s}'. Available: doctor, packages, test-scenario, list-official, add <pkg>\n", .{cmd});
    }
}
