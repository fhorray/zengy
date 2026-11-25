//! Visual 2D Hello (D3) — Textured Sprites, ECS Transform2D, Camera2D & Batching (`examples/visual-2d/main.zig`).
//!
//! Spawns ECS entities with `Transform2D`, `Sprite`, `Visibility`, and `Camera2D`,
//! uploads a procedural RGBA8 checkerboard texture, animates movement and rotation
//! in `.update`, extracts visible sprites in `.render_extract`, and submits batched
//! textured quads to `official.graphics.wgpu`.
//!
//! Run with: `zig build run-visual-2d`

const std = @import("std");
const engine = @import("engine");
const window = @import("window");
const window_sdl3 = @import("window_sdl3");
const graphics = @import("graphics");
const wgpu = @import("graphics_wgpu");
const draw_2d = @import("draw_2d");
const scene = @import("scene");
const camera = @import("camera");
const render_2d = @import("render_2d");

const Demo2DState = struct {
    app: *engine.App,
    gfx: *graphics.GraphicsDeviceService,
    input: *window.InputService,
    rt: graphics.RenderTargetHandle,
    checker_tex: draw_2d.TextureId,
    camera_entity: engine.EntityHandle,
    spinner: engine.EntityHandle,
    orbiter: engine.EntityHandle,
    anchor_x: f32 = 0.0,
    anchor_y: f32 = 0.0,
    spin_dir: f32 = 1.0,
    paused: bool = false,
    elapsed: f32 = 0.0,
};

fn update2DSystem(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(Demo2DState) orelse return;

    const px = window_sdl3.pixelSize(st.app);
    const dpi: f32 = if (px) |p| (if (p.dpi_scale > 0.0) p.dpi_scale else 1.0) else 1.0;
    const log_w: f32 = if (px) |p| @as(f32, @floatFromInt(p.width)) / dpi else 1280.0;
    const log_h: f32 = if (px) |p| @as(f32, @floatFromInt(p.height)) / dpi else 720.0;

    // Pan CameraPose with WASD or Arrow keys.
    if (ctx.world.get(st.camera_entity, camera.CameraPose)) |pose| {
        const pan_speed: f32 = 260.0 * ctx.dt;
        if (st.input.isKeyDown(4) or st.input.isKeyDown(80)) pose.position[0] -= pan_speed;
        if (st.input.isKeyDown(7) or st.input.isKeyDown(79)) pose.position[0] += pan_speed;
        if (st.input.isKeyDown(26) or st.input.isKeyDown(82)) pose.position[1] -= pan_speed;
        if (st.input.isKeyDown(22) or st.input.isKeyDown(81)) pose.position[1] += pan_speed;
    }

    // Left click moves the orbit anchor to the clicked world position and reverses spin.
    if (st.input.wasMouseClicked(.left)) {
        const pose: camera.CameraPose = if (ctx.world.getConst(st.camera_entity, camera.CameraPose)) |p| p.* else .{};
        const zoom: f32 = if (ctx.world.getConst(st.camera_entity, camera.Projection)) |pr|
            (if (pr.* == .orthographic and pr.orthographic.scale > 0.001) 1.0 / pr.orthographic.scale else 1.0)
        else
            1.0;
        st.anchor_x = (st.input.mouse_x - log_w * 0.5) / zoom + pose.position[0];
        st.anchor_y = (st.input.mouse_y - log_h * 0.5) / zoom + pose.position[1];
        st.spin_dir = -st.spin_dir;
        std.debug.print("[visual-2d] left click -> anchor=({d:.1}, {d:.1})\n", .{ st.anchor_x, st.anchor_y });
    }

    // Right click pauses/resumes animation.
    if (st.input.wasMouseClicked(.right)) {
        st.paused = !st.paused;
        std.debug.print("[visual-2d] right click -> paused={}\n", .{st.paused});
    }

    if (!st.paused) {
        st.elapsed += ctx.dt * st.spin_dir;
        if (ctx.world.get(st.spinner, scene.Transform2D)) |t| {
            t.rotation_rad += ctx.dt * 1.6 * st.spin_dir;
            t.x = st.anchor_x + @cos(st.elapsed * 0.9) * 140.0;
            t.y = st.anchor_y + @sin(st.elapsed * 1.3) * 80.0;
        }
        if (ctx.world.get(st.orbiter, scene.Transform2D)) |t| {
            t.rotation_rad -= ctx.dt * 2.4 * st.spin_dir;
            t.x = st.anchor_x + @cos(st.elapsed * 2.0 + 1.5) * 220.0;
            t.y = st.anchor_y + @sin(st.elapsed * 2.0 + 1.5) * 120.0;
        }
    }
}

