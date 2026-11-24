//! Visual Prism & Helios Data-Driven Showcase (`examples/visual-prism/main.zig`).
//!
//! Loads JSON scenes from `examples/visual-prism/scene/` at runtime and lets you
//! cycle between them with `Tab` to visually test Prism Stages 01–10 and Helios:
//! - Procedural Sky (`SkyEnvironment`), Directional Sun + Shadows, PointLights,
//!   Volumetric Fog & God Rays (`FogSettings` resource), SSAO, and Bloom
//! - Persistent `RenderWorld`, frustum culling, opaque `DrawBatch` grouping,
//!   `PassGraph` compilation, `TemporalHistoryManager` camera-cut reset on scene swap,
//!   `QualityPreset` switching (`Q`), and `HeliosService` hybrid cache (`H`)
//!
//! Controls:
//! - Tab: Next JSON scene (`01_sunlit_plaza`, `02_volumetric_cathedral`, `03_cornell_box`, `04_stress_gallery`)
//! - W/A/S/D (+Shift sprint, Q/E down/up) + Right-Click Drag: Fly FreeCamera
//! - 1 / 2 / 3 / 4: Toggle Shadows / SSAO / Volumetric Fog / Bloom
//! - 5: Cycle QualityPreset (`low`, `medium`, `high`, `ultra`)
//! - N: Cycle Sky & Time of Day (`Scene` -> `HDRI` -> `Day` -> `Dusk` -> `Night`)
//! - R: Toggle Sun Rotation (Day/Sunset cycle)
//! - T: Cycle Tonemapper (`AgX Base`, `AgX Punchy`, `ACES`, `PBR Neutral`, `Neutral`)
//! - X / V / F: Toggle Auto Exposure / Vignette / Distance Fog
//! - H: Cycle Helios tier (`off`, `low`, `medium`, `high`)
//! - P: Toggle 3D ReflectionProbe / LocalFogVolume / SH9 ProbeVolume gizmos
//! - G: Toggle visible bounding-sphere gizmos
//! - C: Force temporal camera-cut history reset
//!
//! Run with: `zig build run-visual-prism`

const std = @import("std");
const engine = @import("engine");
const window_sdl3 = @import("window_sdl3");
const graphics = @import("graphics");
const graphics_sdlgpu = @import("graphics_sdlgpu");
const input = @import("input");
const input_sdl3 = @import("input_sdl3");
const camera = @import("camera");
const render_3d = @import("render_3d");
const gizmos = @import("gizmos");
const shapes = @import("shapes");
const dev_tools = @import("dev_tools");
const prism = @import("prism");
const helios = @import("helios");
const testing_sdk = @import("testing_sdk");
const capture_mod = testing_sdk.render_regression;

const SKY_HDR_BYTES = @embedFile("sky_hdr");

const SCENE_FILES = [_][]const u8{
    @embedFile("scene/01_sunlit_plaza.json"),
    @embedFile("scene/02_volumetric_cathedral.json"),
    @embedFile("scene/03_cornell_box.json"),
    @embedFile("scene/04_stress_gallery.json"),
    @embedFile("scene/05_material_and_shadow_lab.json"),
};

const JsonObject = struct {
    shape: []const u8,
    pos: [3]f32,
    scale: [3]f32 = .{ 1, 1, 1 },
    color: [3]f32 = .{ 0.7, 0.7, 0.7 },
    roughness: f32 = 0.5,
    metallic: f32 = 0.0,
    emissive: [3]f32 = .{ 0, 0, 0 },
};

const JsonPointLight = struct {
    pos: [3]f32,
    color: [3]f32,
    lumens: f32 = 1500.0,
    range: f32 = 14.0,
    shadows: bool = true,
};

const JsonScene = struct {
    name: []const u8,
    camera_pos: [3]f32,
    camera_target: [3]f32,
    sky_tint: [3]f32 = .{ 0.14, 0.38, 0.85 },
    horizon_tint: [3]f32 = .{ 0.52, 0.70, 0.92 },
    ground_albedo: [3]f32 = .{ 0.14, 0.14, 0.16 },
    sun_dir: [3]f32 = .{ -0.45, -0.75, -0.45 },
    sun_color: [3]f32 = .{ 1.0, 0.96, 0.90 },
    sun_lux: f32 = 24000.0,
    fog_enabled: bool = false,
    fog_density: f32 = 0.015,
    volumetric_enabled: bool = false,
    bloom_enabled: bool = true,
    ssao_enabled: bool = true,
    objects: []const JsonObject = &.{},
    point_lights: []const JsonPointLight = &.{},
};

const ShapeAssets = struct {
    plane: u64,
    cuboid: u64,
    sphere: u64,
    capsule: u64,
    cylinder: u64,
    torus: u64,
    cone: u64,

    fn meshForName(self: ShapeAssets, name: []const u8) u64 {
        if (std.mem.eql(u8, name, "plane")) return self.plane;
        if (std.mem.eql(u8, name, "cuboid")) return self.cuboid;
        if (std.mem.eql(u8, name, "sphere")) return self.sphere;
        if (std.mem.eql(u8, name, "capsule")) return self.capsule;
        if (std.mem.eql(u8, name, "cylinder")) return self.cylinder;
        if (std.mem.eql(u8, name, "torus")) return self.torus;
        if (std.mem.eql(u8, name, "cone")) return self.cone;
        return self.cuboid;
    }
};

