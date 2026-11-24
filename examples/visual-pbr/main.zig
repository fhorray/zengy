//! Visual PBR, Shadows, Sky, Compute Auto Exposure, Bloom & Tonemapping Demo (`examples/visual-pbr/main.zig`).
//!
//! Controls:
//! - W/A/S/D (+Shift sprint, Q/E down/up) + Right-Click Drag: Fly FreeCamera
//! - 1 / 2 / 3 / 4 / 5: Tonemapper (AgX Base, AgX Punchy, ACES, PBR Neutral, Neutral)
//! - X: Toggle Compute Auto Exposure
//! - B: Toggle HDR Bloom
//! - F: Toggle Atmospheric Distance Fog
//! - G: Toggle Directional CSM Shadows
//! - O: Toggle Screen-Space Ambient Occlusion (SSAO)
//! - N: Cycle Sky Brightness (HDRI -> Day -> Dusk -> Night)
//! - V: Toggle Vignette
//! - R: Toggle Sun Rotation (Day/Sunset cycle)
//!
//! Run with: `zig build run-visual-pbr`

const std = @import("std");
const engine = @import("engine");
const window_sdl3 = @import("window_sdl3");
const graphics = @import("graphics");
const graphics_sdlgpu = @import("graphics_sdlgpu");
const input = @import("input");
const input_sdl3 = @import("input_sdl3");
const camera = @import("camera");
const render_3d = @import("render_3d");

const SKY_HDR_BYTES = @embedFile("assets/sky.hdr");

const PbrDemoState = struct {
    app: *engine.App,
    gfx: *graphics.GraphicsDeviceService,
    rt: graphics.RenderTargetHandle,
    cam_entity: engine.EntityHandle,
    sun_entity: engine.EntityHandle,
    sun_angle: f32 = 0.75,
    rotate_sun: bool = false,
    sky_preset: u8 = 0, // 0=HDRI, 1=Day, 2=Dusk, 3=Night
    hud1: [180]u8 = @splat(0),
    hud1_len: usize = 0,
    hud2: [180]u8 = @splat(0),
    hud2_len: usize = 0,
    in_vol_room: bool = false,
};

fn createUvSphere(allocator: std.mem.Allocator, radius: f32, stacks: u32, slices: u32) !render_3d.gltf.MeshData {
    var verts: std.ArrayList(render_3d.gltf.Vertex3D) = .empty;
    errdefer verts.deinit(allocator);
    var inds: std.ArrayList(u32) = .empty;
    errdefer inds.deinit(allocator);

    for (0..stacks + 1) |i| {
        const v_t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(stacks));
        const phi = v_t * std.math.pi;
        const sp = @sin(phi);
        const cp = @cos(phi);
        for (0..slices + 1) |j| {
            const u_t = @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(slices));
            const theta = u_t * 2.0 * std.math.pi;
            const nx = sp * @cos(theta);
            const ny = cp;
            const nz = sp * @sin(theta);
            try verts.append(allocator, .{
                .x = nx * radius,
                .y = ny * radius,
                .z = nz * radius,
                .nx = nx,
                .ny = ny,
                .nz = nz,
                .u = u_t,
                .v = v_t,
            });
        }
    }

    const row_stride = slices + 1;
    for (0..stacks) |i| {
        for (0..slices) |j| {
            const a: u32 = @intCast(i * row_stride + j);
            const b: u32 = @intCast((i + 1) * row_stride + j);
            const c_i: u32 = @intCast((i + 1) * row_stride + j + 1);
            const d: u32 = @intCast(i * row_stride + j + 1);
            try inds.appendSlice(allocator, &.{ a, d, b, d, c_i, b });
        }
    }

    return .{
        .allocator = allocator,
        .vertices = try verts.toOwnedSlice(allocator),
        .indices = try inds.toOwnedSlice(allocator),
        .bounds_center = .{ 0, 0, 0 },
        .bounds_radius = radius,
    };
}

