//! Optional 3D Renderer Foundation Package (`official.render.3d`).
//!
//! Provides Phase E 3D foundation:
//! - `Transform3D`, `Camera3D`, `MeshRef` ECS components
//! - `math3d` (column-major `Mat4`, `Vec3`, `lookAt`, `[0..1]` `perspective`, 6-plane `Frustum`)
//! - `gltf` (minimal glTF 2.0 JSON + base64/binary mesh importer + procedural cube)
//! - `Render3DService` (`engine.render.3d/1`) extracting visible meshes with frustum culling
//!   and precomputed `mvp_matrix` during `.render_extract`.

const std = @import("std");
const engine = @import("engine");
const camera = @import("camera");
const scene = @import("scene");
pub const math3d = @import("math3d.zig");
pub const gltf = @import("gltf.zig");
pub const pbr = @import("pbr.zig");
pub const ibl = @import("ibl.zig");
pub const cluster = @import("cluster.zig");

/// Owner ID used when registering 3D rendering services and components.
pub const MODULE_OWNER_ID: u64 = 2009;

/// 3D spatial transform component.
pub const Transform3D = struct {
    position: [3]f32 = .{ 0, 0, 0 },
    rotation_euler: [3]f32 = .{ 0, 0, 0 },
    scale: [3]f32 = .{ 1, 1, 1 },

    pub fn toModelMatrix(self: Transform3D) math3d.Mat4 {
        const t = math3d.Mat4.translation(self.position[0], self.position[1], self.position[2]);
        const ry = math3d.Mat4.rotationY(self.rotation_euler[1]);
        const rx = math3d.Mat4.rotationX(self.rotation_euler[0]);
        const s = math3d.Mat4.scale(self.scale[0], self.scale[1], self.scale[2]);
        return math3d.Mat4.mul(t, math3d.Mat4.mul(ry, math3d.Mat4.mul(rx, s)));
    }
};

/// Reference to a mesh asset handle, material ID, tint color, and local bounding sphere (> 0 enables frustum culling).
pub const MeshRef = struct {
    mesh_asset: u64,
    material_id: u32 = 0,
    material_handle: ?pbr.MaterialHandle = null,
    bounds_radius: f32 = 0.0,
    bounds_offset: [3]f32 = .{ 0.0, 0.0, 0.0 },
    color: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
};

/// Extracted 3D draw item prepared during `.render_extract`.
pub const ExtractedMeshDraw = struct {
    entity: engine.EntityHandle,
    position: [3]f32,
    model_matrix: math3d.Mat4,
    mvp_matrix: math3d.Mat4,
    color: [4]f32,
    mesh_asset: u64,
    material_id: u32,
    material_handle: ?pbr.MaterialHandle,
};

/// Lightweight shadow-caster draw item for meshes outside the main camera frustum.
pub const ShadowCasterDraw = struct {
    mesh_asset: u64,
    model_matrix: math3d.Mat4,
};

