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
const wgpu = @import("graphics_wgpu");
const draw_2d = @import("draw_2d");
const gpu_3d = @import("gpu_3d");
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
    @embedFile("scene/06_dark_room_sunbeam.json"),
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

const CpuShape = struct { vertices: []const shapes.Vertex3D, indices: []const u32 };
const ShapeAssets = struct {
    cpu: [7]CpuShape,
    plane: u64,
    cuboid: u64,
    sphere: u64,
    capsule: u64,
    cylinder: u64,
    torus: u64,
    cone: u64,

    fn cpuForMesh(self: ShapeAssets, mesh: u64) ?CpuShape {
        for ([_]u64{self.plane,self.cuboid,self.sphere,self.capsule,self.cylinder,self.torus,self.cone},self.cpu) |id, data| if (id==mesh) return data;
        return null;
    }
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

const GizmoMode = enum { move, scale };
const GizmoAxis = enum(u8) { none, x, y, z, uniform };

fn dot3(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn cross3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

fn normalize3(v: [3]f32) [3]f32 {
    const l = @sqrt(dot3(v, v));
    if (l < 1e-6) return .{ 0, 1, 0 };
    return .{ v[0] / l, v[1] / l, v[2] / l };
}

fn projectToScreen(m: [16]f32, p: [3]f32, vw: f32, vh: f32) ?[2]f32 {
    const cx = m[0] * p[0] + m[4] * p[1] + m[8] * p[2] + m[12];
    const cy = m[1] * p[0] + m[5] * p[1] + m[9] * p[2] + m[13];
    const cw = m[3] * p[0] + m[7] * p[1] + m[11] * p[2] + m[15];
    if (cw <= 0.01) return null;
    const ndc_x = cx / cw;
    const ndc_y = cy / cw;
    return .{ (ndc_x * 0.5 + 0.5) * vw, (0.5 - ndc_y * 0.5) * vh };
}

fn distPointToSegment2D(p: [2]f32, a: [2]f32, b: [2]f32) f32 {
    const abx = b[0] - a[0];
    const aby = b[1] - a[1];
    const len2 = abx * abx + aby * aby;
    if (len2 < 1e-4) return @sqrt((p[0] - a[0]) * (p[0] - a[0]) + (p[1] - a[1]) * (p[1] - a[1]));
    const t = std.math.clamp(((p[0] - a[0]) * abx + (p[1] - a[1]) * aby) / len2, 0.0, 1.0);
    const qx = a[0] + abx * t;
    const qy = a[1] + aby * t;
    return @sqrt((p[0] - qx) * (p[0] - qx) + (p[1] - qy) * (p[1] - qy));
}

/// One Helios bounce light that fades toward its latest solved target instead of popping in or out.
const VplSlot = struct {
    entity: engine.EntityHandle,
    pos: [3]f32,
    color: [3]f32,
    lumens: f32,
    range: f32,
    target_pos: [3]f32,
    target_color: [3]f32,
    target_lumens: f32,
    target_range: f32,
    /// False once the solver no longer produces this light; the slot fades out and is despawned.
    wanted: bool,
};

/// Physical radius (metres) given to bounce lights; it softens their near-field falloff.
const VPL_RADIUS: f32 = 1.8;

/// Render layer of the dark-room interior (scene 06). Bounce lights carry only this layer there.
const ROOM_LAYER: u32 = 2;

/// Minimum time between GI re-solves while an object is being dragged.
const GI_DRAG_INTERVAL: f32 = 0.2;
/// Time without movement after which the full-quality GI solve runs.
const GI_SETTLE_SECONDS: f32 = 0.35;

/// Exponential rate (1/s) at which bounce lights follow their targets: about 0.35 s to settle.
const VPL_FADE_RATE: f32 = 6.0;

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
    spawned_obj_count: usize = 0,
    selected_obj: usize = 0,
    obj_edit_highlight: f32 = 0.0,
    gizmo_mode: GizmoMode = .move,
    gizmo_drag_axis: GizmoAxis = .none,
    gizmo_hover_axis: GizmoAxis = .none,
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
    gi_materials: std.ArrayList(helios.indirect_rt.SurfaceMaterial) = .empty,
    gi_emitters: std.ArrayList(helios.gi_solver.DirectPointEmitter) = .empty,
    gi_vpls: std.ArrayList(helios.gi_solver.VirtualPointLight) = .empty,
    gi_vpl_slots: std.ArrayList(VplSlot) = .empty,
    gi_stats: helios.gi_solver.GiSolveStats = .{},
    gi_dirty: bool = true,
    dynamic_gi_enabled: bool = false,
    gpu_gi_enabled:bool=false,
    gpu_nodes:std.ArrayList(render_3d.pbr.GpuGiNode)=.empty,
    gpu_triangles:std.ArrayList(render_3d.pbr.GpuGiTriangle)=.empty,
    gpu_materials:std.ArrayList(render_3d.pbr.GpuGiMaterial)=.empty,
    gpu_geometry_revision:?u64=null,
    gpu_grid_epoch:u64=0,
    gpu_last_sky:?u8=null,
    advanced_lighting_enabled: bool = false,
    screen_mode: []const u8 = "0",
    froxel_enabled: bool = false,
    dynamic_grid: helios.dynamic_gi.Grid = .{},
    dynamic_revision: u64 = 0,
    dynamic_scene: ?usize = null,
    dynamic_sky_preset: ?u8 = null,
    dynamic_cursor: usize = 0,
    gi_geometry_dirty: bool = false,
    /// A GI re-solve is waiting (an object is being dragged). While the drag lasts the solve runs at most every
    /// `GI_DRAG_INTERVAL` seconds and at reduced quality; once the object has been still for `GI_SETTLE_SECONDS`
    /// one full-quality solve runs.
    gi_pending: bool = false,
    gi_cooldown: f32 = 0.0,
    gi_move_age: f32 = 1.0e9,
    indoor_blend: f32 = 0.0,
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
        self.gi_materials.deinit(self.app.allocator);
        self.gpu_nodes.deinit(self.app.allocator);
        self.gpu_triangles.deinit(self.app.allocator);
        self.gpu_materials.deinit(self.app.allocator);
        self.gi_emitters.deinit(self.app.allocator);
        self.gi_vpls.deinit(self.app.allocator);
        self.gi_vpl_slots.deinit(self.app.allocator);
        self.opaque_q.deinit(self.app.allocator);
        self.transparent_q.deinit(self.app.allocator);
        self.batches.deinit(self.app.allocator);
    }
};

