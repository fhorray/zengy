//! GPU renderer for unlit 3D meshes and gizmos (`official.render.3d.gpu`).
//!
//! Draws meshes queued by the application and the lines/triangles produced by `official.gizmos`, using only the
//! neutral `graphics.gpu` contract. Register `module()` after the graphics provider (and after
//! `official.gizmos` if gizmos are used).

const std = @import("std");
const engine = @import("engine");
const graphics = @import("graphics");
const gizmos = @import("gizmos");

pub const renderer = @import("renderer.zig");
pub const Renderer3D = renderer.Renderer3D;
pub const MeshHandle = renderer.MeshHandle;

pub const MODULE_OWNER_ID: u64 = 2015;
pub const PROVIDER_ID = "official.render.3d.gpu";

fn graphicsService(app: *engine.App) !*graphics.GraphicsDeviceService {
    const entry = try app.services.getService("engine.graphics.device", 1);
    return @ptrCast(@alignCast(@constCast(entry.api_ptr)));
}

fn submitGizmos(
    ctx: *anyopaque,
    params: gizmos.GizmoSubmitParams,
    depth_lines: []const gizmos.GizmoVertex,
    xray_lines: []const gizmos.GizmoVertex,
    solid_tris: []const gizmos.GizmoVertex,
) anyerror!void {
    const r3d: *Renderer3D = @ptrCast(@alignCast(ctx));
    try r3d.stageGizmos(params, depth_lines, xray_lines, solid_tris);
}

fn buildModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    const service = try graphicsService(app);
    try app.resources.insert(Renderer3D, Renderer3D.init(app.allocator));
    errdefer _ = app.resources.remove(Renderer3D);
    const r3d = app.resources.get(Renderer3D).?;
    try service.registerRenderer(r3d.worldRenderer());
    errdefer _ = service.unregisterRenderer("official.render.3d.gpu.world");
    try service.registerRenderer(r3d.gizmoRenderer());
}

/// Hooks optional producers once every module is built.
fn startModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    const r3d = app.resources.get(Renderer3D) orelse return;
    if (app.resources.get(gizmos.GizmoService)) |giz| {
        giz.setBackend(.{ .ctx = r3d, .submitGizmos = submitGizmos });
    }
}

fn stopModule(raw_app: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    if (app.resources.get(gizmos.GizmoService)) |giz| giz.setBackend(null);
    if (graphicsService(app)) |service| {
        _ = service.unregisterRenderer("official.render.3d.gpu.world");
        _ = service.unregisterRenderer("official.render.3d.gpu.gizmos");
    } else |_| {}
    _ = app.resources.remove(Renderer3D);
}

pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = PROVIDER_ID,
            .version = "0.1.0",
            .required_capabilities = &.{"engine.graphics.device/1"},
        },
        .build = buildModule,
        .start = startModule,
        .stop = stopModule,
    };
}

pub fn rendererOf(app: *engine.App) ?*Renderer3D {
    return app.resources.get(Renderer3D);
}

/// Uploads a mesh: 32-byte vertices (position, normal, uv) and u32 indices.
pub fn createMesh3D(app: *engine.App, vertex_bytes: []const u8, indices: []const u32) !MeshHandle {
    const r3d = rendererOf(app) orelse return error.Render3DNotRegistered;
    return r3d.createMesh(try (try graphicsService(app)).gpuDevice(), vertex_bytes, indices);
}

pub fn destroyMesh3D(app: *engine.App, handle: MeshHandle) void {
    const r3d = rendererOf(app) orelse return;
    const service = graphicsService(app) catch return;
    r3d.destroyMesh(service.gpuDevice() catch return, handle);
}

/// Queues a mesh for the next presented frame, drawn with depth testing. `texture == null` uses white.
pub fn queueMeshDraw(app: *engine.App, mesh: MeshHandle, mvp: [16]f32, color: [4]f32, texture: ?graphics.TextureId) !void {
    const r3d = rendererOf(app) orelse return error.Render3DNotRegistered;
    try r3d.queueMesh(.{ .mesh = mesh, .mvp = mvp, .color = color, .texture = texture orelse 0 });
}

test "public API compiles" {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(renderer);
}
