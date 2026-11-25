//! GPU executor for 2D draw commands and queued sprite quads, written only against `graphics.gpu`.
//!
//! One pipeline, one persistent vertex buffer that grows geometrically, one bind group per texture, and one
//! draw call per batch. Nothing here knows about wgpu, SDL GPU or any other backend.

const std = @import("std");
const graphics = @import("graphics");
const text = @import("text");
const batcher_mod = @import("batcher.zig");
const tess = @import("tessellate.zig");

const gpu = graphics.gpu;
const frame = graphics.frame;

const shader_source = @embedFile("textured.wgsl");
const vertex_stride: u64 = @sizeOf(tess.Vertex2DTextured);
const min_vertex_buffer_bytes: u64 = 64 * 1024;

pub const TextureId = graphics.TextureId;

/// Triangle vertex in normalized device coordinates (x/y in -1..1, y up) with a per-vertex color.
pub const NdcVertex = struct { x: f32, y: f32, r: f32, g: f32, b: f32, a: f32 };

const TextureEntry = struct {
    texture: gpu.TextureHandle,
    view: gpu.TextureViewHandle,
    bind_group: gpu.BindGroupHandle,
};

/// Everything that does not depend on the render target format lives here and survives format changes.
const GpuState = struct {
    device: gpu.GpuDevice,
    shader: gpu.ShaderModuleHandle,
    uniform_layout: gpu.BindGroupLayoutHandle,
    texture_layout: gpu.BindGroupLayoutHandle,
    pipeline_layout: gpu.PipelineLayoutHandle,
    /// The only format-bound object: rebuilt when the frame target format changes.
    pipeline: ?gpu.RenderPipelineHandle = null,
    pipeline_format: ?gpu.TextureFormat = null,
    uniform_buffer: gpu.BufferHandle,
    uniform_group: gpu.BindGroupHandle,
    vertex_buffer: gpu.BufferHandle,
    vertex_capacity: u64,
    sampler_nearest: gpu.SamplerHandle,
    sampler_linear: gpu.SamplerHandle,
    white: TextureEntry,
    font: TextureEntry,
    icons: TextureEntry,
};

