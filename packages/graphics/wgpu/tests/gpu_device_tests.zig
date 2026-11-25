//! Real-GPU conformance tests for the wgpu implementation of `graphics.gpu.GpuDevice`.
//!
//! These tests open a headless wgpu device and verify results by reading pixels and buffers back from the
//! GPU. They are NOT part of the default `zig build test` (which must run without a GPU): run them with
//! `zig build test-wgpu-gpu -Dwgpu-root=<sdk>`. When no adapter exists the tests are skipped.
extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
fn requireGpu() bool {
    const value = getenv("ZENGY_REQUIRE_GPU") orelse return false;
    return value[0] == '1' and value[1] == 0;
}

const std = @import("std");
const graphics = @import("graphics");
const wgpu_gpu = @import("wgpu_gpu");
const gpu = graphics.gpu;

const Harness = struct {
    allocator: std.mem.Allocator,
    device: *wgpu_gpu.Device,
    g: gpu.GpuDevice,

    fn init(allocator: std.mem.Allocator) !Harness {
        const device = wgpu_gpu.Device.initHeadless(allocator) catch |err| {
            if (requireGpu()) return err;
            return error.SkipZigTest;
        };
        return .{ .allocator = allocator, .device = device, .g = device.gpuDevice() };
    }

    fn deinit(self: *Harness) void {
        self.device.deinit();
    }

    /// Copies a texture to a mappable buffer (honoring the 256-byte row pitch) and returns tight rows.
    fn readTexture(self: *Harness, texture: gpu.TextureHandle, width: u32, height: u32, bytes_per_texel: u32) ![]u8 {
        const pitch = gpu.alignedBytesPerRow(width * bytes_per_texel);
        const staging = try self.g.createBuffer(.{ .size = @as(u64, pitch) * height, .usage = .{ .map_read = true, .copy_dst = true } });
        defer self.g.destroyBuffer(staging);

        var rec = gpu.CommandRecorder.init(self.allocator);
        defer rec.deinit();
        try rec.copyTextureToBuffer(.{ .texture = texture }, staging, .{ .bytes_per_row = pitch, .rows_per_image = height }, .{ .width = width, .height = height });
        try rec.finish();
        try self.g.submit(rec.slice());

        const raw = try self.allocator.alloc(u8, @as(usize, pitch) * height);
        defer self.allocator.free(raw);
        try self.g.readBufferBlocking(staging, 0, raw);

        const tight = try self.allocator.alloc(u8, @as(usize, width) * bytes_per_texel * height);
        for (0..height) |row| {
            const src = raw[row * pitch ..][0 .. width * bytes_per_texel];
            @memcpy(tight[row * width * bytes_per_texel ..][0 .. width * bytes_per_texel], src);
        }
        return tight;
    }
};

fn pixel(pixels: []const u8, width: u32, x: u32, y: u32) [4]u8 {
    const i = (@as(usize, y) * width + x) * 4;
    return .{ pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3] };
}

test "cancelled readback is idempotent and permits reuse" {
    var h = try Harness.init(std.testing.allocator);
    defer h.deinit();
    // Queue writes only reach a buffer when work is submitted, so the data travels through a copy.
    const source_buffer = try h.g.createBuffer(.{ .size = 16, .usage = .{ .copy_src = true, .copy_dst = true } });
    defer h.g.destroyBuffer(source_buffer);
    const buffer = try h.g.createBuffer(.{ .size = 16, .usage = .{ .map_read = true, .copy_dst = true } });
    defer h.g.destroyBuffer(buffer);
    const source: [16]u8 = @splat(7);
    try h.g.writeBuffer(source_buffer, 0, &source);
    var rec = gpu.CommandRecorder.init(std.testing.allocator);
    defer rec.deinit();
    try rec.copyBufferToBuffer(source_buffer, 0, buffer, 0, 16);
    try h.g.submit(rec.slice());

    const ticket = try h.g.beginReadback(buffer, 0, 16);
    h.g.cancelReadback(ticket);
    h.g.cancelReadback(ticket);
    var result: [16]u8 = undefined;
    try std.testing.expectError(error.InvalidHandle, h.g.pollReadback(ticket, &result));
    try h.g.readBufferBlocking(buffer, 0, &result);
    try std.testing.expectEqualSlices(u8, &source, &result);
}