fn updatePbrDemo(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(PbrDemoState) orelse return;
    const keys = ctx.resources.get(input.KeyInput) orelse return;
    const cam_pose = ctx.world.get(st.cam_entity, camera.CameraPose) orelse return;
    const pp = ctx.world.get(st.cam_entity, render_3d.pbr.PostProcessSettings) orelse return;
    const sun = ctx.world.get(st.sun_entity, render_3d.pbr.DirectionalLight) orelse return;
    const fog = ctx.resources.get(render_3d.pbr.FogSettings) orelse return;

    if (keys.justPressed(.digit_1)) {
        pp.tonemap_mode = .agx;
        pp.tonemap_look = .base;
    } else if (keys.justPressed(.digit_2)) {
        pp.tonemap_mode = .agx;
        pp.tonemap_look = .punchy;
    } else if (keys.justPressed(.digit_3)) {
        pp.tonemap_mode = .aces;
    } else if (keys.justPressed(.digit_4)) {
        pp.tonemap_mode = .pbr_neutral;
    } else if (keys.justPressed(.digit_5)) {
        pp.tonemap_mode = .neutral;
    }

    if (keys.justPressed(.key_x)) pp.auto_exposure.enabled = !pp.auto_exposure.enabled;
    if (keys.justPressed(.key_b)) pp.bloom.enabled = !pp.bloom.enabled;
    if (keys.justPressed(.key_f)) {
        fog.enabled = !fog.enabled;
        fog.volumetric.enabled = fog.enabled;
    }
    if (keys.justPressed(.key_g)) sun.shadows_enabled = !sun.shadows_enabled;
    if (keys.justPressed(.key_o)) pp.ssao.enabled = !pp.ssao.enabled;
    if (keys.justPressed(.key_n)) {
        st.sky_preset = (st.sky_preset + 1) % 4;
        if (ctx.resources.get(render_3d.pbr.SkyEnvironment)) |sky| {
            switch (st.sky_preset) {
                0 => {
                    sky.kind = .hdri;
                    sun.illuminance_lux = 24000.0;
                    sun.color = .{ 1.0, 0.96, 0.90 };
                },
                1 => {
                    sky.kind = .procedural;
                    sky.sky_tint = .{ 0.14, 0.38, 0.85 };
                    sky.horizon_tint = .{ 0.52, 0.70, 0.92 };
                    sky.ground_albedo = .{ 0.14, 0.14, 0.16 };
                    sun.illuminance_lux = 24000.0;
                    sun.color = .{ 1.0, 0.96, 0.90 };
                },
                2 => {
                    sky.kind = .procedural;
                    sky.sky_tint = .{ 0.05, 0.10, 0.28 };
                    sky.horizon_tint = .{ 0.35, 0.20, 0.18 };
                    sky.ground_albedo = .{ 0.04, 0.04, 0.05 };
                    sun.illuminance_lux = 1600.0;
                    sun.color = .{ 1.0, 0.62, 0.38 };
                },
                else => {
                    sky.kind = .procedural;
                    sky.sky_tint = .{ 0.01, 0.02, 0.06 };
                    sky.horizon_tint = .{ 0.03, 0.05, 0.12 };
                    sky.ground_albedo = .{ 0.01, 0.01, 0.015 };
                    sun.illuminance_lux = 180.0;
                    sun.color = .{ 0.55, 0.70, 1.0 };
                },
            }
        }
    }
    if (keys.justPressed(.key_v)) pp.vignette.enabled = !pp.vignette.enabled;
    if (keys.justPressed(.key_r)) st.rotate_sun = !st.rotate_sun;
    if (keys.justPressed(.key_t)) {
        st.in_vol_room = !st.in_vol_room;
        if (st.in_vol_room) {
            cam_pose.* = camera.CameraPose.lookAt(.{ 11.2, 2.1, 2.8 }, .{ 15.2, 2.3, -1.2 }, .{ 0, 1, 0 });
        } else {
            cam_pose.* = camera.CameraPose.lookAt(.{ 0, 2.6, 10.0 }, .{ 0, 2.6, 0 }, .{ 0, 1, 0 });
        }
    }

    if (st.rotate_sun) {
        st.sun_angle += ctx.dt * 0.65;
        const elev = 0.35 + 0.55 * (0.5 + 0.5 * @sin(st.sun_angle * 0.7));
        sun.direction = .{ -@cos(st.sun_angle) * 0.65, -elev, -@sin(st.sun_angle) * 0.55 - 0.15 };
    }

    const sky_label: []const u8 = switch (st.sky_preset) {
        0 => "HDRI",
        1 => "Day",
        2 => "Dusk",
        else => "Night",
    };
    const look_tag: []const u8 = if (pp.tonemap_mode == .agx and pp.tonemap_look == .punchy) " (Punchy)" else "";
    const h1 = std.fmt.bufPrint(
        &st.hud1,
        "Tonemap[1-5]: {s}{s} | AutoExp[X]: {any} | Bloom[B]: {any} | Shadows[G]: {any} | SSAO[O]: {any} | Sky[N]: {s}",
        .{ @tagName(pp.tonemap_mode), look_tag, pp.auto_exposure.enabled, pp.bloom.enabled, sun.shadows_enabled, pp.ssao.enabled, sky_label },
    ) catch "PBR Demo";
    st.hud1_len = h1.len;

    const h2 = std.fmt.bufPrint(
        &st.hud2,
        "WASD+RMB=Fly | T=VolRoom | F=Fog({any}) | R=SunCycle({any}) | V=Vignette({any}) | Pos:({d:.1},{d:.1},{d:.1})",
        .{ fog.enabled, st.rotate_sun, pp.vignette.enabled, cam_pose.position[0], cam_pose.position[1], cam_pose.position[2] },
    ) catch "";
    st.hud2_len = h2.len;
}

