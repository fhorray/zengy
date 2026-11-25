//! Shared GPU texture store.
//!
//! Textures are device resources, not renderer resources: 2D sprites, unlit meshes and PBR materials all sample
//! the same images. The store hands out stable `TextureId`s (0 is reserved for "white"), keeps the texture and
//! its default view alive, and builds mip chains on the GPU. Renderers cache their own bind groups per id.

const std = @import("std");
const gpu = @import("gpu.zig");

/// Stable texture id. It is the bit pattern of the generational handle, so it is never 0.
pub const TextureId = u64;

pub const Entry = struct {
    texture: gpu.TextureHandle,
    view: gpu.TextureViewHandle,
    width: u32,
    height: u32,
    format: gpu.TextureFormat,
    mip_levels: u32,
};

const mip_shader_source = @embedFile("mipgen.wgsl");

/// Mip generation resources, built on first use. One pipeline per target format.
const MipGen = struct {
    shader: gpu.ShaderModuleHandle,
    layout: gpu.BindGroupLayoutHandle,
    pipeline_layout: gpu.PipelineLayoutHandle,
    sampler: gpu.SamplerHandle,
    linear: ?gpu.RenderPipelineHandle = null,
    srgb: ?gpu.RenderPipelineHandle = null,

    fn init(device: gpu.GpuDevice) !MipGen {
        const shader = try device.createShaderModule(.{ .label = "mipgen", .wgsl = mip_shader_source });
        errdefer device.destroyShaderModule(shader);
        const layout = try device.createBindGroupLayout(.{ .entries = &.{
            .{ .binding = 0, .visibility = .{ .fragment = true }, .kind = .{ .texture = .{} } },
            .{ .binding = 1, .visibility = .{ .fragment = true }, .kind = .{ .sampler = .{} } },
        } });
        errdefer device.destroyBindGroupLayout(layout);
        const pipeline_layout = try device.createPipelineLayout(.{ .bind_group_layouts = &.{layout} });
        errdefer device.destroyPipelineLayout(pipeline_layout);
        const sampler = try device.createSampler(.{ .mag_filter = .linear, .min_filter = .linear, .mipmap_filter = .nearest });
        return .{ .shader = shader, .layout = layout, .pipeline_layout = pipeline_layout, .sampler = sampler };
    }

    fn deinit(self: *MipGen, device: gpu.GpuDevice) void {
        if (self.linear) |p| device.destroyRenderPipeline(p);
        if (self.srgb) |p| device.destroyRenderPipeline(p);
        device.destroySampler(self.sampler);
        device.destroyPipelineLayout(self.pipeline_layout);
        device.destroyBindGroupLayout(self.layout);
        device.destroyShaderModule(self.shader);
    }

    fn pipelineFor(self: *MipGen, device: gpu.GpuDevice, format: gpu.TextureFormat) !gpu.RenderPipelineHandle {
        const slot = if (format == .rgba8_unorm_srgb) &self.srgb else &self.linear;
        if (slot.*) |existing| return existing;
        const pipeline = try device.createRenderPipeline(.{
            .label = "mipgen",
            .layout = self.pipeline_layout,
            .shader = self.shader,
            .color_targets = &.{.{ .format = format }},
        });
        slot.* = pipeline;
        return pipeline;
    }
};