const PrismShowcaseState = struct {
    app: *engine.App,
    gfx: *graphics.GraphicsDeviceService,
    rt: graphics.RenderTargetHandle,
    cam_entity: engine.EntityHandle,
    sun_entity: engine.EntityHandle,
    view_id: prism.RenderViewId,
    assets: ShapeAssets,
    scene_index: usize = 0,
    scene_name: [64]u8 = @splat(0),
    scene_name_len: usize = 0,
    spawned: std.ArrayList(engine.EntityHandle) = .empty,
    graph_opts: prism.ForwardPlusGraphOptions = .{
        .enable_shadows = true,
        .enable_ssao = true,
        .enable_volumetric = false,
        .enable_bloom = true,
    },
    show_bounds: bool = false,
    show_volumes: bool = false,
    preset: prism.extensions.QualityPreset = .high,
    sky_preset: u8 = 0, // 0=Scene, 1=HDRI, 2=Day, 3=Dusk, 4=Night
    rotate_sun: bool = false,
    sun_angle: f32 = 0.75,
    tonemap_idx: u8 = 0, // 0=AgX Base, 1=AgX Punchy, 2=ACES, 3=PBR Neutral, 4=Neutral
    base_fog_enabled: bool = false,
    base_fog_density: f32 = 0.015,
    scene_sky_tint: [3]f32 = .{ 0.14, 0.38, 0.85 },
    scene_horizon_tint: [3]f32 = .{ 0.52, 0.70, 0.92 },
    scene_ground_albedo: [3]f32 = .{ 0.14, 0.14, 0.16 },
    scene_sun_dir: [3]f32 = .{ -0.45, -0.75, -0.45 },
    scene_sun_color: [3]f32 = .{ 1.0, 0.96, 0.90 },
    scene_sun_lux: f32 = 24000.0,
    dyn_res: prism.reflections.DynamicResolutionController = .{},
    probe: prism.reflections.ReflectionProbe = .{
        .id = 1,
        .position = .{ 0, 2.5, 0 },
        .box_min = .{ -9.0, 0.0, -9.0 },
        .box_max = .{ 9.0, 5.5, 9.0 },
        .blend_distance = 2.0,
    },
    fog_vol: prism.atmosphere.LocalFogVolume = .{
        .shape = .box,
        .center = .{ 0.0, 2.5, -2.0 },
        .half_extents = .{ 6.0, 2.8, 6.0 },
        .density = 0.012,
        .height_falloff = 0.12,
        .edge_fade = 1.6,
    },
    gi_vol: prism.baked_gi.IrradianceProbeVolume,
    gi_bvh: helios.ray_query.Bvh,
    gi_materials: std.ArrayList(helios.indirect_rt.SurfaceMaterial) = .empty,
    gi_emitters: std.ArrayList(helios.gi_solver.DirectPointEmitter) = .empty,
    gi_vpls: std.ArrayList(helios.gi_solver.VirtualPointLight) = .empty,
    gi_vpl_entities: std.ArrayList(engine.EntityHandle) = .empty,
    gi_stats: helios.gi_solver.GiSolveStats = .{},
    gi_dirty: bool = true,
    gi_frame_counter: u32 = 0,
    capture_dir: ?[]const u8 = null,
    capture_io: std.Io = undefined,
    capture_step: u8 = 0,
    capture_wait: u32 = 0,
    capture_pending: bool = false,
    opaque_q: std.ArrayList(prism.QueueEntry) = .empty,
    transparent_q: std.ArrayList(prism.QueueEntry) = .empty,
    batches: std.ArrayList(prism.DrawBatch) = .empty,
    hud1: [240]u8 = @splat(0),
    hud1_len: usize = 0,
    hud2: [240]u8 = @splat(0),
    hud2_len: usize = 0,
    hud3: [240]u8 = @splat(0),
    hud3_len: usize = 0,
    hud4: [240]u8 = @splat(0),
    hud4_len: usize = 0,
    hud5: [240]u8 = @splat(0),
    hud5_len: usize = 0,

    pub fn deinit(self: *PrismShowcaseState) void {
        self.spawned.deinit(self.app.allocator);
        self.gi_vol.deinit();
        self.gi_bvh.deinit();
        self.gi_materials.deinit(self.app.allocator);
        self.gi_emitters.deinit(self.app.allocator);
        self.gi_vpls.deinit(self.app.allocator);
        self.gi_vpl_entities.deinit(self.app.allocator);
        self.opaque_q.deinit(self.app.allocator);
        self.transparent_q.deinit(self.app.allocator);
        self.batches.deinit(self.app.allocator);
    }
};

fn rebuildHeliosGi(st: *PrismShowcaseState) !void {
    const allocator = st.app.allocator;
    // Despawn previous GI bounce VPL entities.
    for (st.gi_vpl_entities.items) |e| _ = st.app.world.despawn(e) catch false;
    st.gi_vpl_entities.clearRetainingCapacity();
    st.gi_vpls.clearRetainingCapacity();

    const hsvc = st.app.resources.get(helios.HeliosService) orelse return;
    const cfg = helios.gi_solver.configForTier(hsvc.settings.tier);
    if (cfg.max_vpls == 0) {
        st.gi_stats = .{};
        st.gi_dirty = false;
        return;
    }

    var sun_opt: ?helios.gi_solver.DirectSunEmitter = null;
    if (st.app.world.get(st.sun_entity, render_3d.pbr.DirectionalLight)) |sun| {
        if (sun.illuminance_lux > 50.0) {
            sun_opt = .{
                .direction = sun.direction,
                .color = sun.color,
                .illuminance_lux = sun.illuminance_lux,
                .scene_center = .{ 0, 1.5, 0 },
                .scene_radius = 10.0,
            };
        }
    }

    st.gi_stats = try helios.gi_solver.solveInstantRadiosity(
        allocator,
        &st.gi_bvh,
        st.gi_materials.items,
        st.gi_emitters.items,
        sun_opt,
        cfg,
        &st.gi_vpls,
    );

    // Spawn smooth unshadowed bounce VPLs into the ECS world for real-time Forward+ clustered GI.
    for (st.gi_vpls.items) |vpl| {
        const ve = try st.app.world.spawn();
        try st.app.world.set(ve, render_3d.Transform3D, .{ .position = vpl.position });
        try st.app.world.set(ve, render_3d.pbr.PointLight, .{
            .color = vpl.color,
            .intensity_lumens = vpl.lumens,
            .range = vpl.range,
            .radius = 0.65,
            .shadows_enabled = false,
        });
        try st.gi_vpl_entities.append(allocator, ve);
    }
    st.gi_dirty = false;
}

