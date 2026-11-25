//! Engine Diagnostic, Scenario Runner & Package Installer CLI (`tools/cli`).
//!
//! Commands:
//! - `doctor`: validates ABI version, module graph resolution, and service count.
//! - `packages`: prints resolved topological module order and registered providers.
//! - `test-scenario`: runs a deterministic TOML scenario and outputs a structured JSON report.
//! - `list-official`: lists all official packages available from `fhorray/zengy`.
//! - `new <name>`: scaffolds a game.toml + starter Python script + IDE typings project.
//! - `typings`: writes Python `.pyi` stubs (`typings/`) and `pyrightconfig.json` in CWD.
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
const install = @import("install.zig");
const catalog = @import("catalog.zig");
const project = @import("project.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args_it = try init.minimal.args.iterateAllocator(allocator);
    defer args_it.deinit();
    _ = args_it.next(); // skip executable name
    const cmd = args_it.next() orelse "doctor";

    if (std.mem.eql(u8, cmd, "new")) {
        const proj_name = args_it.next() orelse {
            std.debug.print("Usage: zengy new <project-name>\n", .{});
            return;
        };
        try project.scaffoldProject(allocator, init.io, proj_name);
        return;
    }

    if (std.mem.eql(u8, cmd, "typings")) {
        try project.writePythonTypings(allocator, init.io, ".");
        std.debug.print("Generated Python typings in ./typings/ and ./pyrightconfig.json.\n", .{});
        return;
    }

    if (std.mem.eql(u8, cmd, "run")) {
        try project.runProject(allocator, init.io, &args_it);
        return;
    }

    if (std.mem.eql(u8, cmd, "install") or std.mem.eql(u8, cmd, "i")) {
        install.g_fork_path = init.environ_map.get("ZENGY_FORK");
        while (args_it.next()) |a| {
            if (std.mem.startsWith(u8, a, "--fork=")) install.g_fork_path = a["--fork=".len..];
        }
        try install.installFromGameToml(allocator, init.io);
        return;
    }

    if (std.mem.eql(u8, cmd, "list-official")) {
        std.debug.print("Official zengy packages (install with: zengy add <name>):\n", .{});
        for (catalog.OFFICIAL_PACKAGES) |pkg| {
            std.debug.print("  - {s:<18} {s}\n", .{ pkg.name, pkg.summary });
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "add")) {
        install.g_fork_path = init.environ_map.get("ZENGY_FORK");
        var pkg_spec: ?[]const u8 = null;
        while (args_it.next()) |a| {
            if (std.mem.startsWith(u8, a, "--fork=")) {
                install.g_fork_path = a["--fork=".len..];
            } else if (pkg_spec == null) {
                pkg_spec = a;
            }
        }
        const spec = pkg_spec orelse {
            std.debug.print("Usage: zengy add [--fork=<zengy-checkout>] <package | owner/repo[@tag] | github-url | ./local-path>\n", .{});
            return;
        };
        try install.installPluginSpec(allocator, init.io, spec);
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
            "zengy doctor:\n  ABI version: {d}.{d}\n  App state: {s}\n  Modules resolved: {d}\n  Services registered: {d}\n  Status: OK\n",
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
