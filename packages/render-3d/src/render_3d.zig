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
pub const math3d = @import("math3d.zig");
pub const gltf = @import("gltf.zig");

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

/// 3D perspective camera component.
pub const Camera3D = struct {
    position: [3]f32 = .{ 0, 2.0, 6.0 },
    target: [3]f32 = .{ 0, 0, 0 },
    up: [3]f32 = .{ 0, 1, 0 },
    fov_deg: f32 = 60.0,
    near: f32 = 0.1,
    far: f32 = 1000.0,
    aspect: f32 = 16.0 / 9.0,
    active: bool = true,

    pub fn viewProjMatrix(self: Camera3D, aspect_override: ?f32) math3d.Mat4 {
        const eye = math3d.Vec3{ .x = self.position[0], .y = self.position[1], .z = self.position[2] };
        const tgt = math3d.Vec3{ .x = self.target[0], .y = self.target[1], .z = self.target[2] };
        const up_v = math3d.Vec3{ .x = self.up[0], .y = self.up[1], .z = self.up[2] };
        const view = math3d.Mat4.lookAt(eye, tgt, up_v);
        const fov_rad = self.fov_deg * (std.math.pi / 180.0);
        const proj = math3d.Mat4.perspective(fov_rad, aspect_override orelse self.aspect, self.near, self.far);
        return math3d.Mat4.mul(proj, view);
    }
};

/// Reference to a mesh asset handle, material ID, tint color, and bounding radius (> 0 enables frustum culling).
pub const MeshRef = struct {
    mesh_asset: u64,
    material_id: u32 = 0,
    bounds_radius: f32 = 0.0,
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

    var active_cam: ?Camera3D = null;
    {
        var cam_q = try ctx.query(.{ .read = .{Camera3D} });
        defer cam_q.deinit();
        while (cam_q.next()) |row| {
            const c = row.read(Camera3D);
            if (c.active) {
                svc.active_cameras += 1;
                if (active_cam == null) active_cam = c.*;
            }
        }
    }

    const cam = active_cam orelse return;
    const vp = cam.viewProjMatrix(svc.viewport_aspect);
    svc.view_proj = vp;
    const frustum = math3d.Frustum.fromViewProj(vp);

    var mesh_q = try ctx.query(.{ .read = .{ Transform3D, MeshRef } });
    defer mesh_q.deinit();
    while (mesh_q.next()) |row| {
        const t = row.read(Transform3D);
        const m = row.read(MeshRef);

        if (m.bounds_radius > 0.0) {
            const max_scale = @max(@abs(t.scale[0]), @max(@abs(t.scale[1]), @abs(t.scale[2])));
            const world_radius = m.bounds_radius * max_scale;
            const center = math3d.Vec3{ .x = t.position[0], .y = t.position[1], .z = t.position[2] };
            if (!frustum.intersectsSphere(center, world_radius)) {
                svc.culled_count += 1;
                continue;
            }
        }

        const model = t.toModelMatrix();
        const mvp = math3d.Mat4.mul(vp, model);
        try svc.extracted_draws.append(svc.allocator, .{
            .entity = row.entity,
            .position = t.position,
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
    _ = try app.registerComponent(Camera3D);
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
    if (app.resources.get(Render3DService)) |svc| {
        svc.deinit();
        _ = app.resources.remove(Render3DService);
    }
}

pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = "official.render.3d",
            .version = "0.1.0",
            .provides_capabilities = &.{"engine.render.3d/1"},
            .required_capabilities = &.{"engine.graphics.device/1"},
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
