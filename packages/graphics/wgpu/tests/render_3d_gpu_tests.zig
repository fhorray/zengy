//! Real-GPU tests for the unlit mesh and gizmo renderer (`gpu_3d`). Pixels are read back from an offscreen
//! target, so they verify actual output: culling orientation, texture sampling, depth ordering and gizmo lines.
const std = @import("std");
const graphics = @import("graphics");
const wgpu_gpu = @import("wgpu_gpu");
const gpu_3d = @import("gpu_3d");
const gizmos = @import("gizmos");
const render_3d = @import("render_3d");

const gpu = graphics.gpu;
const frame = graphics.frame;
const math3d = render_3d.math3d;

const Fixture = struct {
    allocator: std.mem.Allocator,
    device: *wgpu_gpu.Device,
    g: gpu.GpuDevice,
    r3d: gpu_3d.Renderer3D,
    textures: graphics.textures.TextureStore,

    fn init(allocator: std.mem.Allocator) !Fixture {
        const device = wgpu_gpu.Device.initHeadless(allocator) catch return error.SkipZigTest;
        return .{ .allocator = allocator, .device = device, .g = device.gpuDevice(), .r3d = gpu_3d.Renderer3D.init(allocator), .textures = graphics.textures.TextureStore.init(allocator) };
    }

    fn deinit(self: *Fixture) void {
        self.r3d.deinit();
        self.textures.deinit(self.g);
        self.device.deinit();
    }

    /// Runs both frame renderers (world, then gizmos) into an offscreen target and returns tight RGBA pixels.
    fn renderFrame(self: *Fixture, width: u32, height: u32) ![]u8 {
        const target = try self.g.createTexture(.{ .width = width, .height = height, .format = .rgba8_unorm, .usage = .{ .render_attachment = true, .copy_src = true } });
        defer self.g.destroyTexture(target);
        const view = try self.g.createTextureView(.{ .texture = target });
        defer self.g.destroyTextureView(view);

        var rec = gpu.CommandRecorder.init(self.allocator);
        defer rec.deinit();
        var input: frame.FrameInput = .{
            .device = self.g,
            .recorder = &rec,
            .textures = &self.textures,
            .target = .{ .width = width, .height = height, .dpi_scale = 1, .color_format = .rgba8_unorm },
            .clear = .{ .r = 0, .g = 0, .b = 0.5, .a = 1 },
            .draw_commands = &.{},
            .color_target = .{ .view = view },
        };
        try self.r3d.worldRenderer().render(self.r3d.worldRenderer().ctx, &input);
        try self.r3d.gizmoRenderer().render(self.r3d.gizmoRenderer().ctx, &input);
        if (!input.color_target_used) {
            const att = [_]gpu.ColorAttachment{input.colorAttachment()};
            try rec.beginRenderPass(.{ .color_attachments = &att });
            try rec.endRenderPass();
        }
        try rec.finish();
        try self.g.submit(rec.slice());

        const pitch = gpu.alignedBytesPerRow(width * 4);
        const staging = try self.g.createBuffer(.{ .size = @as(u64, pitch) * height, .usage = .{ .map_read = true, .copy_dst = true } });
        defer self.g.destroyBuffer(staging);
        var copy = gpu.CommandRecorder.init(self.allocator);
        defer copy.deinit();
        try copy.copyTextureToBuffer(.{ .texture = target }, staging, .{ .bytes_per_row = pitch, .rows_per_image = height }, .{ .width = width, .height = height });
        try self.g.submit(copy.slice());
        const raw = try self.allocator.alloc(u8, @as(usize, pitch) * height);
        defer self.allocator.free(raw);
        try self.g.readBufferBlocking(staging, 0, raw);
        const tight = try self.allocator.alloc(u8, @as(usize, width) * 4 * height);
        for (0..height) |row| @memcpy(tight[row * width * 4 ..][0 .. width * 4], raw[row * pitch ..][0 .. width * 4]);
        return tight;
    }
};