/// Extracts visible 3D meshes, lights, environment, and post-processing state for GPU submission.
pub const Render3DService = struct {
    allocator: std.mem.Allocator,
    extracted_draws: std.ArrayList(ExtractedMeshDraw),
    shadow_casters: std.ArrayList(ShadowCasterDraw) = .empty,
    directional_lights: std.ArrayList(pbr.ExtractedDirectionalLight) = .empty,
    point_lights: std.ArrayList(pbr.ExtractedPointLight) = .empty,
    spot_lights: std.ArrayList(pbr.ExtractedSpotLight) = .empty,
    rect_lights: std.ArrayList(pbr.ExtractedRectLight) = .empty,
    reflection_probes: std.ArrayList(pbr.ExtractedReflectionProbe) = .empty,
    pbr_frame: pbr.ExtractedPbrFrame = .{},
    pbr_backend: ?pbr.PbrBackendVTable = null,
    active_cameras: usize,
    culled_count: usize,
    view_proj: math3d.Mat4,
    viewport_aspect: f32,

    pub fn init(allocator: std.mem.Allocator) Render3DService {
        return .{
            .allocator = allocator,
            .extracted_draws = .empty,
            .active_cameras = 0,
            .culled_count = 0,
            .view_proj = math3d.Mat4.identity(),
            .viewport_aspect = 16.0 / 9.0,
        };
    }

    pub fn deinit(self: *Render3DService) void {
        self.extracted_draws.deinit(self.allocator);
        self.shadow_casters.deinit(self.allocator);
        self.directional_lights.deinit(self.allocator);
        self.point_lights.deinit(self.allocator);
        self.spot_lights.deinit(self.allocator);
        self.rect_lights.deinit(self.allocator);
        self.reflection_probes.deinit(self.allocator);
    }

    /// Registers an optional PBR rendering backend (`PbrBackendVTable`).
    pub fn setPbrBackend(self: *Render3DService, backend: ?pbr.PbrBackendVTable) void {
        self.pbr_backend = backend;
    }

    pub fn setViewportSize(self: *Render3DService, width: f32, height: f32) void {
        if (width > 0.0 and height > 0.0) {
            self.viewport_aspect = width / height;
        }
    }

    pub fn drawCount(self: *const Render3DService) usize {
        return self.extracted_draws.items.len;
    }
};

fn rotateDir(
    local_dir: [3]f32,
    gt_opt: ?*const scene.incremental.GlobalTransform3D,
    t_opt: ?*const Transform3D,
) [3]f32 {
    const m = if (gt_opt) |gt|
        gt.m
    else if (t_opt) |t|
        t.toModelMatrix().m
    else
        return local_dir;
    const rx = m[0] * local_dir[0] + m[4] * local_dir[1] + m[8] * local_dir[2];
    const ry = m[1] * local_dir[0] + m[5] * local_dir[1] + m[9] * local_dir[2];
    const rz = m[2] * local_dir[0] + m[6] * local_dir[1] + m[10] * local_dir[2];
    const len = @sqrt(rx * rx + ry * ry + rz * rz);
    if (len < 1e-6) return local_dir;
    return .{ rx / len, ry / len, rz / len };
}