fn rebuildGiBvhFromEntities(st: *PrismShowcaseState) !void {
    const allocator = st.app.allocator;
    var gi_tris = std.ArrayList(helios.ray_query.BvhTriangle).empty;
    defer gi_tris.deinit(allocator);
    const n = @min(st.spawned_obj_count, st.spawned.items.len);
    for (0..n) |oi| {
        const tf = st.app.world.get(st.spawned.items[oi], render_3d.Transform3D) orelse continue;
        const mr=st.app.world.getConst(st.spawned.items[oi],render_3d.MeshRef) orelse continue;
        const mesh=st.assets.cpuForMesh(mr.mesh_asset) orelse continue;
        try appendMeshTriangles(allocator,&gi_tris,mesh,tf.toModelMatrix().m,@intCast(oi));
    }
    const gi_service = st.app.resources.get(helios.HeliosService) orelse return error.MissingHeliosService;
    try gi_service.runtime.replaceGeometry(gi_tris.items, st.gi_materials.items);
    st.gi_geometry_dirty = false;
    if (st.app.resources.get(helios.HeliosService)) |svc| svc.cache.invalidateAll();
}

/// Points the bounce-light slots at the freshly solved `st.gi_vpls`: existing slots are reused in order, extra lights
/// spawn dark and fade in, and slots without a light fade out.
fn retargetVplSlots(st: *PrismShowcaseState) !void {
    const allocator = st.app.allocator;
    for (st.gi_vpls.items, 0..) |vpl, i| {
        if (i < st.gi_vpl_slots.items.len) {
            const slot = &st.gi_vpl_slots.items[i];
            slot.target_pos = vpl.position;
            slot.target_color = vpl.color;
            slot.target_lumens = vpl.lumens;
            slot.target_range = vpl.range;
            slot.wanted = true;
        } else {
            const ve = try st.app.world.spawn();
            try st.app.world.set(ve, render_3d.Transform3D, .{ .position = vpl.position });
            try st.app.world.set(ve, render_3d.pbr.PointLight, .{
                .color = vpl.color,
                .intensity_lumens = 0.0,
                .range = vpl.range,
                // Bounce light is diffuse: a large radius softens the near-field hotspot on nearby walls and no
                // specular lobe means no moving glints on glossy floors.
                .radius = VPL_RADIUS,
                .specular_scale = 0.0,
                .shadows_enabled = false,
                // Unshadowed, so keep them from lighting meshes on the other side of a wall.
                .layers = if (st.scene_index == 5) ROOM_LAYER else render_3d.pbr.ALL_LAYERS,
            });
            try st.gi_vpl_slots.append(allocator, .{
                .entity = ve,
                .pos = vpl.position,
                .color = vpl.color,
                .lumens = 0.0,
                .range = vpl.range,
                .target_pos = vpl.position,
                .target_color = vpl.color,
                .target_lumens = vpl.lumens,
                .target_range = vpl.range,
                .wanted = true,
            });
        }
    }
    for (st.gi_vpl_slots.items, 0..) |*slot, i| {
        if (i >= st.gi_vpls.items.len) {
            slot.wanted = false;
            slot.target_lumens = 0.0;
        }
    }
}

/// Moves every bounce light toward its target and despawns the ones that faded out completely.
fn updateVplFade(st: *PrismShowcaseState, dt: f32) void {
    const alpha = 1.0 - @exp(-std.math.clamp(dt, 0.0, 0.1) * VPL_FADE_RATE);
    var i: usize = 0;
    while (i < st.gi_vpl_slots.items.len) {
        const slot = &st.gi_vpl_slots.items[i];
        for (0..3) |k| {
            slot.pos[k] += (slot.target_pos[k] - slot.pos[k]) * alpha;
            slot.color[k] += (slot.target_color[k] - slot.color[k]) * alpha;
        }
        slot.lumens += (slot.target_lumens - slot.lumens) * alpha;
        slot.range += (slot.target_range - slot.range) * alpha;
        if (!slot.wanted and slot.lumens < 1.0) {
            _ = st.app.world.despawn(slot.entity) catch false;
            _ = st.gi_vpl_slots.swapRemove(i);
            continue;
        }
        if (st.app.world.get(slot.entity, render_3d.Transform3D)) |tf| tf.position = slot.pos;
        if (st.app.world.get(slot.entity, render_3d.pbr.PointLight)) |pl| {
            pl.color = slot.color;
            pl.intensity_lumens = slot.lumens;
            pl.range = slot.range;
            pl.layers = if (st.scene_index == 5) ROOM_LAYER else render_3d.pbr.ALL_LAYERS;
        }
        i += 1;
    }
}

