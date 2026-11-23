//! Engine Diagnostic & Inspection CLI (`tools/cli`).
//!
//! Implements the ergonomic developer CLI commands (`doctor`, `packages`)
//! over the engine's `ModuleRegistry`, `ServiceRegistry`, and C ABI metadata.
//!
//! Usage:
//!   zig build run-cli -- doctor
//!   zig build run-cli -- packages

const std = @import("std");
const engine = @import("engine");
const window = @import("window");
const graphics = @import("graphics");
const ui_core = @import("ui_core");
const scripting_host = @import("scripting_host");
const assets = @import("assets");

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args_it = try init.args.iterateAllocator(allocator);
    defer args_it.deinit();
    _ = args_it.next(); // skip executable name
    const cmd = args_it.next() orelse "doctor";

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
        std.debug.print("Unknown command '{s}'. Available: doctor, packages\n", .{cmd});
    }
}
