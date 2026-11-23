//! Visual Playground (D5) — Integrated 2D Scene + UI Panel (`examples/visual-playground/main.zig`).
//!
//! Combines `window_sdl3`, `graphics_sdlgpu`, `scene`, `render_2d`, and `ui_core`/`ui_markup`:
//! - Interactive 2D scene with `Camera2D` (WASD/Arrows to pan) and rotating/orbiting sprites.
//! - Translucent UI overlay panel with live FPS & sprite counter, "Spawn Sprite" button,
//!   and a clipped scrollable event log.
//! - Clicking on the canvas outside the UI panel also spawns a sprite at the cursor.
//!
//! Run with: `zig build run-visual-playground`

const std = @import("std");
const engine = @import("engine");
const window = @import("window");
const window_sdl3 = @import("window_sdl3");
const graphics = @import("graphics");
const graphics_sdlgpu = @import("graphics_sdlgpu");
const scene = @import("scene");
const render_2d = @import("render_2d");
const ui_core = @import("ui_core");
const ui_markup = @import("ui_markup");

const SpawnedSprite = struct {
    orbit_radius: f32,
    orbit_speed: f32,
    phase: f32,
    spin_speed: f32,
    base_x: f32,
    base_y: f32,
};

const PlaygroundState = struct {
    allocator: std.mem.Allocator,
    app: *engine.App,
    gfx: *graphics.GraphicsDeviceService,
    input: *window.InputService,
    tree: *ui_core.UiTree,
    rt: graphics.RenderTargetHandle,
    sprite_tex: graphics_sdlgpu.GpuTextureHandle,
    camera_entity: engine.EntityHandle,
    fps_idx: ?usize = null,
    log_list_idx: ?usize = null,
    panel_idx: ?usize = null,
    cmds: std.ArrayList(graphics.DrawCommand),
    sprite_count: u32 = 0,
    elapsed: f32 = 0.0,
    fps_accum: f32 = 0.0,
    fps_frames: u32 = 0,
    current_fps: f32 = 0.0,
};

fn spawnPlaygroundSprite(st: *PlaygroundState, wx: f32, wy: f32) !void {
    st.sprite_count += 1;
    const n = st.sprite_count;
    const e = try st.app.world.spawn();
    try st.app.world.set(e, scene.Transform2D, .{ .x = wx, .y = wy });

    const hue_sel = n % 3;
    const col: graphics.Color = switch (hue_sel) {
        0 => .{ .r = 0.95, .g = 0.45, .b = 0.35, .a = 0.95 },
        1 => .{ .r = 0.35, .g = 0.85, .b = 0.65, .a = 0.95 },
        else => .{ .r = 0.40, .g = 0.65, .b = 0.98, .a = 0.95 },
    };

    try st.app.world.set(e, render_2d.Sprite, .{
        .width = 56.0,
        .height = 56.0,
        .color = col,
        .texture_id = @bitCast(st.sprite_tex),
        .layer = @intCast(n),
    });
    try st.app.world.set(e, SpawnedSprite, .{
        .orbit_radius = 24.0 + @as(f32, @floatFromInt((n % 5) * 14)),
        .orbit_speed = 1.1 + @as(f32, @floatFromInt(n % 4)) * 0.35,
        .phase = @as(f32, @floatFromInt(n)) * 0.9,
        .spin_speed = if (n % 2 == 0) 1.8 else -1.8,
        .base_x = wx,
        .base_y = wy,
    });

    if (st.log_list_idx) |list_idx| {
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Spawned sprite #{d}", .{n}) catch "Spawned sprite";
        _ = try st.tree.createNode(list_idx, .{
            .id = "",
            .kind = .label,
            .text = msg,
            .style = .{
                .min_height = 18,
                .padding = 4,
                .bg_color = .{ .r = 0.12, .g = 0.15, .b = 0.20, .a = 0.9 },
            },
        });
    }
    st.app.diagnostics.log(.info, "visual.playground", "Spawned sprite") catch {};
}

fn onUiAction(user_ctx: ?*anyopaque, ev: engine.EventEnvelope) void {
    const st: *PlaygroundState = @ptrCast(@alignCast(user_ctx orelse return));
    if (std.mem.eql(u8, ev.payload, "playground.spawn")) {
        const angle = @as(f32, @floatFromInt(st.sprite_count)) * 0.85;
        const wx = 120.0 + @cos(angle) * 140.0;
        const wy = @sin(angle) * 120.0;
        spawnPlaygroundSprite(st, wx, wy) catch {};
    } else if (std.mem.eql(u8, ev.payload, "playground.scroll_down")) {
        if (st.log_list_idx) |li| st.tree.scrollNode(li, 18.0);
    } else if (std.mem.eql(u8, ev.payload, "playground.scroll_up")) {
        if (st.log_list_idx) |li| st.tree.scrollNode(li, -18.0);
    }
}

