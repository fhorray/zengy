//! Visual Hello (D1) — native SDL3 window (`examples/visual-hello/main.zig`).
//!
//! Opens a resizable 1280x720 window through `official.window.sdl3`, feeds keyboard, mouse
//! and text input into `InputService`, reports DPI and pixel size, and closes on Escape
//! or on the window's close button.
//!
//! Run with: `zig build run-visual-hello` (Windows x64 for D1; the SDL3 DLL is copied to zig-out/bin).

const std = @import("std");
const engine = @import("engine");
const window_sdl3 = @import("window_sdl3");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        if (gpa.deinit() == .leak) std.debug.print("[visual-hello] WARNING: memory leak detected\n", .{});
    }
    const allocator = gpa.allocator();

    var app = engine.App.init(allocator, .{});
    defer app.deinit();

    try app.registerModule(window_sdl3.module());

    // Insert the window configuration before initialize(); the module reads it on build.
    try app.resources.insert(window_sdl3.WindowConfig, .{
        .title = "ZigEng — Visual Hello (D1)",
        .width = 1280,
        .height = 720,
        .resizable = true,
    });

    try app.initialize();
    if (window_sdl3.pixelSize(&app)) |px| {
        std.debug.print("[visual-hello] pixels {d}x{d}, dpi scale {d:.2}\n", .{ px.width, px.height, px.dpi_scale });
    }

    // Owns the OS loop until the window closes. Escape also closes it.
    try window_sdl3.runVisualLoop(&app);

    std.debug.print("[visual-hello] window closed after {d} frames\n", .{app.diagnostics.frame_count});
}
