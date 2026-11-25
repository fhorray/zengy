//! 2D draw-command renderer (`official.render.2d.draw`).
//!
//! Executes `graphics.DrawCommand` lists (UI, shapes, text, icons, gradients), clipping and queued sprite
//! quads on top of whatever graphics provider is active. It only needs the neutral `graphics.gpu` contract,
//! so swapping the provider never touches this package. Add `module()` after the graphics provider module.

const std = @import("std");
const engine = @import("engine");
const graphics = @import("graphics");

pub const renderer = @import("renderer.zig");
pub const batcher = @import("batcher.zig");
pub const tessellate = @import("tessellate.zig");

pub const Renderer2D = renderer.Renderer2D;
pub const TextureId = renderer.TextureId;
pub const TexturedQuad = tessellate.TexturedQuad;
pub const ScissorRect = tessellate.ScissorRect;

pub const MODULE_OWNER_ID: u64 = 2014;
pub const PROVIDER_ID = "official.render.2d.draw";

fn graphicsService(app: *engine.App) !*graphics.GraphicsDeviceService {
    const entry = try app.services.getService("engine.graphics.device", 1);
    return @ptrCast(@alignCast(@constCast(entry.api_ptr)));
}

fn buildModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    const service = try graphicsService(app);
    try app.resources.insert(Renderer2D, try Renderer2D.init(app.allocator));
    errdefer _ = app.resources.remove(Renderer2D);
    const r2d = app.resources.get(Renderer2D).?;
    try service.registerRenderer(r2d.frameRenderer());
}

fn stopModule(raw_app: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    if (graphicsService(app)) |service| {
        _ = service.unregisterRenderer("official.render.2d.draw");
    } else |_| {}
    _ = app.resources.remove(Renderer2D);
}

pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = PROVIDER_ID,
            .version = "0.1.0",
            .required_capabilities = &.{"engine.graphics.device/1"},
        },
        .build = buildModule,
        .stop = stopModule,
    };
}

/// The live renderer, for callers that need direct access (text measurement context, diagnostics).
pub fn rendererOf(app: *engine.App) ?*Renderer2D {
    return app.resources.get(Renderer2D);
}

/// Queues a sprite quad given in physical pixels; it draws under the next frame's command list.
pub fn queueTexturedQuad(app: *engine.App, quad: TexturedQuad) !void {
    const r2d = rendererOf(app) orelse return error.Render2DNotRegistered;
    try r2d.queueTexturedQuad(quad);
}

fn createTexture(app: *engine.App, width: u32, height: u32, pixels: []const u8, srgb: bool) !TextureId {
    const r2d = rendererOf(app) orelse return error.Render2DNotRegistered;
    const device = try (try graphicsService(app)).gpuDevice();
    return r2d.createTexture(device, width, height, pixels, srgb);
}

/// Uploads linear RGBA8 pixels; returns an id for `TexturedQuad.texture` (0 is the white texture).
pub fn createTextureRgba8(app: *engine.App, width: u32, height: u32, pixels: []const u8) !TextureId {
    return createTexture(app, width, height, pixels, false);
}

/// Uploads sRGB-encoded RGBA8 pixels; sampling converts to linear like the legacy backend.
pub fn createTextureSrgbRgba8(app: *engine.App, width: u32, height: u32, pixels: []const u8) !TextureId {
    return createTexture(app, width, height, pixels, true);
}

pub fn destroyTexture(app: *engine.App, id: TextureId) void {
    const r2d = rendererOf(app) orelse return;
    const service = graphicsService(app) catch return;
    const device = service.gpuDevice() catch return;
    r2d.destroyTexture(device, id);
}

/// `UiTree.measure_text_fn` implementation. Pass `rendererOf(app)` as the context pointer.
pub fn measureTextWidth(raw_ctx: ?*anyopaque, content: []const u8, scale: f32) f32 {
    const ctx = raw_ctx orelse return @as(f32, @floatFromInt(content.len)) * 4.4 * (if (scale > 0.0) scale else 1.0);
    const r2d: *const Renderer2D = @ptrCast(@alignCast(ctx));
    return r2d.measureTextWidth(content, scale);
}

test {
    _ = batcher;
    _ = tessellate;
}