test "device shutdown cancels an unconsumed readback" {
    var h = try Harness.init(std.testing.allocator);
    defer h.deinit();
    const buffer = try h.g.createBuffer(.{ .size = 16, .usage = .{ .map_read = true, .copy_dst = true } });
    _ = try h.g.beginReadback(buffer, 0, 16);
}

test "capabilities are detected from the real adapter" {
    var h = try Harness.init(std.testing.allocator);
    defer h.deinit();
    const caps = h.g.capabilities();

    std.debug.print("\n[gpu] adapter='{s}' backend={s} type={s} timestamps={} ray_query={} accel={}\n", .{
        caps.info.name(),
        @tagName(caps.info.backend),
        @tagName(caps.info.adapter_type),
        caps.features.timestamp_query,
        caps.features.ray_query,
        caps.acceleration_structures,
    });
    try std.testing.expect(caps.info.name().len > 0);
    try std.testing.expect(caps.info.backend != .unknown);
    try std.testing.expect(caps.limits.max_texture_dimension_2d >= 2048);
    try std.testing.expect(caps.limits.max_bind_groups >= 4);
    try std.testing.expect(caps.limits.max_buffer_size >= 256 * 1024 * 1024);
    try std.testing.expect(caps.supportsCompute());
    // The pinned wgpu-native has no BLAS/TLAS API: never advertise it.
    try std.testing.expect(!caps.acceleration_structures);
}

test "buffer write and blocking readback round trip" {
    var h = try Harness.init(std.testing.allocator);
    defer h.deinit();

    const source = try h.g.createBuffer(.{ .size = 256, .usage = .{ .copy_src = true, .copy_dst = true } });
    const staging = try h.g.createBuffer(.{ .size = 256, .usage = .{ .map_read = true, .copy_dst = true } });

    var data: [256]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast((i * 7 + 3) & 0xff);
    try h.g.writeBuffer(source, 0, &data);

    var rec = gpu.CommandRecorder.init(std.testing.allocator);
    defer rec.deinit();
    try rec.copyBufferToBuffer(source, 0, staging, 0, 256);
    try h.g.submit(rec.slice());

    var out: [256]u8 = undefined;
    try h.g.readBufferBlocking(staging, 0, &out);
    try std.testing.expectEqualSlices(u8, &data, &out);

    // Stale handles fail cleanly instead of touching freed native memory.
    h.g.destroyBuffer(source);
    try std.testing.expectError(error.InvalidHandle, h.g.writeBuffer(source, 0, &data));
    h.g.destroyBuffer(source); // double destroy is a no-op
    h.g.destroyBuffer(staging);
}

test "asynchronous readback reports pending then completes" {
    var h = try Harness.init(std.testing.allocator);
    defer h.deinit();

    const buffer = try h.g.createBuffer(.{ .size = 64, .usage = .{ .map_read = true, .copy_dst = true } });
    defer h.g.destroyBuffer(buffer);

    const ticket = try h.g.beginReadback(buffer, 0, 64);
    var out: [64]u8 = undefined;
    var attempts: u32 = 0;
    while (!try h.g.pollReadback(ticket, &out)) : (attempts += 1) {
        try std.testing.expect(attempts < 100_000);
        h.g.poll(false);
    }
    // A completed ticket is consumed.
    try std.testing.expectError(error.InvalidHandle, h.g.pollReadback(ticket, &out));
}

test "buffer validation rejects bad requests without failing the device" {
    var h = try Harness.init(std.testing.allocator);
    defer h.deinit();

    try std.testing.expectError(error.InvalidDescriptor, h.g.createBuffer(.{ .size = 0, .usage = .{ .copy_dst = true } }));
    try std.testing.expectError(error.MissingUsage, h.g.createBuffer(.{ .size = 16, .usage = .{} }));

    const buffer = try h.g.createBuffer(.{ .size = 16, .usage = .{ .copy_dst = true } });
    defer h.g.destroyBuffer(buffer);
    try std.testing.expectError(error.Unaligned, h.g.writeBuffer(buffer, 1, &[_]u8{ 1, 2, 3, 4 }));
    try std.testing.expectError(error.OutOfBounds, h.g.writeBuffer(buffer, 8, &@as([16]u8, @splat(0))));

    const no_dst = try h.g.createBuffer(.{ .size = 16, .usage = .{ .copy_src = true } });
    defer h.g.destroyBuffer(no_dst);
    try std.testing.expectError(error.MissingUsage, h.g.writeBuffer(no_dst, 0, &[_]u8{ 1, 2, 3, 4 }));
}

