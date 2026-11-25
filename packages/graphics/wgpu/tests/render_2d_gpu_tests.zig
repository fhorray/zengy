//! Real-GPU tests for `render/2d` running on the wgpu provider. Each test renders into an offscreen texture
//! and checks the pixels read back from the GPU, so they verify actual output, not just API calls.
extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
fn requireGpu() bool {
    const value = getenv("ZENGY_REQUIRE_GPU") orelse return false;
    return value[0] == '1' and value[1] == 0;
}

const std = @import("std");
const graphics = @import("graphics");
const wgpu_gpu = @import("wgpu_gpu");
const draw_2d = @import("draw_2d");

const gpu = graphics.gpu;
const frame = graphics.frame;

const Fixture = struct {
    allocator: std.mem.Allocator,
    device: *wgpu_gpu.Device,
    g: gpu.GpuDevice,
    r2d: draw_2d.Renderer2D,
    textures: graphics.textures.TextureStore,

    fn init(allocator: std.mem.Allocator) !Fixture {
        const device = wgpu_gpu.Device.initHeadless(allocator) catch |err| {
            if (requireGpu()) return err;
            return error.SkipZigTest;
        };
        errdefer device.deinit();
        return .{ .allocator = allocator, .device = device, .g = device.gpuDevice(), .r2d = try draw_2d.Renderer2D.init(allocator), .textures = graphics.textures.TextureStore.init(allocator) };
    }

    fn deinit(self: *Fixture) void {
        self.r2d.deinit();
        self.textures.deinit(self.g);
        self.device.deinit();
    }

    /// Renders one frame of `commands` into a fresh offscreen target and returns tight RGBA/BGRA bytes.
    fn renderFrame(self: *Fixture, commands: []const graphics.DrawCommand, width: u32, height: u32, dpi: f32, format: gpu.TextureFormat, clear: gpu.ClearColor) ![]u8 {
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
            .target = .{ .width = width, .height = height, .dpi_scale = dpi, .color_format = format },
            .clear = clear,
            .draw_commands = commands,
            .color_target = .{ .view = view },
        };
        try self.r2d.render(&input);
        if (!input.color_target_used) {
            const att = [_]gpu.ColorAttachment{input.colorAttachment()};
            try rec.beginRenderPass(.{ .color_attachments = &att });
            try rec.endRenderPass();
        }
        try rec.finish();
        try self.g.submit(rec.slice());
        return self.readTexture(target, width, height);
    }

    fn readTexture(self: *Fixture, texture: gpu.TextureHandle, width: u32, height: u32) ![]u8 {
        const pitch = gpu.alignedBytesPerRow(width * 4);
        const staging = try self.g.createBuffer(.{ .size = @as(u64, pitch) * height, .usage = .{ .map_read = true, .copy_dst = true } });
        defer self.g.destroyBuffer(staging);
        var rec = gpu.CommandRecorder.init(self.allocator);
        defer rec.deinit();
        try rec.copyTextureToBuffer(.{ .texture = texture }, staging, .{ .bytes_per_row = pitch, .rows_per_image = height }, .{ .width = width, .height = height });
        try self.g.submit(rec.slice());
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

fn near(actual: [4]u8, expected: [4]u8, tolerance: u8) bool {
    for (actual, expected) |a, e| {
        const diff = if (a > e) a - e else e - a;
        if (diff > tolerance) return false;
    }
    return true;
}

fn expectPixel(pixels: []const u8, width: u32, x: u32, y: u32, expected: [4]u8, tolerance: u8) !void {
    const got = px(pixels, width, x, y);
    if (!near(got, expected, tolerance)) {
        std.debug.print("pixel ({d},{d}) = {any}, expected {any} +/-{d}\n", .{ x, y, got, expected, tolerance });
        return error.PixelMismatch;
    }
}

const blue: gpu.ClearColor = .{ .r = 0, .g = 0, .b = 1, .a = 1 };

test "solid rect draws exactly its pixels over the clear color" {
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    const pixels = try f.renderFrame(&.{.{ .rect = .{ .x = 10, .y = 10, .width = 20, .height = 20, .color = .{ .r = 1, .g = 0, .b = 0 } } }}, 64, 64, 1.0, .rgba8_unorm, blue);
    defer std.testing.allocator.free(pixels);
    try expectPixel(pixels, 64, 20, 20, .{ 255, 0, 0, 255 }, 0);
    try expectPixel(pixels, 64, 5, 5, .{ 0, 0, 255, 255 }, 0);
    try expectPixel(pixels, 64, 40, 40, .{ 0, 0, 255, 255 }, 0);
    // Edges: first/last covered pixel and the first uncovered one.
    try expectPixel(pixels, 64, 10, 10, .{ 255, 0, 0, 255 }, 0);
    try expectPixel(pixels, 64, 29, 29, .{ 255, 0, 0, 255 }, 0);
    try expectPixel(pixels, 64, 30, 30, .{ 0, 0, 255, 255 }, 0);
}

test "alpha blending mixes with the background using straight alpha" {
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    const pixels = try f.renderFrame(&.{.{ .rect = .{ .x = 0, .y = 0, .width = 32, .height = 32, .color = .{ .r = 1, .g = 0, .b = 0, .a = 0.5 } } }}, 32, 32, 1.0, .rgba8_unorm, blue);
    defer std.testing.allocator.free(pixels);
    // 0.5 * red + 0.5 * blue.
    try expectPixel(pixels, 32, 16, 16, .{ 128, 0, 128, 255 }, 2);
}

test "clip rectangles restrict drawing and nest by intersection" {
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    const green: graphics.Color = .{ .r = 0, .g = 1, .b = 0 };
    const pixels = try f.renderFrame(&.{
        .{ .clip_push = .{ .x = 0, .y = 0, .width = 40, .height = 40 } },
        .{ .clip_push = .{ .x = 20, .y = 20, .width = 40, .height = 40 } },
        .{ .rect = .{ .x = 0, .y = 0, .width = 64, .height = 64, .color = green } },
        .clip_pop,
        .clip_pop,
    }, 64, 64, 1.0, .rgba8_unorm, blue);
    defer std.testing.allocator.free(pixels);
    try expectPixel(pixels, 64, 30, 30, .{ 0, 255, 0, 255 }, 0); // inside both clips
    try expectPixel(pixels, 64, 10, 10, .{ 0, 0, 255, 255 }, 0); // outside the inner clip
    try expectPixel(pixels, 64, 50, 50, .{ 0, 0, 255, 255 }, 0); // outside the outer clip
}

test "dpi scale maps logical units to physical pixels" {
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    const pixels = try f.renderFrame(&.{.{ .rect = .{ .x = 5, .y = 5, .width = 10, .height = 10, .color = .{ .r = 1, .g = 1, .b = 1 } } }}, 64, 64, 2.0, .rgba8_unorm, blue);
    defer std.testing.allocator.free(pixels);
    try expectPixel(pixels, 64, 25, 25, .{ 255, 255, 255, 255 }, 0); // logical 12 -> physical 24..
    try expectPixel(pixels, 64, 8, 8, .{ 0, 0, 255, 255 }, 0);
    try expectPixel(pixels, 64, 31, 31, .{ 0, 0, 255, 255 }, 0); // physical 10..30 covered, 31 not
}

test "rounded rect cuts its corners but fills the center" {
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    const pixels = try f.renderFrame(&.{.{ .rounded_rect = .{ .x = 8, .y = 8, .width = 48, .height = 48, .color = .{ .r = 1, .g = 1, .b = 0 }, .corner_radii = .{ 16, 16, 16, 16 } } }}, 64, 64, 1.0, .rgba8_unorm, blue);
    defer std.testing.allocator.free(pixels);
    try expectPixel(pixels, 64, 32, 32, .{ 255, 255, 0, 255 }, 0);
    try expectPixel(pixels, 64, 9, 9, .{ 0, 0, 255, 255 }, 8); // outermost corner pixel is outside the arc
    try expectPixel(pixels, 64, 32, 10, .{ 255, 255, 0, 255 }, 8); // straight edge is filled
}

test "text and icons rasterize glyph coverage into the frame" {
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    const white: graphics.Color = .{ .r = 1, .g = 1, .b = 1 };
    const pixels = try f.renderFrame(&.{
        .{ .text = .{ .x = 4, .y = 4, .content = "Hello", .color = white, .scale = 2.0 } },
        .{ .icon = .{ .x = 4, .y = 48, .size = 24, .kind = .check, .color = white } },
    }, 128, 80, 1.0, .rgba8_unorm, .{ .r = 0, .g = 0, .b = 0, .a = 1 });
    defer std.testing.allocator.free(pixels);

    var text_lit: usize = 0;
    var empty_lit: usize = 0;
    var icon_lit: usize = 0;
    for (0..80) |y| for (0..128) |x| {
        const lit = pixels[(y * 128 + x) * 4] > 64;
        if (!lit) continue;
        if (y < 28 and x < 100) text_lit += 1 else if (y >= 44 and x < 40) icon_lit += 1 else empty_lit += 1;
    };
    try std.testing.expect(text_lit > 40); // glyph strokes were drawn
    try std.testing.expect(icon_lit > 10); // the icon was drawn
    try std.testing.expectEqual(@as(usize, 0), empty_lit); // nothing leaked outside the drawn regions
}

test "queued sprite quad samples a user texture with nearest filtering" {
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    // 2x2 texture: red green / blue white.
    const texels = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255 };
    const id = try f.textures.createRgba8(f.g, 2, 2, &texels, false);
    try f.r2d.queueTexturedQuad(.{ .x = 0, .y = 0, .width = 32, .height = 32, .texture = id });
    const pixels = try f.renderFrame(&.{}, 32, 32, 1.0, .rgba8_unorm, .{ .r = 0, .g = 0, .b = 0, .a = 1 });
    defer std.testing.allocator.free(pixels);
    try expectPixel(pixels, 32, 4, 4, .{ 255, 0, 0, 255 }, 0);
    try expectPixel(pixels, 32, 28, 4, .{ 0, 255, 0, 255 }, 0);
    try expectPixel(pixels, 32, 4, 28, .{ 0, 0, 255, 255 }, 0);
    try expectPixel(pixels, 32, 28, 28, .{ 255, 255, 255, 255 }, 0);
}

