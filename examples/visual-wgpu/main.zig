//! Independent migration smoke example. No SDL_GPU module is registered.
const std = @import("std");
const engine = @import("engine");
const window_sdl3 = @import("window_sdl3");
const graphics = @import("graphics");
const wgpu = @import("graphics_wgpu");
const State = struct { app: *engine.App, gfx: *graphics.GraphicsDeviceService, target: graphics.RenderTargetHandle };
fn render(ctx: *engine.SystemContext) !void {
    const state = ctx.resources.get(State) orelse return;
    try state.gfx.beginFrame(state.target);
    try wgpu.queueTriangle(state.app,
        .{ .x=0,.y=0.55,.r=0.95,.g=0.25,.b=0.3,.a=1 },
        .{ .x=-0.5,.y=-0.45,.r=0.2,.g=0.85,.b=0.45,.a=1 },
        .{ .x=0.5,.y=-0.45,.r=0.25,.g=0.45,.b=0.95,.a=1 },false);
    try state.gfx.submitDrawCommands(state.target,&.{
        .{ .clear=.{ .r=0.07,.g=0.09,.b=0.13 } },
        .{ .clip_push=.{ .x=32,.y=32,.width=140,.height=72 } },
        .{ .rect=.{ .x=48,.y=48,.width=160,.height=72,.color=.{.r=0.18,.g=0.55,.b=0.92,.a=0.85} } },
        .{ .clip_pop={} },
    });
    try state.gfx.present(state.target);
}
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer { if (gpa.deinit()==.leak) std.debug.print("[visual-wgpu] memory leak\n", .{}); }
    var app = engine.App.init(gpa.allocator(),.{});
    defer app.deinit();
    try app.registerModule(window_sdl3.module());
    try app.registerModule(wgpu.module());
    try app.resources.insert(window_sdl3.WindowConfig,.{ .title="Zengy — wgpu smoke", .width=1280,.height=720,.resizable=true,.metal_view=true });
    try app.scheduler.addSystem(.{ .name="visual_wgpu.render", .stage=.render_extract,.run=render });
    try app.initialize();
    const entry = try app.services.getService("engine.graphics.device",1);
    const gfx: *graphics.GraphicsDeviceService = @ptrCast(@alignCast(@constCast(entry.api_ptr)));
    const px = window_sdl3.pixelSize(&app);
    const target = try gfx.createSurface(1,if(px)|p|p.width else 1280,if(px)|p|p.height else 720);
    defer _ = gfx.destroySurface(target);
    try app.resources.insert(State,.{.app=&app,.gfx=gfx,.target=target});
    std.debug.print("[visual-wgpu] driver={s}\n", .{wgpu.driverName(&app) orelse "unknown"});
    try window_sdl3.runVisualLoop(&app);
}