test "invalid WGSL is reported as a validation error and the device stays usable" {
    var h = try Harness.init(std.testing.allocator);
    defer h.deinit();

    try std.testing.expectError(error.GpuValidation, h.g.createShaderModule(.{ .wgsl = "this is not wgsl" }));
    try std.testing.expect(h.device.lastError().len > 0);

    // The device must still work after a recoverable validation error.
    const buffer = try h.g.createBuffer(.{ .size = 16, .usage = .{ .copy_dst = true } });
    h.g.destroyBuffer(buffer);
}

const compute_wgsl =
    \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
    \\@compute @workgroup_size(64)
    \\fn cs_main(@builtin(global_invocation_id) id: vec3<u32>) {
    \\    if (id.x < arrayLength(&data)) { data[id.x] = id.x * 2u + 1u; }
    \\}
;

test "compute dispatch writes a storage buffer" {
    var h = try Harness.init(std.testing.allocator);
    defer h.deinit();

    const count: u32 = 200; // not a multiple of the workgroup size: exercises the bounds check
    const bytes: u64 = @as(u64, count) * 4;
    const storage = try h.g.createBuffer(.{ .size = bytes, .usage = .{ .storage = true, .copy_src = true } });
    defer h.g.destroyBuffer(storage);
    const staging = try h.g.createBuffer(.{ .size = bytes, .usage = .{ .map_read = true, .copy_dst = true } });
    defer h.g.destroyBuffer(staging);

    const layout = try h.g.createBindGroupLayout(.{ .entries = &.{.{ .binding = 0, .visibility = .{ .compute = true }, .kind = .{ .buffer = .{ .type = .storage } } }} });
    defer h.g.destroyBindGroupLayout(layout);
    const pipeline_layout = try h.g.createPipelineLayout(.{ .bind_group_layouts = &.{layout} });
    defer h.g.destroyPipelineLayout(pipeline_layout);
    const shader = try h.g.createShaderModule(.{ .wgsl = compute_wgsl });
    defer h.g.destroyShaderModule(shader);
    const pipeline = try h.g.createComputePipeline(.{ .layout = pipeline_layout, .shader = shader });
    defer h.g.destroyComputePipeline(pipeline);
    const group = try h.g.createBindGroup(.{ .layout = layout, .entries = &.{.{ .binding = 0, .resource = .{ .buffer = .{ .buffer = storage } } }} });
    defer h.g.destroyBindGroup(group);

    var rec = gpu.CommandRecorder.init(std.testing.allocator);
    defer rec.deinit();
    try rec.beginComputePass(.{ .label = "fill" });
    try rec.setComputePipeline(pipeline);
    try rec.setBindGroup(0, group, &.{});
    try rec.dispatch((count + 63) / 64, 1, 1);
    try rec.endComputePass();
    try rec.copyBufferToBuffer(storage, 0, staging, 0, bytes);
    try rec.finish();
    try h.g.submit(rec.slice());

    var out: [200]u32 = undefined;
    try h.g.readBufferBlocking(staging, 0, std.mem.sliceAsBytes(&out));
    for (out, 0..) |value, i| try std.testing.expectEqual(@as(u32, @intCast(i)) * 2 + 1, value);
}

const triangle_wgsl =
    \\struct VsOut { @builtin(position) pos: vec4<f32>, @location(0) color: vec4<f32> };
    \\@vertex fn vs_main(@location(0) pos: vec2<f32>, @location(1) color: vec4<f32>) -> VsOut {
    \\    var out: VsOut;
    \\    out.pos = vec4<f32>(pos, 0.0, 1.0);
    \\    out.color = color;
    \\    return out;
    \\}
    \\@fragment fn fs_main(in: VsOut) -> @location(0) vec4<f32> { return in.color; }
