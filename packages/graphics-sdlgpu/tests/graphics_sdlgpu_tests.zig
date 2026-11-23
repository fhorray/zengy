//! Unit Tests for `graphics-sdlgpu` (`packages/graphics-sdlgpu/tests/graphics_sdlgpu_tests.zig`).
//!
//! Validates pure-Zig GPU resource handle pools, vertex/uniform layouts,
//! rectangle triangulation, and `GraphicsDeviceService` `BackendVTable` delegation
//! without requiring a live GPU or display server.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const graphics = @import("graphics");
const gpu_resources = @import("gpu_resources");

test "GenerationalPool handles reuse slots safely and reject stale handles" {
    var pool = gpu_resources.GenerationalPool(u32, gpu_resources.GpuBufferHandle).init(testing.allocator);
    defer pool.deinit();

    const h1 = try pool.insert(100);
    const h2 = try pool.insert(200);
    try testing.expectEqual(@as(usize, 2), pool.aliveCount());
    try testing.expectEqual(@as(?u32, 100), pool.get(h1));
    try testing.expectEqual(@as(?u32, 200), pool.get(h2));

    try testing.expectEqual(@as(?u32, 100), pool.remove(h1));
    try testing.expectEqual(@as(?u32, null), pool.get(h1));
    try testing.expectEqual(@as(usize, 1), pool.aliveCount());

    const h3 = try pool.insert(300);
    try testing.expectEqual(h1.index, h3.index);
    try testing.expect(h1.generation != h3.generation);
    try testing.expectEqual(@as(?u32, null), pool.get(h1));
    try testing.expectEqual(@as(?u32, 300), pool.get(h3));
}

test "Vertex2D and FrameUniforms layouts match shader expectations" {
    try testing.expectEqual(@as(usize, 24), @sizeOf(gpu_resources.Vertex2D));
    try testing.expectEqual(@as(usize, 16), @sizeOf(gpu_resources.FrameUniforms));
}

test "appendRectVertices emits 6 vertices with expected bounds and color" {
    var list: std.ArrayList(gpu_resources.Vertex2D) = .empty;
    defer list.deinit(testing.allocator);

    try gpu_resources.appendRectVertices(&list, testing.allocator, 10.0, 20.0, 100.0, 50.0, .{
        .r = 0.25,
        .g = 0.5,
        .b = 0.75,
        .a = 1.0,
    });

    try testing.expectEqual(@as(usize, 6), list.items.len);
    try testing.expectEqual(@as(f32, 10.0), list.items[0].x);
    try testing.expectEqual(@as(f32, 20.0), list.items[0].y);
    try testing.expectEqual(@as(f32, 110.0), list.items[2].x);
    try testing.expectEqual(@as(f32, 70.0), list.items[2].y);
    try testing.expectEqual(@as(f32, 0.75), list.items[4].b);
}

test "GraphicsDeviceService delegates lifecycle and DrawCommands to BackendVTable" {
    const MockBackend = struct {
        created: usize = 0,
        resized_w: u32 = 0,
        resized_h: u32 = 0,
        presented: usize = 0,
        last_cmd_count: usize = 0,
        destroyed: usize = 0,

        fn onCreate(ctx: *anyopaque, _: graphics.RenderTargetHandle, _: u64, _: u32, _: u32) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.created += 1;
        }
        fn onResize(ctx: *anyopaque, _: graphics.RenderTargetHandle, w: u32, h: u32) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.resized_w = w;
            self.resized_h = h;
        }
        fn onDestroy(ctx: *anyopaque, _: graphics.RenderTargetHandle) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.destroyed += 1;
        }
        fn onPresent(ctx: *anyopaque, _: graphics.RenderTargetHandle, cmds: []const graphics.DrawCommand) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.presented += 1;
            self.last_cmd_count = cmds.len;
        }
    };

    var mock = MockBackend{};
    const vtable = graphics.BackendVTable{
        .on_create_surface = MockBackend.onCreate,
        .on_resize_surface = MockBackend.onResize,
        .on_destroy_surface = MockBackend.onDestroy,
        .on_present = MockBackend.onPresent,
    };

    var svc = graphics.GraphicsDeviceService.initWithBackend(testing.allocator, &vtable, &mock, .{});
    defer svc.deinit();

    const rt = try svc.createSurface(1, 800, 600);
    try testing.expectEqual(@as(usize, 1), mock.created);

    try testing.expect(svc.resizeSurface(rt, 1920, 1080));
    try testing.expectEqual(@as(u32, 1920), mock.resized_w);
    try testing.expectEqual(@as(u32, 1080), mock.resized_h);

    try svc.beginFrame(rt);
    try svc.submitDrawCommands(rt, &.{
        .{ .clear = .{ .r = 0.1, .g = 0.1, .b = 0.1 } },
        .{ .rect = .{ .x = 0, .y = 0, .width = 50, .height = 50, .color = .{ .r = 1, .g = 0, .b = 0 } } },
    });
    try svc.present(rt);

    try testing.expectEqual(@as(usize, 1), mock.presented);
    try testing.expectEqual(@as(usize, 2), mock.last_cmd_count);
    try testing.expectEqual(@as(?u64, 1), svc.presentedFrames(rt));

    try testing.expect(svc.destroySurface(rt));
    try testing.expectEqual(@as(usize, 1), mock.destroyed);
}