pub const Renderer2D = struct {
    allocator: std.mem.Allocator,
    font: text.TtfAtlas,
    icons: text.IconAtlas,
    batcher: batcher_mod.Batcher,
    queued: std.ArrayList(tess.TexturedQuad) = .empty,
    ndc_triangles: std.ArrayList(NdcVertex) = .empty,
    triangle_scratch: std.ArrayList(batcher_mod.Vertex) = .empty,
    gpu_state: ?GpuState = null,
    /// Bind groups for textures owned by the shared `graphics.textures` store, created on first use.
    user_groups: std.AutoHashMapUnmanaged(TextureId, gpu.BindGroupHandle) = .empty,

    /// Bakes the CPU atlases. GPU resources are created lazily on the first frame.
    pub fn init(allocator: std.mem.Allocator) !Renderer2D {
        var font = try text.TtfAtlas.bake(allocator, text.FIRA_SANS_REGULAR, 28.0);
        errdefer font.deinit();
        var icons = try text.IconAtlas.bake(allocator, 32.0);
        errdefer icons.deinit();
        return .{ .allocator = allocator, .font = font, .icons = icons, .batcher = batcher_mod.Batcher.init(allocator) };
    }

    pub fn deinit(self: *Renderer2D) void {
        if (self.gpu_state) |gs| self.destroyGpu(gs.device);
        self.user_groups.deinit(self.allocator);
        self.queued.deinit(self.allocator);
        self.ndc_triangles.deinit(self.allocator);
        self.triangle_scratch.deinit(self.allocator);
        self.batcher.deinit();
        self.icons.deinit();
        self.font.deinit();
    }

    /// Measures UI text width in logical pixels, matching the width the renderer will draw.
    pub fn measureTextWidth(self: *const Renderer2D, content: []const u8, scale: f32) f32 {
        const target_px = (if (scale > 0.0) scale else 2.0) * 8.0;
        return self.font.measureText(content, target_px).width;
    }

    /// Queues a sprite quad (physical pixels) drawn under the next frame's command list.
    pub fn queueTexturedQuad(self: *Renderer2D, quad: tess.TexturedQuad) !void {
        try self.queued.append(self.allocator, quad);
    }

    /// Queues one colored triangle in normalized device coordinates; it draws under the next command list.
    pub fn queueTriangleNdc(self: *Renderer2D, a: NdcVertex, b: NdcVertex, c: NdcVertex) !void {
        for ([_]NdcVertex{ a, b, c }) |v| {
            inline for (.{ v.x, v.y, v.r, v.g, v.b, v.a }) |f| if (!std.math.isFinite(f)) return error.InvalidVertex;
        }
        try self.ndc_triangles.appendSlice(self.allocator, &.{ a, b, c });
    }

    /// Drops the cached bind group of a texture that is about to be destroyed in the shared store.
    pub fn forgetTexture(self: *Renderer2D, device: gpu.GpuDevice, id: TextureId) void {
        const removed = self.user_groups.fetchRemove(id) orelse return;
        device.destroyBindGroup(removed.value);
    }

    pub fn frameRenderer(self: *Renderer2D) frame.FrameRenderer {
        return .{
            .name = "official.render.2d.draw",
            .ctx = self,
            .order = frame.Order.overlay_2d,
            .render = renderThunk,
            .release = releaseThunk,
            .forget_texture = forgetThunk,
        };
    }

    fn renderThunk(ctx: *anyopaque, input: *frame.FrameInput) anyerror!void {
        const self: *Renderer2D = @ptrCast(@alignCast(ctx));
        try self.render(input);
    }

    fn forgetThunk(ctx: *anyopaque, device: gpu.GpuDevice, id: TextureId) void {
        const self: *Renderer2D = @ptrCast(@alignCast(ctx));
        self.forgetTexture(device, id);
    }

    fn releaseThunk(ctx: *anyopaque, device: gpu.GpuDevice) void {
        const self: *Renderer2D = @ptrCast(@alignCast(ctx));
        self.destroyGpu(device);
    }

    /// Creates format-independent GPU resources on first use.
    fn ensureGpu(self: *Renderer2D, device: gpu.GpuDevice) !*GpuState {
        if (self.gpu_state == null) self.gpu_state = try createGpuState(self, device);
        return &self.gpu_state.?;
    }

    /// Returns the pipeline for `format`, rebuilding it if the frame target format changed.
    fn ensurePipeline(gs: *GpuState, format: gpu.TextureFormat) !gpu.RenderPipelineHandle {
        if (gs.pipeline) |existing| {
            if (gs.pipeline_format == format) return existing;
            gs.device.destroyRenderPipeline(existing);
            gs.pipeline = null;
            gs.pipeline_format = null;
        }
        const pipeline = try gs.device.createRenderPipeline(.{
            .label = "render2d",
            .layout = gs.pipeline_layout,
            .shader = gs.shader,
            .vertex_buffers = &.{.{ .stride = vertex_stride, .attributes = &.{
                .{ .format = .float32x2, .offset = @offsetOf(tess.Vertex2DTextured, "x"), .shader_location = 0 },
                .{ .format = .float32x2, .offset = @offsetOf(tess.Vertex2DTextured, "u"), .shader_location = 1 },
                .{ .format = .float32x4, .offset = @offsetOf(tess.Vertex2DTextured, "r"), .shader_location = 2 },
            } }},
            .color_targets = &.{.{ .format = format, .blend = gpu.BlendState.alpha_blend }},
        });
        gs.pipeline = pipeline;
        gs.pipeline_format = format;
        return pipeline;
    }

    fn destroyGpu(self: *Renderer2D, device: gpu.GpuDevice) void {
        var groups = self.user_groups.valueIterator();
        while (groups.next()) |group| device.destroyBindGroup(group.*);
        self.user_groups.clearRetainingCapacity();
        const gs = self.gpu_state orelse return;
        destroyEntry(device, gs.white);
        destroyEntry(device, gs.font);
        destroyEntry(device, gs.icons);
        device.destroySampler(gs.sampler_nearest);
        device.destroySampler(gs.sampler_linear);
        device.destroyBuffer(gs.vertex_buffer);
        device.destroyBindGroup(gs.uniform_group);
        device.destroyBuffer(gs.uniform_buffer);
        if (gs.pipeline) |pipeline| device.destroyRenderPipeline(pipeline);
        device.destroyPipelineLayout(gs.pipeline_layout);
        device.destroyBindGroupLayout(gs.texture_layout);
        device.destroyBindGroupLayout(gs.uniform_layout);
        device.destroyShaderModule(gs.shader);
        self.gpu_state = null;
    }

    fn bindGroupFor(self: *Renderer2D, gs: *const GpuState, store: *const graphics.textures.TextureStore, slot: batcher_mod.TextureSlot) gpu.BindGroupHandle {
        switch (slot) {
            .white => return gs.white.bind_group,
            .font => return gs.font.bind_group,
            .icons => return gs.icons.bind_group,
            .user => |id| {
                if (self.user_groups.get(id)) |group| return group;
                // Unknown or destroyed texture: fall back to white instead of failing the whole frame.
                const entry = store.get(id) orelse return gs.white.bind_group;
                const group = gs.device.createBindGroup(.{ .layout = gs.texture_layout, .entries = &.{
                    .{ .binding = 0, .resource = .{ .texture_view = entry.view } },
                    .{ .binding = 1, .resource = .{ .sampler = gs.sampler_nearest } },
                } }) catch return gs.white.bind_group;
                self.user_groups.put(self.allocator, id, group) catch {
                    gs.device.destroyBindGroup(group);
                    return gs.white.bind_group;
                };
                return group;
            },
        }
    }

    pub fn render(self: *Renderer2D, input: *frame.FrameInput) !void {
        const gs = try self.ensureGpu(input.device);
        // NDC triangles become pixel-space vertices once the target size is known; UV (0,0) samples white.
        self.triangle_scratch.clearRetainingCapacity();
        const half_w: f32 = @as(f32, @floatFromInt(input.target.width)) * 0.5;
        const half_h: f32 = @as(f32, @floatFromInt(input.target.height)) * 0.5;
        for (self.ndc_triangles.items) |v| {
            try self.triangle_scratch.append(self.allocator, .{
                .x = (v.x + 1.0) * half_w,
                .y = (1.0 - v.y) * half_h,
                .u = 0,
                .v = 0,
                .r = v.r,
                .g = v.g,
                .b = v.b,
                .a = v.a,
            });
        }
        try self.batcher.build(input.draw_commands, self.queued.items, self.triangle_scratch.items, input.target.dpi_scale, .{ .font = &self.font, .icons = &self.icons });
        self.queued.clearRetainingCapacity();
        self.ndc_triangles.clearRetainingCapacity();
        if (self.batcher.vertices.items.len == 0) return;

        const pipeline = try ensurePipeline(gs, input.target.color_format);
        const bytes = std.mem.sliceAsBytes(self.batcher.vertices.items);
        try ensureVertexCapacity(gs, bytes.len);
        try gs.device.writeBuffer(gs.vertex_buffer, 0, bytes);
        const viewport = [4]f32{ @floatFromInt(input.target.width), @floatFromInt(input.target.height), 0, 0 };
        try gs.device.writeBuffer(gs.uniform_buffer, 0, std.mem.sliceAsBytes(&viewport));

        const rec = input.recorder;
        const attachments = [_]gpu.ColorAttachment{input.colorAttachment()};
        try rec.beginRenderPass(.{ .label = "render2d", .color_attachments = &attachments });
        try rec.setRenderPipeline(pipeline);
        try rec.setVertexBuffer(0, gs.vertex_buffer, 0, 0);
        try rec.setBindGroup(0, gs.uniform_group, &.{});
        for (self.batcher.batches.items) |batch| {
            const scissor = if (batch.scissor) |sc|
                batcher_mod.clampScissor(sc, input.target.width, input.target.height) orelse continue
            else
                batcher_mod.ScissorRect{ .x = 0, .y = 0, .w = input.target.width, .h = input.target.height };
            try rec.setScissor(@intCast(scissor.x), @intCast(scissor.y), scissor.w, scissor.h);
            try rec.setBindGroup(1, self.bindGroupFor(gs, input.textures, batch.texture), &.{});
            try rec.draw(batch.vertex_count, 1, batch.first_vertex, 0);
        }
        try rec.endRenderPass();
    }
};