;

test "render pass draws a triangle into an offscreen texture" {
    var h = try Harness.init(std.testing.allocator);
    defer h.deinit();

    // 100 px wide: 400-byte rows are not 256-aligned, which exercises the padded readback path.
    const width: u32 = 100;
    const height: u32 = 50;
    const target = try h.g.createTexture(.{ .width = width, .height = height, .format = .rgba8_unorm, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer h.g.destroyTexture(target);
    const view = try h.g.createTextureView(.{ .texture = target });
    defer h.g.destroyTextureView(view);

    // x, y, r, g, b, a
    const vertices = [_]f32{
        -0.6, -0.6, 0, 1, 0, 1,
        0.6,  -0.6, 0, 1, 0, 1,
        0.0,  0.6,  0, 1, 0, 1,
    };
    const vbo = try h.g.createBuffer(.{ .size = @sizeOf(@TypeOf(vertices)), .usage = .{ .vertex = true, .copy_dst = true } });
    defer h.g.destroyBuffer(vbo);
    try h.g.writeBuffer(vbo, 0, std.mem.sliceAsBytes(&vertices));

    const pipeline_layout = try h.g.createPipelineLayout(.{ .bind_group_layouts = &.{} });
    defer h.g.destroyPipelineLayout(pipeline_layout);
    const shader = try h.g.createShaderModule(.{ .wgsl = triangle_wgsl });
    defer h.g.destroyShaderModule(shader);
    const pipeline = try h.g.createRenderPipeline(.{
        .layout = pipeline_layout,
        .shader = shader,
        .vertex_buffers = &.{.{ .stride = 24, .attributes = &.{
            .{ .format = .float32x2, .offset = 0, .shader_location = 0 },
            .{ .format = .float32x4, .offset = 8, .shader_location = 1 },
        } }},
        .color_targets = &.{.{ .format = .rgba8_unorm }},
    });
    defer h.g.destroyRenderPipeline(pipeline);

    var rec = gpu.CommandRecorder.init(std.testing.allocator);
    defer rec.deinit();
    try rec.beginRenderPass(.{ .color_attachments = &.{.{ .target = .{ .view = view }, .clear_value = .{ .r = 0, .g = 0, .b = 1, .a = 1 } }} });
    try rec.setRenderPipeline(pipeline);
    try rec.setVertexBuffer(0, vbo, 0, 0);
    try rec.draw(3, 1, 0, 0);
    try rec.endRenderPass();
    try rec.finish();
    try h.g.submit(rec.slice());

    const pixels = try h.readTexture(target, width, height, 4);
    defer std.testing.allocator.free(pixels);
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, pixel(pixels, width, 1, 1)); // clear color
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, pixel(pixels, width, 50, 25)); // triangle
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, pixel(pixels, width, 98, 1)); // outside the triangle
}

const textured_wgsl =
    \\struct VsOut { @builtin(position) pos: vec4<f32>, @location(0) uv: vec2<f32> };
    \\@vertex fn vs_main(@builtin(vertex_index) i: u32) -> VsOut {
    \\    var p = array<vec2<f32>, 6>(
    \\        vec2<f32>(-1.0, -1.0), vec2<f32>(1.0, -1.0), vec2<f32>(-1.0, 1.0),
    \\        vec2<f32>(-1.0, 1.0), vec2<f32>(1.0, -1.0), vec2<f32>(1.0, 1.0));
    \\    var out: VsOut;
    \\    out.pos = vec4<f32>(p[i], 0.0, 1.0);
    \\    out.uv = vec2<f32>((p[i].x + 1.0) * 0.5, 1.0 - (p[i].y + 1.0) * 0.5);
    \\    return out;
    \\}
    \\@group(0) @binding(0) var tex: texture_2d<f32>;
    \\@group(0) @binding(1) var samp: sampler;
    \\@fragment fn fs_main(in: VsOut) -> @location(0) vec4<f32> { return textureSample(tex, samp, in.uv); }
;