pub const TextureStore = struct {
    allocator: std.mem.Allocator,
    entries: std.AutoHashMapUnmanaged(TextureId, Entry) = .empty,
    mipgen: ?MipGen = null,

    pub fn init(allocator: std.mem.Allocator) TextureStore {
        return .{ .allocator = allocator };
    }

    /// Releases every texture and the mip generator. `device` may be null only if nothing was created.
    pub fn deinit(self: *TextureStore, device: ?gpu.GpuDevice) void {
        if (device) |d| self.releaseAll(d);
        self.entries.deinit(self.allocator);
    }

    pub fn releaseAll(self: *TextureStore, device: gpu.GpuDevice) void {
        var it = self.entries.valueIterator();
        while (it.next()) |entry| {
            device.destroyTextureView(entry.view);
            device.destroyTexture(entry.texture);
        }
        self.entries.clearRetainingCapacity();
        if (self.mipgen) |*m| m.deinit(device);
        self.mipgen = null;
    }

    pub fn get(self: *const TextureStore, id: TextureId) ?Entry {
        return self.entries.get(id);
    }

    pub fn destroy(self: *TextureStore, device: gpu.GpuDevice, id: TextureId) void {
        const removed = self.entries.fetchRemove(id) orelse return;
        device.destroyTextureView(removed.value.view);
        device.destroyTexture(removed.value.texture);
    }

    /// Uploads tightly packed RGBA8 pixels and builds a full mip chain. `srgb` selects the sRGB format
    /// (albedo, emissive); linear data (normals, roughness, UI) uses `rgba8_unorm`.
    pub fn createRgba8(self: *TextureStore, device: gpu.GpuDevice, width: u32, height: u32, pixels: []const u8, srgb: bool) !TextureId {
        if (width == 0 or height == 0) return error.InvalidTextureSize;
        if (pixels.len < @as(usize, width) * height * 4) return error.InvalidTextureData;
        const levels: u32 = if (@max(width, height) > 1) std.math.log2_int(u32, @max(width, height)) + 1 else 1;
        const format: gpu.TextureFormat = if (srgb) .rgba8_unorm_srgb else .rgba8_unorm;
        const texture = try device.createTexture(.{
            .label = "texture",
            .width = width,
            .height = height,
            .mip_levels = levels,
            .format = format,
            .usage = .{ .texture_binding = true, .copy_dst = true, .copy_src = true, .render_attachment = levels > 1 },
        });
        errdefer device.destroyTexture(texture);
        try device.writeTexture(.{ .texture = texture }, pixels[0 .. @as(usize, width) * height * 4], .{ .bytes_per_row = width * 4, .rows_per_image = height }, .{ .width = width, .height = height });
        if (levels > 1) try self.generateMips(device, texture, format, width, height, levels);
        const view = try device.createTextureView(.{ .texture = texture });
        errdefer device.destroyTextureView(view);
        const id: TextureId = @bitCast(texture);
        try self.entries.put(self.allocator, id, .{ .texture = texture, .view = view, .width = width, .height = height, .format = format, .mip_levels = levels });
        return id;
    }

    fn generateMips(self: *TextureStore, device: gpu.GpuDevice, texture: gpu.TextureHandle, format: gpu.TextureFormat, width: u32, height: u32, levels: u32) !void {
        _ = width;
        _ = height;
        if (self.mipgen == null) self.mipgen = try MipGen.init(device);
        const mg = &self.mipgen.?;
        const pipeline = try mg.pipelineFor(device, format);

        var rec = gpu.CommandRecorder.init(self.allocator);
        defer rec.deinit();
        var temp_views: std.ArrayList(gpu.TextureViewHandle) = .empty;
        defer temp_views.deinit(self.allocator);
        var temp_groups: std.ArrayList(gpu.BindGroupHandle) = .empty;
        defer temp_groups.deinit(self.allocator);
        defer {
            for (temp_groups.items) |g| device.destroyBindGroup(g);
            for (temp_views.items) |v| device.destroyTextureView(v);
        }

        var level: u32 = 1;
        while (level < levels) : (level += 1) {
            const src = try device.createTextureView(.{ .texture = texture, .base_mip = level - 1, .mip_count = 1 });
            try temp_views.append(self.allocator, src);
            const dst = try device.createTextureView(.{ .texture = texture, .base_mip = level, .mip_count = 1 });
            try temp_views.append(self.allocator, dst);
            const group = try device.createBindGroup(.{ .layout = mg.layout, .entries = &.{
                .{ .binding = 0, .resource = .{ .texture_view = src } },
                .{ .binding = 1, .resource = .{ .sampler = mg.sampler } },
            } });
            try temp_groups.append(self.allocator, group);
            const attachments = [_]gpu.ColorAttachment{.{ .target = .{ .view = dst } }};
            try rec.beginRenderPass(.{ .label = "mipgen", .color_attachments = &attachments });
            try rec.setRenderPipeline(pipeline);
            try rec.setBindGroup(0, group, &.{});
            try rec.draw(3, 1, 0, 0);
            try rec.endRenderPass();
        }
        try rec.finish();
        try device.submit(rec.slice());
    }
};
