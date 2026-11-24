//! Visual 3D Hello (Phase E) — 3D Meshes, Depth Buffer, Camera3D & Frustum Culling (`examples/visual-3d/main.zig`).
//!
//! Renders spinning 3D cubes with a checkerboard RGBA8 texture, depth-tested unlit shading,
//! `Camera3D` projection/culling in `.render_extract`, and a 2D HUD text overlay.
//! Use WASD / Arrow keys to move the camera.
//!
//! Run with: `zig build run-visual-3d`

const std = @import("std");
const engine = @import("engine");
const window = @import("window");
const window_sdl3 = @import("window_sdl3");
const graphics = @import("graphics");
const graphics_sdlgpu = @import("graphics_sdlgpu");
const camera = @import("camera");
const render_3d = @import("render_3d");

const Demo3DState = struct {
    allocator: std.mem.Allocator,
    app: *engine.App,
    gfx: *graphics.GraphicsDeviceService,
    input: *window.InputService,
    rt: graphics.RenderTargetHandle,
    cube_mesh: graphics_sdlgpu.GpuMeshHandle,
    checker_tex: graphics_sdlgpu.GpuTextureHandle,
    cam_entity: engine.EntityHandle,
    center_cube: engine.EntityHandle,
    orbit_cube: engine.EntityHandle,
    elapsed: f32 = 0.0,
};

fn update3DSystem(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(Demo3DState) orelse return;
    st.elapsed += ctx.dt;

    if (ctx.world.get(st.cam_entity, camera.CameraPose)) |pose| {
        const speed: f32 = 4.5 * ctx.dt;
        if (st.input.isKeyDown(4) or st.input.isKeyDown(80)) pose.position[0] -= speed; // A / Left
        if (st.input.isKeyDown(7) or st.input.isKeyDown(79)) pose.position[0] += speed; // D / Right
        if (st.input.isKeyDown(26) or st.input.isKeyDown(82)) pose.position[2] -= speed; // W / Up
        if (st.input.isKeyDown(22) or st.input.isKeyDown(81)) pose.position[2] += speed; // S / Down
    }

    if (ctx.world.get(st.center_cube, render_3d.Transform3D)) |t| {
        t.rotation_euler[1] += ctx.dt * 1.1;
        t.rotation_euler[0] += ctx.dt * 0.5;
    }
    if (ctx.world.get(st.orbit_cube, render_3d.Transform3D)) |t| {
        t.position[0] = @cos(st.elapsed * 1.4) * 2.6;
        t.position[2] = @sin(st.elapsed * 1.4) * 2.6;
        t.rotation_euler[1] -= ctx.dt * 1.8;
    }
}