test "texture upload, sampler and bind group sample exact texels" {
    var h = try Harness.init(std.testing.allocator);
    defer h.deinit();

    // 2x2 source texture: red, green / blue, white. Upload with a deliberately padded row pitch.
    const source = try h.g.createTexture(.{ .width = 2, .height = 2, .format = .rgba8_unorm, .usage = .{ .texture_binding = true, .copy_dst = true } });
    defer h.g.destroyTexture(source);
    var texels: [256 + 8]u8 = @splat(0);
    texels[0..8].* = .{ 255, 0, 0, 255, 0, 255, 0, 255 };
    texels[256..][0..8].* = .{ 0, 0, 255, 255, 255, 255, 255, 255 };
    try h.g.writeTexture(.{ .texture = source }, &texels, .{ .bytes_per_row = 256, .rows_per_image = 2 }, .{ .width = 2, .height = 2 });
    const source_view = try h.g.createTextureView(.{ .texture = source });
    defer h.g.destroyTextureView(source_view);
    const sampler = try h.g.createSampler(.{ .mag_filter = .nearest, .min_filter = .nearest, .mipmap_filter = .nearest });
    defer h.g.destroySampler(sampler);

    const layout = try h.g.createBindGroupLayout(.{ .entries = &.{
        .{ .binding = 0, .visibility = .{ .fragment = true }, .kind = .{ .texture = .{} } },
        .{ .binding = 1, .visibility = .{ .fragment = true }, .kind = .{ .sampler = .{} } },
    } });
    defer h.g.destroyBindGroupLayout(layout);
    const group = try h.g.createBindGroup(.{ .layout = layout, .entries = &.{
        .{ .binding = 0, .resource = .{ .texture_view = source_view } },
        .{ .binding = 1, .resource = .{ .sampler = sampler } },
    } });
    defer h.g.destroyBindGroup(group);
    const pipeline_layout = try h.g.createPipelineLayout(.{ .bind_group_layouts = &.{layout} });
    defer h.g.destroyPipelineLayout(pipeline_layout);
    const shader = try h.g.createShaderModule(.{ .wgsl = textured_wgsl });
    defer h.g.destroyShaderModule(shader);
    const pipeline = try h.g.createRenderPipeline(.{ .layout = pipeline_layout, .shader = shader, .color_targets = &.{.{ .format = .rgba8_unorm }} });
    defer h.g.destroyRenderPipeline(pipeline);

    const size: u32 = 4;
    const target = try h.g.createTexture(.{ .width = size, .height = size, .format = .rgba8_unorm, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer h.g.destroyTexture(target);
    const target_view = try h.g.createTextureView(.{ .texture = target });
    defer h.g.destroyTextureView(target_view);

    var rec = gpu.CommandRecorder.init(std.testing.allocator);
    defer rec.deinit();
    try rec.beginRenderPass(.{ .color_attachments = &.{.{ .target = .{ .view = target_view } }} });
    try rec.setRenderPipeline(pipeline);
    try rec.setBindGroup(0, group, &.{});
    try rec.draw(6, 1, 0, 0);
    try rec.endRenderPass();
    try h.g.submit(rec.slice());

    const pixels = try h.readTexture(target, size, size, 4);
    defer std.testing.allocator.free(pixels);
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, pixel(pixels, size, 0, 0));
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, pixel(pixels, size, 3, 0));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, pixel(pixels, size, 0, 3));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, pixel(pixels, size, 3, 3));
}

const depth_wgsl =
    \\struct VsOut { @builtin(position) pos: vec4<f32>, @location(0) color: vec4<f32> };
    \\@vertex fn vs_main(@location(0) pos: vec3<f32>, @location(1) color: vec4<f32>) -> VsOut {
    \\    var out: VsOut;
    \\    out.pos = vec4<f32>(pos, 1.0);
    \\    out.color = color;
    \\    return out;
    \\}
    \\@fragment fn fs_main(in: VsOut) -> @location(0) vec4<f32> { return in.color; }
;

