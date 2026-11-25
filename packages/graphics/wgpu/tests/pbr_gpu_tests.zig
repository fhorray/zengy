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

fn readExposure(f: *Fixture) !f32 {
    const image = f.renderer.gpu.?.exposure;
    const staging = try f.g.createBuffer(.{ .size = 256, .usage = .{ .map_read = true, .copy_dst = true } });
    defer f.g.destroyBuffer(staging);
    var rec = gpu.CommandRecorder.init(f.allocator);
    defer rec.deinit();
    try rec.copyTextureToBuffer(.{ .texture = image.texture }, staging, .{ .bytes_per_row = 256, .rows_per_image = 1 }, .{ .width = 1, .height = 1 });
    try f.g.submit(rec.slice());
    var raw: [256]u8 = undefined;
    try f.g.readBufferBlocking(staging, 0, &raw);
    return @bitCast(raw[0..4].*);
}

test "auto exposure stores a higher EV100 for a brighter scene" {
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    const backend = f.renderer.vtable();

    var dim = sceneFrame(.{ 0, 1, 5 }, 1.0);
    dim.post_process.auto_exposure.enabled = true;
    dim.post_process.auto_exposure.speed_brighten = 100;
    dim.post_process.auto_exposure.speed_darken = 100;
    dim.post_process.bloom.enabled = false;
    dim.sky.kind = .solid_color;
    dim.sky.solid_color = .{ 0.02, 0.02, 0.02 };
    dim.dt = 0.1;
    var bright = dim;
    bright.sky.solid_color = .{ 8.0, 8.0, 8.0 };

    var dim_ev: f32 = 0;
    for (0..8) |_| {
        try backend.beginPbrFrame(backend.ctx, &dim);
        const px_ = try f.renderFrame(64, 64, .rgba8_unorm);
        std.testing.allocator.free(px_);
        dim_ev = try readExposure(f);
    }
    var bright_ev: f32 = 0;
    for (0..8) |_| {
        try backend.beginPbrFrame(backend.ctx, &bright);
        const px_ = try f.renderFrame(64, 64, .rgba8_unorm);
        std.testing.allocator.free(px_);
        bright_ev = try readExposure(f);
    }
    std.debug.print("\n[pbr] exposure dim={d:.3} bright={d:.3}\n", .{ dim_ev, bright_ev });
    try std.testing.expect(std.math.isFinite(dim_ev) and std.math.isFinite(bright_ev));
    try std.testing.expect(dim_ev != bright_ev);
    // The texture holds the metered EV100: a brighter scene meters a higher value (the composite then applies less gain).
    try std.testing.expect(bright_ev > dim_ev + 3.0);
    // Both stay inside the configured bounds (-4..8 by default).
    try std.testing.expect(dim_ev >= -4.0 and bright_ev <= 8.0);
}

fn fogScene(fog_on: bool, temporal: bool, froxel: bool) pbr.ExtractedPbrFrame {
    var data = sceneFrame(.{ 0, 1, 5 }, 1.0);
    data.directional_lights = &sun;
    data.post_process.bloom.enabled = false;
    data.fog.enabled = fog_on;
    data.fog.density = 0.08;
    data.fog.color = .{ 0.6, 0.65, 0.7 };
    data.fog.volumetric.enabled = fog_on;
    data.fog.volumetric.temporal = temporal;
    data.fog.volumetric.froxel_enabled = froxel;
    return data;
}