fn ensureVertexCapacity(gs: *GpuState, bytes: usize) !void {
    if (bytes <= gs.vertex_capacity) return;
    var capacity = @max(gs.vertex_capacity, min_vertex_buffer_bytes);
    while (capacity < bytes) capacity *= 2;
    const next = try gs.device.createBuffer(.{ .label = "render2d vertices", .size = capacity, .usage = .{ .vertex = true, .copy_dst = true } });
    gs.device.destroyBuffer(gs.vertex_buffer);
    gs.vertex_buffer = next;
    gs.vertex_capacity = capacity;
}

fn createTextureEntry(
    gs: *const GpuState,
    width: u32,
    height: u32,
    pixels: []const u8,
    format: gpu.TextureFormat,
    sampler: gpu.SamplerHandle,
) !TextureEntry {
    const device = gs.device;
    const texture = try device.createTexture(.{ .width = width, .height = height, .format = format, .usage = .{ .texture_binding = true, .copy_dst = true } });
    errdefer device.destroyTexture(texture);
    try device.writeTexture(.{ .texture = texture }, pixels, .{ .bytes_per_row = width * 4, .rows_per_image = height }, .{ .width = width, .height = height });
    const view = try device.createTextureView(.{ .texture = texture });
    errdefer device.destroyTextureView(view);
    const group = try device.createBindGroup(.{ .layout = gs.texture_layout, .entries = &.{
        .{ .binding = 0, .resource = .{ .texture_view = view } },
        .{ .binding = 1, .resource = .{ .sampler = sampler } },
    } });
    return .{ .texture = texture, .view = view, .bind_group = group };
}