test "depth attachment resolves overlapping triangles by depth, not draw order" {
    var h = try Harness.init(std.testing.allocator);
    defer h.deinit();

    const size: u32 = 32;
    const color = try h.g.createTexture(.{ .width = size, .height = size, .format = .rgba8_unorm, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer h.g.destroyTexture(color);
    const color_view = try h.g.createTextureView(.{ .texture = color });
    defer h.g.destroyTextureView(color_view);
    const depth = try h.g.createTexture(.{ .width = size, .height = size, .format = .depth32_float, .usage = .{ .render_attachment = true } });
    defer h.g.destroyTexture(depth);
    const depth_view = try h.g.createTextureView(.{ .texture = depth });
    defer h.g.destroyTextureView(depth_view);

    // Two full-screen triangles at different depths. The far (blue) one is drawn LAST yet must lose.
    const near_red = [_]f32{ -1, -1, 0.2, 1, 0, 0, 1, 3, -1, 0.2, 1, 0, 0, 1, -1, 3, 0.2, 1, 0, 0, 1 };
    const far_blue = [_]f32{ -1, -1, 0.8, 0, 0, 1, 1, 3, -1, 0.8, 0, 0, 1, 1, -1, 3, 0.8, 0, 0, 1, 1 };
    const near_buf = try h.g.createBuffer(.{ .size = @sizeOf(@TypeOf(near_red)), .usage = .{ .vertex = true, .copy_dst = true } });
    defer h.g.destroyBuffer(near_buf);
    const far_buf = try h.g.createBuffer(.{ .size = @sizeOf(@TypeOf(far_blue)), .usage = .{ .vertex = true, .copy_dst = true } });
    defer h.g.destroyBuffer(far_buf);
    try h.g.writeBuffer(near_buf, 0, std.mem.sliceAsBytes(&near_red));
    try h.g.writeBuffer(far_buf, 0, std.mem.sliceAsBytes(&far_blue));

    const pipeline_layout = try h.g.createPipelineLayout(.{ .bind_group_layouts = &.{} });
    defer h.g.destroyPipelineLayout(pipeline_layout);
    const shader = try h.g.createShaderModule(.{ .wgsl = depth_wgsl });
    defer h.g.destroyShaderModule(shader);
    const pipeline = try h.g.createRenderPipeline(.{
        .layout = pipeline_layout,
        .shader = shader,
        .vertex_buffers = &.{.{ .stride = 28, .attributes = &.{
            .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
            .{ .format = .float32x4, .offset = 12, .shader_location = 1 },
        } }},
        .color_targets = &.{.{ .format = .rgba8_unorm }},
        .depth_stencil = .{ .format = .depth32_float, .depth_compare = .less },
    });
    defer h.g.destroyRenderPipeline(pipeline);

    var rec = gpu.CommandRecorder.init(std.testing.allocator);
    defer rec.deinit();
    try rec.beginRenderPass(.{
        .color_attachments = &.{.{ .target = .{ .view = color_view } }},
        .depth = .{ .view = depth_view },
    });
    try rec.setRenderPipeline(pipeline);
    try rec.setVertexBuffer(0, near_buf, 0, 0);
    try rec.draw(3, 1, 0, 0);
    try rec.setVertexBuffer(0, far_buf, 0, 0);
    try rec.draw(3, 1, 0, 0);
    try rec.endRenderPass();
    try h.g.submit(rec.slice());

    const pixels = try h.readTexture(color, size, size, 4);
    defer std.testing.allocator.free(pixels);
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, pixel(pixels, size, 16, 16));
}

test "timestamp queries measure a compute pass when the adapter supports them" {
    var h = try Harness.init(std.testing.allocator);
    defer h.deinit();
    if (!h.g.capabilities().features.timestamp_query) {
        // The query set must be rejected, not silently accepted, when the feature is missing.
        try std.testing.expectError(error.FeatureUnsupported, h.g.createQuerySet(.{ .count = 2 }));
        return error.SkipZigTest;
    }

    const set = try h.g.createQuerySet(.{ .count = 2 });
    defer h.g.destroyQuerySet(set);
    const resolve = try h.g.createBuffer(.{ .size = 16, .usage = .{ .query_resolve = true, .copy_src = true } });
    defer h.g.destroyBuffer(resolve);
    const staging = try h.g.createBuffer(.{ .size = 16, .usage = .{ .map_read = true, .copy_dst = true } });
    defer h.g.destroyBuffer(staging);

    const storage = try h.g.createBuffer(.{ .size = 4096, .usage = .{ .storage = true } });
    defer h.g.destroyBuffer(storage);
    const layout = try h.g.createBindGroupLayout(.{ .entries = &.{.{ .binding = 0, .visibility = .{ .compute = true }, .kind = .{ .buffer = .{ .type = .storage } } }} });
    defer h.g.destroyBindGroupLayout(layout);
    const pipeline_layout = try h.g.createPipelineLayout(.{ .bind_group_layouts = &.{layout} });
    defer h.g.destroyPipelineLayout(pipeline_layout);
    const shader = try h.g.createShaderModule(.{ .wgsl = compute_wgsl });
    defer h.g.destroyShaderModule(shader);
    const pipeline = try h.g.createComputePipeline(.{ .layout = pipeline_layout, .shader = shader });
    defer h.g.destroyComputePipeline(pipeline);
    const group = try h.g.createBindGroup(.{ .layout = layout, .entries = &.{.{ .binding = 0, .resource = .{ .buffer = .{ .buffer = storage } } }} });
    defer h.g.destroyBindGroup(group);

    var rec = gpu.CommandRecorder.init(std.testing.allocator);
    defer rec.deinit();
    try rec.beginComputePass(.{ .timestamps = .{ .query_set = set, .begin_index = 0, .end_index = 1 } });
    try rec.setComputePipeline(pipeline);
    try rec.setBindGroup(0, group, &.{});
    try rec.dispatch(16, 1, 1);
    try rec.endComputePass();
    try rec.resolveQuerySet(set, 0, 2, resolve, 0);
    try rec.copyBufferToBuffer(resolve, 0, staging, 0, 16);
    try h.g.submit(rec.slice());

    var ticks: [2]u64 = undefined;
    try h.g.readBufferBlocking(staging, 0, std.mem.sliceAsBytes(&ticks));
    try std.testing.expect(ticks[1] >= ticks[0]);
    try std.testing.expect(h.g.capabilities().timestamp_period_ns > 0);
}

test "recorder rejects a pass that is never closed before submit" {
    var rec = gpu.CommandRecorder.init(std.testing.allocator);
    defer rec.deinit();
    try rec.beginComputePass(.{});
    try std.testing.expectError(error.PassStillOpen, rec.finish());
}

test "device releases leftover resources on deinit" {
    var h = try Harness.init(std.testing.allocator);
    // Intentionally leak engine handles: deinit must release them natively and the Zig allocator must stay clean.
    _ = try h.g.createBuffer(.{ .size = 64, .usage = .{ .copy_dst = true } });
    _ = try h.g.createTexture(.{ .width = 4, .height = 4, .format = .rgba8_unorm, .usage = .{ .texture_binding = true } });
    _ = try h.g.createSampler(.{});
    h.deinit();
}

test "blocking readback enforces a wall-clock deadline and leaves the device usable" {
    var h = try Harness.init(std.testing.allocator);
    defer h.deinit();
    const source_buffer = try h.g.createBuffer(.{ .size = 16, .usage = .{ .copy_src = true, .copy_dst = true } });
    defer h.g.destroyBuffer(source_buffer);
    const buffer = try h.g.createBuffer(.{ .size = 16, .usage = .{ .map_read = true, .copy_dst = true } });
    defer h.g.destroyBuffer(buffer);
    const source: [16]u8 = @splat(9);
    try h.g.writeBuffer(source_buffer, 0, &source);
    var rec = gpu.CommandRecorder.init(std.testing.allocator);
    defer rec.deinit();
    try rec.copyBufferToBuffer(source_buffer, 0, buffer, 0, 16);
    try h.g.submit(rec.slice());

    // A zero deadline either times out immediately or the mapping was already complete; nothing else is acceptable.
    var result: [16]u8 = undefined;
    h.g.readBufferTimeout(buffer, 0, &result, 0) catch |err| try std.testing.expectEqual(error.ReadbackTimeout, err);

    // The cancelled ticket must not block the buffer: a normal read right after succeeds.
    try h.g.readBufferBlocking(buffer, 0, &result);
    try std.testing.expectEqualSlices(u8, &source, &result);
}