fn px(pixels: []const u8, width: u32, x: u32, y: u32) [4]u8 {
    const i = (@as(usize, y) * width + x) * 4;
    return .{ pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3] };
}

fn near(a: [4]u8, b: [4]u8, tol: u8) bool {
    for (a, b) |x, y| if ((if (x > y) x - y else y - x) > tol) return false;
    return true;
}

fn expect(pixels: []const u8, width: u32, x: u32, y: u32, expected: [4]u8, tol: u8) !void {
    const got = px(pixels, width, x, y);
    if (!near(got, expected, tol)) {
        std.debug.print("pixel ({d},{d}) = {any}, expected {any} +/-{d}\n", .{ x, y, got, expected, tol });
        return error.PixelMismatch;
    }
}

fn viewProj(eye: [3]f32, aspect: f32) math3d.Mat4 {
    const view = math3d.Mat4.lookAt(.{ .x = eye[0], .y = eye[1], .z = eye[2] }, .{ .x = 0, .y = 0, .z = 0 }, .{ .x = 0, .y = 1, .z = 0 });
    const proj = math3d.Mat4.perspective(std.math.pi / 3.0, aspect, 0.1, 50.0);
    return math3d.Mat4.mul(proj, view);
}

test "unlit cube shows its outward faces with the expected shading" {
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    var cube = try render_3d.gltf.createCubeMesh(std.testing.allocator, 1.0);
    defer cube.deinit();
    const mesh = try f.r3d.createMesh(f.g, std.mem.sliceAsBytes(cube.vertices), cube.indices);

    const vp = viewProj(.{ 0, 0, 4 }, 1.0);
    try f.r3d.queueMesh(.{ .mesh = mesh, .mvp = vp.m, .color = .{ 1, 1, 1, 1 } });
    const pixels = try f.renderFrame(128, 128);
    defer std.testing.allocator.free(pixels);

    // Centre is the +Z face: shade = 0.65 + 0.35 * dot(n, L) with L = normalize(0.4, 0.8, 0.5) = 0.827.
    // If back-face culling were inverted we would see the far (-Z) face instead: shade 0.473.
    try expect(pixels, 128, 64, 64, .{ 211, 211, 211, 255 }, 4);
    // Corner is background.
    try expect(pixels, 128, 2, 2, .{ 0, 0, 128, 255 }, 1);
}

test "texture and vertex tint multiply, nearest sampling keeps texels crisp" {
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    var cube = try render_3d.gltf.createCubeMesh(std.testing.allocator, 1.0);
    defer cube.deinit();
    const mesh = try f.r3d.createMesh(f.g, std.mem.sliceAsBytes(cube.vertices), cube.indices);
    // 1x1 pure green texture.
    const tex = try f.textures.createRgba8(f.g, 1, 1, &[_]u8{ 0, 255, 0, 255 }, false);

    const vp = viewProj(.{ 0, 0, 4 }, 1.0);
    try f.r3d.queueMesh(.{ .mesh = mesh, .mvp = vp.m, .color = .{ 1, 0.5, 1, 1 }, .texture = tex });
    const pixels = try f.renderFrame(128, 128);
    defer std.testing.allocator.free(pixels);
    // green * (1, 0.5, 1) * 0.827
    try expect(pixels, 128, 64, 64, .{ 0, 105, 0, 255 }, 4);
}

test "depth buffer orders meshes by distance, not submission order" {
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    var cube = try render_3d.gltf.createCubeMesh(std.testing.allocator, 0.5);
    defer cube.deinit();
    const mesh = try f.r3d.createMesh(f.g, std.mem.sliceAsBytes(cube.vertices), cube.indices);

    const vp = viewProj(.{ 0, 0, 6 }, 1.0);
    const near_model = math3d.Mat4.translation(0, 0, 1.5);
    const far_model = math3d.Mat4.translation(0, 0, -1.5);
    // Draw the far (blue) cube LAST: depth testing must still keep the near (red) one visible.
    try f.r3d.queueMesh(.{ .mesh = mesh, .mvp = math3d.Mat4.mul(vp, near_model).m, .color = .{ 1, 0, 0, 1 } });
    try f.r3d.queueMesh(.{ .mesh = mesh, .mvp = math3d.Mat4.mul(vp, far_model).m, .color = .{ 0, 0, 1, 1 } });
    const pixels = try f.renderFrame(128, 128);
    defer std.testing.allocator.free(pixels);
    const centre = px(pixels, 128, 64, 64);
    try std.testing.expect(centre[0] > 150 and centre[2] < 20);
}

