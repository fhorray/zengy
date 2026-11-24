//! Optional 2D Render Extraction Package (`official.render.2d`).
//!
//! Provides `Sprite` and `Visibility` ECS components, plus a `.render_extract`
//! system that projects visible `scene.Transform2D` + `Sprite` entities through
//! the active `official.camera` (`Camera` + `CameraPose` + `Projection`) into a
//! sorted `Render2DFrame` snapshot ready for GPU batching.

const std = @import("std");
const engine = @import("engine");
const graphics = @import("graphics");
const scene = @import("scene");
const camera = @import("camera");

pub const MODULE_OWNER_ID: u64 = 2013;
pub const PROVIDER_ID = "official.render.2d";

pub const Sprite = struct {
    width: f32 = 64.0,
    height: f32 = 64.0,
    color: graphics.Color = .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 },
    texture_id: u64 = 0,
    uv_min: [2]f32 = .{ 0.0, 0.0 },
    uv_max: [2]f32 = .{ 1.0, 1.0 },
    layer: i32 = 0,
};

pub const Visibility = struct {
    visible: bool = true,
};

pub const ExtractedSprite = struct {
    screen_x: f32,
    screen_y: f32,
    screen_w: f32,
    screen_h: f32,
    rotation_rad: f32,
    color: graphics.Color,
    texture_id: u64,
    uv_min: [2]f32,
    uv_max: [2]f32,
    layer: i32,
};

pub const Render2DFrame = struct {
    allocator: std.mem.Allocator,
    viewport_w: f32 = 1280.0,
    viewport_h: f32 = 720.0,
    cam_x: f32 = 0.0,
    cam_y: f32 = 0.0,
    cam_zoom: f32 = 1.0,
    items: std.ArrayList(ExtractedSprite),

    pub fn init(allocator: std.mem.Allocator) Render2DFrame {
        return .{
            .allocator = allocator,
            .items = .empty,
        };
    }

    pub fn deinit(self: *Render2DFrame) void {
        self.items.deinit(self.allocator);
    }

    pub fn setViewport(self: *Render2DFrame, width: f32, height: f32) void {
        self.viewport_w = if (width > 0.0) width else 1.0;
        self.viewport_h = if (height > 0.0) height else 1.0;
    }

    pub fn clear(self: *Render2DFrame) void {
        self.items.clearRetainingCapacity();
    }
};

fn lessThanSprite(_: void, a: ExtractedSprite, b: ExtractedSprite) bool {
    if (a.layer != b.layer) return a.layer < b.layer;
    return a.texture_id < b.texture_id;
}

/// Converts world-space `(wx, wy)` to top-left viewport coordinates.
pub fn worldToScreen(cam_x: f32, cam_y: f32, zoom_in: f32, viewport_w: f32, viewport_h: f32, wx: f32, wy: f32) [2]f32 {
    const zoom = if (zoom_in > 0.001) zoom_in else 0.001;
    return .{
        (wx - cam_x) * zoom + viewport_w * 0.5,
        (wy - cam_y) * zoom + viewport_h * 0.5,
    };
}

/// `.render_extract` system: extracts visible sprites and sorts by `(layer, texture_id)`.
pub fn extract2DSystem(ctx: *engine.SystemContext) !void {
    const frame = ctx.resources.get(Render2DFrame) orelse return;
    frame.clear();

    var cam_x: f32 = 0.0;
    var cam_y: f32 = 0.0;
    var cam_zoom: f32 = 1.0;

    if (ctx.resources.get(camera.CameraService)) |cam_svc| {
        const active = cam_svc.sortedActiveCameras();
        if (active.len > 0) {
            const cam_ent = active[0].entity;
            if (ctx.world.getConst(cam_ent, camera.CameraPose)) |pose| {
                cam_x = pose.position[0];
                cam_y = pose.position[1];
            }
            if (ctx.world.getConst(cam_ent, camera.Projection)) |proj| {
                if (proj.* == .orthographic and proj.orthographic.scale > 0.001) {
                    cam_zoom = 1.0 / proj.orthographic.scale;
                }
            }
        }
    }
    frame.cam_x = cam_x;
    frame.cam_y = cam_y;
    frame.cam_zoom = cam_zoom;

    const zoom = if (cam_zoom > 0.001) cam_zoom else 0.001;
    var q = try ctx.query(.{
        .read = .{Sprite},
        .optional = .{ scene.incremental.GlobalTransform2D, scene.Transform2D },
    });
    defer q.deinit();

    while (q.next()) |row| {
        if (ctx.world.getConst(row.entity, Visibility)) |vis| {
            if (!vis.visible) continue;
        }
        const s = row.read(Sprite);

        var wx: f32 = 0.0;
        var wy: f32 = 0.0;
        var rot: f32 = 0.0;
        var sx: f32 = 1.0;
        var sy: f32 = 1.0;
        if (row.optional(scene.incremental.GlobalTransform2D)) |gt| {
            const dec = gt.toMat().decompose();
            wx = gt.tx;
            wy = gt.ty;
            rot = dec.rotation_rad;
            sx = dec.scale_x;
            sy = dec.scale_y;
        } else if (row.optional(scene.Transform2D)) |t| {
            wx = t.world_x;
            wy = t.world_y;
            rot = t.rotation_rad;
            sx = t.scale_x;
            sy = t.scale_y;
        } else continue;

        const screen_w = s.width * @abs(sx) * zoom;
        const screen_h = s.height * @abs(sy) * zoom;
        const center = worldToScreen(cam_x, cam_y, zoom, frame.viewport_w, frame.viewport_h, wx, wy);

        try frame.items.append(frame.allocator, .{
            .screen_x = center[0] - screen_w * 0.5,
            .screen_y = center[1] - screen_h * 0.5,
            .screen_w = screen_w,
            .screen_h = screen_h,
            .rotation_rad = rot,
            .color = s.color,
            .texture_id = s.texture_id,
            .uv_min = s.uv_min,
            .uv_max = s.uv_max,
            .layer = s.layer,
        });
    }

    std.mem.sort(ExtractedSprite, frame.items.items, {}, lessThanSprite);
}

fn buildModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    _ = try app.registerComponent(Sprite);
    _ = try app.registerComponent(Visibility);

    try app.resources.insert(Render2DFrame, Render2DFrame.init(app.allocator));
    const frame = app.resources.get(Render2DFrame).?;

    try app.addSystem(.{
        .name = "render2d.extract",
        .stage = .render_extract,
        .run = extract2DSystem,
    });

    try app.services.register(.{
        .capability = "engine.render.2d",
        .major_version = 1,
        .provider_id = PROVIDER_ID,
        .owner_id = MODULE_OWNER_ID,
        .exclusive = true,
        .api_ptr = frame,
        .api_size = @sizeOf(Render2DFrame),
    });
}

fn stopModule(raw_app: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    _ = app.services.unregisterByOwner(MODULE_OWNER_ID);
    _ = app.resources.remove(Render2DFrame);
}

pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = PROVIDER_ID,
            .version = "0.2.0",
            .provides_capabilities = &.{"engine.render.2d/1"},
            .required_capabilities = &.{ "engine.scene.2d/1", "engine.graphics.device/1", "engine.camera/1" },
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
