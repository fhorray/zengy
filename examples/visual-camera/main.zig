//! Visual Camera & Bevy-style Input Demo (`examples/visual-camera/main.zig`).
//!
//! Demonstrates `official.camera` (`Camera`, `Projection`, `CameraPose`, `FreeCamera`,
//! `Frustum`, `viewportToWorld` ray picking) and `official.input` (`KeyInput`,
//! `MouseInput`, `AccumulatedMouseMotion`, `AccumulatedMouseScroll`).
//!
//! Controls:
//! - `WASD` + `Q`/`E`: Fly horizontally / vertically (`Shift` to sprint)
//! - `Right Mouse Drag`: Look around (yaw / pitch)
//! - `Mouse Wheel`: Adjust fly speed
//! - `1` / `2`: Switch between Perspective and Orthographic projection
//! - `Left Click`: Ray-pick 3D cubes using `Camera.viewportToWorld`
//!
//! Run with: `zig build run-visual-camera`

const std = @import("std");
const engine = @import("engine");
const window = @import("window");
const window_sdl3 = @import("window_sdl3");
const graphics = @import("graphics");
const wgpu = @import("graphics_wgpu");
const draw_2d = @import("draw_2d");
const gpu_3d = @import("gpu_3d");
const input = @import("input");
const camera = @import("camera");
const render_3d = @import("render_3d");

const CubeItem = struct {
    entity: engine.EntityHandle,
    name: []const u8,
    base_color: [4]f32,
    radius: f32,
};

const VisualCameraState = struct {
    app: *engine.App,
    gfx: *graphics.GraphicsDeviceService,
    rt: graphics.RenderTargetHandle,
    cube_mesh: gpu_3d.MeshHandle,
    checker_tex: graphics.TextureId,
    cam_entity: engine.EntityHandle,
    cubes: [4]CubeItem,
    selected_idx: ?usize = null,
    elapsed: f32 = 0.0,
    hud_buf: [160]u8 = @splat(0),
    hud_len: usize = 0,
};

fn raySphereDist(ray: camera.Ray3D, center: [3]f32, radius: f32) ?f32 {
    const oc = [3]f32{
        ray.origin[0] - center[0],
        ray.origin[1] - center[1],
        ray.origin[2] - center[2],
    };
    const b = oc[0] * ray.direction[0] + oc[1] * ray.direction[1] + oc[2] * ray.direction[2];
    const c = oc[0] * oc[0] + oc[1] * oc[1] + oc[2] * oc[2] - radius * radius;
    const disc = b * b - c;
    if (disc < 0.0) return null;
    const t = -b - @sqrt(disc);
    return if (t >= 0.0) t else null;
}

fn updateDemoSystem(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(VisualCameraState) orelse return;
    const keys = ctx.resources.get(input.KeyInput) orelse return;
    const mouse = ctx.resources.get(input.MouseInput) orelse return;
    const motion = ctx.resources.get(input.AccumulatedMouseMotion) orelse return;

    st.elapsed += ctx.dt;

    // Spin center cube and orbit satellite cube.
    if (ctx.world.get(st.cubes[0].entity, render_3d.Transform3D)) |t| {
        t.rotation_euler[1] += ctx.dt * 1.1;
        t.rotation_euler[0] += ctx.dt * 0.4;
    }
    if (ctx.world.get(st.cubes[1].entity, render_3d.Transform3D)) |t| {
        t.position[0] = @cos(st.elapsed * 1.2) * 2.8;
        t.position[2] = @sin(st.elapsed * 1.2) * 2.8;
        t.rotation_euler[1] -= ctx.dt * 1.6;
    }

    // Switch Perspective (1) vs Orthographic (2).
    if (keys.justPressed(.digit_1)) {
        try ctx.world.set(st.cam_entity, camera.Projection, .{ .perspective = .{ .fov_rad = std.math.pi / 3.0 } });
    } else if (keys.justPressed(.digit_2)) {
        try ctx.world.set(st.cam_entity, camera.Projection, .{ .orthographic = .{ .scaling_mode = .{ .fixed_vertical = 8.0 } } });
    }

    // Left-click 3D ray picking via Camera.viewportToWorld.
    if (mouse.justPressed(.left)) {
        if (ctx.world.get(st.cam_entity, camera.Camera)) |cam| {
            if (cam.viewportToWorld(motion.position)) |ray| {
                var best_idx: ?usize = null;
                var best_t: f32 = std.math.floatMax(f32);
                for (st.cubes, 0..) |item, i| {
                    if (ctx.world.get(item.entity, render_3d.Transform3D)) |t| {
                        if (raySphereDist(ray, t.position, item.radius)) |hit_t| {
                            if (hit_t < best_t) {
                                best_t = hit_t;
                                best_idx = i;
                            }
                        }
                    }
                }
                st.selected_idx = best_idx;
            }
        }
    }
}

