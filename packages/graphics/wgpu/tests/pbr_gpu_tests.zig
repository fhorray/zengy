//! Real-GPU tests for the PBR renderer. They drive the `PbrBackendVTable` exactly like the ECS frontend and
//! check pixels read back from an offscreen target.
const std = @import("std");
const graphics = @import("graphics");
const wgpu_gpu = @import("wgpu_gpu");
const gpu_3d = @import("gpu_3d");
const render_3d = @import("render_3d");

const gpu = graphics.gpu;
const frame = graphics.frame;
const pbr = render_3d.pbr;
const math3d = render_3d.math3d;

const Fixture = struct {
    allocator: std.mem.Allocator,
    device: *wgpu_gpu.Device,
    g: gpu.GpuDevice,
    r3d: gpu_3d.Renderer3D,
    renderer: gpu_3d.PbrRenderer,
    textures: graphics.textures.TextureStore,

    fn init(allocator: std.mem.Allocator) !*Fixture {
        const device = wgpu_gpu.Device.initHeadless(allocator) catch return error.SkipZigTest;
        errdefer device.deinit();
        const self = try allocator.create(Fixture);
        self.* = .{
            .allocator = allocator,
            .device = device,
            .g = device.gpuDevice(),
            .r3d = gpu_3d.Renderer3D.init(allocator),
            .renderer = undefined,
            .textures = graphics.textures.TextureStore.init(allocator),
        };
        self.renderer = try gpu_3d.PbrRenderer.init(allocator, &self.r3d);
        return self;
    }

    fn deinit(self: *Fixture) void {
        const allocator = self.allocator;
        self.renderer.deinit();
        self.r3d.deinit();
        self.textures.deinit(self.g);
        self.device.deinit();
        allocator.destroy(self);
    }

    /// Runs the PBR frame renderer into an offscreen target and returns tight RGBA pixels.
    fn renderFrame(self: *Fixture, width: u32, height: u32, format: gpu.TextureFormat) ![]u8 {
        const target = try self.g.createTexture(.{ .width = width, .height = height, .format = format, .usage = .{ .render_attachment = true, .copy_src = true } });
        defer self.g.destroyTexture(target);
        const view = try self.g.createTextureView(.{ .texture = target });
        defer self.g.destroyTextureView(view);

        var rec = gpu.CommandRecorder.init(self.allocator);
        defer rec.deinit();
        var input: frame.FrameInput = .{
            .device = self.g,
            .recorder = &rec,
            .textures = &self.textures,
            .target = .{ .width = width, .height = height, .dpi_scale = 1, .color_format = format },
            .clear = .{ .r = 1, .g = 0, .b = 1, .a = 1 },
            .draw_commands = &.{},
            .color_target = .{ .view = view },
        };
        const r = self.renderer.frameRenderer();
        try r.render(r.ctx, &input);
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

fn luma(p: [4]u8) f32 {
    return 0.2126 * @as(f32, @floatFromInt(p[0])) + 0.7152 * @as(f32, @floatFromInt(p[1])) + 0.0722 * @as(f32, @floatFromInt(p[2]));
}

fn sceneFrame(eye: [3]f32, aspect: f32) pbr.ExtractedPbrFrame {
    const view = math3d.Mat4.lookAt(.{ .x = eye[0], .y = eye[1], .z = eye[2] }, .{ .x = 0, .y = 0, .z = 0 }, .{ .x = 0, .y = 1, .z = 0 });
    const proj = math3d.Mat4.perspective(std.math.pi / 3.0, aspect, 0.1, 100.0);
    var f: pbr.ExtractedPbrFrame = .{};
    f.camera_position = eye;
    const fwd = math3d.Vec3.normalize(.{ .x = -eye[0], .y = -eye[1], .z = -eye[2] });
    f.camera_forward = .{ fwd.x, fwd.y, fwd.z };
    f.view_matrix = view.m;
    f.proj_matrix = proj.m;
    f.view_proj = math3d.Mat4.mul(proj, view).m;
    return f;
}

const sun = [_]pbr.ExtractedDirectionalLight{.{
    .direction = .{ -0.3, -1.0, -0.2 },
    .color = .{ 1, 1, 1 },
    .illuminance_lux = 10_000,
    .shadows_enabled = false,
    .shadow_depth_bias = 0.005,
    .shadow_normal_bias = 0.05,
    .cascade_count = 4,
}};

test "lit cube: sun-facing top is brighter than the side and the sky shows behind it" {
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    var cube = try render_3d.gltf.createCubeMesh(std.testing.allocator, 1.0);
    defer cube.deinit();
    const mesh = try f.r3d.createMesh(f.g, std.mem.sliceAsBytes(cube.vertices), cube.indices);

    var data = sceneFrame(.{ 0, 3.5, 5.0 }, 1.0);
    data.directional_lights = &sun;
    data.post_process.bloom.enabled = false;
    data.post_process.tonemap_mode = .neutral;

    const backend = f.renderer.vtable();
    try backend.beginPbrFrame(backend.ctx, &data);
    const model = math3d.Mat4.identity();
    try backend.submitLitMesh(backend.ctx, @bitCast(mesh), model.m, data.view_proj, .{ .base_color = .{ 0.8, 0.8, 0.8, 1 }, .roughness = 0.6 }, .{ 1, 1, 1, 1 });

    const pixels = try f.renderFrame(160, 160, .rgba8_unorm);
    defer std.testing.allocator.free(pixels);

    // Sky pixel in a corner: the procedural sky, not the magenta clear color and not black.
    const sky = px(pixels, 160, 4, 4);
    try std.testing.expect(!(sky[0] > 200 and sky[1] < 50 and sky[2] > 200));
    try std.testing.expect(luma(sky) > 8);

    // Find the cube: top face above, front face below the same column through the image centre.
    const top = px(pixels, 160, 80, 64);
    const front = px(pixels, 160, 80, 100);
    std.debug.print("\n[pbr] sky={any} top={any} front={any}\n", .{ sky, top, front });
    try std.testing.expect(luma(top) > luma(front)); // the sun comes from above
    try std.testing.expect(luma(top) > luma(sky) * 0.5);
}

test "pbr frame with no meshes still produces a sky and does not leak state across frames" {
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    var data = sceneFrame(.{ 0, 1, 5 }, 1.0);
    data.post_process.bloom.enabled = false;
    for (0..3) |_| {
        const backend = f.renderer.vtable();
        try backend.beginPbrFrame(backend.ctx, &data);
        const pixels = try f.renderFrame(64, 64, .rgba8_unorm);
        defer std.testing.allocator.free(pixels);
        const p = px(pixels, 64, 32, 10);
        try std.testing.expect(luma(p) > 5);
        try std.testing.expectEqual(@as(u8, 255), p[3]);
    }
}
