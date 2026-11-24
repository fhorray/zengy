//! Optional 2D Render Extraction Package (`official.render.2d`).
//!
//! Provides `Camera2D`, `Sprite`, and `Visibility` ECS components, plus a
//! `.render_extract` system that projects visible `scene.Transform2D` + `Sprite`
//! entities through the active `Camera2D` into a sorted `Render2DFrame` snapshot
//! ready for GPU batching.

const std = @import("std");
const engine = @import("engine");
const graphics = @import("graphics");
const scene = @import("scene");

pub const MODULE_OWNER_ID: u64 = 2013;
pub const PROVIDER_ID = "official.render.2d";

pub const Camera2D = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    zoom: f32 = 1.0,
    active: bool = true,
};

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
    active_camera: Camera2D = .{},
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

/// Converts world-space `(wx, wy)` to top-left viewport coordinates using `cam`.
pub fn worldToScreen(cam: Camera2D, viewport_w: f32, viewport_h: f32, wx: f32, wy: f32) [2]f32 {
    const zoom = if (cam.zoom > 0.001) cam.zoom else 0.001;
    return .{
        (wx - cam.x) * zoom + viewport_w * 0.5,
        (wy - cam.y) * zoom + viewport_h * 0.5,
    };
}

/// `.render_extract` system: extracts visible sprites and sorts by `(layer, texture_id)`.
pub fn extract2DSystem(ctx: *engine.SystemContext) !void {
    const frame = ctx.resources.get(Render2DFrame) orelse return;
    frame.clear();

    var cam = Camera2D{};
    var cam_q = try ctx.query(.{ .read = .{Camera2D} });
    defer cam_q.deinit();
    while (cam_q.next()) |row| {
        const c = row.read(Camera2D);
        if (c.active) {
            cam = c.*;
            break;
        }
    }
    frame.active_camera = cam;

    const zoom = if (cam.zoom > 0.001) cam.zoom else 0.001;
    var q = try ctx.query(.{ .read = .{ scene.Transform2D, Sprite } });
    defer q.deinit();

    while (q.next()) |row| {
        if (ctx.world.getConst(row.entity, Visibility)) |vis| {
            if (!vis.visible) continue;
        }
        const t = row.read(scene.Transform2D);
        const s = row.read(Sprite);

        const screen_w = s.width * @abs(t.scale_x) * zoom;
        const screen_h = s.height * @abs(t.scale_y) * zoom;
        const center = worldToScreen(cam, frame.viewport_w, frame.viewport_h, t.world_x, t.world_y);

        try frame.items.append(frame.allocator, .{
            .screen_x = center[0] - screen_w * 0.5,
            .screen_y = center[1] - screen_h * 0.5,
            .screen_w = screen_w,
            .screen_h = screen_h,
            .rotation_rad = t.rotation_rad,
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
    _ = try app.registerComponent(Camera2D);
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
            .version = "0.1.0",
            .provides_capabilities = &.{"engine.render.2d/1"},
            .required_capabilities = &.{ "engine.scene.2d/1", "engine.graphics.device/1" },
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
