//! Visual Python Hello — PocketPy Script Driving SDL3 + SDL_GPU (`examples/visual-python/main.zig`).
//!
//! Loads a PocketPy script into `ScriptingHost` that defines `on_frame(arg)` and calls
//! `engine.draw_rect(...)` each frame. The host translates `ScriptDrawQueue` rects into
//! `graphics.DrawCommand.rect` and presents them via `official.graphics.sdlgpu`.
//!
//! Run with: `zig build run-visual-python`

const std = @import("std");
const engine = @import("engine");
const window_sdl3 = @import("window_sdl3");
const graphics = @import("graphics");
const graphics_sdlgpu = @import("graphics_sdlgpu");
const scripting_host = @import("scripting_host");
const scripting_python = @import("scripting_python");

const PYTHON_SOURCE =
    \\import zigeng
    \\import math
    \\
    \\t = 0.0
    \\
    \\def on_frame(dt_str):
    \\    global t
    \\    t = t + float(dt_str)
    \\    for i in range(6):
    \\        phase = t * 2.0 + i * 0.7
    \\        x = 580.0 + math.cos(phase) * (140.0 + i * 24.0)
    \\        y = 320.0 + math.sin(phase * 1.3) * (90.0 + i * 18.0)
    \\        r = 0.25 + 0.12 * i
    \\        g = 0.85 - 0.10 * i
    \\        b = 0.95
    \\        zigeng.draw_rect(x, y, 56.0, 56.0, r, g, b, 0.9)
    \\
;

const PyVisualState = struct {
    allocator: std.mem.Allocator,
    app: *engine.App,
    host: *scripting_host.ScriptingHost,
    script: scripting_host.ScriptModuleHandle,
    gfx: *graphics.GraphicsDeviceService,
    rt: graphics.RenderTargetHandle,
    cmds: std.ArrayList(graphics.DrawCommand),
};

fn pyTickSystem(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(PyVisualState) orelse return;
    if (st.app.resources.get(scripting_host.ScriptDrawQueue)) |q| {
        q.clear();
    }

    var dt_buf: [32]u8 = undefined;
    const dt_str = std.fmt.bufPrint(&dt_buf, "{d:.5}", .{ctx.dt}) catch "0.016";
    const res = st.host.invokeScript(st.script, "on_frame", dt_str);
    if (!res.ok) {
        std.debug.print("[visual-python] script error: {s}\n", .{res.error_message});
    }
}

fn pyRenderSystem(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(PyVisualState) orelse return;
    st.cmds.clearRetainingCapacity();

    try st.cmds.append(st.allocator, .{ .clear = .{ .r = 0.05, .g = 0.06, .b = 0.10, .a = 1.0 } });
    if (st.app.resources.get(scripting_host.ScriptDrawQueue)) |q| {
        for (q.rects.items) |r| {
            try st.cmds.append(st.allocator, .{
                .rect = .{
                    .x = r.x,
                    .y = r.y,
                    .width = r.width,
                    .height = r.height,
                    .color = .{ .r = r.r, .g = r.g, .b = r.b, .a = r.a },
                },
            });
        }
    }
    try st.cmds.append(st.allocator, .{
        .text = .{
            .x = 24.0,
            .y = 24.0,
            .content = "PocketPy + SDL3 GPU (engine.draw_rect)",
            .color = .{ .r = 0.92, .g = 0.95, .b = 1.0, .a = 1.0 },
        },
    });

    try st.gfx.beginFrame(st.rt);
    try st.gfx.submitDrawCommands(st.rt, st.cmds.items);
    try st.gfx.present(st.rt);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        if (gpa.deinit() == .leak) std.debug.print("[visual-python] WARNING: memory leak detected\n", .{});
    }
    const allocator = gpa.allocator();

    var app = engine.App.init(allocator, .{});
    defer app.deinit();

    try app.registerModule(window_sdl3.module());
    try app.registerModule(graphics_sdlgpu.module());
    try app.registerModule(scripting_host.module());
    try app.registerModule(scripting_python.module());

    try app.resources.insert(window_sdl3.WindowConfig, .{
        .title = "ZigEng — Visual Python (PocketPy + SDL_GPU)",
        .width = 1280,
        .height = 720,
        .resizable = true,
    });

    try app.scheduler.addSystem(.{ .name = "visual_py.update", .stage = .update, .run = pyTickSystem });
    try app.scheduler.addSystem(.{ .name = "visual_py.render", .stage = .render_extract, .run = pyRenderSystem });

    try app.initialize();

    const s_entry = try app.services.getService("engine.script.host", 1);
    const host: *scripting_host.ScriptingHost = @ptrCast(@alignCast(@constCast(s_entry.api_ptr)));
    const g_entry = try app.services.getService("engine.graphics.device", 1);
    const gfx: *graphics.GraphicsDeviceService = @ptrCast(@alignCast(@constCast(g_entry.api_ptr)));

    const script = try host.loadScript(0, "visual_demo.py", PYTHON_SOURCE);

    const px = window_sdl3.pixelSize(&app);
    const px_w: u32 = if (px) |p| p.width else 1280;
    const px_h: u32 = if (px) |p| p.height else 720;
    const surface = try gfx.createSurface(1, px_w, px_h);

    try app.resources.insert(PyVisualState, .{
        .allocator = allocator,
        .app = &app,
        .host = host,
        .script = script,
        .gfx = gfx,
        .rt = surface,
        .cmds = .empty,
    });
    const st_ptr = app.resources.get(PyVisualState).?;
    defer st_ptr.cmds.deinit(allocator);

    try window_sdl3.runVisualLoop(&app);
    std.debug.print("[visual-python] closed after {d} frames\n", .{app.diagnostics.frame_count});
}