fn updatePlaygroundSystem(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(PlaygroundState) orelse return;
    st.elapsed += ctx.dt;
    st.fps_accum += ctx.dt;
    st.fps_frames += 1;

    if (st.fps_accum >= 0.25) {
        st.current_fps = @as(f32, @floatFromInt(st.fps_frames)) / st.fps_accum;
        st.fps_accum = 0.0;
        st.fps_frames = 0;
        if (st.fps_idx) |idx| {
            var buf: [64]u8 = undefined;
            const label = std.fmt.bufPrint(&buf, "FPS: {d:.0} | Sprites: {d}", .{ st.current_fps, st.sprite_count }) catch "FPS: ?";
            try st.tree.setNodeText(idx, label);
        }
    }

    // Camera2D pan with WASD (scancodes: A=4, D=7, S=22, W=26) or Arrow keys (Right=79, Left=80, Down=81, Up=82).
    if (ctx.world.get(st.camera_entity, render_2d.Camera2D)) |cam| {
        const pan_speed: f32 = 260.0 * ctx.dt;
        if (st.input.isKeyDown(4) or st.input.isKeyDown(80)) cam.x -= pan_speed;
        if (st.input.isKeyDown(7) or st.input.isKeyDown(79)) cam.x += pan_speed;
        if (st.input.isKeyDown(26) or st.input.isKeyDown(82)) cam.y -= pan_speed;
        if (st.input.isKeyDown(22) or st.input.isKeyDown(81)) cam.y += pan_speed;
    }

    // Animate all spawned sprites.
    var q = try ctx.query(.{ .read = .{SpawnedSprite}, .write = .{scene.Transform2D} });
    defer q.deinit();
    while (q.next()) |row| {
        const sp = row.read(SpawnedSprite);
        const t = row.write(scene.Transform2D);
        t.rotation_rad += ctx.dt * sp.spin_speed;
        t.x = sp.base_x + @cos(st.elapsed * sp.orbit_speed + sp.phase) * sp.orbit_radius;
        t.y = sp.base_y + @sin(st.elapsed * sp.orbit_speed + sp.phase) * sp.orbit_radius;
    }

    // Layout UI in logical coordinates.
    const px = window_sdl3.pixelSize(st.app);
    const dpi: f32 = if (px) |p| (if (p.dpi_scale > 0.0) p.dpi_scale else 1.0) else 1.0;
    const log_w: f32 = if (px) |p| @as(f32, @floatFromInt(p.width)) / dpi else 1280.0;
    const log_h: f32 = if (px) |p| @as(f32, @floatFromInt(p.height)) / dpi else 720.0;
    st.tree.layoutTree(log_w, log_h);

    // Handle left click: UI first, otherwise spawn sprite on canvas.
    if (st.input.wasMouseClicked(.left)) {
        const hit = st.tree.handlePointerClick(st.input.mouse_x, st.input.mouse_y, ctx.events);
        if (hit == null) {
            const cam: render_2d.Camera2D = if (ctx.world.getConst(st.camera_entity, render_2d.Camera2D)) |c| c.* else .{};
            const zoom = if (cam.zoom > 0.001) cam.zoom else 0.001;
            const wx = (st.input.mouse_x - log_w * 0.5) / zoom + cam.x;
            const wy = (st.input.mouse_y - log_h * 0.5) / zoom + cam.y;
            try spawnPlaygroundSprite(st, wx, wy);
        }
    }
}