fn renderPbrOverlay(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(PbrDemoState) orelse return;
    const cam_svc = ctx.resources.get(camera.CameraService) orelse return;
    const px = window_sdl3.pixelSize(st.app);
    cam_svc.setPrimaryTargetSize(if (px) |p| p.width else 1280, if (px) |p| p.height else 720);

    try st.gfx.beginFrame(st.rt);
    try st.gfx.submitDrawCommands(st.rt, &.{
        .{ .text = .{ .x = 18, .y = 18, .content = st.hud1[0..st.hud1_len], .color = .{ .r = 0.96, .g = 0.98, .b = 1.0, .a = 1.0 } } },
        .{ .text = .{ .x = 18, .y = 42, .content = st.hud2[0..st.hud2_len], .color = .{ .r = 0.78, .g = 0.88, .b = 0.98, .a = 1.0 } } },
    });
    try st.gfx.present(st.rt);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var app = engine.App.init(allocator, .{});
    defer app.deinit();

    try app.registerModule(window_sdl3.module());
    try app.registerModule(graphics_sdlgpu.module());
    try app.registerModule(input.module());
    try app.registerModule(input_sdl3.module());
    try app.registerModule(camera.module());
    try app.registerModule(render_3d.module());

    try app.resources.insert(window_sdl3.WindowConfig, .{
        .title = "Zengy — PBR Lighting, Shadows, Sky, AutoExposure & Tonemapping",
        .width = 1280,
        .height = 720,
        .resizable = true,
    });

    try app.addSystem(.{ .name = "pbr_demo.update", .stage = .update, .run = updatePbrDemo });
    try app.addSystem(.{ .name = "pbr_demo.overlay", .stage = .render_extract, .run = renderPbrOverlay });

    try app.initialize();

    const g_entry = try app.services.getService("engine.graphics.device", 1);
    const gfx: *graphics.GraphicsDeviceService = @ptrCast(@alignCast(@constCast(g_entry.api_ptr)));
    const mats = app.resources.get(render_3d.pbr.MaterialRegistry).?;

    var sphere = try createUvSphere(allocator, 0.55, 20, 32);
    defer sphere.deinit();
    const gpu_sphere = try graphics_sdlgpu.createMesh3D(&app, std.mem.sliceAsBytes(sphere.vertices), sphere.indices);

    var cube = try render_3d.gltf.createCubeMesh(allocator, 1.0);
    defer cube.deinit();
    const gpu_cube = try graphics_sdlgpu.createMesh3D(&app, std.mem.sliceAsBytes(cube.vertices), cube.indices);

    // Camera with FreeCamera + PostProcessSettings (AutoExposure + Bloom + AgX).
    const cam_e = try app.world.spawn();
    try app.world.set(cam_e, camera.Camera, .{ .order = 0 });
    try app.world.set(cam_e, camera.Projection, .{ .perspective = .{ .fov_rad = std.math.pi / 3.0, .near = 0.25, .far = 200.0 } });
    try app.world.set(cam_e, camera.CameraPose, camera.CameraPose.lookAt(.{ 0, 2.6, 10.0 }, .{ 0, 2.6, 0 }, .{ 0, 1, 0 }));
    try app.world.set(cam_e, camera.FreeCamera, .{ .walk_speed = 7.0, .run_speed = 16.0 });
    try app.world.set(cam_e, camera.FreeCameraState, .{});
    try app.world.set(cam_e, render_3d.pbr.PostProcessSettings, .{
        .auto_exposure = .{ .enabled = true, .min_ev100 = -2.0, .max_ev100 = 3.0, .speed_brighten = 3.0, .speed_darken = 1.5 },
        .bloom = .{ .enabled = true, .intensity = 0.25, .threshold = 1.2, .scatter = 0.7 },
        .ssao = .{ .enabled = true, .radius = 0.65, .intensity = 1.2, .bias = 0.03 },
        .contact_shadows = .{ .enabled = true, .length = 0.45, .thickness = 0.12, .opacity = 0.8 },
        .tonemap_mode = .agx,
        .tonemap_look = .base,
    });

    // Directional Sun Light + HDRI Sky Environment.
    var hdri = try render_3d.ibl.loadRadianceHdrFromMemory(allocator, SKY_HDR_BYTES);
    defer hdri.deinit();
    try app.resources.insert(render_3d.pbr.SkyEnvironment, .{
        .kind = .hdri,
        .hdri_pixels = hdri.pixels,
        .hdri_width = hdri.width,
        .hdri_height = hdri.height,
        .hdri_exposure_ev = -0.6,
        .sky_tint = .{ 0.14, 0.38, 0.85 },
        .horizon_tint = .{ 0.52, 0.70, 0.92 },
        .ground_albedo = .{ 0.14, 0.14, 0.16 },
    });
    try app.resources.insert(render_3d.pbr.AmbientLight, .{
        .color = .{ 0.55, 0.68, 0.88 },
        .brightness = 0.04,
    });
    try app.resources.insert(render_3d.pbr.FogSettings, .{
        .enabled = true,
        .density = 0.014,
        .start_distance = 4.0,
        .volumetric = .{
            .enabled = true,
            .anisotropy = 0.68,
            .scattering = 0.22,
            .max_distance = 75.0,
        },
    });
    const sun_e = try app.world.spawn();
    try app.world.set(sun_e, render_3d.pbr.DirectionalLight, .{
        .color = .{ 1.0, 0.96, 0.90 },
        .illuminance_lux = 24000.0,
        .direction = .{ -0.45, -0.75, -0.45 },
        .shadows_enabled = true,
        .pcss_enabled = true,
    });

    // Screen/TV Area Light (RectLight) with dark metallic bezel & pedestal stand.
    const bezel_mat = try mats.add(.{ .base_color = .{ 0.08, 0.09, 0.11, 1.0 }, .metallic = 0.85, .roughness = 0.25 });
    const tv_bezel = try app.world.spawn();
    try app.world.set(tv_bezel, render_3d.Transform3D, .{ .position = .{ 0.0, 2.8, -4.68 }, .scale = .{ 4.0, 2.2, 0.10 } });
    try app.world.set(tv_bezel, render_3d.MeshRef, .{ .mesh_asset = @bitCast(gpu_cube), .material_handle = bezel_mat });

    const tv_stand = try app.world.spawn();
    try app.world.set(tv_stand, render_3d.Transform3D, .{ .position = .{ 0.0, 0.75, -4.78 }, .scale = .{ 0.45, 2.2, 0.20 } });
    try app.world.set(tv_stand, render_3d.MeshRef, .{ .mesh_asset = @bitCast(gpu_cube), .material_handle = bezel_mat });

    const tv_panel = try app.world.spawn();
    try app.world.set(tv_panel, render_3d.Transform3D, .{ .position = .{ 0.0, 2.8, -4.35 }, .scale = .{ 3.6, 1.8, 0.08 } });
    const tv_mat = try mats.add(.{
        .base_color = .{ 0.05, 0.08, 0.12, 1.0 },
        .emissive = .{ 0.7, 2.0, 3.8, 1.0 },
        .roughness = 0.12,
    });
    try app.world.set(tv_panel, render_3d.MeshRef, .{ .mesh_asset = @bitCast(gpu_cube), .material_handle = tv_mat });
    try app.world.set(tv_panel, render_3d.pbr.RectLight, .{
        .color = .{ 0.45, 0.82, 1.0 },
        .intensity_lumens = 2800.0,
        .width = 3.6,
        .height = 1.8,
        .range = 18.0,
    });

    // Architectural gallery columns casting crisp directional & spot shadows.
    const col_mat = try mats.add(.{ .base_color = .{ 0.72, 0.70, 0.66, 1.0 }, .metallic = 0.05, .roughness = 0.72 });
    const col_positions = [_][3]f32{
        .{ -6.2, 2.4, -4.0 },
        .{ 6.2, 2.4, -4.0 },
        .{ -6.2, 2.4, 4.5 },
    };
    for (col_positions) |cp| {
        const ce = try app.world.spawn();
        try app.world.set(ce, render_3d.Transform3D, .{ .position = cp, .scale = .{ 0.65, 5.6, 0.65 } });
        try app.world.set(ce, render_3d.MeshRef, .{ .mesh_asset = @bitCast(gpu_cube), .material_handle = col_mat });
    }

    // Shadowed SpotLight aimed across the dark volumetric room.
    const spot_e = try app.world.spawn();
    try app.world.set(spot_e, render_3d.Transform3D, .{ .position = .{ 11.4, 4.4, 2.2 } });
    try app.world.set(spot_e, render_3d.pbr.SpotLight, .{
        .color = .{ 0.92, 0.96, 1.0 },
        .intensity_lumens = 1200.0,
        .direction = .{ 0.55, -0.68, -0.48 },
        .range = 16.0,
        .inner_angle_rad = 0.22,
        .outer_angle_rad = 0.52,
        .shadows_enabled = true,
    });

    // Dark ReflectionProbe covering the enclosed volumetric room so the interior stays dark.
    const probe_e = try app.world.spawn();
    try app.world.set(probe_e, render_3d.Transform3D, .{ .position = .{ 14.0, 2.6, 0.0 } });
    try app.world.set(probe_e, render_3d.pbr.ReflectionProbe, .{
        .half_extents = .{ 4.3, 3.0, 4.3 },
        .blend_distance = 0.6,
        .intensity = 0.96,
        .sky_tint = .{ 0.008, 0.008, 0.012 },
        .ground_tint = .{ 0.004, 0.004, 0.006 },
    });

    // Two colored PointLights: blue near metallic grid, red inside the dark volumetric room.
    const pl1 = try app.world.spawn();
    try app.world.set(pl1, render_3d.Transform3D, .{ .position = .{ -4.5, 2.5, 3.0 } });
    try app.world.set(pl1, render_3d.pbr.PointLight, .{ .color = .{ 0.25, 0.65, 1.0 }, .intensity_lumens = 2500.0, .range = 16.0, .shadows_enabled = true });

    const pl2 = try app.world.spawn();
    try app.world.set(pl2, render_3d.Transform3D, .{ .position = .{ 14.2, 2.4, 0.2 } });
    try app.world.set(pl2, render_3d.pbr.PointLight, .{ .color = .{ 1.0, 0.12, 0.06 }, .intensity_lumens = 320.0, .range = 9.0, .shadows_enabled = true });

    // Procedural architectural tile floor texture (256x256).
    var floor_pixels: [256 * 256 * 4]u8 = undefined;
    for (0..256) |py| {
        for (0..256) |px_i| {
            const tile_x = (px_i / 32) % 2;
            const tile_y = (py / 32) % 2;
            const grout = (px_i % 32 < 2) or (py % 32 < 2);
            const checker = (tile_x ^ tile_y) == 0;
            const base_v: u8 = if (grout) 54 else if (checker) 168 else 124;
            const idx = (py * 256 + px_i) * 4;
            floor_pixels[idx + 0] = base_v;
            floor_pixels[idx + 1] = base_v + 4;
            floor_pixels[idx + 2] = base_v + 10;
            floor_pixels[idx + 3] = 255;
        }
    }
    const floor_tex = try graphics_sdlgpu.createTextureRgba8(&app, 256, 256, &floor_pixels);

    // Ground plane.
    const floor_mat = try mats.add(.{
        .base_color = .{ 0.92, 0.94, 0.98, 1.0 },
        .base_color_tex = @bitCast(floor_tex),
        .metallic = 0.05,
        .roughness = 0.62,
    });
    const floor_e = try app.world.spawn();
    try app.world.set(floor_e, render_3d.Transform3D, .{ .position = .{ 0, -0.5, 0 }, .scale = .{ 36.0, 0.25, 36.0 } });
    try app.world.set(floor_e, render_3d.MeshRef, .{ .mesh_asset = @bitCast(gpu_cube), .material_handle = floor_mat });

    // 5x5 Metallic / Roughness sphere showcase grid with Gold, Chrome, Copper, and Emerald accents.
    const row_colors = [5][4]f32{
        .{ 0.85, 0.24, 0.20, 1.0 }, // Dielectric terracotta
        .{ 0.16, 0.72, 0.44, 1.0 }, // Satin emerald
        .{ 0.96, 0.64, 0.54, 1.0 }, // Copper
        .{ 1.00, 0.78, 0.34, 1.0 }, // Gold
        .{ 0.95, 0.96, 0.98, 1.0 }, // Chrome
    };
    for (0..5) |row| {
        for (0..5) |col| {
            const metallic = @as(f32, @floatFromInt(row)) / 4.0;
            const roughness = 0.06 + (@as(f32, @floatFromInt(col)) / 4.0) * 0.90;
            const mat = try mats.add(.{
                .base_color = row_colors[row],
                .metallic = metallic,
                .roughness = roughness,
            });
            const se = try app.world.spawn();
            const x = (@as(f32, @floatFromInt(col)) - 2.0) * 1.6;
            const y = 0.6 + @as(f32, @floatFromInt(row)) * 1.35;
            try app.world.set(se, render_3d.Transform3D, .{ .position = .{ x, y, 0.0 } });
            try app.world.set(se, render_3d.MeshRef, .{
                .mesh_asset = @bitCast(gpu_sphere),
                .material_handle = mat,
                .bounds_radius = sphere.bounds_radius,
            });
        }
    }

    // Emissive HDR beacon cubes (demonstrates Bloom).
    const em_mat = try mats.add(.{
        .base_color = .{ 0.1, 0.1, 0.1, 1.0 },
        .emissive = .{ 2.5, 5.5, 10.0, 1.0 },
        .roughness = 0.2,
    });
    const beacon = try app.world.spawn();
    try app.world.set(beacon, render_3d.Transform3D, .{ .position = .{ -5.5, 1.5, 0.0 }, .scale = .{ 0.7, 2.8, 0.7 } });
    try app.world.set(beacon, render_3d.MeshRef, .{ .mesh_asset = @bitCast(gpu_cube), .material_handle = em_mat });

    // Enclosed dark volumetric room on the right (press T to jump inside) with a grated skylight window.
    const wall_mat = try mats.add(.{ .base_color = .{ 0.22, 0.23, 0.26, 1.0 }, .metallic = 0.0, .roughness = 0.9 });
    const alcove_parts = [_]struct { pos: [3]f32, scale: [3]f32 }{
        // Back (-Z), Front (+Z), Right (+X), and Left (-X with small doorway at z=2.6..4.0) walls
        .{ .pos = .{ 14.0, 2.5, -4.0 }, .scale = .{ 8.5, 5.5, 0.5 } },
        .{ .pos = .{ 14.0, 2.5, 4.0 }, .scale = .{ 8.5, 5.5, 0.5 } },
        .{ .pos = .{ 18.0, 2.5, 0.0 }, .scale = .{ 0.5, 5.5, 8.5 } },
        .{ .pos = .{ 10.0, 2.5, -0.9 }, .scale = .{ 0.5, 5.5, 6.2 } },
        .{ .pos = .{ 10.0, 3.8, 3.1 }, .scale = .{ 0.5, 2.9, 2.2 } },
        // Solid roof sections around the skylight opening (opening at x=14.6..17.4, z=-1.0..2.2)
        .{ .pos = .{ 12.3, 5.2, 0.0 }, .scale = .{ 4.8, 0.5, 8.5 } },
        .{ .pos = .{ 16.0, 5.2, -2.5 }, .scale = .{ 4.0, 0.5, 3.2 } },
        .{ .pos = .{ 16.0, 5.2, 3.1 }, .scale = .{ 4.0, 0.5, 2.0 } },
        .{ .pos = .{ 17.7, 5.2, 0.6 }, .scale = .{ 0.8, 0.5, 3.6 } },
        // Grated window bars across the skylight opening
        .{ .pos = .{ 15.5, 5.2, 0.6 }, .scale = .{ 0.24, 0.5, 3.4 } },
        .{ .pos = .{ 16.5, 5.2, 0.6 }, .scale = .{ 0.24, 0.5, 3.4 } },
        .{ .pos = .{ 16.0, 5.2, -0.1 }, .scale = .{ 3.2, 0.5, 0.24 } },
        .{ .pos = .{ 16.0, 5.2, 0.7 }, .scale = .{ 3.2, 0.5, 0.24 } },
        .{ .pos = .{ 16.0, 5.2, 1.5 }, .scale = .{ 3.2, 0.5, 0.24 } },
    };
    for (alcove_parts) |ap| {
        const we = try app.world.spawn();
        try app.world.set(we, render_3d.Transform3D, .{ .position = ap.pos, .scale = ap.scale });
        try app.world.set(we, render_3d.MeshRef, .{ .mesh_asset = @bitCast(gpu_cube), .material_handle = wall_mat });
    }

    const px = window_sdl3.pixelSize(&app);
    const rt = try gfx.createSurface(1, if (px) |p| p.width else 1280, if (px) |p| p.height else 720);

    try app.resources.insert(PbrDemoState, .{
        .app = &app,
        .gfx = gfx,
        .rt = rt,
        .cam_entity = cam_e,
        .sun_entity = sun_e,
    });

    try window_sdl3.runVisualLoop(&app);
}