test "many draws reuse one growing uniform buffer" {
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    var cube = try render_3d.gltf.createCubeMesh(std.testing.allocator, 0.05);
    defer cube.deinit();
    const mesh = try f.r3d.createMesh(f.g, std.mem.sliceAsBytes(cube.vertices), cube.indices);
    const vp = viewProj(.{ 0, 0, 6 }, 1.0);
    // 200 draws exceed the initial 64 uniform slots, forcing a reallocation mid-frame.
    for (0..200) |i| {
        const x: f32 = (@as(f32, @floatFromInt(i % 20)) - 9.5) * 0.25;
        const y: f32 = (@as(f32, @floatFromInt(i / 20)) - 4.5) * 0.25;
        try f.r3d.queueMesh(.{ .mesh = mesh, .mvp = math3d.Mat4.mul(vp, math3d.Mat4.translation(x, y, 0)).m, .color = .{ 1, 1, 0, 1 } });
    }
    const pixels = try f.renderFrame(128, 128);
    defer std.testing.allocator.free(pixels);
    var lit: usize = 0;
    for (0..128 * 128) |i| {
        if (pixels[i * 4] > 100 and pixels[i * 4 + 2] < 50) lit += 1;
    }
    try std.testing.expect(lit > 200);
}

test "gizmo lines draw over the scene and respect depth when requested" {
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    const vp = viewProj(.{ 0, 0, 4 }, 1.0);
    const red = [4]f32{ 1, 0, 0, 1 };
    // A horizontal xray line through the middle, thick (> 1.25 px) so the quad expansion runs.
    try f.r3d.stageGizmos(
        .{ .view_proj = vp.m, .line_width = 4.0 },
        &.{},
        &.{ .{ .pos = .{ -1, 0, 0 }, .color = red }, .{ .pos = .{ 1, 0, 0 }, .color = red } },
        &.{},
    );
    const pixels = try f.renderFrame(128, 128);
    defer std.testing.allocator.free(pixels);
    try expect(pixels, 128, 64, 64, .{ 255, 0, 0, 255 }, 2); // on the line
    try expect(pixels, 128, 64, 90, .{ 0, 0, 128, 255 }, 1); // well off the line
}

test "gizmo depth lines are hidden behind a nearer mesh" {
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    var cube = try render_3d.gltf.createCubeMesh(std.testing.allocator, 1.0);
    defer cube.deinit();
    const mesh = try f.r3d.createMesh(f.g, std.mem.sliceAsBytes(cube.vertices), cube.indices);
    const vp = viewProj(.{ 0, 0, 5 }, 1.0);
    try f.r3d.queueMesh(.{ .mesh = mesh, .mvp = vp.m, .color = .{ 0, 1, 0, 1 } });
    const red = [4]f32{ 1, 0, 0, 1 };
    // The line sits at z = -2, behind the cube (front face at z = 1): depth-tested, it must be hidden.
    try f.r3d.stageGizmos(
        .{ .view_proj = vp.m, .line_width = 4.0 },
        &.{ .{ .pos = .{ -0.5, 0, -2 }, .color = red }, .{ .pos = .{ 0.5, 0, -2 }, .color = red } },
        &.{},
        &.{},
    );
    const pixels = try f.renderFrame(128, 128);
    defer std.testing.allocator.free(pixels);
    const centre = px(pixels, 128, 64, 64);
    try std.testing.expect(centre[1] > 150 and centre[0] < 30);
}