// Dynamic probes replace the diffuse fallback; VPLs are disabled in this mode.
fn updateDynamicGi(st: *PrismShowcaseState) !void {
    if (!st.dynamic_gi_enabled) return;
    const service = st.app.resources.get(helios.HeliosService) orelse return;
    const target = st.app.resources.get(render_3d.pbr.DynamicGiGrid) orelse return;
    if (service.settings.tier == .off) {
        if(st.app.resources.get(render_3d.pbr.GpuGiInput)) |gpu_input| gpu_input.enabled=false;
        st.gpu_last_sky=null;
        target.origin_enabled[3] = 0;
        st.dynamic_grid.origin_enabled[3] = 0;
        return;
    }
    // Do not spend the ray budget on a stale geometry snapshot while a drag is pending.
    if (st.gi_geometry_dirty) {
        if(st.app.resources.get(render_3d.pbr.GpuGiInput)) |gpu_input| gpu_input.enabled=false;
        return;
    }
    if (st.dynamic_scene == null or st.dynamic_scene.? != st.scene_index or st.dynamic_sky_preset == null or st.dynamic_sky_preset.? != st.sky_preset or st.dynamic_grid.origin_enabled[3] == 0) {
        st.dynamic_grid = .{};
        if (st.scene_index == 5) {
            st.dynamic_grid.origin_enabled = .{ -2.86, 0.13, -4.86, 1 };
            st.dynamic_grid.spacing = .{ 1.9067, 1.2, 1.9067, 2 };
        } else {
            st.dynamic_grid.origin_enabled = .{ -8, 0.5, -8, 1 };
            st.dynamic_grid.spacing = .{ 5.3333, 1.8, 5.3333, 0 };
        }
        st.dynamic_revision = service.runtime.geometry_revision;
        st.dynamic_scene=st.scene_index;
        st.dynamic_sky_preset = st.sky_preset;
        st.dynamic_cursor = 0;
    }
    const changed_geometry=st.dynamic_revision!=service.runtime.geometry_revision;
    if(changed_geometry){
        st.dynamic_revision=service.runtime.geometry_revision;
        // Start with the probe nearest the edited object. Preserve unaffected history.
        if(st.selected_obj<st.spawned_obj_count and st.selected_obj<st.spawned.items.len){
            if(st.app.world.getConst(st.spawned.items[st.selected_obj],render_3d.Transform3D)) |tf| {
                st.dynamic_cursor=helios.dynamic_gi.invalidateNear(&st.dynamic_grid,tf.position,@max(@abs(tf.scale[0]),@max(@abs(tf.scale[1]),@abs(tf.scale[2])))+2.0);
            }
        }
    }
    var sun: ?helios.gi_solver.DirectSunEmitter = null;
    if (st.app.world.getConst(st.sun_entity, render_3d.pbr.DirectionalLight)) |light| {
        sun = .{ .direction = light.direction, .color = light.color, .illuminance_lux = light.illuminance_lux };
    }
    var settings = helios.dynamic_gi.Settings{
        .probes_per_frame = switch (service.settings.tier) { .off => 0, .low => 1, .medium => 2, .high => 4 },
        .rays_per_probe = switch (service.settings.tier) { .off, .low => 24, .medium => 48, .high => 64 },
        .max_ray_queries=switch(service.settings.tier){.off=>0,.low=>384,.medium=>768,.high=>1536},
        .hysteresis = if (st.gi_move_age < GI_SETTLE_SECONDS) 0.35 else 0.85,
    };
    if (st.app.resources.getConst(render_3d.pbr.SkyEnvironment)) |sky| {
        if (sky.kind == .solid_color) {
            settings.sky_radiance = sky.solid_color;
        } else {
            settings.sky_gradient = .{ .zenith = sky.sky_tint, .horizon = sky.horizon_tint, .ground = sky.ground_albedo };
        }
    }
    if(st.gpu_gi_enabled){
        try publishGpuGi(st,service,target,&settings);
        return;
    }
    try refreshGiEmitters(st);
    _ = helios.dynamic_gi.update(&st.dynamic_grid, &service.runtime.bvh, service.runtime.materials.items, st.gi_emitters.items, sun, settings, &st.dynamic_cursor, service.frame_index);
    target.origin_enabled = st.dynamic_grid.origin_enabled;
    target.spacing = st.dynamic_grid.spacing;
    for (&target.probes, &st.dynamic_grid.probes) |*dst, *src| {
        dst.lobes = src.lobes;
        dst.moments = src.moments;
        dst.offset_validity = src.offset_validity;
    }
}