fn extract3DSystem(ctx: *engine.SystemContext) !void {
    const svc = ctx.resources.get(Render3DService) orelse return;
    svc.extracted_draws.clearRetainingCapacity();
    svc.shadow_casters.clearRetainingCapacity();
    svc.directional_lights.clearRetainingCapacity();
    svc.point_lights.clearRetainingCapacity();
    svc.spot_lights.clearRetainingCapacity();
    svc.rect_lights.clearRetainingCapacity();
    svc.reflection_probes.clearRetainingCapacity();
    svc.active_cameras = 0;
    svc.culled_count = 0;

    const cam_svc = ctx.resources.get(camera.CameraService) orelse return;
    const active = cam_svc.sortedActiveCameras();
    svc.active_cameras = active.len;
    if (active.len == 0) return;

    // Pick highest-order active camera from `official.camera`.
    const primary = active[active.len - 1];
    const vp = math3d.Mat4{ .m = primary.computed.clip_from_world };
    svc.view_proj = vp;
    const frustum = primary.computed.frustum;

    var mesh_q = try ctx.query(.{
        .read = .{MeshRef},
        .optional = .{ scene.incremental.GlobalTransform3D, Transform3D },
    });
    defer mesh_q.deinit();
    while (mesh_q.next()) |row| {
        const m = row.read(MeshRef);
        var model: math3d.Mat4 = undefined;
        var pos: [3]f32 = .{ 0, 0, 0 };
        var max_scale: f32 = 1.0;

        if (row.optional(scene.incremental.GlobalTransform3D)) |gt| {
            model = .{ .m = gt.m };
            pos = .{ gt.m[12], gt.m[13], gt.m[14] };
            const sx = @sqrt(gt.m[0] * gt.m[0] + gt.m[1] * gt.m[1] + gt.m[2] * gt.m[2]);
            const sy = @sqrt(gt.m[4] * gt.m[4] + gt.m[5] * gt.m[5] + gt.m[6] * gt.m[6]);
            const sz = @sqrt(gt.m[8] * gt.m[8] + gt.m[9] * gt.m[9] + gt.m[10] * gt.m[10]);
            max_scale = @max(sx, @max(sy, sz));
        } else if (row.optional(Transform3D)) |t| {
            model = t.toModelMatrix();
            pos = t.position;
            max_scale = @max(@abs(t.scale[0]), @max(@abs(t.scale[1]), @abs(t.scale[2])));
        } else continue;

        if (m.bounds_radius > 0.0) {
            const world_radius = m.bounds_radius * max_scale;
            const ox = m.bounds_offset[0];
            const oy = m.bounds_offset[1];
            const oz = m.bounds_offset[2];
            const center = [3]f32{
                model.m[0] * ox + model.m[4] * oy + model.m[8] * oz + model.m[12],
                model.m[1] * ox + model.m[5] * oy + model.m[9] * oz + model.m[13],
                model.m[2] * ox + model.m[6] * oy + model.m[10] * oz + model.m[14],
            };
            if (!frustum.containsSphere(center, world_radius)) {
                svc.culled_count += 1;
                try svc.shadow_casters.append(svc.allocator, .{
                    .mesh_asset = m.mesh_asset,
                    .model_matrix = model,
                });
                continue;
            }
        }
        const mvp = math3d.Mat4.mul(vp, model);
        try svc.extracted_draws.append(svc.allocator, .{
            .entity = row.entity,
            .position = pos,
            .model_matrix = model,
            .mvp_matrix = mvp,
            .color = m.color,
            .mesh_asset = m.mesh_asset,
            .material_id = m.material_id,
            .material_handle = m.material_handle,
        });
    }

    // Extract Directional, Point, and Spot lights.
    {
        var dl_q = try ctx.query(.{
            .read = .{pbr.DirectionalLight},
            .optional = .{ scene.incremental.GlobalTransform3D, Transform3D },
        });
        defer dl_q.deinit();
        while (dl_q.next()) |row| {
            const dl = row.read(pbr.DirectionalLight);
            var cfg = dl.cascades;
            cfg.cascade_count = std.math.clamp(dl.cascade_count, 1, 4);
            const ldir = rotateDir(
                dl.direction,
                row.optional(scene.incremental.GlobalTransform3D),
                row.optional(Transform3D),
            );
            try svc.directional_lights.append(svc.allocator, .{
                .direction = ldir,
                .color = dl.color,
                .illuminance_lux = dl.illuminance_lux,
                .shadows_enabled = dl.shadows_enabled,
                .shadow_depth_bias = dl.shadow_depth_bias,
                .shadow_normal_bias = dl.shadow_normal_bias,
                .pcss_enabled = dl.pcss_enabled,
                .pcss_light_size = dl.pcss_light_size,
                .cascade_count = cfg.cascade_count,
                .cascade_bounds = pbr.calculateCascadeBounds(cfg),
                .overlap_proportion = cfg.overlap_proportion,
                .minimum_distance = cfg.minimum_distance,
            });
        }
    }
    {
        var pl_q = try ctx.query(.{
            .read = .{pbr.PointLight},
            .optional = .{ scene.incremental.GlobalTransform3D, Transform3D },
        });
        defer pl_q.deinit();
        while (pl_q.next()) |row| {
            const pl = row.read(pbr.PointLight);
            const lpos: [3]f32 = if (row.optional(scene.incremental.GlobalTransform3D)) |gt|
                .{ gt.m[12], gt.m[13], gt.m[14] }
            else if (row.optional(Transform3D)) |t|
                t.position
            else
                .{ 0, 0, 0 };
            try svc.point_lights.append(svc.allocator, .{
                .position = lpos,
                .color = pl.color,
                .intensity_lumens = pl.intensity_lumens,
                .range = pl.range,
                .radius = pl.radius,
                .shadows_enabled = pl.shadows_enabled,
                .shadow_depth_bias = pl.shadow_depth_bias,
            });
        }
    }
    {
        var sl_q = try ctx.query(.{
            .read = .{pbr.SpotLight},
            .optional = .{ scene.incremental.GlobalTransform3D, Transform3D },
        });
        defer sl_q.deinit();
        while (sl_q.next()) |row| {
            const sl = row.read(pbr.SpotLight);
            const lpos: [3]f32 = if (row.optional(scene.incremental.GlobalTransform3D)) |gt|
                .{ gt.m[12], gt.m[13], gt.m[14] }
            else if (row.optional(Transform3D)) |t|
                t.position
            else
                .{ 0, 0, 0 };
            const ldir = rotateDir(
                sl.direction,
                row.optional(scene.incremental.GlobalTransform3D),
                row.optional(Transform3D),
            );
            try svc.spot_lights.append(svc.allocator, .{
                .position = lpos,
                .direction = ldir,
                .color = sl.color,
                .intensity_lumens = sl.intensity_lumens,
                .range = sl.range,
                .inner_angle_rad = sl.inner_angle_rad,
                .outer_angle_rad = sl.outer_angle_rad,
                .radius = sl.radius,
                .shadows_enabled = sl.shadows_enabled,
                .shadow_depth_bias = sl.shadow_depth_bias,
            });
        }
    }
    {
        var rl_q = try ctx.query(.{
            .read = .{pbr.RectLight},
            .optional = .{ scene.incremental.GlobalTransform3D, Transform3D },
        });
        defer rl_q.deinit();
        while (rl_q.next()) |row| {
            const rl = row.read(pbr.RectLight);
            const mat: math3d.Mat4 = if (row.optional(scene.incremental.GlobalTransform3D)) |gt|
                .{ .m = gt.m }
            else if (row.optional(Transform3D)) |t|
                t.toModelMatrix()
            else
                math3d.Mat4.identity();
            const r_v = math3d.Vec3.normalize(.{ .x = mat.m[0], .y = mat.m[1], .z = mat.m[2] });
            const u_v = math3d.Vec3.normalize(.{ .x = mat.m[4], .y = mat.m[5], .z = mat.m[6] });
            const f_v = math3d.Vec3.normalize(.{ .x = -mat.m[8], .y = -mat.m[9], .z = -mat.m[10] });
            try svc.rect_lights.append(svc.allocator, .{
                .position = .{ mat.m[12], mat.m[13], mat.m[14] },
                .direction = .{ f_v.x, f_v.y, f_v.z },
                .right = .{ r_v.x, r_v.y, r_v.z },
                .up = .{ u_v.x, u_v.y, u_v.z },
                .color = rl.color,
                .intensity_lumens = rl.intensity_lumens,
                .half_extents = .{ rl.width * 0.5, rl.height * 0.5 },
                .range = rl.range,
                .two_sided = rl.two_sided,
            });
        }
    }
    {
        var rp_q = try ctx.query(.{
            .read = .{pbr.ReflectionProbe},
            .optional = .{ scene.incremental.GlobalTransform3D, Transform3D },
        });
        defer rp_q.deinit();
        while (rp_q.next()) |row| {
            const rp = row.read(pbr.ReflectionProbe);
            const ppos: [3]f32 = if (row.optional(scene.incremental.GlobalTransform3D)) |gt|
                .{ gt.m[12], gt.m[13], gt.m[14] }
            else if (row.optional(Transform3D)) |t|
                t.position
            else
                .{ 0, 0, 0 };
            try svc.reflection_probes.append(svc.allocator, .{
                .position = ppos,
                .half_extents = rp.half_extents,
                .blend_distance = rp.blend_distance,
                .intensity = rp.intensity,
                .box_projection = rp.box_projection,
                .sky_tint = rp.sky_tint,
                .ground_tint = rp.ground_tint,
            });
        }
    }

    const pp = ctx.world.getConst(primary.entity, pbr.PostProcessSettings);
    const cam_pose = ctx.world.getConst(primary.entity, camera.CameraPose);
    const vw = primary.computed.view_from_world;
    const cam_fwd = math3d.Vec3.normalize(.{ .x = -vw[2], .y = -vw[6], .z = -vw[10] });
    svc.pbr_frame = .{
        .camera_position = if (cam_pose) |cp| cp.position else .{ 0, 0, 0 },
        .camera_forward = .{ cam_fwd.x, cam_fwd.y, cam_fwd.z },
        .view_matrix = vw,
        .view_proj = vp.m,
        .proj_matrix = primary.computed.clip_from_view,
        .ambient = if (ctx.resources.getConst(pbr.AmbientLight)) |a| a.* else .{},
        .sky = if (ctx.resources.getConst(pbr.SkyEnvironment)) |s| s.* else .{},
        .fog = if (ctx.resources.getConst(pbr.FogSettings)) |f| f.* else .{},
        .post_process = if (pp) |p| p.* else .{},
        .directional_lights = svc.directional_lights.items,
        .point_lights = svc.point_lights.items,
        .spot_lights = svc.spot_lights.items,
        .rect_lights = svc.rect_lights.items,
        .reflection_probes = svc.reflection_probes.items,
        .dt = ctx.dt,
    };

    if (svc.pbr_backend) |be| {
        const mat_reg = ctx.resources.getConst(pbr.MaterialRegistry);
        try be.beginPbrFrame(be.ctx, &svc.pbr_frame);
        for (svc.extracted_draws.items) |draw| {
            const mat: pbr.StandardMaterial = if (draw.material_handle) |mh|
                if (mat_reg) |reg| (reg.getConst(mh) orelse &pbr.StandardMaterial{}).* else .{}
            else
                .{};
            try be.submitLitMesh(be.ctx, draw.mesh_asset, draw.model_matrix.m, draw.mvp_matrix.m, mat, draw.color);
        }
        if (be.submitShadowCaster) |submit_sc| {
            for (svc.shadow_casters.items) |sc| {
                try submit_sc(be.ctx, sc.mesh_asset, sc.model_matrix.m);
            }
        }
        try be.endPbrFrame(be.ctx);
    }
}

