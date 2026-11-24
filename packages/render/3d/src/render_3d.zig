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
};

/// Extracts visible 3D meshes and active camera state for downstream GPU submission.
pub const Render3DService = struct {
    allocator: std.mem.Allocator,
    extracted_draws: std.ArrayList(ExtractedMeshDraw),
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

fn extract3DSystem(ctx: *engine.SystemContext) !void {
    const svc = ctx.resources.get(Render3DService) orelse return;
    svc.extracted_draws.clearRetainingCapacity();
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
        });
    }
}

fn buildModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    try app.resources.insert(Render3DService, Render3DService.init(app.allocator));
    const svc = app.resources.get(Render3DService).?;

    _ = try app.registerComponent(Transform3D);
    _ = try app.registerComponent(MeshRef);
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
}

pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = "official.render.3d",
            .version = "0.2.0",
            .provides_capabilities = &.{"engine.render.3d/1"},
            .required_capabilities = &.{ "engine.graphics.device/1", "engine.camera/1" },
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