fn render3DSystem(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(Demo3DState) orelse return;
    const r3d = ctx.resources.get(render_3d.Render3DService) orelse return;

    const px = window_sdl3.pixelSize(st.app);
    const px_w: u32 = if (px) |p| p.width else 1280;
    const px_h: u32 = if (px) |p| p.height else 720;
    if (ctx.resources.get(camera.CameraService)) |cam_svc| {
        cam_svc.setPrimaryTargetSize(px_w, px_h);
    }
    r3d.setViewportSize(@floatFromInt(px_w), @floatFromInt(px_h));

    try st.gfx.beginFrame(st.rt);
    try st.gfx.submitDrawCommands(st.rt, &.{
        .{ .clear = .{ .r = 0.05, .g = 0.07, .b = 0.11, .a = 1.0 } },
        .{ .text = .{
            .x = 20.0,
            .y = 20.0,
            .content = "Zengy Phase E: 3D Unlit + Depth + Frustum Culling (WASD move)",
            .color = .{ .r = 0.92, .g = 0.95, .b = 1.0, .a = 1.0 },
        } },
    });

    for (r3d.extracted_draws.items) |draw| {
        const mesh_handle: graphics_sdlgpu.GpuMeshHandle = @bitCast(draw.mesh_asset);
        const tex: ?graphics_sdlgpu.GpuTextureHandle = if (draw.material_id == 1) st.checker_tex else null;
        try graphics_sdlgpu.queueMeshDraw(st.app, mesh_handle, draw.mvp_matrix.m, draw.color, tex);
    }

    try st.gfx.present(st.rt);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        if (gpa.deinit() == .leak) std.debug.print("[visual-3d] WARNING: memory leak detected\n", .{});
    }
    const allocator = gpa.allocator();

    var app = engine.App.init(allocator, .{});
    defer app.deinit();

    try app.registerModule(window_sdl3.module());
    try app.registerModule(graphics_sdlgpu.module());
    try app.registerModule(camera.module());
    try app.registerModule(render_3d.module());

    try app.resources.insert(window_sdl3.WindowConfig, .{
        .title = "Zengy — Phase E Visual 3D",
        .width = 1280,
        .height = 720,
        .resizable = true,
    });

    try app.scheduler.addSystem(.{ .name = "visual_3d.update", .stage = .update, .run = update3DSystem });
    try app.scheduler.addSystem(.{
        .name = "visual_3d.render",
        .stage = .render_extract,
        .after = &.{"render3d.extract"},
        .run = render3DSystem,
    });

    try app.initialize();

    const i_entry = try app.services.getService("engine.input", 1);
    const input: *window.InputService = @ptrCast(@alignCast(@constCast(i_entry.api_ptr)));
    const g_entry = try app.services.getService("engine.graphics.device", 1);
    const gfx: *graphics.GraphicsDeviceService = @ptrCast(@alignCast(@constCast(g_entry.api_ptr)));

    var cube = try render_3d.gltf.createCubeMesh(allocator, 0.75);
    defer cube.deinit();
    const gpu_cube = try graphics_sdlgpu.createMesh3D(&app, std.mem.sliceAsBytes(cube.vertices), cube.indices);

    var tex_pixels: [32 * 32 * 4]u8 = undefined;
    for (0..32) |y| {
        for (0..32) |x| {
            const idx = (y * 32 + x) * 4;
            const checker = ((x / 4) + (y / 4)) % 2 == 0;
            tex_pixels[idx + 0] = if (checker) 245 else 75;
            tex_pixels[idx + 1] = if (checker) 235 else 145;
            tex_pixels[idx + 2] = if (checker) 210 else 230;
            tex_pixels[idx + 3] = 255;
        }
    }
    const checker_tex = try graphics_sdlgpu.createTextureRgba8(&app, 32, 32, &tex_pixels);

    const cam_e = try app.world.spawn();
    try app.world.set(cam_e, camera.Camera, .{});
    try app.world.set(cam_e, camera.Projection, .{ .perspective = .{ .fov_rad = std.math.pi / 3.0 } });
    try app.world.set(cam_e, camera.CameraPose, camera.CameraPose.lookAt(.{ 0.0, 2.2, 6.5 }, .{ 0.0, 0.0, 0.0 }, .{ 0.0, 1.0, 0.0 }));

    const center_cube = try app.world.spawn();
    try app.world.set(center_cube, render_3d.Transform3D, .{ .position = .{ 0, 0.2, 0 } });
    try app.world.set(center_cube, render_3d.MeshRef, .{
        .mesh_asset = @bitCast(gpu_cube),
        .material_id = 1,
        .bounds_radius = cube.bounds_radius,
        .color = .{ 1.0, 1.0, 1.0, 1.0 },
    });

    const orbit_cube = try app.world.spawn();
    try app.world.set(orbit_cube, render_3d.Transform3D, .{
        .position = .{ 2.6, 0.0, 0.0 },
        .scale = .{ 0.65, 0.65, 0.65 },
    });
    try app.world.set(orbit_cube, render_3d.MeshRef, .{
        .mesh_asset = @bitCast(gpu_cube),
        .material_id = 0,
        .bounds_radius = cube.bounds_radius,
        .color = .{ 0.35, 0.85, 0.65, 1.0 },
    });

    const floor_cube = try app.world.spawn();
    try app.world.set(floor_cube, render_3d.Transform3D, .{
        .position = .{ 0.0, -1.2, 0.0 },
        .scale = .{ 5.0, 0.12, 5.0 },
    });
    try app.world.set(floor_cube, render_3d.MeshRef, .{
        .mesh_asset = @bitCast(gpu_cube),
        .material_id = 0,
        .bounds_radius = cube.bounds_radius,
        .color = .{ 0.22, 0.27, 0.36, 1.0 },
    });

    const px = window_sdl3.pixelSize(&app);
    const px_w: u32 = if (px) |p| p.width else 1280;
    const px_h: u32 = if (px) |p| p.height else 720;
    const rt = try gfx.createSurface(1, px_w, px_h);

    try app.resources.insert(Demo3DState, .{
        .allocator = allocator,
        .app = &app,
        .gfx = gfx,
        .input = input,
        .rt = rt,
        .cube_mesh = gpu_cube,
        .checker_tex = checker_tex,
        .cam_entity = cam_e,
        .center_cube = center_cube,
        .orbit_cube = orbit_cube,
    });

    try window_sdl3.runVisualLoop(&app);
    std.debug.print("[visual-3d] closed after {d} frames\n", .{app.diagnostics.frame_count});
}