test "volumetric fog changes the scene for ray march, temporal resolve and froxels" {
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    const backend = f.renderer.vtable();

    var base = fogScene(false, false, false);
    try backend.beginPbrFrame(backend.ctx, &base);
    const clear = try f.renderFrame(96, 96, .rgba8_unorm);
    defer std.testing.allocator.free(clear);

    const modes = [_][2]bool{ .{ false, false }, .{ true, false }, .{ true, true } };
    for (modes) |m| {
        var data = fogScene(true, m[0], m[1]);
        var last: []u8 = &.{};
        defer if (last.len != 0) std.testing.allocator.free(last);
        // Several frames so the temporal history is exercised (valid history path, ping-pong).
        for (0..4) |_| {
            if (last.len != 0) std.testing.allocator.free(last);
            try backend.beginPbrFrame(backend.ctx, &data);
            last = try f.renderFrame(96, 96, .rgba8_unorm);
        }
        var changed: usize = 0;
        var i: usize = 0;
        while (i < last.len) : (i += 4) {
            const a = clear[i .. i + 3];
            const b = last[i .. i + 3];
            if (!std.mem.eql(u8, a, b)) changed += 1;
            // Never NaN-black or blown out to the clear colour.
            try std.testing.expect(!(b[0] > 250 and b[1] < 5 and b[2] > 250));
        }
        std.debug.print("\n[pbr] fog temporal={} froxel={} changed={d}/{d}\n", .{ m[0], m[1], changed, last.len / 4 });
        try std.testing.expect(changed > last.len / 4 / 4);
    }
}

test "screen transport traces the Hi-Z pyramid and changes indirect lighting" {
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    const limits = f.g.capabilities().limits;
    if (limits.max_color_attachments < 4 or limits.max_color_attachment_bytes_per_sample < 40) return error.SkipZigTest;
    var cube = try render_3d.gltf.createCubeMesh(std.testing.allocator, 1.0);
    defer cube.deinit();
    const mesh = try f.r3d.createMesh(f.g, std.mem.sliceAsBytes(cube.vertices), cube.indices);
    const backend = f.renderer.vtable();
    // A smooth floor and a bright box above it: the floor has something to reflect and to receive bounce from.
    const floor_model = math3d.Mat4.mul(math3d.Mat4.translation(0, -0.5, 0), math3d.Mat4.scale(8, 0.1, 8));
    const box_model = math3d.Mat4.translation(0, 0.4, 0);

    var off = sceneFrame(.{ 0, 2.5, 5.0 }, 1.0);
    off.directional_lights = &sun;
    off.post_process.bloom.enabled = false;
    var on = off;
    on.post_process.quality.screen_transport = .{ .ssr_strength = 1.0, .ssgi_strength = 0.6 };

    var results: [2][]u8 = undefined;
    for ([_]*const pbr.ExtractedPbrFrame{ &off, &on }, 0..) |data, i| {
        try backend.beginPbrFrame(backend.ctx, data);
        const floor_mvp = math3d.Mat4.mul(math3d.Mat4{ .m = data.view_proj }, floor_model);
        const box_mvp = math3d.Mat4.mul(math3d.Mat4{ .m = data.view_proj }, box_model);
        try backend.submitLitMesh(backend.ctx, @bitCast(mesh), floor_model.m, floor_mvp.m, .{ .base_color = .{ 0.8, 0.8, 0.8, 1 }, .roughness = 0.05 }, .{ 1, 1, 1, 1 });
        try backend.submitLitMesh(backend.ctx, @bitCast(mesh), box_model.m, box_mvp.m, .{ .base_color = .{ 0.9, 0.2, 0.1, 1 }, .roughness = 0.6, .emissive = .{ 2, 0.4, 0.2, 1 } }, .{ 1, 1, 1, 1 });
        results[i] = try f.renderFrame(96, 96, .rgba8_unorm);
    }
    defer for (results) |r| std.testing.allocator.free(r);
    try std.testing.expect(f.renderer.screen != null);
    var differing: usize = 0;
    var i: usize = 0;
    while (i < results[0].len) : (i += 4) {
        if (!std.mem.eql(u8, results[0][i .. i + 3], results[1][i .. i + 3])) differing += 1;
    }
    std.debug.print("\n[pbr] screen transport: {d}/{d} pixels differ\n", .{ differing, results[0].len / 4 });
    // The smooth floor reflects the box, so a visible share of pixels must change, and the frame must stay plausible.
    try std.testing.expect(differing > 200);
    try std.testing.expect(luma(px(results[1], 96, 48, 48)) > 5);
}