fn applySkyPreset(st: *const PrismShowcaseState, sky: *render_3d.pbr.SkyEnvironment, sun: *render_3d.pbr.DirectionalLight, fog: ?*render_3d.pbr.FogSettings, preset: u8) void {
    switch (preset) {
        0 => {
            sky.kind = .procedural;
            sky.sky_tint = st.scene_sky_tint;
            sky.horizon_tint = st.scene_horizon_tint;
            sky.ground_albedo = st.scene_ground_albedo;
            sun.direction = st.scene_sun_dir;
            sun.color = st.scene_sun_color;
            sun.illuminance_lux = st.scene_sun_lux;
            sun.shadows_enabled = st.graph_opts.enable_shadows and st.scene_sun_lux > 0.0;
        },
        1 => {
            sky.kind = .hdri;
            sky.horizon_tint = .{ 0.45, 0.56, 0.70 };
            sun.illuminance_lux = 24000.0;
            sun.color = .{ 1.0, 0.96, 0.90 };
            sun.shadows_enabled = st.graph_opts.enable_shadows;
        },
        2 => {
            sky.kind = .procedural;
            sky.sky_tint = .{ 0.14, 0.38, 0.85 };
            sky.horizon_tint = .{ 0.52, 0.70, 0.92 };
            sky.ground_albedo = .{ 0.14, 0.14, 0.16 };
            sun.illuminance_lux = 24000.0;
            sun.color = .{ 1.0, 0.96, 0.90 };
            sun.shadows_enabled = st.graph_opts.enable_shadows;
        },
        3 => {
            sky.kind = .procedural;
            sky.sky_tint = .{ 0.05, 0.10, 0.28 };
            sky.horizon_tint = .{ 0.35, 0.20, 0.18 };
            sky.ground_albedo = .{ 0.04, 0.04, 0.05 };
            sun.illuminance_lux = 1600.0;
            sun.color = .{ 1.0, 0.62, 0.38 };
            sun.shadows_enabled = st.graph_opts.enable_shadows;
        },
        else => {
            sky.kind = .procedural;
            sky.sky_tint = .{ 0.01, 0.02, 0.06 };
            sky.horizon_tint = .{ 0.03, 0.05, 0.12 };
            sky.ground_albedo = .{ 0.01, 0.01, 0.015 };
            sun.illuminance_lux = 180.0;
            sun.color = .{ 0.55, 0.70, 1.0 };
            sun.shadows_enabled = st.graph_opts.enable_shadows;
        },
    }
    if (fog) |fg| {
        fg.color = .{ sky.horizon_tint[0] * 0.65, sky.horizon_tint[1] * 0.65, sky.horizon_tint[2] * 0.65 };
    }
}

