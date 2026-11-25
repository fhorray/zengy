//! First native wgpu provider for the existing GraphicsDeviceService.
//! Deliberately rejects unported commands instead of silently dropping them.
const std = @import("std");
const engine = @import("engine");
const graphics = @import("graphics");
const window_sdl3 = @import("window_sdl3");

pub const PROVIDER_ID = "official.graphics.wgpu";
pub const MODULE_OWNER_ID: u64 = 2099;
const Native = opaque {};
pub const Vertex2D = extern struct { x: f32, y: f32, r: f32, g: f32, b: f32, a: f32 };
extern fn zwgpu_create(window: *anyopaque, wgsl: [*]const u8, len: usize) ?*Native;
extern fn zwgpu_destroy(gpu: *Native) void;
extern fn zwgpu_draw(gpu: *Native, vertices: [*]const Vertex2D, count: usize, clear: *const [4]f32) c_int;
extern fn zwgpu_logical_size(gpu: *Native, width: *c_int, height: *c_int) void;
extern fn zwgpu_backend(gpu: *Native) [*:0]const u8;
extern fn zwgpu_error() [*:0]const u8;
extern fn zwgpu_rect(out: *[6]Vertex2D, rect: *const [4]f32, clip: *const [4]f32, color: *const [4]f32, width: f32, height: f32) usize;
const State = struct {
    allocator: std.mem.Allocator,
    gpu: *Native,
    service: graphics.GraphicsDeviceService,
    surface: ?graphics.RenderTargetHandle = null,
    triangles: std.ArrayList(Vertex2D) = .empty,
    vertices: std.ArrayList(Vertex2D) = .empty,
    clips: std.ArrayList([4]f32) = .empty,
};
const max_vertices = 64 * 1024 * 1024 / @sizeOf(Vertex2D);
/// Registry handle: the provider keeps State on the heap so `service` and `backend` pointers stay stable.
const StateRef = struct { state: *State };
fn stateOf(raw: *anyopaque) *State { return @ptrCast(@alignCast(raw)); }
fn rgba(color: graphics.Color) [4]f32 { return .{ color.r, color.g, color.b, color.a }; }
fn rectOf(clip: graphics.ClipRect) [4]f32 { return .{ clip.x, clip.y, clip.width, clip.height }; }
fn same(a: graphics.RenderTargetHandle, b: graphics.RenderTargetHandle) bool { return @as(u64,@bitCast(a)) == @as(u64,@bitCast(b)); }
fn nativeError() error{WgpuFailure} {
    std.debug.print("[wgpu] {s}\n", .{std.mem.span(zwgpu_error())});
    return error.WgpuFailure;
}
fn createSurface(raw: *anyopaque, handle: graphics.RenderTargetHandle, window_handle: u64, _: u32, _: u32) !void {
    const state = stateOf(raw);
    if (window_handle == 0 or state.surface != null) return error.WgpuSingleWindowOnly;
    state.surface = handle;
}
fn destroySurface(raw: *anyopaque, handle: graphics.RenderTargetHandle) void {
    const state = stateOf(raw);
    if (state.surface) |current| if (same(handle,current)) {
        state.surface = null;
        state.triangles.clearRetainingCapacity();
    };
}
fn intersect(a: [4]f32, b: [4]f32) [4]f32 {
    for (b) |value| if (!std.math.isFinite(value)) return .{0,0,0,0};
    const x = @max(a[0],b[0]); const y = @max(a[1],b[1]);
    const right = @min(a[0]+a[2],b[0]+@max(b[2],0));
    const bottom = @min(a[1]+a[3],b[1]+@max(b[3],0));
    return .{ x, y, @max(right-x,0), @max(bottom-y,0) };
}
fn appendVertices(state: *State, vertices: []const Vertex2D) !void {
    if (vertices.len > max_vertices - state.vertices.items.len) return error.WgpuVertexBudgetExceeded;
    try state.vertices.appendSlice(state.allocator,vertices);
}
fn present(raw: *anyopaque, handle: graphics.RenderTargetHandle, commands: []const graphics.DrawCommand) !void {
    const state = stateOf(raw);
    if (state.surface == null or !same(handle,state.surface.?)) return error.InvalidSurfaceHandle;
    defer state.triangles.clearRetainingCapacity();
    state.vertices.clearRetainingCapacity(); state.clips.clearRetainingCapacity();
    var w: c_int = 0; var h: c_int = 0;
    zwgpu_logical_size(state.gpu,&w,&h);
    if (w <= 0 or h <= 0) return;
    const width: f32 = @floatFromInt(w); const height: f32 = @floatFromInt(h);
    const viewport = [4]f32{0,0,width,height};
    var clip = viewport;
    var clear = [4]f32{0.07,0.09,0.13,1.0};
    try appendVertices(state,state.triangles.items);
    for (commands) |command| switch (command) {
        .clear => |color| clear = rgba(color),
        .rect => |rect| {
            var output: [6]Vertex2D = undefined;
            const count = zwgpu_rect(&output,&.{rect.x,rect.y,rect.width,rect.height},&clip,&rgba(rect.color),width,height);
            try appendVertices(state,output[0..count]);
        },
        .clip_rect => |value| { clip = if (value) |r| intersect(viewport,rectOf(r)) else viewport; },
        .clip_push => |value| { try state.clips.append(state.allocator,clip); clip = intersect(clip,rectOf(value)); },
        .clip_pop => { clip = state.clips.pop() orelse return error.UnbalancedClipStack; },
        else => return error.WgpuDrawCommandNotPorted,
    };
    if (state.clips.items.len != 0) return error.UnbalancedClipStack;
    const result = zwgpu_draw(state.gpu,state.vertices.items.ptr,state.vertices.items.len,&clear);
    if (result == 0) { state.service.setDeviceAvailable(false); return nativeError(); }
}
const backend: graphics.BackendVTable = .{
    .on_create_surface = createSurface,
    .on_destroy_surface = destroySurface,
    .on_present = present,
};
fn buildModule(raw: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw));
    if (app.resources.get(StateRef) != null) return error.DuplicateWgpuProvider;
    const window = window_sdl3.sdlWindowOpaque(app) orelse return error.MissingWindowBackend;
    const wgsl: []const u8 = @embedFile("shaders/color.wgsl");
    const gpu = zwgpu_create(window,wgsl.ptr,wgsl.len) orelse return nativeError();
    errdefer zwgpu_destroy(gpu);
    const state = try app.allocator.create(State);
    errdefer app.allocator.destroy(state);
    state.* = .{ .allocator = app.allocator, .gpu = gpu, .service = graphics.GraphicsDeviceService.initWithBackend(app.allocator,&backend,state,.{ .compute = false, .depth_texture_sampling = false, .storage_buffers = false, .timestamp_queries = false }) };
    errdefer state.service.deinit();
    try app.resources.insert(StateRef,.{ .state = state });
    errdefer _ = app.resources.remove(StateRef);
    try app.services.register(.{ .capability = "engine.graphics.device", .major_version = 1, .provider_id = PROVIDER_ID, .owner_id = MODULE_OWNER_ID, .exclusive = true, .api_ptr = &state.service, .api_size = @sizeOf(graphics.GraphicsDeviceService) });
    app.scheduler.render_extract_enabled = true;
}
fn stopModule(raw: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw));
    const slot = app.resources.get(StateRef) orelse return;
    const state = slot.state;
    app.scheduler.render_extract_enabled = false;
    _ = app.services.unregisterByOwner(MODULE_OWNER_ID);
    _ = app.resources.remove(StateRef);
    state.triangles.deinit(state.allocator); state.vertices.deinit(state.allocator); state.clips.deinit(state.allocator);
    state.service.deinit(); zwgpu_destroy(state.gpu); app.allocator.destroy(state);
}
pub fn module() engine.Module {
    return .{ .descriptor = .{ .id = PROVIDER_ID, .version = "0.1.0", .provides_capabilities = &.{"engine.graphics.device/1"}, .required_capabilities = &.{"engine.window/1"} }, .build = buildModule, .stop = stopModule };
}
pub fn driverName(app: *engine.App) ?[]const u8 {
    const ref = app.resources.get(StateRef) orelse return null;
    return std.mem.span(zwgpu_backend(ref.state.gpu));
}
pub fn queueTriangle(app: *engine.App, a: Vertex2D, b: Vertex2D, c: Vertex2D, _: bool) !void {
    const slot = app.resources.get(StateRef) orelse return error.MissingWgpuState;
    const state = slot.state;
    for ([_]Vertex2D{a,b,c}) |v| for ([_]f32{v.x,v.y,v.r,v.g,v.b,v.a}) |value| if (!std.math.isFinite(value)) return error.InvalidVertex;
    if (state.triangles.items.len > max_vertices - 3) return error.WgpuVertexBudgetExceeded;
    try state.triangles.appendSlice(state.allocator,&.{a,b,c});
}