fn rebuildHeliosGi(st: *PrismShowcaseState) !void {
    const allocator = st.app.allocator;
    // Bounce lights are not despawned here: they are retargeted below and fade (see `updateVplFade`), so a change in
    // visibility (a closing door, a moved cube) never turns the room's light off or on in a single frame.
    const hsvc = st.app.resources.get(helios.HeliosService) orelse return;
    var cfg = helios.gi_solver.configForTier(hsvc.settings.tier);
    if (cfg.max_vpls == 0) {
        st.gi_stats = try hsvc.runtime.solve(&.{}, null, cfg);
        st.gi_vpls.clearRetainingCapacity();
        try retargetVplSlots(st);
        st.gi_dirty = false;
        return;
    }
    if (st.gi_geometry_dirty) try rebuildGiBvhFromEntities(st);
    if (st.dynamic_gi_enabled) {
        st.gi_stats = .{};
        st.gi_vpls.clearRetainingCapacity();
        try retargetVplSlots(st);
        st.gi_dirty = false;
        return;
    }
    // While an object is being dragged the solve runs often, so it uses a coarser sun refinement; the full-quality solve
    // follows once the object is still.
    if (st.gi_move_age < GI_SETTLE_SECONDS) {
        cfg.sun_refine_max_depth = @min(cfg.sun_refine_max_depth, 3);
        cfg.sun_refine_ray_budget = @min(cfg.sun_refine_ray_budget, 1536);
    }
    if (st.app.world.get(st.cam_entity, camera.CameraPose)) |cp| {
        cfg.viewer_pos = cp.position;
    }

    var sun_opt: ?helios.gi_solver.DirectSunEmitter = null;
    if (st.app.world.get(st.sun_entity, render_3d.pbr.DirectionalLight)) |sun| {
        if (sun.illuminance_lux > 50.0) {
            const focus = if (st.app.world.get(st.cam_entity, camera.CameraPose)) |cp| cp.position else [3]f32{ 0, 1.5, 0 };
            sun_opt = .{
                .direction = sun.direction,
                .color = sun.color,
                .illuminance_lux = sun.illuminance_lux,
                .scene_center = if (st.scene_index == 5) .{ 0.0, 1.2, -2.0 } else focus,
                .scene_radius = if (st.scene_index == 5) 4.5 else 10.0,
            };
        }
    }

    try refreshGiEmitters(st);
    st.gi_stats = try hsvc.runtime.solve(st.gi_emitters.items, sun_opt, cfg);
    const result = hsvc.runtime.result();
    try st.gi_vpls.ensureTotalCapacity(allocator, result.len);
    st.gi_vpls.clearRetainingCapacity();
    st.gi_vpls.appendSliceAssumeCapacity(result);

    try retargetVplSlots(st);
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
    for (st.spawned.items) |e| {
        if (st.app.world.getConst(e,render_3d.MeshRef)) |mr| {
            if (mr.material_handle) |handle| _=mats.remove(handle);
        }
        _=st.app.world.despawn(e) catch false;
    }
    st.spawned.clearRetainingCapacity();

    const parsed = try std.json.parseFromSlice(JsonScene, allocator, SCENE_FILES[idx], .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const sc = parsed.value;

    st.scene_index = idx;
    st.dynamic_scene=null;
    if(st.app.resources.get(render_3d.pbr.DynamicGiGrid)) |grid| grid.origin_enabled[3]=0;
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
        fg.volumetric.physical_scattering = st.advanced_lighting_enabled or st.froxel_enabled;
        fg.volumetric.froxel_enabled=st.froxel_enabled;
        if(st.froxel_enabled) fg.volumetric.half_resolution=true;
    }
    if (st.app.world.get(st.cam_entity, render_3d.pbr.PostProcessSettings)) |pp| {
        pp.ssao.enabled = sc.ssao_enabled;
        pp.ssao.horizon_based = st.advanced_lighting_enabled;
        pp.auto_exposure.history_epoch +%= 1;
        pp.bloom.enabled = sc.bloom_enabled;
        pp.quality.area_light_quadrature = st.advanced_lighting_enabled;
        pp.quality.ltc_area_lights = st.advanced_lighting_enabled;
        pp.quality.specular_aa = st.advanced_lighting_enabled;
        const screen_enabled=std.mem.eql(u8, st.screen_mode, "1");
        pp.quality.screen_transport=.{.ssr_strength=if(screen_enabled) 0.8 else 0,.ssgi_strength=if(screen_enabled) 0.35 else 0};
        pp.auto_exposure.physical.local_exposure_strength = if (st.advanced_lighting_enabled) 0.35 else 0.0;
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
        // Scene 06: everything except the ground plane belongs to the room layer, so the unshadowed bounce lights
        // (which live on that layer only) never light the ground outside the walls.
        if (idx == 5 and oi >= 1) {
            try st.app.world.set(e, render_3d.pbr.RenderLayers, .{ .mask = render_3d.pbr.DEFAULT_LAYER | ROOM_LAYER });
        }
        try st.spawned.append(allocator, e);

        try st.gi_materials.append(allocator, .{
            .albedo = obj.color,
            .emissive = obj.emissive,
            .roughness = obj.roughness,
            .metallic = obj.metallic,
        });
        const mesh=st.assets.cpuForMesh(st.assets.meshForName(obj.shape)) orelse return error.MissingCpuMesh;
        const tf=render_3d.Transform3D{.position=obj.pos,.scale=obj.scale};
        try appendMeshTriangles(allocator,&gi_tris,mesh,tf.toModelMatrix().m,@intCast(oi));
    }
    const gi_service = st.app.resources.get(helios.HeliosService) orelse return error.MissingHeliosService;
    try gi_service.runtime.replaceGeometry(gi_tris.items, st.gi_materials.items);
    st.gi_geometry_dirty = false;
    if (st.app.resources.get(helios.HeliosService)) |svc| svc.cache.invalidateAll();
    st.spawned_obj_count = sc.objects.len;
    // Default selection to the interactive pedestal cube in Scene 06 (index 9) or the last prop object.
    st.selected_obj = if (idx == 5 and sc.objects.len > 9) 9 else if (sc.objects.len > 1) sc.objects.len - 1 else 0;
    st.obj_edit_highlight = 0.0;

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

    // Scene 06: the sky IBL (SH9 + prefiltered environment) has no visibility term, so it would light the closed room
    // from outside. A reflection probe over the interior replaces it with a near-black environment; its blend distance
    // fades it in and out at the walls, so crossing the doorway is smooth and the global environment never rebuilds.
    if (idx == 5) {
        const pe = try st.app.world.spawn();
        try st.app.world.set(pe, render_3d.Transform3D, .{ .position = .{ 0.0, 1.94, -2.0 } });
        try st.app.world.set(pe, render_3d.pbr.ReflectionProbe, .{
            // The interior is x +-2.9, y 0.08..3.8, z -4.9..0.9. The box is larger by the blend distance on every side, so
            // the wall, floor and ceiling surfaces themselves sit fully inside the probe (weight 1). A box that ends at the
            // surfaces gives them almost no weight and leaves the sky IBL lighting exactly the walls it should not.
            .half_extents = .{ 3.5, 2.46, 3.5 },
            .blend_distance = 0.6,
            .intensity = 1.0,
            .box_projection = true,
            .sky_tint = .{ 0.05, 0.046, 0.046 },
            .ground_tint = .{ 0.03, 0.028, 0.028 },
            // Diffuse stays near zero (about 0.0007 linear), so the closed room is dark; the reflections keep a dim
            // interior colour instead of black, which is what metallic and glossy props show.
            .diffuse_scale = 0.015,
        });
        try st.spawned.append(allocator, pe);
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
        // The GI solve is throttled and runs at reduced quality while the sun moves (see `gi_pending`).
        st.gi_pending = true;
        st.gi_move_age = 0.0;
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

    // Interactive 3D Transform Gizmo (Left-Click drag X/Y/Z handles, Left-Click object to select,
    // [Z] toggle Move/Scale, plus keyboard [Arrows/U/O] move, [J/L] scale, [M] cycle) with live GI BVH update.
    if (keys.justPressed(.key_z)) {
        st.gizmo_mode = if (st.gizmo_mode == .move) .scale else .move;
    }
    if (st.spawned_obj_count > 1) {
        if (keys.justPressed(.key_m)) {
            st.selected_obj = 1 + (st.selected_obj % (st.spawned_obj_count - 1));
            st.obj_edit_highlight = 1.5;
        }
        const mouse_opt = ctx.resources.get(input.MouseInput);
        const motion_opt = ctx.resources.get(input.AccumulatedMouseMotion);
        const px_g = window_sdl3.pixelSize(st.app);
        const gvw: f32 = @floatFromInt(if (px_g) |p| p.width else 1280);
        const gvh: f32 = @floatFromInt(if (px_g) |p| p.height else 720);

        if (st.selected_obj < st.spawned_obj_count and st.selected_obj < st.spawned.items.len) {
            if (ctx.world.get(st.spawned.items[st.selected_obj], render_3d.Transform3D)) |tf| {
                const cam_dx = tf.position[0] - cam_pose.position[0];
                const cam_dy = tf.position[1] - cam_pose.position[1];
                const cam_dz = tf.position[2] - cam_pose.position[2];
                const cam_dist = @max(@sqrt(cam_dx * cam_dx + cam_dy * cam_dy + cam_dz * cam_dz), 1.5);
                const g_len: f32 = std.math.clamp(cam_dist * 0.16, 0.75, 2.6);

                const p0 = tf.position;
                const px_tip = [3]f32{ p0[0] + g_len, p0[1], p0[2] };
                const py_tip = [3]f32{ p0[0], p0[1] + g_len, p0[2] };
                const pz_tip = [3]f32{ p0[0], p0[1], p0[2] + g_len };

                const s0 = projectToScreen(cam.computed.clip_from_world, p0, gvw, gvh);
                const sx = projectToScreen(cam.computed.clip_from_world, px_tip, gvw, gvh);
                const sy = projectToScreen(cam.computed.clip_from_world, py_tip, gvw, gvh);
                const sz = projectToScreen(cam.computed.clip_from_world, pz_tip, gvw, gvh);

                var moved = false;

                if (mouse_opt != null and motion_opt != null) {
                    const mouse = mouse_opt.?;
                    const motion = motion_opt.?;
                    const mpos = motion.position;

                    if (st.gizmo_drag_axis == .none) {
                        var best_axis: GizmoAxis = .none;
                        var best_d: f32 = 16.0;
                        if (s0) |o2| {
                            if (st.gizmo_mode == .scale) {
                                const dc = @sqrt((mpos[0] - o2[0]) * (mpos[0] - o2[0]) + (mpos[1] - o2[1]) * (mpos[1] - o2[1]));
                                if (dc < 18.0) {
                                    best_axis = .uniform;
                                    best_d = dc;
                                }
                            }
                            if (sx) |t2| {
                                const d = distPointToSegment2D(mpos, o2, t2);
                                if (d < best_d) {
                                    best_d = d;
                                    best_axis = .x;
                                }
                            }
                            if (sy) |t2| {
                                const d = distPointToSegment2D(mpos, o2, t2);
                                if (d < best_d) {
                                    best_d = d;
                                    best_axis = .y;
                                }
                            }
                            if (sz) |t2| {
                                const d = distPointToSegment2D(mpos, o2, t2);
                                if (d < best_d) {
                                    best_d = d;
                                    best_axis = .z;
                                }
                            }
                        }
                        st.gizmo_hover_axis = best_axis;

                        if (mouse.justPressed(.left) and !mouse.pressed(.right)) {
                            if (best_axis != .none) {
                                st.gizmo_drag_axis = best_axis;
                            } else {
                                const right_v = normalize3(cross3(cam_pose.forward, cam_pose.up));
                                const up_v = normalize3(cross3(right_v, cam_pose.forward));
                                const tan_half = @tan(std.math.pi / 6.0);
                                const aspect = gvw / @max(gvh, 1.0);
                                const ndc_x = (mpos[0] / @max(gvw, 1.0)) * 2.0 - 1.0;
                                const ndc_y = 1.0 - (mpos[1] / @max(gvh, 1.0)) * 2.0;
                                const rdir = normalize3(.{
                                    cam_pose.forward[0] + right_v[0] * (ndc_x * aspect * tan_half) + up_v[0] * (ndc_y * tan_half),
                                    cam_pose.forward[1] + right_v[1] * (ndc_x * aspect * tan_half) + up_v[1] * (ndc_y * tan_half),
                                    cam_pose.forward[2] + right_v[2] * (ndc_x * aspect * tan_half) + up_v[2] * (ndc_y * tan_half),
                                });
                                if (st.gi_geometry_dirty) try rebuildGiBvhFromEntities(st);
                                var qst = helios.ray_query.QueryStats{};
                                const gi_service = st.app.resources.get(helios.HeliosService) orelse return error.MissingHeliosService;
                                const hit = gi_service.runtime.bvh.traceClosest(.{ .origin = cam_pose.position, .direction = rdir, .t_min = 0.05, .t_max = 120.0 }, &qst);
                                if (hit.hit and hit.instance_id > 0 and hit.instance_id < st.spawned_obj_count) {
                                    st.selected_obj = hit.instance_id;
                                    st.obj_edit_highlight = 1.0;
                                }
                            }
                        }
                    } else {
                        if (!mouse.pressed(.left) or mouse.pressed(.right)) {
                            st.gizmo_drag_axis = .none;
                        } else if (motion.delta[0] != 0.0 or motion.delta[1] != 0.0) {
                            if (st.gizmo_drag_axis == .uniform) {
                                const delta_s = (motion.delta[0] - motion.delta[1]) * 0.008;
                                const ns = std.math.clamp(tf.scale[0] + delta_s, 0.2, 8.0);
                                const ratio = ns / @max(tf.scale[0], 0.05);
                                tf.scale = .{ tf.scale[0] * ratio, tf.scale[1] * ratio, tf.scale[2] * ratio };
                                moved = true;
                            } else if (s0) |o2| {
                                const tip2_opt: ?[2]f32 = switch (st.gizmo_drag_axis) {
                                    .x => sx,
                                    .y => sy,
                                    .z => sz,
                                    else => null,
                                };
                                if (tip2_opt) |t2| {
                                    const ax = t2[0] - o2[0];
                                    const ay = t2[1] - o2[1];
                                    const alen = @max(@sqrt(ax * ax + ay * ay), 12.0);
                                    const amount = ((motion.delta[0] * ax + motion.delta[1] * ay) / alen) * (g_len / alen);
                                    const idx_ax: usize = switch (st.gizmo_drag_axis) {
                                        .x => 0,
                                        .y => 1,
                                        .z => 2,
                                        else => 0,
                                    };
                                    if (st.gizmo_mode == .move) {
                                        tf.position[idx_ax] += amount;
                                    } else {
                                        tf.scale[idx_ax] = std.math.clamp(tf.scale[idx_ax] + amount, 0.2, 8.0);
                                    }
                                    moved = true;
                                }
                            }
                        }
                    }
                }

                const move_sp: f32 = 2.6 * @as(f32, @floatCast(ctx.dt));
                const scale_sp: f32 = 1.2 * @as(f32, @floatCast(ctx.dt));
                if (keys.pressed(.arrow_left)) {
                    tf.position[0] -= move_sp;
                    moved = true;
                }
                if (keys.pressed(.arrow_right)) {
                    tf.position[0] += move_sp;
                    moved = true;
                }
                if (keys.pressed(.arrow_up)) {
                    tf.position[2] -= move_sp;
                    moved = true;
                }
                if (keys.pressed(.arrow_down)) {
                    tf.position[2] += move_sp;
                    moved = true;
                }
                if (keys.pressed(.key_o)) {
                    tf.position[1] += move_sp;
                    moved = true;
                }
                if (keys.pressed(.key_u)) {
                    tf.position[1] = @max(tf.position[1] - move_sp, tf.scale[1] * 0.5);
                    moved = true;
                }
                if (keys.pressed(.key_l)) {
                    const ns = @min(tf.scale[0] + scale_sp, 6.0);
                    const ratio = ns / @max(tf.scale[0], 0.05);
                    tf.scale = .{ tf.scale[0] * ratio, tf.scale[1] * ratio, tf.scale[2] * ratio };
                    moved = true;
                }
                if (keys.pressed(.key_j)) {
                    const ns = @max(tf.scale[0] - scale_sp, 0.25);
                    const ratio = ns / @max(tf.scale[0], 0.05);
                    tf.scale = .{ tf.scale[0] * ratio, tf.scale[1] * ratio, tf.scale[2] * ratio };
                    moved = true;
                }
                if (moved) {
                    st.obj_edit_highlight = 0.6;
                    st.gi_geometry_dirty = true;
                    // The solve itself is deferred and throttled (see `gi_pending`): running it on every frame of a
                    // drag made moving objects stutter.
                    st.gi_pending = true;
                    st.gi_move_age = 0.0;
                }

                // Draw X-Ray 3D RGB Transform Gizmo.
                const active_ax = if (st.gizmo_drag_axis != .none) st.gizmo_drag_axis else st.gizmo_hover_axis;
                const col_x: [4]f32 = if (active_ax == .x) .{ 1.0, 0.95, 0.2, 1.0 } else .{ 1.0, 0.22, 0.22, 1.0 };
                const col_y: [4]f32 = if (active_ax == .y) .{ 1.0, 0.95, 0.2, 1.0 } else .{ 0.22, 1.0, 0.30, 1.0 };
                const col_z: [4]f32 = if (active_ax == .z) .{ 1.0, 0.95, 0.2, 1.0 } else .{ 0.25, 0.55, 1.0, 1.0 };
                giz.lineXray(p0, px_tip, col_x);
                giz.lineXray(p0, py_tip, col_y);
                giz.lineXray(p0, pz_tip, col_z);

                const h_sz = g_len * 0.14;
                if (st.gizmo_mode == .move) {
                    giz.sphere(px_tip, h_sz * 0.7, 8, col_x);
                    giz.sphere(py_tip, h_sz * 0.7, 8, col_y);
                    giz.sphere(pz_tip, h_sz * 0.7, 8, col_z);
                } else {
                    const col_c: [4]f32 = if (active_ax == .uniform) .{ 1.0, 0.95, 0.2, 1.0 } else .{ 0.95, 0.95, 0.98, 1.0 };
                    giz.cuboid(p0, .{ h_sz * 1.4, h_sz * 1.4, h_sz * 1.4 }, col_c);
                    giz.cuboid(px_tip, .{ h_sz, h_sz, h_sz }, col_x);
                    giz.cuboid(py_tip, .{ h_sz, h_sz, h_sz }, col_y);
                    giz.cuboid(pz_tip, .{ h_sz, h_sz, h_sz }, col_z);
                }
                if (st.obj_edit_highlight > 0.0) {
                    st.obj_edit_highlight = @max(0.0, st.obj_edit_highlight - @as(f32, @floatCast(ctx.dt)));
                    giz.cuboid(tf.position, .{ tf.scale[0] + 0.05, tf.scale[1] + 0.05, tf.scale[2] + 0.05 }, .{ 0.25, 0.95, 1.0, 0.85 });
                }
            }
        }
    }

    {
        const frame_dt: f32 = @floatCast(ctx.dt);
        st.gi_move_age += frame_dt;
        st.gi_cooldown -= frame_dt;
        if (st.gi_pending) {
            if (st.gi_move_age >= GI_SETTLE_SECONDS) {
                st.gi_dirty = true;
                st.gi_pending = false;
            } else if (st.gi_cooldown <= 0.0) {
                st.gi_dirty = true;
                st.gi_cooldown = GI_DRAG_INTERVAL;
            }
        }
    }
    if (st.gi_dirty) {
        try rebuildHeliosGi(st);
    }
    updateVplFade(st, @floatCast(ctx.dt));
    try updateDynamicGi(st);

    // Optional automated screenshot capture (`ZENGY_PRISM_CAPTURE=<dir>`) to visually verify GI OFF vs HIGH.
    if (st.capture_dir) |cdir| {
        if (st.capture_pending) {
            if (wgpu.takeCapture(st.app)) |img_val| {
                var img = img_val;
                defer img.deinit(st.app.allocator);
                const rgb = try capture_mod.displayToRgb8(st.app.allocator, img);
                defer st.app.allocator.free(rgb);
                const png = try capture_mod.encodePngRgb8(st.app.allocator, img.width, img.height, rgb);
                defer st.app.allocator.free(png);
                const fname: []const u8 = switch (st.capture_step) {
                    0 => "cornell_gi_off.png",
                    1 => "cornell_gi_high.png",
                    2 => "dark_room_inside_gi_off.png",
                    else => "dark_room_inside_gi_high.png",
                };
                const path = try std.fmt.allocPrint(st.app.allocator, "{s}/{s}", .{ cdir, fname });
                defer st.app.allocator.free(path);
                const file = try std.Io.Dir.cwd().createFile(st.capture_io, path, .{});
                defer file.close(st.capture_io);
                try file.writeStreamingAll(st.capture_io, png);
                st.capture_pending = false;
                st.capture_step += 1;
                st.capture_wait = 0;
                if (st.capture_step >= 4) {
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
                    if (ctx.resources.get(helios.HeliosService)) |hsvc| hsvc.settings.tier = .off;
                    try loadJsonScene(st, 5); // 06_dark_room_sunbeam.json inside room, GI OFF
                    cam_pose.* = camera.CameraPose.lookAt(.{ -0.4, 2.3, 1.6 }, .{ -0.6, 1.8, -4.0 }, .{ 0, 1, 0 });
                    if (ctx.world.get(st.cam_entity, camera.FreeCamera)) |fc| fc.state.initialized = false;
                } else if (st.capture_step == 3) {
                    if (ctx.resources.get(helios.HeliosService)) |hsvc| hsvc.settings.tier = .high;
                    try rebuildHeliosGi(st); // 06_dark_room_sunbeam.json inside room, GI HIGH
                }
            }
            st.capture_wait += 1;
            if (st.capture_wait >= 60) {
                _ = wgpu.requestCapture(st.app, .final);
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

    // In Scene 06 (Dark Room Sunbeam), keep SkyEnvironment static (zero per-frame IBL rebuilds / flicker)
    // and only update AmbientLight + trigger Helios GI visibility re-solve when crossing the doorway.
    if (st.scene_index == 5 and st.sky_preset == 0 and !st.dynamic_gi_enabled) {
        const p = cam_pose.position;
        const dx = @max(@abs(p[0]) - 3.1, 0.0);
        const dy = @max(@max(-0.2 - p[1], p[1] - 3.9), 0.0);
        const dz = @max(@max(-5.1 - p[2], p[2] - 1.1), 0.0);
        const outside_dist = @sqrt(dx * dx + dy * dy + dz * dz);
        const t = 1.0 - std.math.clamp(outside_dist / 2.5, 0.0, 1.0);
        const spatial_inside = t * t * (3.0 - 2.0 * t);
        const alpha = 1.0 - @exp(-@as(f32, @floatCast(ctx.dt)) * 4.5);
        const prev_blend = st.indoor_blend;
        st.indoor_blend += (spatial_inside - st.indoor_blend) * alpha;
        if ((prev_blend < 0.5 and st.indoor_blend >= 0.5) or (prev_blend >= 0.5 and st.indoor_blend < 0.5)) {
            st.gi_dirty = true;
        }
        if (ctx.resources.get(render_3d.pbr.AmbientLight)) |amb| {
            amb.brightness = 0.02 * (1.0 - st.indoor_blend);
        }
    } else {
        st.indoor_blend = 0.0;
        if (ctx.resources.get(render_3d.pbr.AmbientLight)) |amb| amb.brightness = 0.05;
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
    const h5 = std.fmt.bufPrint(
        &st.hud5,
        "[N]Sky:{s} [R]Sun:{any} [T]TM:{s}{s} [X]AE:{any} [F]Fog:{any} | [Z]Gizmo:{s} (LMB Drag/Pick) [M]Obj#{d}",
        .{ sky_label, st.rotate_sun, tm_name, tm_look, ae_on, st.base_fog_enabled, @tagName(st.gizmo_mode), st.selected_obj },
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
    try app.registerModule(wgpu.module());
    try app.registerModule(draw_2d.module());
    try app.registerModule(gpu_3d.module());
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
        .cpu=.{
            .{.vertices=m_plane.vertices,.indices=m_plane.indices},
            .{.vertices=m_cuboid.vertices,.indices=m_cuboid.indices},
            .{.vertices=m_sphere.vertices,.indices=m_sphere.indices},
            .{.vertices=m_capsule.vertices,.indices=m_capsule.indices},
            .{.vertices=m_cyl.vertices,.indices=m_cyl.indices},
            .{.vertices=m_torus.vertices,.indices=m_torus.indices},
            .{.vertices=m_cone.vertices,.indices=m_cone.indices},
        },
        .plane = @bitCast(try gpu_3d.createMesh3D(&app, std.mem.sliceAsBytes(m_plane.vertices), m_plane.indices)),
        .cuboid = @bitCast(try gpu_3d.createMesh3D(&app, std.mem.sliceAsBytes(m_cuboid.vertices), m_cuboid.indices)),
        .sphere = @bitCast(try gpu_3d.createMesh3D(&app, std.mem.sliceAsBytes(m_sphere.vertices), m_sphere.indices)),
        .capsule = @bitCast(try gpu_3d.createMesh3D(&app, std.mem.sliceAsBytes(m_capsule.vertices), m_capsule.indices)),
        .cylinder = @bitCast(try gpu_3d.createMesh3D(&app, std.mem.sliceAsBytes(m_cyl.vertices), m_cyl.indices)),
        .torus = @bitCast(try gpu_3d.createMesh3D(&app, std.mem.sliceAsBytes(m_torus.vertices), m_torus.indices)),
        .cone = @bitCast(try gpu_3d.createMesh3D(&app, std.mem.sliceAsBytes(m_cone.vertices), m_cone.indices)),
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
        .auto_exposure = .{ .enabled = true, .min_ev100 = -3.0, .max_ev100 = 4.5, .speed_brighten = 1.2, .speed_darken = 2.0 },
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
            // A moving sun rebuilds the environment often; spread each rebuild over several frames.
            .ibl_rebuild_budget = .sliced,
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

    try app.resources.insert(render_3d.pbr.DynamicGiGrid, .{});
    try app.resources.insert(render_3d.pbr.GpuGiInput,.{});
    try app.resources.insert(PrismShowcaseState, .{
        .dynamic_gi_enabled = std.mem.eql(u8, init.environ_map.get("ZENGY_DYNAMIC_GI") orelse "0", "1") or std.mem.eql(u8,init.environ_map.get("ZENGY_GPU_GI") orelse "0","1"),
        .gpu_gi_enabled=std.mem.eql(u8,init.environ_map.get("ZENGY_GPU_GI") orelse "0","1"),
        .advanced_lighting_enabled = std.mem.eql(u8, init.environ_map.get("ZENGY_ADVANCED_LIGHTING") orelse "0", "1"),
        .screen_mode=init.environ_map.get("ZENGY_SCREEN_TRANSPORT") orelse "0",
        .froxel_enabled=std.mem.eql(u8,init.environ_map.get("ZENGY_FROXEL") orelse "0","1"),
        .app = &app,
        .gfx = gfx,
        .rt = rt,
        .cam_entity = cam_e,
        .sun_entity = sun_e,
        .view_id = view_id,
        .assets = assets,
        .gi_vol = gi_vol,
        .capture_dir = cap_dir,
        .capture_io = init.io,
    });

    try loadJsonScene(app.resources.get(PrismShowcaseState).?, 0);
    try window_sdl3.runVisualLoop(&app);
}


fn meshPoint(v: shapes.Vertex3D,m: [16]f32) [3]f32 {
    return .{m[0]*v.x+m[4]*v.y+m[8]*v.z+m[12],m[1]*v.x+m[5]*v.y+m[9]*v.z+m[13],m[2]*v.x+m[6]*v.y+m[10]*v.z+m[14]};
}
fn appendMeshTriangles(allocator: std.mem.Allocator, out: *std.ArrayList(helios.ray_query.BvhTriangle), mesh: CpuShape, model: [16]f32, instance: u32) !void {
    if (mesh.indices.len%3!=0) return error.InvalidMeshIndices;
    try out.ensureUnusedCapacity(allocator,mesh.indices.len/3);
    const determinant=model[0]*(model[5]*model[10]-model[9]*model[6])-model[4]*(model[1]*model[10]-model[9]*model[2])+model[8]*(model[1]*model[6]-model[5]*model[2]);
    var i:usize=0;
    while(i<mesh.indices.len):(i+=3){
        const a=mesh.indices[i];const b=mesh.indices[i+1];const c_index=mesh.indices[i+2];
        if(a>=mesh.vertices.len or b>=mesh.vertices.len or c_index>=mesh.vertices.len)return error.InvalidMeshIndices;
        out.appendAssumeCapacity(.{.v0=meshPoint(mesh.vertices[a],model),.v1=meshPoint(mesh.vertices[if(determinant<0)c_index else b],model),.v2=meshPoint(mesh.vertices[if(determinant<0)b else c_index],model),.instance_id=instance,.primitive_id=@intCast(i/3)});
    }
}

fn refreshGiEmitters(st: *PrismShowcaseState) !void {
    st.gi_emitters.clearRetainingCapacity();
    for(st.spawned.items[@min(st.spawned_obj_count,st.spawned.items.len)..]) |entity| {
        const light=st.app.world.getConst(entity,render_3d.pbr.PointLight) orelse continue;
        const tf=st.app.world.getConst(entity,render_3d.Transform3D) orelse continue;
        try st.gi_emitters.append(st.app.allocator,.{.position=tf.position,.color=light.color,.lumens=light.intensity_lumens,.range=light.range});
    }
}

fn publishGpuGi(st:*PrismShowcaseState,service:*helios.HeliosService,target:*render_3d.pbr.DynamicGiGrid,settings:*const helios.dynamic_gi.Settings) !void {
    const gpu_input=st.app.resources.get(render_3d.pbr.GpuGiInput) orelse return error.MissingGpuGiInput;
    const allocator=st.app.allocator;
    const revision=service.runtime.geometry_revision;
    if(st.gpu_geometry_revision==null or st.gpu_geometry_revision.?!=revision){
        // Reallocation invalidates previously borrowed slices, even on a later failure.
        gpu_input.*=.{};
        // Reserve every array before publishing any borrowed slice.
        try st.gpu_nodes.ensureTotalCapacity(allocator,service.runtime.bvh.nodes.items.len);
        try st.gpu_triangles.ensureTotalCapacity(allocator,service.runtime.bvh.triangles.items.len);
        try st.gpu_materials.ensureTotalCapacity(allocator,service.runtime.materials.items.len);
        st.gpu_nodes.clearRetainingCapacity();st.gpu_triangles.clearRetainingCapacity();st.gpu_materials.clearRetainingCapacity();
        for(service.runtime.bvh.nodes.items) |node| st.gpu_nodes.appendAssumeCapacity(.{.aabb_min=node.aabb_min,.left_or_first=node.left_or_first,.aabb_max=node.aabb_max,.prim_count=node.prim_count});
        for(service.runtime.bvh.triangles.items) |tri| st.gpu_triangles.appendAssumeCapacity(.{.v0=tri.v0,.material=tri.instance_id,.v1=tri.v1,.mask=tri.mask,.v2=tri.v2});
        for(service.runtime.materials.items) |mat| st.gpu_materials.appendAssumeCapacity(.{.albedo_metal=.{mat.albedo[0],mat.albedo[1],mat.albedo[2],mat.metallic},.emissive_rough=.{mat.emissive[0],mat.emissive[1],mat.emissive[2],mat.roughness}});
        st.gpu_geometry_revision=revision;st.gpu_grid_epoch+%=1;
    }
    if(st.gpu_last_sky==null or st.gpu_last_sky.?!=st.sky_preset){st.gpu_last_sky=st.sky_preset;st.gpu_grid_epoch+%=1;}
    // Reset the CPU seed only; the backend keeps the updated probes on GPU between frames.
    target.origin_enabled=st.dynamic_grid.origin_enabled;target.spacing=st.dynamic_grid.spacing;
    gpu_input.*=.{.enabled=true,.geometry_revision=revision,.grid_epoch=st.gpu_grid_epoch,.nodes=st.gpu_nodes.items,.triangles=st.gpu_triangles.items,.materials=st.gpu_materials.items,.rays_per_probe=settings.rays_per_probe,.probes_per_frame=settings.probes_per_frame};
}