fn renderPlaygroundSystem(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(PlaygroundState) orelse return;
    const frame = ctx.resources.get(render_2d.Render2DFrame) orelse return;

    const px = window_sdl3.pixelSize(st.app);
    const dpi: f32 = if (px) |p| (if (p.dpi_scale > 0.0) p.dpi_scale else 1.0) else 1.0;
    const px_w: f32 = if (px) |p| @floatFromInt(p.width) else 1280.0;
    const px_h: f32 = if (px) |p| @floatFromInt(p.height) else 720.0;
    frame.setViewport(px_w / dpi, px_h / dpi);

    st.cmds.clearRetainingCapacity();
    try st.cmds.append(st.allocator, .{ .clear = .{ .r = 0.05, .g = 0.07, .b = 0.11, .a = 1.0 } });

    try st.gfx.beginFrame(st.rt);

    // Queue 2D sprites (scaled from logical to physical pixels).
    for (frame.items.items) |item| {
        const tex: graphics_sdlgpu.GpuTextureHandle = if (item.texture_id != 0)
            @bitCast(item.texture_id)
        else
            graphics_sdlgpu.whiteTextureHandle(st.app).?;

        try graphics_sdlgpu.queueTexturedQuad(st.app, .{
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
            .texture = tex,
        });
    }

    // Paint UI overlay on top of the 2D scene.
    try st.tree.paint(st.allocator, &st.cmds);
    try st.gfx.submitDrawCommands(st.rt, st.cmds.items);
    try st.gfx.present(st.rt);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        if (gpa.deinit() == .leak) std.debug.print("[visual-playground] WARNING: memory leak detected\n", .{});
    }
    const allocator = gpa.allocator();

    var app = engine.App.init(allocator, .{});
    defer app.deinit();

    try app.registerModule(window_sdl3.module());
    try app.registerModule(graphics_sdlgpu.module());
    try app.registerModule(scene.module());
    try app.registerModule(render_2d.module());
    try app.registerModule(ui_core.module());

    try app.resources.insert(window_sdl3.WindowConfig, .{
        .title = "ZigEng — Visual Playground (D5)",
        .width = 1280,
        .height = 720,
        .resizable = true,
    });

    _ = try app.registerComponent(SpawnedSprite);

    try app.scheduler.addSystem(.{ .name = "visual_pg.update", .stage = .update, .run = updatePlaygroundSystem });
    try app.scheduler.addSystem(.{
        .name = "visual_pg.render",
        .stage = .render_extract,
        .after = &.{"render2d.extract"},
        .run = renderPlaygroundSystem,
    });

    try app.initialize();

    const i_entry = try app.services.getService("engine.input", 1);
    const input: *window.InputService = @ptrCast(@alignCast(@constCast(i_entry.api_ptr)));
    const g_entry = try app.services.getService("engine.graphics.device", 1);
    const gfx: *graphics.GraphicsDeviceService = @ptrCast(@alignCast(@constCast(g_entry.api_ptr)));
    const u_entry = try app.services.getService("engine.ui.tree", 1);
    const tree: *ui_core.UiTree = @ptrCast(@alignCast(@constCast(u_entry.api_ptr)));

    try ui_markup.parseIntoTree(allocator,
        \\<panel id="pg_panel">
        \\  <label id="pg_title">ZigEng Visual Playground</label>
        \\  <label id="pg_fps">FPS: -- | Sprites: 0</label>
        \\  <button id="spawn_btn" action="playground.spawn">Spawn Sprite</button>
        \\  <button id="log_dn" action="playground.scroll_down">Scroll Log Down</button>
        \\  <button id="log_up" action="playground.scroll_up">Scroll Log Up</button>
        \\  <virtual-list id="log_list">
        \\    <label id="log_boot">Ready (WASD pan, click to spawn)</label>
        \\  </virtual-list>
        \\</panel>
    , tree);

    const panel_idx = tree.findById("pg_panel");
    if (panel_idx) |pi| {
        tree.nodes.items[pi].style.width = 360.0;
        tree.nodes.items[pi].style.bg_color = .{ .r = 0.08, .g = 0.10, .b = 0.14, .a = 0.88 };
    }
    if (tree.findById("spawn_btn")) |bi| {
        tree.nodes.items[bi].style.bg_color = .{ .r = 0.16, .g = 0.48, .b = 0.78, .a = 1.0 };
    }
    const log_list_idx = tree.findById("log_list");
    if (log_list_idx) |li| {
        tree.nodes.items[li].style.height = 140.0;
        tree.nodes.items[li].style.clip_children = true;
        tree.nodes.items[li].style.bg_color = .{ .r = 0.06, .g = 0.08, .b = 0.11, .a = 0.92 };
    }

    var tex_pixels: [32 * 32 * 4]u8 = undefined;
    for (0..32) |y| {
        for (0..32) |x| {
            const idx = (y * 32 + x) * 4;
            const checker = ((x / 4) + (y / 4)) % 2 == 0;
            tex_pixels[idx + 0] = if (checker) 255 else 180;
            tex_pixels[idx + 1] = if (checker) 255 else 200;
            tex_pixels[idx + 2] = if (checker) 255 else 240;
            tex_pixels[idx + 3] = 255;
        }
    }
    const sprite_tex = try graphics_sdlgpu.createTextureRgba8(&app, 32, 32, &tex_pixels);

    const cam_e = try app.world.spawn();
    try app.world.set(cam_e, render_2d.Camera2D, .{ .x = 0.0, .y = 0.0, .zoom = 1.0, .active = true });

    const px = window_sdl3.pixelSize(&app);
    const px_w: u32 = if (px) |p| p.width else 1280;
    const px_h: u32 = if (px) |p| p.height else 720;
    const rt = try gfx.createSurface(1, px_w, px_h);

    try app.resources.insert(PlaygroundState, .{
        .allocator = allocator,
        .app = &app,
        .gfx = gfx,
        .input = input,
        .tree = tree,
        .rt = rt,
        .sprite_tex = sprite_tex,
        .camera_entity = cam_e,
        .fps_idx = tree.findById("pg_fps"),
        .log_list_idx = log_list_idx,
        .panel_idx = panel_idx,
        .cmds = .empty,
    });
    const st_ptr = app.resources.get(PlaygroundState).?;
    _ = try app.events.subscribe(9002, "ui.action", onUiAction, st_ptr);

    // Seed 2 initial sprites.
    try spawnPlaygroundSprite(st_ptr, 120.0, -40.0);
    try spawnPlaygroundSprite(st_ptr, 220.0, 60.0);

    try window_sdl3.runVisualLoop(&app);
    if (app.resources.get(PlaygroundState)) |st| {
        st.cmds.deinit(allocator);
    }
    std.debug.print("[visual-playground] closed after {d} frames\n", .{app.diagnostics.frame_count});
}