test "repeated frames are deterministic and reuse GPU resources" {
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    const commands = [_]graphics.DrawCommand{
        .{ .rect = .{ .x = 4, .y = 4, .width = 24, .height = 24, .color = .{ .r = 0.25, .g = 0.5, .b = 0.75 } } },
        .{ .text = .{ .x = 2, .y = 30, .content = "ok", .color = .{ .r = 1, .g = 1, .b = 1 }, .scale = 1.0 } },
    };
    const first = try f.renderFrame(&commands, 48, 48, 1.0, .rgba8_unorm, blue);
    defer std.testing.allocator.free(first);
    for (0..5) |_| {
        const again = try f.renderFrame(&commands, 48, 48, 1.0, .rgba8_unorm, blue);
        defer std.testing.allocator.free(again);
        try std.testing.expectEqualSlices(u8, first, again);
    }
}

test "pipeline follows a target format change without losing textures" {
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    const texels = [_]u8{ 255, 0, 0, 255 };
    const id = try f.textures.createRgba8(f.g, 1, 1, &texels, false);

    try f.r2d.queueTexturedQuad(.{ .x = 0, .y = 0, .width = 16, .height = 16, .texture = id });
    const rgba = try f.renderFrame(&.{}, 16, 16, 1.0, .rgba8_unorm, .{ .r = 0, .g = 0, .b = 0, .a = 1 });
    defer std.testing.allocator.free(rgba);
    try expectPixel(rgba, 16, 8, 8, .{ 255, 0, 0, 255 }, 0);

    // Same texture, BGRA target: memory order is B,G,R,A so red lands in the third byte.
    try f.r2d.queueTexturedQuad(.{ .x = 0, .y = 0, .width = 16, .height = 16, .texture = id });
    const bgra = try f.renderFrame(&.{}, 16, 16, 1.0, .bgra8_unorm, .{ .r = 0, .g = 0, .b = 0, .a = 1 });
    defer std.testing.allocator.free(bgra);
    try expectPixel(bgra, 16, 8, 8, .{ 0, 0, 255, 255 }, 0);
}

