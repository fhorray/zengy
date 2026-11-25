//! wgpu showcase: window + `official.graphics.wgpu` + `official.render.2d.draw`. No SDL_GPU module is registered.
//!
//! Exercises the full 2D path on the new stack: solid and rounded rects, borders, gradients, the color wheel,
//! Lucide icons, TTF text with alignment, nested clipping, and a user-uploaded texture quad.
const std = @import("std");
const engine = @import("engine");
const window_sdl3 = @import("window_sdl3");
const graphics = @import("graphics");
const wgpu = @import("graphics_wgpu");
const draw_2d = @import("draw_2d");

const State = struct {
    app: *engine.App,
    gfx: *graphics.GraphicsDeviceService,
    target: graphics.RenderTargetHandle,
    checker: draw_2d.TextureId = 0,
    time: f32 = 0,
};

fn color(r: f32, g: f32, b: f32, a: f32) graphics.Color {
    return .{ .r = r, .g = g, .b = b, .a = a };
}

fn render(ctx: *engine.SystemContext) !void {
    const state = ctx.resources.get(State) orelse return;
    state.time += 1.0 / 60.0;
    const hue = @mod(state.time * 40.0, 360.0);

    try state.gfx.beginFrame(state.target);

    // Sprite-style quad: a user texture (4x4 checker) drawn under the command list, in physical pixels.
    try draw_2d.queueTexturedQuad(state.app, .{ .x = 940, .y = 40, .width = 160, .height = 160, .texture = state.checker });

    const white = color(1, 1, 1, 1);
    const panel = color(0.12, 0.14, 0.2, 1);
    try state.gfx.submitDrawCommands(state.target, &.{
        .{ .clear = .{ .r = 0.07, .g = 0.09, .b = 0.13 } },
        .{ .rounded_rect = .{ .x = 24, .y = 24, .width = 400, .height = 200, .color = panel, .border_color = color(0.3, 0.6, 1, 1), .border_widths = .{ 2, 2, 2, 2 }, .corner_radii = .{ 14, 14, 14, 14 } } },
        .{ .text = .{ .x = 44, .y = 40, .content = "wgpu-native + Zengy", .color = white, .scale = 3.0 } },
        .{ .text = .{ .x = 44, .y = 84, .content = "Render2D on the neutral GPU contract", .color = color(0.7, 0.8, 1, 1), .scale = 1.6 } },
        .{ .icon = .{ .x = 44, .y = 128, .size = 28, .kind = .check_circle, .color = color(0.3, 0.9, 0.5, 1) } },
        .{ .icon = .{ .x = 84, .y = 128, .size = 28, .kind = .settings, .color = white } },
        .{ .icon = .{ .x = 124, .y = 128, .size = 28, .kind = .search, .color = white } },
        .{ .icon = .{ .x = 164, .y = 128, .size = 28, .kind = .alert_triangle, .color = color(1, 0.8, 0.2, 1) } },

        .{ .gradient_rect = .{ .x = 24, .y = 248, .width = 400, .height = 28, .kind = .hue_horizontal } },
        .{ .gradient_rect = .{ .x = 24, .y = 288, .width = 400, .height = 28, .kind = .linear_horizontal, .stops = .{ color(1, 0.2, 0.3, 1), color(0.2, 0.4, 1, 1), white, white }, .corner_radii = .{ 6, 6, 6, 6 } } },
        .{ .color_wheel = .{ .x = 450, .y = 24, .size = 200, .hue_deg = hue } },

        // Nested clipping: the long text and the oversized rect are cut by the inner clip.
        .{ .rounded_rect = .{ .x = 24, .y = 340, .width = 300, .height = 120, .color = panel, .corner_radii = .{ 10, 10, 10, 10 } } },
        .{ .clip_push = .{ .x = 24, .y = 340, .width = 300, .height = 120 } },
        .{ .clip_push = .{ .x = 44, .y = 360, .width = 260, .height = 80 } },
        .{ .rect = .{ .x = 0, .y = 0, .width = 2000, .height = 2000, .color = color(0.2, 0.25, 0.4, 1) } },
        .{ .text = .{ .x = 50, .y = 370, .content = "This text is clipped by two nested scissor rectangles and keeps going past the edge", .color = white, .scale = 2.0 } },
        .clip_pop,
        .clip_pop,
        .{ .text = .{ .x = 24, .y = 470, .content = "Centered", .color = white, .scale = 2.0, .align_mode = .center, .box_width = 300 } },
        .{ .text = .{ .x = 24, .y = 500, .content = "Right aligned", .color = white, .scale = 2.0, .align_mode = .right, .box_width = 300 } },

        .{ .rect = .{ .x = 700, .y = 260, .width = 220, .height = 120, .color = color(0.9, 0.3, 0.3, 0.85) } },
        .{ .rect = .{ .x = 760, .y = 300, .width = 220, .height = 120, .color = color(0.3, 0.5, 0.95, 0.6) } },
    });
    try state.gfx.present(state.target);
}

fn checkerPixels() [4 * 4 * 4]u8 {
    var pixels: [4 * 4 * 4]u8 = undefined;
    for (0..4) |y| {
        for (0..4) |x| {
            const on = (x + y) % 2 == 0;
            const i = (y * 4 + x) * 4;
            pixels[i..][0..4].* = if (on) .{ 240, 200, 60, 255 } else .{ 40, 60, 140, 255 };
        }
    }
    return pixels;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        if (gpa.deinit() == .leak) std.debug.print("[visual-wgpu] memory leak\n", .{});
    }
    var app = engine.App.init(gpa.allocator(), .{});
    defer app.deinit();
    try app.registerModule(window_sdl3.module());
    try app.registerModule(wgpu.module());
    try app.registerModule(draw_2d.module());
    try app.resources.insert(window_sdl3.WindowConfig, .{ .title = "Zengy - wgpu", .width = 1280, .height = 720, .resizable = true, .metal_view = true });
    try app.scheduler.addSystem(.{ .name = "visual_wgpu.render", .stage = .render_extract, .run = render });
    try app.initialize();

    const entry = try app.services.getService("engine.graphics.device", 1);
    const gfx: *graphics.GraphicsDeviceService = @ptrCast(@alignCast(@constCast(entry.api_ptr)));
    const px = window_sdl3.pixelSize(&app);
    const target = try gfx.createSurface(1, if (px) |p| p.width else 1280, if (px) |p| p.height else 720);
    defer _ = gfx.destroySurface(target);

    const pixels = checkerPixels();
    const checker = try graphics.createTextureRgba8(&app, 4, 4, &pixels);
    defer graphics.destroyTexture(&app, checker);

    try app.resources.insert(State, .{ .app = &app, .gfx = gfx, .target = target, .checker = checker });

    const caps = gfx.capabilities().detected.?;
    std.debug.print("[visual-wgpu] driver={s} adapter='{s}' compute={} timestamps={}\n", .{
        wgpu.driverName(&app) orelse "unknown",
        caps.info.name(),
        caps.supportsCompute(),
        caps.features.timestamp_query,
    });
    try window_sdl3.runVisualLoop(&app);
}