fn loadJsonScene(st: *PrismShowcaseState, idx: usize) !void {
    const allocator = st.app.allocator;
    const mats = st.app.resources.get(render_3d.pbr.MaterialRegistry).?;

    // Despawn previous scene entities.
    for (st.spawned.items) |e| _ = st.app.world.despawn(e) catch false;
    st.spawned.clearRetainingCapacity();

    const parsed = try std.json.parseFromSlice(JsonScene, allocator, SCENE_FILES[idx], .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const sc = parsed.value;

    st.scene_index = idx;
    const nlen = @min(sc.name.len, st.scene_name.len);
    @memcpy(st.scene_name[0..nlen], sc.name[0..nlen]);
    st.scene_name_len = nlen;

    // Update camera pose & trigger temporal camera-cut + Helios cache reset.
    if (st.app.world.get(st.cam_entity, camera.CameraPose)) |pose| {
        pose.* = camera.CameraPose.lookAt(sc.camera_pos, sc.camera_target, .{ 0, 1, 0 });
    }
    if (st.app.resources.get(prism.PrismService)) |psvc| {
        psvc.history.resetView(st.view_id);
    }
    if (st.app.resources.get(helios.HeliosService)) |hsvc| {
        hsvc.cache.invalidateAll();
    }

    // Save scene-authored atmosphere & sun defaults so [N] can cycle HDRI/Day/Dusk/Night and return to Scene.
    st.sky_preset = 0;
    st.rotate_sun = false;
    st.scene_sky_tint = sc.sky_tint;
    st.scene_horizon_tint = sc.horizon_tint;
    st.scene_ground_albedo = sc.ground_albedo;
    st.scene_sun_dir = sc.sun_dir;
    st.scene_sun_color = sc.sun_color;
    st.scene_sun_lux = sc.sun_lux;
    st.base_fog_enabled = sc.fog_enabled;
    st.base_fog_density = sc.fog_density;

    // Update SkyEnvironment, FogSettings, PostProcessSettings, and DirectionalLight.
    if (st.app.resources.get(render_3d.pbr.SkyEnvironment)) |sky| {
        sky.kind = .procedural;
        sky.sky_tint = sc.sky_tint;
        sky.horizon_tint = sc.horizon_tint;
        sky.ground_albedo = sc.ground_albedo;
    }
    if (st.app.resources.get(render_3d.pbr.FogSettings)) |fg| {
        fg.enabled = sc.fog_enabled;
        fg.density = sc.fog_density;
        fg.color = .{ sc.horizon_tint[0] * 0.65, sc.horizon_tint[1] * 0.65, sc.horizon_tint[2] * 0.65 };
        fg.volumetric.enabled = sc.volumetric_enabled;
    }
    if (st.app.world.get(st.cam_entity, render_3d.pbr.PostProcessSettings)) |pp| {
        pp.ssao.enabled = sc.ssao_enabled;
        pp.bloom.enabled = sc.bloom_enabled;
    }
    if (st.app.world.get(st.sun_entity, render_3d.pbr.DirectionalLight)) |sun| {
        sun.direction = sc.sun_dir;
        sun.color = sc.sun_color;
        sun.illuminance_lux = sc.sun_lux;
        sun.shadow_normal_bias = 0.025;
        sun.shadows_enabled = sc.sun_lux > 0.0;
    }

    st.graph_opts = .{
        .enable_shadows = true,
        .enable_ssao = sc.ssao_enabled,
        .enable_volumetric = sc.volumetric_enabled,
        .enable_bloom = sc.bloom_enabled,
    };

    // Spawn JSON objects & populate Helios GI BVH geometry + materials.
    st.gi_materials.clearRetainingCapacity();
    st.gi_emitters.clearRetainingCapacity();
    var gi_tris = std.ArrayList(helios.ray_query.BvhTriangle).empty;
    defer gi_tris.deinit(allocator);

    for (sc.objects, 0..) |obj, oi| {
        const mat = try mats.add(.{
            .base_color = .{ obj.color[0], obj.color[1], obj.color[2], 1.0 },
            .roughness = obj.roughness,
            .metallic = obj.metallic,
            .emissive = .{ obj.emissive[0], obj.emissive[1], obj.emissive[2], 1.0 },
        });
        const e = try st.app.world.spawn();
        try st.app.world.set(e, render_3d.Transform3D, .{ .position = obj.pos, .scale = obj.scale });
        try st.app.world.set(e, render_3d.MeshRef, .{ .mesh_asset = st.assets.meshForName(obj.shape), .material_handle = mat });
        try st.spawned.append(allocator, e);

        try st.gi_materials.append(allocator, .{
            .albedo = obj.color,
            .emissive = obj.emissive,
            .roughness = obj.roughness,
            .metallic = obj.metallic,
        });
        const half_ext = if (std.mem.eql(u8, obj.shape, "plane"))
            [3]f32{ obj.scale[0] * 0.5, 0.05, obj.scale[2] * 0.5 }
        else
            [3]f32{ obj.scale[0] * 0.5, obj.scale[1] * 0.5, obj.scale[2] * 0.5 };
        try helios.gi_solver.appendBoxTriangles(allocator, &gi_tris, obj.pos, half_ext, @intCast(oi));
    }
    try st.gi_bvh.build(gi_tris.items);

    // Spawn JSON point lights & record direct emitters for Helios GI.
    for (sc.point_lights) |pl| {
        const le = try st.app.world.spawn();
        try st.app.world.set(le, render_3d.Transform3D, .{ .position = pl.pos });
        try st.app.world.set(le, render_3d.pbr.PointLight, .{
            .color = pl.color,
            .intensity_lumens = pl.lumens,
            .range = pl.range,
            .shadows_enabled = pl.shadows,
        });
        try st.spawned.append(allocator, le);
        try st.gi_emitters.append(allocator, .{
            .position = pl.pos,
            .color = pl.color,
            .lumens = pl.lumens,
            .range = pl.range,
        });
    }

    st.gi_dirty = true;
    try rebuildHeliosGi(st);
}

fn updatePrismShowcase(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(PrismShowcaseState) orelse return;
    const keys = ctx.resources.get(input.KeyInput) orelse return;
    const psvc = ctx.resources.get(prism.PrismService) orelse return;
    const prof = ctx.resources.get(dev_tools.FrameProfilerService) orelse return;
    const giz = ctx.resources.get(gizmos.GizmoService) orelse return;
    const cam = ctx.world.get(st.cam_entity, camera.Camera) orelse return;
    const cam_pose = ctx.world.get(st.cam_entity, camera.CameraPose) orelse return;

    if (keys.justPressed(.tab)) {
        try loadJsonScene(st, (st.scene_index + 1) % SCENE_FILES.len);
    }
    if (keys.justPressed(.digit_1)) {
        st.graph_opts.enable_shadows = !st.graph_opts.enable_shadows;
        if (ctx.world.get(st.sun_entity, render_3d.pbr.DirectionalLight)) |sun| sun.shadows_enabled = st.graph_opts.enable_shadows;
    }
    if (keys.justPressed(.digit_2)) {
        st.graph_opts.enable_ssao = !st.graph_opts.enable_ssao;
        if (ctx.world.get(st.cam_entity, render_3d.pbr.PostProcessSettings)) |pp| pp.ssao.enabled = st.graph_opts.enable_ssao;
    }
    if (keys.justPressed(.digit_3)) {
        st.graph_opts.enable_volumetric = !st.graph_opts.enable_volumetric;
        if (st.graph_opts.enable_volumetric) st.base_fog_enabled = true;
        if (ctx.resources.get(render_3d.pbr.FogSettings)) |fg| {
            fg.enabled = st.base_fog_enabled or st.graph_opts.enable_volumetric;
            fg.volumetric.enabled = st.graph_opts.enable_volumetric;
        }
    }
    if (keys.justPressed(.digit_4)) {
        st.graph_opts.enable_bloom = !st.graph_opts.enable_bloom;
        if (ctx.world.get(st.cam_entity, render_3d.pbr.PostProcessSettings)) |pp| pp.bloom.enabled = st.graph_opts.enable_bloom;
    }
    if (keys.justPressed(.key_n)) {
        st.sky_preset = (st.sky_preset + 1) % 5;
        if (ctx.resources.get(render_3d.pbr.SkyEnvironment)) |sky| {
            if (ctx.world.get(st.sun_entity, render_3d.pbr.DirectionalLight)) |sun| {
                applySkyPreset(st, sky, sun, ctx.resources.get(render_3d.pbr.FogSettings), st.sky_preset);
                st.gi_dirty = true;
            }
        }
    }
    if (keys.justPressed(.key_r)) {
        st.rotate_sun = !st.rotate_sun;
        if (st.rotate_sun) {
            if (ctx.world.get(st.sun_entity, render_3d.pbr.DirectionalLight)) |sun| {
                if (sun.illuminance_lux <= 0.0) {
                    sun.illuminance_lux = 18000.0;
                    sun.shadows_enabled = st.graph_opts.enable_shadows;
                }
            }
            st.gi_dirty = true;
        }
    }
    if (keys.justPressed(.key_t)) {
        st.tonemap_idx = (st.tonemap_idx + 1) % 5;
        if (ctx.world.get(st.cam_entity, render_3d.pbr.PostProcessSettings)) |pp| {
            switch (st.tonemap_idx) {
                0 => {
                    pp.tonemap_mode = .agx;
                    pp.tonemap_look = .base;
                },
                1 => {
                    pp.tonemap_mode = .agx;
                    pp.tonemap_look = .punchy;
                },
                2 => pp.tonemap_mode = .aces,
                3 => pp.tonemap_mode = .pbr_neutral,
                else => pp.tonemap_mode = .neutral,
            }
        }
    }
    if (keys.justPressed(.key_x)) {
        if (ctx.world.get(st.cam_entity, render_3d.pbr.PostProcessSettings)) |pp| pp.auto_exposure.enabled = !pp.auto_exposure.enabled;
    }
    if (keys.justPressed(.key_v)) {
        if (ctx.world.get(st.cam_entity, render_3d.pbr.PostProcessSettings)) |pp| pp.vignette.enabled = !pp.vignette.enabled;
    }
    if (keys.justPressed(.key_f)) {
        st.base_fog_enabled = !st.base_fog_enabled;
        if (ctx.resources.get(render_3d.pbr.FogSettings)) |fg| {
            fg.enabled = st.base_fog_enabled;
            fg.volumetric.enabled = st.base_fog_enabled and st.graph_opts.enable_volumetric;
        }
    }
    if (st.rotate_sun) {
        st.sun_angle += ctx.dt * 0.35;
        if (ctx.world.get(st.sun_entity, render_3d.pbr.DirectionalLight)) |sun| {
            sun.direction = .{ -@cos(st.sun_angle) * 0.6, -@max(@sin(st.sun_angle), 0.05), -0.45 };
        }
        st.gi_frame_counter += 1;
        if (st.gi_frame_counter % 6 == 0) st.gi_dirty = true;
    }
    if (keys.justPressed(.key_g)) st.show_bounds = !st.show_bounds;
    if (keys.justPressed(.key_p)) st.show_volumes = !st.show_volumes;
    if (keys.justPressed(.key_h)) {
        if (ctx.resources.get(helios.HeliosService)) |hsvc| {
            hsvc.settings.tier = switch (hsvc.settings.tier) {
                .off => .low,
                .low => .medium,
                .medium => .high,
                .high => .off,
            };
            st.gi_dirty = true;
        }
    }
    if (st.gi_dirty) {
        try rebuildHeliosGi(st);
    }

    // Optional automated screenshot capture (`ZENGY_PRISM_CAPTURE=<dir>`) to visually verify GI OFF vs HIGH.
    if (st.capture_dir) |cdir| {
        if (st.capture_pending) {
            if (graphics_sdlgpu.takeCapture(st.app)) |img_val| {
                var img = img_val;
                defer img.deinit(st.app.allocator);
                const rgb = try capture_mod.displayToRgb8(st.app.allocator, img);
                defer st.app.allocator.free(rgb);
                const png = try capture_mod.encodePngRgb8(st.app.allocator, img.width, img.height, rgb);
                defer st.app.allocator.free(png);
                const fname: []const u8 = switch (st.capture_step) {
                    0 => "cornell_gi_off.png",
                    1 => "cornell_gi_high.png",
                    else => "material_lab_gi_high.png",
                };
                const path = try std.fmt.allocPrint(st.app.allocator, "{s}/{s}", .{ cdir, fname });
                defer st.app.allocator.free(path);
                const file = try std.Io.Dir.cwd().createFile(st.capture_io, path, .{});
                defer file.close(st.capture_io);
                try file.writeStreamingAll(st.capture_io, png);
                st.capture_pending = false;
                st.capture_step += 1;
                st.capture_wait = 0;
                if (st.capture_step >= 3) {
                    st.app.quit();
                    return;
                }
            }
        } else {
            if (st.capture_wait == 0) {
                if (st.capture_step == 0) {
                    if (ctx.resources.get(helios.HeliosService)) |hsvc| hsvc.settings.tier = .off;
                    try loadJsonScene(st, 2); // 03_cornell_box.json with GI OFF
                    if (ctx.world.get(st.cam_entity, camera.FreeCamera)) |fc| fc.state.initialized = false;
                } else if (st.capture_step == 1) {
                    if (ctx.resources.get(helios.HeliosService)) |hsvc| hsvc.settings.tier = .high;
                    try rebuildHeliosGi(st); // 03_cornell_box.json with GI HIGH
                } else if (st.capture_step == 2) {
                    if (ctx.resources.get(helios.HeliosService)) |hsvc| hsvc.settings.tier = .high;
                    try loadJsonScene(st, 4); // 05_material_and_shadow_lab.json with GI HIGH
                    if (ctx.world.get(st.cam_entity, camera.FreeCamera)) |fc| fc.state.initialized = false;
                }
            }
            st.capture_wait += 1;
            if (st.capture_wait >= 45) {
                graphics_sdlgpu.requestCapture(st.app, .final);
                st.capture_pending = true;
            }
        }
    }
    if (keys.justPressed(.digit_5)) {
        st.preset = switch (st.preset) {
            .low => .medium,
            .medium => .high,
            .high => .ultra,
            .ultra => .low,
        };
        const pc = prism.extensions.presetConfig(st.preset);
        st.graph_opts.enable_ssao = pc.ssao_enabled;
        st.graph_opts.enable_volumetric = pc.volumetric_enabled;
        st.graph_opts.enable_bloom = pc.bloom_enabled;
        if (ctx.world.get(st.cam_entity, render_3d.pbr.PostProcessSettings)) |pp| {
            pp.ssao.enabled = pc.ssao_enabled;
            pp.bloom.enabled = pc.bloom_enabled;
        }
        if (ctx.resources.get(render_3d.pbr.FogSettings)) |fg| {
            fg.enabled = pc.volumetric_enabled;
            fg.volumetric.enabled = pc.volumetric_enabled;
        }
    }
    const force_cut = keys.justPressed(.key_c);

    // Stage 03 temporal history + Halton jitter tracking.
    const px = window_sdl3.pixelSize(st.app);
    const vw: u32 = if (px) |p| p.width else 1280;
    const vh: u32 = if (px) |p| p.height else 720;
    const jitter = prism.coordinates.haltonJitter(psvc.frame_epoch, vw, vh);
    const tstate = try psvc.history.updateView(
        st.view_id,
        vw,
        vh,
        cam.computed.clip_from_world,
        cam_pose.position,
        jitter.ndc,
        1.0,
        force_cut,
    );
    psvc.frame_epoch += 1;

    // Stage 01 PassGraph compilation.
    var graph = try prism.buildDefaultForwardPlusGraph(st.app.allocator, st.graph_opts);
    defer graph.deinit();
    var sched = try graph.compile(st.app.allocator);
    defer sched.deinit();

    // Stage 02 persistent RenderWorld sync & frustum culling.
    psvc.world.beginSync();
    var q = try ctx.query(.{ .read = .{ render_3d.Transform3D, render_3d.MeshRef } });
    defer q.deinit();
    while (q.next()) |row| {
        const tf = row.read(render_3d.Transform3D);
        const mr = row.read(render_3d.MeshRef);
        const max_s = @max(@abs(tf.scale[0]), @max(@abs(tf.scale[1]), @abs(tf.scale[2])));
        try psvc.world.upsert(
            row.entity,
            mr.mesh_asset,
            if (mr.material_handle) |mh| @as(u32, @truncate(@as(u64, @bitCast(mh)))) else 0,
            1,
            tf.toModelMatrix().m,
            tf.position,
            0.75 * max_s,
            false,
        );
    }
    _ = psvc.world.pruneUnseen();

    const planes = prism.render_world.extractFrustumPlanes(cam.computed.clip_from_world);
    const stats = try psvc.world.cullAndQueue(planes, cam_pose.position, &st.opaque_q, &st.transparent_q, &st.batches, st.app.allocator);

    if (st.show_bounds) {
        for (st.opaque_q.items) |entry| {
            const inst = psvc.world.instances.items[entry.slot_index];
            if (inst.bounds_radius < 8.0) {
                giz.sphere(inst.bounds_center, inst.bounds_radius, 12, .{ 0.25, 0.95, 0.65, 0.55 });
            }
        }
    }

    // Stages 06-09 live evaluation & optional 3D debug volumes ([P] toggle).
    const probe_w = prism.reflections.probeInfluenceWeight(st.probe, cam_pose.position);
    const local_fog = prism.atmosphere.evaluateLocalFogDensity(st.fog_vol, cam_pose.position);
    if (ctx.resources.get(render_3d.pbr.FogSettings)) |fg| {
        if (local_fog > 0.001) {
            fg.enabled = true;
            fg.density = st.base_fog_density + local_fog * 0.65;
        } else {
            fg.enabled = st.base_fog_enabled;
            fg.density = st.base_fog_density;
            fg.volumetric.enabled = st.base_fog_enabled and st.graph_opts.enable_volumetric;
        }
    }
    const dyn_scale = st.dyn_res.update(@floatCast(prof.totalFrameMs()));
    const gi_sample = st.gi_vol.sampleIrradiance(cam_pose.position, .{ 0, 1, 0 });
    var helios_tier_name: []const u8 = "off";
    var helios_cells: usize = 0;
    if (ctx.resources.get(helios.HeliosService)) |hsvc| {
        hsvc.beginFrame();
        _ = try hsvc.evaluatePoint(cam_pose.position, .{ 0, 1, 0 }, &st.gi_vol, .{ 0.25, 0.35, 0.55 }, gi_sample, 0.35);
        helios_tier_name = @tagName(hsvc.settings.tier);
        helios_cells = hsvc.cache.cells.count();
    }

    if (st.show_volumes) {
        const pb_c = [3]f32{
            (st.probe.box_min[0] + st.probe.box_max[0]) * 0.5,
            (st.probe.box_min[1] + st.probe.box_max[1]) * 0.5,
            (st.probe.box_min[2] + st.probe.box_max[2]) * 0.5,
        };
        const pb_s = [3]f32{
            st.probe.box_max[0] - st.probe.box_min[0],
            st.probe.box_max[1] - st.probe.box_min[1],
            st.probe.box_max[2] - st.probe.box_min[2],
        };
        giz.cuboid(pb_c, pb_s, .{ 1.0, 0.82, 0.25, 0.75 });
        giz.sphere(st.probe.position, 0.35, 14, .{ 1.0, 0.88, 0.35, 0.95 });
        giz.cuboid(st.fog_vol.center, .{ st.fog_vol.half_extents[0] * 2, st.fog_vol.half_extents[1] * 2, st.fog_vol.half_extents[2] * 2 }, .{ 0.25, 0.85, 1.0, 0.75 });
        for (0..st.gi_vol.dims[2]) |iz| {
            for (0..st.gi_vol.dims[1]) |iy| {
                for (0..st.gi_vol.dims[0]) |ix| {
                    const p = st.gi_vol.probePtr(@intCast(ix), @intCast(iy), @intCast(iz)).?;
                    const irr = p.sh.evaluate(.{ 0, 1, 0 });
                    const pos = [3]f32{
                        st.gi_vol.origin[0] + @as(f32, @floatFromInt(ix)) * st.gi_vol.spacing[0],
                        st.gi_vol.origin[1] + @as(f32, @floatFromInt(iy)) * st.gi_vol.spacing[1],
                        st.gi_vol.origin[2] + @as(f32, @floatFromInt(iz)) * st.gi_vol.spacing[2],
                    };
                    giz.sphere(pos, 0.22, 10, .{ std.math.clamp(irr[0], 0.15, 1.0), std.math.clamp(irr[1], 0.15, 1.0), std.math.clamp(irr[2], 0.15, 1.0), 0.85 });
                }
            }
        }
        for (st.gi_vpls.items) |vpl| {
            giz.sphere(vpl.position, 0.18, 10, .{
                std.math.clamp(vpl.color[0], 0.1, 1.0),
                std.math.clamp(vpl.color[1], 0.1, 1.0),
                std.math.clamp(vpl.color[2], 0.1, 1.0),
                0.95,
            });
        }
    }

    var pass_buf: [160]u8 = @splat(0);
    var p_len: usize = 0;
    for (sched.order, 0..) |idx, i| {
        const sep = if (i > 0) " -> " else "";
        const s = std.fmt.bufPrint(pass_buf[p_len..], "{s}{s}", .{ sep, graph.passes.items[idx].name }) catch break;
        p_len += s.len;
    }

    const h1 = std.fmt.bufPrint(
        &st.hud1,
        "[Tab] Scene: {s} | FPS:{d:.0} ({d:.2}ms) | Inst:{d} Vis:{d} Cull:{d} Batch:{d}",
        .{ st.scene_name[0..st.scene_name_len], prof.fps(), prof.totalFrameMs(), stats.total_instances, stats.visible_opaque, stats.culled_count, stats.opaque_batches },
    ) catch "Prism";
    st.hud1_len = h1.len;

    const h2 = std.fmt.bufPrint(&st.hud2, "PassGraph ({d}): {s}", .{ sched.order.len, pass_buf[0..p_len] }) catch "PassGraph";
    st.hud2_len = h2.len;

    const h3 = std.fmt.bufPrint(
        &st.hud3,
        "[1]Shd:{any} [2]SSAO:{any} [3]Vol:{any} [4]Bloom:{any} [5]Preset:{s} [P]Vols [G]Bounds [C]Cut",
        .{ st.graph_opts.enable_shadows, st.graph_opts.enable_ssao, st.graph_opts.enable_volumetric, st.graph_opts.enable_bloom, @tagName(st.preset) },
    ) catch "Controls";
    st.hud3_len = h3.len;

    const vmem = prism.editor_api.estimateViewMemoryBytes(
        vw,
        vh,
        st.graph_opts.enable_ssao,
        st.graph_opts.enable_volumetric,
        st.graph_opts.enable_bloom,
        true,
    );
    const vram_mb = @as(f64, @floatFromInt(vmem.totalBytes())) / (1024.0 * 1024.0);
    const h4 = std.fmt.bufPrint(
        &st.hud4,
        "Hist:{d}f | ProbeW:{d:.2} DynRes:{d:.0}% VRAM:{d:.1}MB | [H]Helios:{s} ({d} VPL / {d} rays, {d} cells)",
        .{ tstate.valid_frames, probe_w, dyn_scale * 100.0, vram_mb, helios_tier_name, st.gi_stats.vpl_count, st.gi_stats.rays_cast, helios_cells },
    ) catch "Stages";
    st.hud4_len = h4.len;

    const sky_label: []const u8 = switch (st.sky_preset) {
        0 => "Scene",
        1 => "HDRI",
        2 => "Day",
        3 => "Dusk",
        else => "Night",
    };
    const pp_opt = ctx.world.get(st.cam_entity, render_3d.pbr.PostProcessSettings);
    const tm_name: []const u8 = if (pp_opt) |pp| @tagName(pp.tonemap_mode) else "agx";
    const tm_look: []const u8 = if (pp_opt) |pp| (if (pp.tonemap_mode == .agx and pp.tonemap_look == .punchy) "(Punchy)" else "") else "";
    const ae_on: bool = if (pp_opt) |pp| pp.auto_exposure.enabled else true;
    const vig_on: bool = if (pp_opt) |pp| pp.vignette.enabled else false;
    const h5 = std.fmt.bufPrint(
        &st.hud5,
        "[N]Sky:{s} | [R]SunRot:{any} | [T]Tonemap:{s}{s} | [X]AutoExp:{any} | [V]Vig:{any} | [F]Fog:{any}",
        .{ sky_label, st.rotate_sun, tm_name, tm_look, ae_on, vig_on, st.base_fog_enabled },
    ) catch "PBR";
    st.hud5_len = h5.len;
}

fn renderOverlay(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(PrismShowcaseState) orelse return;
    const cam_svc = ctx.resources.get(camera.CameraService) orelse return;
    const psvc = ctx.resources.get(prism.PrismService) orelse return;
    const px = window_sdl3.pixelSize(st.app);
    const w: u32 = if (px) |p| p.width else 1280;
    const h: u32 = if (px) |p| p.height else 720;
    cam_svc.setPrimaryTargetSize(w, h);
    _ = psvc.views.resizeView(st.view_id, w, h);

    try st.gfx.beginFrame(st.rt);
    try st.gfx.submitDrawCommands(st.rt, &.{
        .{ .text = .{ .x = 16, .y = 16, .content = st.hud1[0..st.hud1_len], .color = .{ .r = 0.55, .g = 0.96, .b = 0.72, .a = 1.0 } } },
        .{ .text = .{ .x = 16, .y = 38, .content = st.hud2[0..st.hud2_len], .color = .{ .r = 0.88, .g = 0.92, .b = 1.0, .a = 1.0 } } },
        .{ .text = .{ .x = 16, .y = 60, .content = st.hud3[0..st.hud3_len], .color = .{ .r = 1.0, .g = 0.93, .b = 0.72, .a = 1.0 } } },
        .{ .text = .{ .x = 16, .y = 82, .content = st.hud4[0..st.hud4_len], .color = .{ .r = 0.65, .g = 0.90, .b = 1.0, .a = 1.0 } } },
        .{ .text = .{ .x = 16, .y = 104, .content = st.hud5[0..st.hud5_len], .color = .{ .r = 0.96, .g = 0.80, .b = 1.0, .a = 1.0 } } },
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
    try app.registerModule(gizmos.module());
    try app.registerModule(shapes.module());
    try app.registerModule(dev_tools.module());
    try app.registerModule(prism.module());
    try app.registerModule(helios.module());

    try app.resources.insert(window_sdl3.WindowConfig, .{
        .title = "Zengy — Prism & Helios Data-Driven Showcase ([Tab] Switch JSON Scene)",
        .width = 1280,
        .height = 720,
        .resizable = true,
    });
    var hdri = try render_3d.ibl.loadRadianceHdrFromMemory(allocator, SKY_HDR_BYTES);
    defer hdri.deinit();

    try app.resources.insert(render_3d.pbr.SkyEnvironment, .{
        .kind = .procedural,
        .hdri_pixels = hdri.pixels,
        .hdri_width = hdri.width,
        .hdri_height = hdri.height,
        .hdri_exposure_ev = -0.6,
        .sky_tint = .{ 0.14, 0.40, 0.88 },
        .horizon_tint = .{ 0.58, 0.76, 0.96 },
        .ground_albedo = .{ 0.16, 0.17, 0.19 },
    });
    try app.resources.insert(render_3d.pbr.AmbientLight, .{
        .color = .{ 0.55, 0.68, 0.88 },
        .brightness = 0.05,
    });
    try app.resources.insert(render_3d.pbr.FogSettings, .{
        .enabled = false,
        .density = 0.010,
        .start_distance = 4.0,
        .volumetric = .{
            .enabled = false,
            .anisotropy = 0.68,
            .scattering = 0.18,
            .max_distance = 75.0,
        },
    });

    try app.addSystem(.{ .name = "prism_showcase.update", .stage = .update, .run = updatePrismShowcase });
    try app.addSystem(.{ .name = "prism_showcase.overlay", .stage = .render_extract, .run = renderOverlay });

    try app.initialize();

    const g_entry = try app.services.getService("engine.graphics.device", 1);
    const gfx: *graphics.GraphicsDeviceService = @ptrCast(@alignCast(@constCast(g_entry.api_ptr)));
    const psvc = app.resources.get(prism.PrismService).?;

    // Upload all 7 procedural shape meshes once; JSON scenes reference them by name.
    var m_plane = try (shapes.Plane{ .size = .{ 1.0, 1.0 }, .subdivisions = .{ 4, 4 } }).mesh(allocator);
    defer m_plane.deinit();
    var m_cuboid = try (shapes.Cuboid{ .size = .{ 1.0, 1.0, 1.0 } }).mesh(allocator);
    defer m_cuboid.deinit();
    var m_sphere = try (shapes.Sphere{ .radius = 0.5, .rings = 18, .sectors = 32 }).mesh(allocator);
    defer m_sphere.deinit();
    var m_capsule = try (shapes.Capsule{ .radius = 0.32, .half_length = 0.36, .rings = 10, .sectors = 24 }).mesh(allocator);
    defer m_capsule.deinit();
    var m_cyl = try (shapes.Cylinder{ .radius = 0.5, .height = 1.0, .radial_segments = 28 }).mesh(allocator);
    defer m_cyl.deinit();
    var m_torus = try (shapes.Torus{ .major_radius = 0.48, .minor_radius = 0.18, .major_segments = 32, .minor_segments = 16 }).mesh(allocator);
    defer m_torus.deinit();
    var m_cone = try (shapes.Cone{ .radius = 0.5, .height = 1.0, .radial_segments = 28 }).mesh(allocator);
    defer m_cone.deinit();

    const assets = ShapeAssets{
        .plane = @bitCast(try graphics_sdlgpu.createMesh3D(&app, std.mem.sliceAsBytes(m_plane.vertices), m_plane.indices)),
        .cuboid = @bitCast(try graphics_sdlgpu.createMesh3D(&app, std.mem.sliceAsBytes(m_cuboid.vertices), m_cuboid.indices)),
        .sphere = @bitCast(try graphics_sdlgpu.createMesh3D(&app, std.mem.sliceAsBytes(m_sphere.vertices), m_sphere.indices)),
        .capsule = @bitCast(try graphics_sdlgpu.createMesh3D(&app, std.mem.sliceAsBytes(m_capsule.vertices), m_capsule.indices)),
        .cylinder = @bitCast(try graphics_sdlgpu.createMesh3D(&app, std.mem.sliceAsBytes(m_cyl.vertices), m_cyl.indices)),
        .torus = @bitCast(try graphics_sdlgpu.createMesh3D(&app, std.mem.sliceAsBytes(m_torus.vertices), m_torus.indices)),
        .cone = @bitCast(try graphics_sdlgpu.createMesh3D(&app, std.mem.sliceAsBytes(m_cone.vertices), m_cone.indices)),
    };

    const sun_e = try app.world.spawn();
    try app.world.set(sun_e, render_3d.pbr.DirectionalLight, .{
        .color = .{ 1.0, 0.96, 0.90 },
        .illuminance_lux = 26000.0,
        .direction = .{ -0.45, -0.78, -0.42 },
        .shadows_enabled = true,
    });

    const cam_e = try app.world.spawn();
    try app.world.set(cam_e, camera.Camera, .{ .order = 0 });
    try app.world.set(cam_e, camera.Projection, .{ .perspective = .{ .fov_rad = std.math.pi / 3.0, .near = 0.25, .far = 200.0 } });
    try app.world.set(cam_e, camera.CameraPose, camera.CameraPose.lookAt(.{ 0, 5.2, 13.5 }, .{ 0, 1.4, 0 }, .{ 0, 1, 0 }));
    try app.world.set(cam_e, camera.FreeCamera, .{ .walk_speed = 8.0, .run_speed = 18.0 });
    try app.world.set(cam_e, camera.FreeCameraState, .{});
    try app.world.set(cam_e, render_3d.pbr.PostProcessSettings, .{
        .auto_exposure = .{ .enabled = true, .min_ev100 = -2.0, .max_ev100 = 3.0, .speed_brighten = 3.0, .speed_darken = 1.5 },
        .bloom = .{ .enabled = true, .intensity = 0.30, .threshold = 1.1, .scatter = 0.72 },
        .ssao = .{ .enabled = true, .radius = 0.65, .intensity = 1.25, .bias = 0.03 },
        .contact_shadows = .{ .enabled = true, .length = 0.45, .thickness = 0.12, .opacity = 0.8 },
        .quality = .{
            .shadows = .{
                .normal_offset = true,
                .prioritize_local_lights = true,
                .static_cache = true,
                .adaptive_atlas = true,
            },
        },
        .tonemap_mode = .agx,
        .tonemap_look = .base,
    });

    const px = window_sdl3.pixelSize(&app);
    const w: u32 = if (px) |p| p.width else 1280;
    const h: u32 = if (px) |p| p.height else 720;
    const rt = try gfx.createSurface(1, w, h);
    const view_id = try psvc.views.createView(w, h, .{ .lighting = .rasterized, .anti_aliasing = .fxaa });

    var gi_vol = try prism.baked_gi.IrradianceProbeVolume.init(allocator, .{ -10.0, 1.8, -10.0 }, .{ 6.5, 2.8, 6.5 }, .{ 4, 2, 4 });
    for (0..gi_vol.dims[2]) |iz| {
        for (0..gi_vol.dims[1]) |iy| {
            for (0..gi_vol.dims[0]) |ix| {
                const p = gi_vol.probePtr(@intCast(ix), @intCast(iy), @intCast(iz)).?;
                const warm: f32 = if (ix < 2) 0.95 else 0.45;
                const cool: f32 = if (ix >= 2) 0.95 else 0.50;
                p.sh.addDirectional(.{ 0, 1, 0 }, .{ warm, 0.75, cool }, 0.85);
            }
        }
    }

    if (app.resources.get(helios.HeliosService)) |hsvc| {
        hsvc.settings.tier = .high;
    }

    const cap_dir: ?[]const u8 = init.environ_map.get("ZENGY_PRISM_CAPTURE");
    if (cap_dir) |d| {
        std.Io.Dir.cwd().createDirPath(init.io, d) catch {};
    }

    try app.resources.insert(PrismShowcaseState, .{
        .app = &app,
        .gfx = gfx,
        .rt = rt,
        .cam_entity = cam_e,
        .sun_entity = sun_e,
        .view_id = view_id,
        .assets = assets,
        .gi_vol = gi_vol,
        .gi_bvh = helios.ray_query.Bvh.init(allocator),
        .capture_dir = cap_dir,
        .capture_io = init.io,
    });

    try loadJsonScene(app.resources.get(PrismShowcaseState).?, 0);
    try window_sdl3.runVisualLoop(&app);
}