fn render2DSystem(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(Demo2DState) orelse return;
    const frame = ctx.resources.get(render_2d.Render2DFrame) orelse return;

    const px = window_sdl3.pixelSize(st.app);
    const dpi: f32 = if (px) |p| (if (p.dpi_scale > 0.0) p.dpi_scale else 1.0) else 1.0;
    const px_w: f32 = if (px) |p| @floatFromInt(p.width) else 1280.0;
    const px_h: f32 = if (px) |p| @floatFromInt(p.height) else 720.0;
    frame.setViewport(px_w / dpi, px_h / dpi);

    try st.gfx.beginFrame(st.rt);
    try st.gfx.submitDrawCommands(st.rt, &.{
        .{ .clear = .{ .r = 0.06, .g = 0.08, .b = 0.12, .a = 1.0 } },
    });

    for (frame.items.items) |item| {
        try draw_2d.queueTexturedQuad(st.app, .{
            .x = item.screen_x * dpi,
            .y = item.screen_y * dpi,
            .width = item.screen_w * dpi,
            .height = item.screen_h * dpi,
            .rotation_rad = item.rotation_rad,
            .u0 = item.uv_min[0],
            .v0 = item.uv_min[1],
            .u1 = item.uv_max[0],
            .v1 = item.uv_max[1],
            .color = item.color,
            .texture = item.texture_id,
        });
    }

    try st.gfx.present(st.rt);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        if (gpa.deinit() == .leak) std.debug.print("[visual-2d] WARNING: memory leak detected\n", .{});
    }
    const allocator = gpa.allocator();

    var app = engine.App.init(allocator, .{});
    defer app.deinit();

    try app.registerModule(window_sdl3.module());
    try app.registerModule(wgpu.module());
    try app.registerModule(draw_2d.module());
    try app.registerModule(scene.module());
    try app.registerModule(camera.module());
    try app.registerModule(render_2d.module());

    try app.resources.insert(window_sdl3.WindowConfig, .{
        .title = "Zengy — Visual 2D Hello (D3)",
        .width = 1280,
        .height = 720,
        .resizable = true,
    });

    try app.scheduler.addSystem(.{
        .name = "visual_2d.update",
        .stage = .update,
        .run = update2DSystem,
    });
    try app.scheduler.addSystem(.{
        .name = "visual_2d.render",
        .stage = .render_extract,
        .after = &.{"render2d.extract"},
        .run = render2DSystem,
    });

    try app.initialize();

    const g_entry = try app.services.getService("engine.graphics.device", 1);
    const gfx: *graphics.GraphicsDeviceService = @ptrCast(@alignCast(@constCast(g_entry.api_ptr)));
    const i_entry = try app.services.getService("engine.input", 1);
    const input: *window.InputService = @ptrCast(@alignCast(@constCast(i_entry.api_ptr)));

    const px = window_sdl3.pixelSize(&app);
    const px_w: u32 = if (px) |p| p.width else 1280;
    const px_h: u32 = if (px) |p| p.height else 720;
    const rt = try gfx.createSurface(1, px_w, px_h);

    // Build a 32x32 RGBA8 checkerboard texture.
    var tex_pixels: [32 * 32 * 4]u8 = undefined;
    for (0..32) |y| {
        for (0..32) |x| {
            const idx = (y * 32 + x) * 4;
            const checker = ((x / 4) + (y / 4)) % 2 == 0;
            tex_pixels[idx + 0] = if (checker) 240 else 60;
            tex_pixels[idx + 1] = if (checker) 220 else 130;
            tex_pixels[idx + 2] = if (checker) 180 else 220;
            tex_pixels[idx + 3] = 255;
        }
    }
    const checker_tex = try graphics.createTextureRgba8(&app, 32, 32, &tex_pixels);

    const cam = try app.world.spawn();
    try app.world.set(cam, camera.Camera, .{});
    try app.world.set(cam, camera.CameraPose, .{ .position = .{ 0.0, 0.0, 0.0 } });
    try app.world.set(cam, camera.Projection, .{ .orthographic = .{ .scale = 1.0 } });

    const spinner = try app.world.spawn();
    try app.world.set(spinner, scene.Transform2D, .{ .x = 0.0, .y = 0.0 });
    try app.world.set(spinner, render_2d.Sprite, .{
        .width = 140.0,
        .height = 140.0,
        .texture_id = checker_tex,
        .layer = 1,
    });

    const orbiter = try app.world.spawn();
    try app.world.set(orbiter, scene.Transform2D, .{ .x = 180.0, .y = 0.0 });
    try app.world.set(orbiter, render_2d.Sprite, .{
        .width = 90.0,
        .height = 90.0,
        .color = .{ .r = 0.25, .g = 0.85, .b = 0.65, .a = 0.85 },
        .texture_id = checker_tex,
        .layer = 2,
    });

    try app.resources.insert(Demo2DState, .{
        .app = &app,
        .gfx = gfx,
        .input = input,
        .rt = rt,
        .checker_tex = checker_tex,
        .camera_entity = cam,
        .spinner = spinner,
        .orbiter = orbiter,
    });

    try window_sdl3.runVisualLoop(&app);
    std.debug.print("[visual-2d] closed after {d} frames\n", .{app.diagnostics.frame_count});
}
