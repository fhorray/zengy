//! Visual GPU Hello (D2) — SDL3 Window + SDL_GPU Rendering (`examples/visual-gpu/main.zig`).
//!
//! Opens a resizable 1280x720 window through `official.window.sdl3`, initializes
//! `official.graphics.sdlgpu`, renders a shader-driven RGB triangle (NDC) and an
//! animated pixel-space rectangle via `GraphicsDeviceService`, and logs backend
//! initialization to `Diagnostics`.
//!
//! Run with: `zig build run-visual-gpu`

const std = @import("std");
const engine = @import("engine");
const window = @import("window");
const window_sdl3 = @import("window_sdl3");
const graphics = @import("graphics");
const graphics_sdlgpu = @import("graphics_sdlgpu");

const RenderState = struct {
    app: *engine.App,
    gfx: *graphics.GraphicsDeviceService,
    input: *window.InputService,
    rt: graphics.RenderTargetHandle,
    elapsed: f32 = 0.0,
};

fn renderFrameSystem(ctx: *engine.SystemContext) !void {
    const rs = ctx.resources.get(RenderState) orelse return;
    rs.elapsed += ctx.dt;

    try rs.gfx.beginFrame(rs.rt);

    // 1. Shader-rendered RGB triangle in NDC space.
    try graphics_sdlgpu.queueTriangle(
        rs.app,
        .{ .x = 0.0, .y = 0.55, .r = 0.95, .g = 0.25, .b = 0.30, .a = 1.0 },
        .{ .x = -0.50, .y = -0.45, .r = 0.20, .g = 0.85, .b = 0.45, .a = 1.0 },
        .{ .x = 0.50, .y = -0.45, .r = 0.25, .g = 0.45, .b = 0.95, .a = 1.0 },
        false,
    );

    // 2. Shader-rendered rectangle in pixel space via GraphicsDeviceService DrawCommand.
    const pulse = 0.5 + 0.5 * @sin(rs.elapsed * 2.5);
    const rect_x: f32 = if (rs.input.mouse_x > 0.0) rs.input.mouse_x - 60.0 else 64.0 + 40.0 * @sin(rs.elapsed * 1.5);
    const rect_y: f32 = if (rs.input.mouse_y > 0.0) rs.input.mouse_y - 36.0 else 64.0;

    try rs.gfx.submitDrawCommands(rs.rt, &.{
        .{ .clear = .{ .r = 0.07, .g = 0.09, .b = 0.13, .a = 1.0 } },
        .{ .rect = .{
            .x = rect_x,
            .y = rect_y,
            .width = 120.0,
            .height = 72.0,
            .color = .{ .r = 0.18, .g = 0.55 + 0.30 * pulse, .b = 0.92, .a = 0.85 },
        } },
    });

    try rs.gfx.present(rs.rt);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        if (gpa.deinit() == .leak) std.debug.print("[visual-gpu] WARNING: memory leak detected\n", .{});
    }
    const allocator = gpa.allocator();

    var app = engine.App.init(allocator, .{});
    defer app.deinit();

    try app.registerModule(window_sdl3.module());
    try app.registerModule(graphics_sdlgpu.module());

    try app.resources.insert(window_sdl3.WindowConfig, .{
        .title = "Zengy — Visual GPU Hello (D2)",
        .width = 1280,
        .height = 720,
        .resizable = true,
    });
    try app.resources.insert(graphics_sdlgpu.GpuConfig, .{
        .debug_mode = true,
    });

    try app.scheduler.addSystem(.{
        .name = "visual_gpu.render_frame",
        .stage = .render_extract,
        .run = renderFrameSystem,
    });

    try app.initialize();

    const g_entry = try app.services.getService("engine.graphics.device", 1);
    const gfx: *graphics.GraphicsDeviceService = @ptrCast(@alignCast(@constCast(g_entry.api_ptr)));
    const i_entry = try app.services.getService("engine.input", 1);
    const input: *window.InputService = @ptrCast(@alignCast(@constCast(i_entry.api_ptr)));

    const px = window_sdl3.pixelSize(&app);
    const px_w: u32 = if (px) |p| p.width else 1280;
    const px_h: u32 = if (px) |p| p.height else 720;
    const dpi_scale: f32 = if (px) |p| p.dpi_scale else 1.0;

    const rt = try gfx.createSurface(1, px_w, px_h);
    try app.resources.insert(RenderState, .{
        .app = &app,
        .gfx = gfx,
        .input = input,
        .rt = rt,
    });

    const driver = graphics_sdlgpu.driverName(&app) orelse "unknown";
    std.debug.print("[visual-gpu] driver={s}, pixels={d}x{d}, dpi={d:.2}\n", .{
        driver,
        px_w,
        px_h,
        dpi_scale,
    });

    // Print startup Diagnostics recorded by graphics.sdlgpu.
    for (0..app.diagnostics.count()) |i| {
        if (app.diagnostics.get(i)) |rec| {
            std.debug.print("[diag:{s}] {s}\n", .{ rec.subsystem, rec.message });
        }
    }

    try window_sdl3.runVisualLoop(&app);
    std.debug.print("[visual-gpu] closed after {d} frames\n", .{app.diagnostics.frame_count});
}