fn renderDemoSystem(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(VisualCameraState) orelse return;
    const cam_svc = ctx.resources.get(camera.CameraService) orelse return;

    const px = window_sdl3.pixelSize(st.app);
    const px_w: u32 = if (px) |p| p.width else 1280;
    const px_h: u32 = if (px) |p| p.height else 720;
    cam_svc.setPrimaryTargetSize(px_w, px_h);

    const cam = ctx.world.get(st.cam_entity, camera.Camera) orelse return;
    const proj_name: []const u8 = if (ctx.world.get(st.cam_entity, camera.Projection)) |p| switch (p.*) {
        .perspective => "Perspective [1]",
        .orthographic => "Orthographic [2]",
    } else "Perspective";
    const sel_name: []const u8 = if (st.selected_idx) |idx| st.cubes[idx].name else "None (Left-Click cube)";
    const hud = std.fmt.bufPrint(
        &st.hud_buf,
        "{s} | Fly: WASD+QE (Shift) | Look: RMB | Pick: {s}",
        .{ proj_name, sel_name },
    ) catch "Camera Demo";
    st.hud_len = hud.len;

    try st.gfx.beginFrame(st.rt);
    try st.gfx.submitDrawCommands(st.rt, &.{
        .{ .clear = .{ .r = 0.05, .g = 0.07, .b = 0.11, .a = 1.0 } },
        .{ .text = .{
            .x = 18.0,
            .y = 18.0,
            .content = st.hud_buf[0..st.hud_len],
            .color = .{ .r = 0.92, .g = 0.95, .b = 1.0, .a = 1.0 },
        } },
    });

    const vp = render_3d.math3d.Mat4{ .m = cam.computed.clip_from_world };

    // Draw floor + cubes using camera.Camera.computed.clip_from_world + frustum culling.
    var mesh_q = try ctx.query(.{ .read = .{ render_3d.Transform3D, render_3d.MeshRef } });
    defer mesh_q.deinit();
    while (mesh_q.next()) |row| {
        const t = row.read(render_3d.Transform3D);
        const m = row.read(render_3d.MeshRef);

        if (m.bounds_radius > 0.0) {
            const max_scale = @max(@abs(t.scale[0]), @max(@abs(t.scale[1]), @abs(t.scale[2])));
            if (!cam.computed.frustum.containsSphere(t.position, m.bounds_radius * max_scale)) {
                continue;
            }
        }

        var col = m.color;
        if (st.selected_idx) |s_idx| {
            if (row.entity.index == st.cubes[s_idx].entity.index) {
                col = .{ 1.0, 0.85, 0.25, 1.0 };
            }
        }

        const model = t.toModelMatrix();
        const mvp = render_3d.math3d.Mat4.mul(vp, model);
        const tex: ?graphics.TextureId = if (m.material_id == 1) st.checker_tex else null;
        try gpu_3d.queueMeshDraw(st.app, st.cube_mesh, mvp.m, col, tex);
    }

    try st.gfx.present(st.rt);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        if (gpa.deinit() == .leak) std.debug.print("[visual-camera] WARNING: memory leak detected\n", .{});
    }
    const allocator = gpa.allocator();

    var app = engine.App.init(allocator, .{});
    defer app.deinit();

    try app.registerModule(window_sdl3.module());
    try app.registerModule(wgpu.module());
    try app.registerModule(draw_2d.module());
    try app.registerModule(gpu_3d.module());
    try app.registerModule(input.module());
    try app.registerModule(camera.module());

    try app.resources.insert(window_sdl3.WindowConfig, .{
        .title = "Zengy — Visual Camera & Input Demo",
        .width = 1280,
        .height = 720,
        .resizable = true,
    });

    try app.scheduler.addSystem(.{ .name = "visual_camera.update", .stage = .update, .run = updateDemoSystem });
    try app.scheduler.addSystem(.{ .name = "visual_camera.render", .stage = .render_extract, .run = renderDemoSystem });

    try app.initialize();

    const g_entry = try app.services.getService("engine.graphics.device", 1);
    const gfx: *graphics.GraphicsDeviceService = @ptrCast(@alignCast(@constCast(g_entry.api_ptr)));

    var cube = try render_3d.gltf.createCubeMesh(allocator, 0.75);
    defer cube.deinit();
    const gpu_cube = try gpu_3d.createMesh3D(&app, std.mem.sliceAsBytes(cube.vertices), cube.indices);

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
    const checker_tex = try graphics.createTextureRgba8(&app, 32, 32, &tex_pixels);

    const cam_e = try app.world.spawn();
    try app.world.set(cam_e, camera.Camera, .{ .order = 0 });
    try app.world.set(cam_e, camera.Projection, .{ .perspective = .{ .fov_rad = std.math.pi / 3.0 } });
    try app.world.set(cam_e, camera.CameraPose, camera.CameraPose.lookAt(.{ 0.0, 2.4, 7.0 }, .{ 0.0, 0.0, 0.0 }, .{ 0.0, 1.0, 0.0 }));
    try app.world.set(cam_e, camera.FreeCamera, .{});

    const center_cube = try app.world.spawn();
    try app.world.set(center_cube, render_3d.Transform3D, .{ .position = .{ 0.0, 0.2, 0.0 } });
    try app.world.set(center_cube, render_3d.MeshRef, .{
        .mesh_asset = @bitCast(gpu_cube),
        .material_id = 1,
        .bounds_radius = cube.bounds_radius,
        .color = .{ 1.0, 1.0, 1.0, 1.0 },
    });

    const orbit_cube = try app.world.spawn();
    try app.world.set(orbit_cube, render_3d.Transform3D, .{ .position = .{ 2.8, 0.0, 0.0 }, .scale = .{ 0.7, 0.7, 0.7 } });
    try app.world.set(orbit_cube, render_3d.MeshRef, .{
        .mesh_asset = @bitCast(gpu_cube),
        .material_id = 0,
        .bounds_radius = cube.bounds_radius,
        .color = .{ 0.35, 0.85, 0.65, 1.0 },
    });

    const left_pillar = try app.world.spawn();
    try app.world.set(left_pillar, render_3d.Transform3D, .{ .position = .{ -3.2, 0.6, -2.0 }, .scale = .{ 0.7, 1.8, 0.7 } });
    try app.world.set(left_pillar, render_3d.MeshRef, .{
        .mesh_asset = @bitCast(gpu_cube),
        .material_id = 0,
        .bounds_radius = cube.bounds_radius,
        .color = .{ 0.85, 0.42, 0.38, 1.0 },
    });

    const right_pillar = try app.world.spawn();
    try app.world.set(right_pillar, render_3d.Transform3D, .{ .position = .{ 3.2, 0.6, -2.0 }, .scale = .{ 0.7, 1.8, 0.7 } });
    try app.world.set(right_pillar, render_3d.MeshRef, .{
        .mesh_asset = @bitCast(gpu_cube),
        .material_id = 0,
        .bounds_radius = cube.bounds_radius,
        .color = .{ 0.38, 0.58, 0.92, 1.0 },
    });

    const floor_cube = try app.world.spawn();
    try app.world.set(floor_cube, render_3d.Transform3D, .{ .position = .{ 0.0, -1.2, 0.0 }, .scale = .{ 7.0, 0.12, 7.0 } });
    try app.world.set(floor_cube, render_3d.MeshRef, .{
        .mesh_asset = @bitCast(gpu_cube),
        .material_id = 0,
        .bounds_radius = cube.bounds_radius,
        .color = .{ 0.20, 0.24, 0.32, 1.0 },
    });

    const px = window_sdl3.pixelSize(&app);
    const px_w: u32 = if (px) |p| p.width else 1280;
    const px_h: u32 = if (px) |p| p.height else 720;
    const rt = try gfx.createSurface(1, px_w, px_h);

    try app.resources.insert(VisualCameraState, .{
        .app = &app,
        .gfx = gfx,
        .rt = rt,
        .cube_mesh = gpu_cube,
        .checker_tex = checker_tex,
        .cam_entity = cam_e,
        .cubes = .{
            .{ .entity = center_cube, .name = "Center Cube", .base_color = .{ 1, 1, 1, 1 }, .radius = cube.bounds_radius },
            .{ .entity = orbit_cube, .name = "Orbit Cube", .base_color = .{ 0.35, 0.85, 0.65, 1 }, .radius = cube.bounds_radius * 0.7 },
            .{ .entity = left_pillar, .name = "Red Pillar", .base_color = .{ 0.85, 0.42, 0.38, 1 }, .radius = cube.bounds_radius * 1.4 },
            .{ .entity = right_pillar, .name = "Blue Pillar", .base_color = .{ 0.38, 0.58, 0.92, 1 }, .radius = cube.bounds_radius * 1.4 },
        },
    });

    try window_sdl3.runVisualLoop(&app);
}