fn destroyEntry(device: gpu.GpuDevice, entry: TextureEntry) void {
    device.destroyBindGroup(entry.bind_group);
    device.destroyTextureView(entry.view);
    device.destroyTexture(entry.texture);
}

fn createGpuState(self: *Renderer2D, device: gpu.GpuDevice) !GpuState {
    const shader = try device.createShaderModule(.{ .label = "render2d textured", .wgsl = shader_source });
    errdefer device.destroyShaderModule(shader);
    const uniform_layout = try device.createBindGroupLayout(.{ .entries = &.{
        .{ .binding = 0, .visibility = .{ .vertex = true }, .kind = .{ .buffer = .{ .type = .uniform } } },
    } });
    errdefer device.destroyBindGroupLayout(uniform_layout);
    const texture_layout = try device.createBindGroupLayout(.{ .entries = &.{
        .{ .binding = 0, .visibility = .{ .fragment = true }, .kind = .{ .texture = .{} } },
        .{ .binding = 1, .visibility = .{ .fragment = true }, .kind = .{ .sampler = .{} } },
    } });
    errdefer device.destroyBindGroupLayout(texture_layout);
    const pipeline_layout = try device.createPipelineLayout(.{ .bind_group_layouts = &.{ uniform_layout, texture_layout } });
    errdefer device.destroyPipelineLayout(pipeline_layout);
    const uniform_buffer = try device.createBuffer(.{ .label = "render2d viewport", .size = 16, .usage = .{ .uniform = true, .copy_dst = true } });
    errdefer device.destroyBuffer(uniform_buffer);
    const uniform_group = try device.createBindGroup(.{ .layout = uniform_layout, .entries = &.{
        .{ .binding = 0, .resource = .{ .buffer = .{ .buffer = uniform_buffer } } },
    } });
    errdefer device.destroyBindGroup(uniform_group);
    const vertex_buffer = try device.createBuffer(.{ .label = "render2d vertices", .size = min_vertex_buffer_bytes, .usage = .{ .vertex = true, .copy_dst = true } });
    errdefer device.destroyBuffer(vertex_buffer);

    // Same sampling as the legacy backend: nearest for sprites/white, anisotropic linear for glyph atlases.
    const sampler_nearest = try device.createSampler(.{ .mag_filter = .nearest, .min_filter = .nearest, .mipmap_filter = .nearest });
    errdefer device.destroySampler(sampler_nearest);
    const sampler_linear = try device.createSampler(.{ .mag_filter = .linear, .min_filter = .linear, .mipmap_filter = .linear, .lod_max = 16.0, .max_anisotropy = 8 });
    errdefer device.destroySampler(sampler_linear);

    var gs: GpuState = .{
        .device = device,
        .shader = shader,
        .uniform_layout = uniform_layout,
        .texture_layout = texture_layout,
        .pipeline_layout = pipeline_layout,
        .uniform_buffer = uniform_buffer,
        .uniform_group = uniform_group,
        .vertex_buffer = vertex_buffer,
        .vertex_capacity = min_vertex_buffer_bytes,
        .sampler_nearest = sampler_nearest,
        .sampler_linear = sampler_linear,
        .white = undefined,
        .font = undefined,
        .icons = undefined,
    };
    const white_pixel = [_]u8{ 255, 255, 255, 255 };
    gs.white = try createTextureEntry(&gs, 1, 1, &white_pixel, .rgba8_unorm, sampler_nearest);
    errdefer destroyEntry(device, gs.white);
    gs.font = try createTextureEntry(&gs, self.font.width, self.font.height, self.font.rgba_pixels, .rgba8_unorm, sampler_linear);
    errdefer destroyEntry(device, gs.font);
    gs.icons = try createTextureEntry(&gs, self.icons.width, self.icons.height, self.icons.rgba_pixels, .rgba8_unorm, sampler_linear);
    return gs;
}
