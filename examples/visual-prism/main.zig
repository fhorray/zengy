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
//! - Tab: Next JSON scene (`01_sunlit_plaza.json` <-> `02_volumetric_cathedral.json`)
//! - W/A/S/D (+Shift sprint, Q/E down/up) + Right-Click Drag: Fly FreeCamera
//! - 1 / 2 / 3 / 4: Toggle Shadows / SSAO / Volumetric Fog / Bloom
//! - 5: Cycle QualityPreset (`low`, `medium`, `high`, `ultra`)
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

const SCENE_FILES = [_][]const u8{
    @embedFile("scene/01_sunlit_plaza.json"),
    @embedFile("scene/02_volumetric_cathedral.json"),
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
        .density = 0.025,
        .height_falloff = 0.12,
        .edge_fade = 1.2,
    },
    gi_vol: prism.baked_gi.IrradianceProbeVolume,
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

    pub fn deinit(self: *PrismShowcaseState) void {
        self.spawned.deinit(self.app.allocator);
        self.gi_vol.deinit();
        self.opaque_q.deinit(self.app.allocator);
        self.transparent_q.deinit(self.app.allocator);
        self.batches.deinit(self.app.allocator);
    }
};

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
        sun.shadows_enabled = true;
    }

    st.graph_opts = .{
        .enable_shadows = true,
        .enable_ssao = sc.ssao_enabled,
        .enable_volumetric = sc.volumetric_enabled,
        .enable_bloom = sc.bloom_enabled,
    };

    // Spawn JSON objects.
    for (sc.objects) |obj| {
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
    }

    // Spawn JSON point lights.
    for (sc.point_lights) |pl| {
        const le = try st.app.world.spawn();
        try st.app.world.set(le, render_3d.Transform3D, .{ .position = pl.pos });
        try st.app.world.set(le, render_3d.pbr.PointLight, .{
            .color = pl.color,
            .intensity_lumens = pl.lumens,
            .range = pl.range,
            .shadows_enabled = true,
        });
        try st.spawned.append(allocator, le);
    }
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
        if (ctx.resources.get(render_3d.pbr.FogSettings)) |fg| {
            fg.enabled = st.graph_opts.enable_volumetric;
            fg.volumetric.enabled = st.graph_opts.enable_volumetric;
        }
    }
    if (keys.justPressed(.digit_4)) {
        st.graph_opts.enable_bloom = !st.graph_opts.enable_bloom;
        if (ctx.world.get(st.cam_entity, render_3d.pbr.PostProcessSettings)) |pp| pp.bloom.enabled = st.graph_opts.enable_bloom;
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

    const h4 = std.fmt.bufPrint(
        &st.hud4,
        "Hist:{d}f | ProbeW:{d:.2} DynRes:{d:.0}% LocalFog:{d:.3} | GI:({d:.2},{d:.2},{d:.2}) | [H]Helios:{s}({d})",
        .{ tstate.valid_frames, probe_w, dyn_scale * 100.0, local_fog, gi_sample[0], gi_sample[1], gi_sample[2], helios_tier_name, helios_cells },
    ) catch "Stages";
    st.hud4_len = h4.len;
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
    try app.resources.insert(render_3d.pbr.SkyEnvironment, .{
        .kind = .procedural,
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
        .density = 0.015,
        .start_distance = 3.0,
        .volumetric = .{
            .enabled = false,
            .anisotropy = 0.68,
            .scattering = 0.24,
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

    try app.resources.insert(PrismShowcaseState, .{
        .app = &app,
        .gfx = gfx,
        .rt = rt,
        .cam_entity = cam_e,
        .sun_entity = sun_e,
        .view_id = view_id,
        .assets = assets,
        .gi_vol = gi_vol,
    });
    defer if (app.resources.get(PrismShowcaseState)) |s| s.deinit();

    try loadJsonScene(app.resources.get(PrismShowcaseState).?, 0);
    try window_sdl3.runVisualLoop(&app);
}
