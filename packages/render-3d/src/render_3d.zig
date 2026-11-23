//! Optional 3D Renderer Foundation Package (`official.render.3d`).
//!
//! Provides Phase 13 3D components (`Transform3D`, `Camera3D`, `MeshRef`) and
//! `Render3DService` (`engine.render.3d/1`) which extracts 3D renderables during
//! `.render_extract` without coupling `src/core/` to any 3D math or GPU API.

const std = @import("std");
const engine = @import("engine");

pub const MODULE_OWNER_ID: u64 = 2009;

/// 3D spatial transform component.
pub const Transform3D = struct {
    position: [3]f32 = .{ 0, 0, 0 },
    scale: [3]f32 = .{ 1, 1, 1 },
};

/// 3D perspective camera component.
pub const Camera3D = struct {
    fov_deg: f32 = 60.0,
    near: f32 = 0.1,
    far: f32 = 1000.0,
    active: bool = true,
};

/// Reference to a mesh asset handle and material ID.
pub const MeshRef = struct {
    mesh_asset: u64,
    material_id: u32 = 0,
};

/// Extracted 3D draw item prepared during `.render_extract`.
pub const ExtractedMeshDraw = struct {
    entity: engine.EntityHandle,
    position: [3]f32,
    mesh_asset: u64,
    material_id: u32,
};

/// Extracts visible 3D meshes and active camera state for downstream GPU submission.
pub const Render3DService = struct {
    allocator: std.mem.Allocator,
    extracted_draws: std.ArrayList(ExtractedMeshDraw),
    active_cameras: usize,

    pub fn init(allocator: std.mem.Allocator) Render3DService {
        return .{
            .allocator = allocator,
            .extracted_draws = .empty,
            .active_cameras = 0,
        };
    }

    pub fn deinit(self: *Render3DService) void {
        self.extracted_draws.deinit(self.allocator);
    }

    pub fn drawCount(self: *const Render3DService) usize {
        return self.extracted_draws.items.len;
    }
};

fn extract3DSystem(ctx: *engine.SystemContext) !void {
    const svc = ctx.resources.get(Render3DService) orelse return;
    svc.extracted_draws.clearRetainingCapacity();
    svc.active_cameras = 0;

    // Count active 3D cameras.
    {
        var cam_q = try ctx.query(.{ .read = .{Camera3D} });
        defer cam_q.deinit();
        while (cam_q.next()) |row| {
            if (row.read(Camera3D).active) {
                svc.active_cameras += 1;
            }
        }
    }

    // Extract mesh instances if at least one active camera exists.
    if (svc.active_cameras == 0) return;

    var mesh_q = try ctx.query(.{ .read = .{ Transform3D, MeshRef } });
    defer mesh_q.deinit();
    while (mesh_q.next()) |row| {
        const t = row.read(Transform3D);
        const m = row.read(MeshRef);
        try svc.extracted_draws.append(svc.allocator, .{
            .entity = row.entity,
            .position = t.position,
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