test "frame with no commands still clears the target" {
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    const pixels = try f.renderFrame(&.{}, 16, 16, 1.0, .rgba8_unorm, .{ .r = 1, .g = 0, .b = 0, .a = 1 });
    defer std.testing.allocator.free(pixels);
    try expectPixel(pixels, 16, 8, 8, .{ 255, 0, 0, 255 }, 0);
}

test "texture store builds a correct mip chain on the GPU" {
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    // 4x4: left half white, right half black.
    var texels: [4 * 4 * 4]u8 = undefined;
    for (0..4) |y| for (0..4) |x| {
        const v: u8 = if (x < 2) 255 else 0;
        texels[(y * 4 + x) * 4 ..][0..4].* = .{ v, v, v, 255 };
    };
    const id = try f.textures.createRgba8(f.g, 4, 4, &texels, false);
    const entry = f.textures.get(id).?;
    try std.testing.expectEqual(@as(u32, 3), entry.mip_levels);

    const staging = try f.g.createBuffer(.{ .size = 512, .usage = .{ .map_read = true, .copy_dst = true } });
    defer f.g.destroyBuffer(staging);
    var rec = gpu.CommandRecorder.init(std.testing.allocator);
    defer rec.deinit();
    // Level 1 (2x2) lands in rows of 256 bytes; level 2 (1x1) goes to the second half of the buffer.
    try rec.copyTextureToBuffer(.{ .texture = entry.texture, .mip_level = 1 }, staging, .{ .offset = 0, .bytes_per_row = 256, .rows_per_image = 2 }, .{ .width = 2, .height = 2 });
    try rec.finish();
    try f.g.submit(rec.slice());
    var raw: [512]u8 = undefined;
    try f.g.readBufferBlocking(staging, 0, &raw);
    // Level 1: column 0 is white, column 1 is black (box filter of pure halves).
    try std.testing.expectEqual(@as(u8, 255), raw[0]);
    try std.testing.expectEqual(@as(u8, 0), raw[4]);
    try std.testing.expectEqual(@as(u8, 255), raw[256]);
    try std.testing.expectEqual(@as(u8, 0), raw[260]);

    // Level 2 averages the two columns: mid gray.
    const staging2 = try f.g.createBuffer(.{ .size = 256, .usage = .{ .map_read = true, .copy_dst = true } });
    defer f.g.destroyBuffer(staging2);
    var rec2 = gpu.CommandRecorder.init(std.testing.allocator);
    defer rec2.deinit();
    try rec2.copyTextureToBuffer(.{ .texture = entry.texture, .mip_level = 2 }, staging2, .{ .bytes_per_row = 256, .rows_per_image = 1 }, .{ .width = 1, .height = 1 });
    try f.g.submit(rec2.slice());
    var raw2: [256]u8 = undefined;
    try f.g.readBufferBlocking(staging2, 0, &raw2);
    try std.testing.expect(raw2[0] >= 126 and raw2[0] <= 129);
}