fn buildModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    try app.resources.insert(Render3DService, Render3DService.init(app.allocator));
    const svc = app.resources.get(Render3DService).?;

    if (!app.resources.contains(pbr.MaterialRegistry)) {
        try app.resources.insert(pbr.MaterialRegistry, try pbr.MaterialRegistry.init(app.allocator));
    }
    if (!app.resources.contains(pbr.AmbientLight)) {
        try app.resources.insert(pbr.AmbientLight, .{});
    }
    if (!app.resources.contains(pbr.SkyEnvironment)) {
        try app.resources.insert(pbr.SkyEnvironment, .{});
    }
    if (!app.resources.contains(pbr.FogSettings)) {
        try app.resources.insert(pbr.FogSettings, .{});
    }

    _ = try app.registerComponent(Transform3D);
    _ = try app.registerComponent(MeshRef);
    _ = try app.registerComponent(pbr.DirectionalLight);
    _ = try app.registerComponent(pbr.PointLight);
    _ = try app.registerComponent(pbr.SpotLight);
    _ = try app.registerComponent(pbr.PostProcessSettings);
    try app.addSystem(.{
        .name = "render3d.extract",
        .stage = .render_extract,
        .run = extract3DSystem,
    });

    try app.services.register(.{
        .capability = "engine.render.3d",
        .major_version = 1,
        .provider_id = "official.render.3d",
        .owner_id = MODULE_OWNER_ID,
        .exclusive = true,
        .api_ptr = svc,
        .api_size = @sizeOf(Render3DService),
    });
}

fn stopModule(raw_app: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    _ = app.services.unregisterByOwner(MODULE_OWNER_ID);
    _ = app.resources.remove(Render3DService);
    _ = app.resources.remove(pbr.MaterialRegistry);
}

pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = "official.render.3d",
            .version = "0.6.0",
            .provides_capabilities = &.{"engine.render.3d/1"},
            .required_capabilities = &.{ "engine.graphics.device/1", "engine.camera/1" },
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
