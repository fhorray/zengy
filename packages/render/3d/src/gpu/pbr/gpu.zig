//! GPU object graph of the PBR renderer: shader modules, bind group layouts, samplers, static textures,
//! persistent buffers and the pipelines of the main chain. Every object is registered in a tracker so that
//! `deinit` releases exactly what was created, in reverse order, even after a partial failure.
//!
//! Bind group conventions (they match `tools/wgpu/port_shaders.py`):
//! - fullscreen passes: group 0 = textures/samplers/buffers, group 1 = one dynamic uniform block
//! - lit pass: group 0 = material textures, 1 = vertex uniforms, 2 = frame resources, 3 = fragment uniforms
//! - depth-only passes: group 1 = vertex uniform (alpha-masked casters also use groups 2 and 3)

const std = @import("std");
const graphics = @import("graphics");
const render_3d = @import("render_3d");
const layout = @import("layout.zig");
const util = @import("util.zig");
const screen_transport = @import("screen_transport.zig");

const gpu = graphics.gpu;
const cluster = render_3d.cluster;
const ibl = render_3d.ibl;

pub const hdr_format: gpu.TextureFormat = .rgba16_float;
pub const ao_format: gpu.TextureFormat = .rgba8_unorm;
pub const depth_format: gpu.TextureFormat = .depth32_float;

const sh = struct {
    const fullscreen_vs = @embedFile("../shaders/sky_vs.wgsl");
    const sky_fs = @embedFile("../shaders/sky_fs.wgsl");
    const pbr_vs = @embedFile("../shaders/pbr_vs.wgsl");
    const pbr_fs = @embedFile("../shaders/pbr_fs.wgsl");
    const shadow_vs = @embedFile("../shaders/shadow_vs.wgsl");
    const shadow_fs = @embedFile("../shaders/shadow_fs.wgsl");
    const shadow_mask_fs = @embedFile("../shaders/shadow_mask_fs.wgsl");
    const ssao_fs = @embedFile("../shaders/ssao_fs.wgsl");
    const ssao_blur_fs = @embedFile("../shaders/ssao_blur_fs.wgsl");
    const bloom_down_fs = @embedFile("../shaders/bloom_downsample_fs.wgsl");
    const bloom_up_fs = @embedFile("../shaders/bloom_upsample_fs.wgsl");
    const postfx_fs = @embedFile("../shaders/postfx_fs.wgsl");
    const pbr_screen_fs = @embedFile("../shaders/pbr_screen_fs.wgsl");
    const screen_transport_fs = @embedFile("../shaders/screen_transport_fs.wgsl");
    const hiz_reduce_cs = @embedFile("../shaders/hiz_reduce_cs.wgsl");
    const volumetric_fog_fs = @embedFile("../shaders/volumetric_fog_fs.wgsl");
    const volumetric_resolve_fs = @embedFile("../shaders/volumetric_resolve_fs.wgsl");
    const volumetric_composite_fs = @embedFile("../shaders/volumetric_composite_fs.wgsl");
    const froxel_integrate_fs = @embedFile("../shaders/froxel_integrate_fs.wgsl");
    const exposure_hist_cs = @embedFile("../shaders/auto_exposure_hist_cs.wgsl");
    const exposure_adapt_cs = @embedFile("../shaders/auto_exposure_adapt_cs.wgsl");
};

const ltc_table = @embedFile("../shaders/ltc_fit.bin");

pub const TexKind = enum { float, unfilterable, depth };
pub const SampKind = enum { filtering, non_filtering, comparison };

/// Layout entry helpers keep the bind group declarations readable.
pub fn tex(binding: u32, kind: TexKind, stages: gpu.ShaderStages) gpu.BindGroupLayoutEntry {
    return .{ .binding = binding, .visibility = stages, .kind = .{ .texture = .{ .sample_type = switch (kind) {
        .float => .float,
        .unfilterable => .unfilterable_float,
        .depth => .depth,
    } } } };
}

pub fn samp(binding: u32, kind: SampKind, stages: gpu.ShaderStages) gpu.BindGroupLayoutEntry {
    return .{ .binding = binding, .visibility = stages, .kind = .{ .sampler = .{ .type = switch (kind) {
        .filtering => .filtering,
        .non_filtering => .non_filtering,
        .comparison => .comparison,
    } } } };
}

pub fn ubo(binding: u32, size: u64, stages: gpu.ShaderStages) gpu.BindGroupLayoutEntry {
    return .{ .binding = binding, .visibility = stages, .kind = .{ .buffer = .{ .type = .uniform, .has_dynamic_offset = true, .min_binding_size = size } } };
}

pub fn sbo(binding: u32, read_only: bool, stages: gpu.ShaderStages) gpu.BindGroupLayoutEntry {
    return .{ .binding = binding, .visibility = stages, .kind = .{ .buffer = .{ .type = if (read_only) .read_only_storage else .storage } } };
}

pub const frag: gpu.ShaderStages = .{ .fragment = true };
pub const vert: gpu.ShaderStages = .{ .vertex = true };
pub const comp: gpu.ShaderStages = .{ .compute = true };

const mesh_vertex_buffers = [_]gpu.VertexBufferLayout{.{ .stride = 32, .attributes = &.{
    .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
    .{ .format = .float32x3, .offset = 12, .shader_location = 1 },
    .{ .format = .float32x2, .offset = 24, .shader_location = 2 },
} }};

/// One persistent uniform slot size: aligned to the device's dynamic offset requirement.
pub fn slotSize(device: gpu.GpuDevice, bytes: usize) u32 {
    const alignment = @max(device.capabilities().limits.min_uniform_buffer_offset_alignment, 16);
    return std.mem.alignForward(u32, @intCast(bytes), alignment);
}

/// Every object created through the tracker is destroyed by `deinit`, in reverse creation order.
const Tracked = union(enum) {
    shader: gpu.ShaderModuleHandle,
    bgl: gpu.BindGroupLayoutHandle,
    bg: gpu.BindGroupHandle,
    pl: gpu.PipelineLayoutHandle,
    rp: gpu.RenderPipelineHandle,
    cp: gpu.ComputePipelineHandle,
    sampler: gpu.SamplerHandle,
    texture: gpu.TextureHandle,
    view: gpu.TextureViewHandle,
    buffer: gpu.BufferHandle,
};

pub const Gpu = struct {
    allocator: std.mem.Allocator,
    device: gpu.GpuDevice,
    tracked: std.ArrayList(Tracked) = .empty,

    // Samplers.
    shadow_cmp: gpu.SamplerHandle = undefined,
    material: gpu.SamplerHandle = undefined,
    ibl: gpu.SamplerHandle = undefined,
    linear: gpu.SamplerHandle = undefined,
    nearest: gpu.SamplerHandle = undefined,

    // Static textures (with default views).
    white: Image = undefined,
    black: Image = undefined,
    flat_normal: Image = undefined,
    brdf_lut: Image = undefined,
    ltc: ?Image = null,
    env_prefilter: Image = undefined,
    shadow_atlas: Image = undefined,
    local_shadow: Image = undefined,
    exposure: Image = undefined,

    // Persistent storage buffers.
    cluster_lights: gpu.BufferHandle = undefined,
    cluster_grid: gpu.BufferHandle = undefined,
    cluster_indices: gpu.BufferHandle = undefined,
    local_shadow_buf: gpu.BufferHandle = undefined,
    histogram: gpu.BufferHandle = undefined,

    // Layouts.
    l_material: gpu.BindGroupLayoutHandle = undefined,
    l_vs_pbr: gpu.BindGroupLayoutHandle = undefined,
    l_frame: gpu.BindGroupLayoutHandle = undefined,
    l_fs_pbr: gpu.BindGroupLayoutHandle = undefined,
    l_vs_shadow: gpu.BindGroupLayoutHandle = undefined,
    l_mask_tex: gpu.BindGroupLayoutHandle = undefined,
    l_mask_params: gpu.BindGroupLayoutHandle = undefined,
    l_empty: gpu.BindGroupLayoutHandle = undefined,
    /// WebGPU requires a bind group even for an empty layout slot.
    empty_group: gpu.BindGroupHandle = undefined,

    // Shader modules shared by several pipelines.
    m_fullscreen_vs: gpu.ShaderModuleHandle = undefined,
    m_shadow_vs: gpu.ShaderModuleHandle = undefined,

    // Pipelines: lit pass variants.
    pbr_opaque: gpu.RenderPipelineHandle = undefined,
    pbr_double_sided: gpu.RenderPipelineHandle = undefined,
    pbr_blend: gpu.RenderPipelineHandle = undefined,
    pbr_reuse: gpu.RenderPipelineHandle = undefined,
    pbr_reuse_double_sided: gpu.RenderPipelineHandle = undefined,

    // Pipelines: depth-only.
    shadow_opaque: gpu.RenderPipelineHandle = undefined,
    shadow_double_sided: gpu.RenderPipelineHandle = undefined,
    shadow_mask: gpu.RenderPipelineHandle = undefined,
    shadow_mask_double_sided: gpu.RenderPipelineHandle = undefined,
    depth_clear: gpu.RenderPipelineHandle = undefined,

    // Pipelines: fullscreen chain (format-independent).
    sky: gpu.RenderPipelineHandle = undefined,
    ssao: gpu.RenderPipelineHandle = undefined,
    ssao_blur: gpu.RenderPipelineHandle = undefined,
    bloom_down: gpu.RenderPipelineHandle = undefined,
    bloom_up: gpu.RenderPipelineHandle = undefined,

    // Layouts reused by the pass bind groups created in the renderer.
    l_sky: gpu.BindGroupLayoutHandle = undefined,
    l_ssao: gpu.BindGroupLayoutHandle = undefined,
    l_ssao_blur: gpu.BindGroupLayoutHandle = undefined,
    l_float1: gpu.BindGroupLayoutHandle = undefined,
    l_post: gpu.BindGroupLayoutHandle = undefined,
    l_u_sky: gpu.BindGroupLayoutHandle = undefined,
    l_u_ssao: gpu.BindGroupLayoutHandle = undefined,
    l_u_blur: gpu.BindGroupLayoutHandle = undefined,
    l_u_bloom: gpu.BindGroupLayoutHandle = undefined,
    l_u_post: gpu.BindGroupLayoutHandle = undefined,

    /// Volumetric fog pipelines, created on first use.
    volumetric_gpu: ?Volumetric = null,

    /// Screen-space transport pipelines, created on first use.
    screen_gpu: ?Screen = null,

    /// Automatic exposure compute pipelines, created on first use.
    exposure_gpu: ?Exposure = null,

    // Post-process pipeline depends on the frame target format.
    postfx_pl: gpu.PipelineLayoutHandle = undefined,
    m_postfx_fs: gpu.ShaderModuleHandle = undefined,
    postfx: ?gpu.RenderPipelineHandle = null,
    postfx_format: ?gpu.TextureFormat = null,

    pub const Image = struct { texture: gpu.TextureHandle, view: gpu.TextureViewHandle };

    /// Colour bytes per sample of the transport lit pass: HDR (8) + surface rgba32f (16) + diffuse (8) + specular (8).
    pub const screen_color_bytes: u32 = 40;

    /// Lit-pass variants that also write the screen-transport metadata, plus the Hi-Z reduce and resolve passes.
    pub const Screen = struct {
        pbr_opaque: gpu.RenderPipelineHandle,
        pbr_double_sided: gpu.RenderPipelineHandle,
        pbr_blend: gpu.RenderPipelineHandle,
        pbr_reuse: gpu.RenderPipelineHandle,
        pbr_reuse_double_sided: gpu.RenderPipelineHandle,
        resolve: gpu.RenderPipelineHandle,
        reduce: gpu.ComputePipelineHandle,
        l_resolve: gpu.BindGroupLayoutHandle,
        l_reduce_depth: gpu.BindGroupLayoutHandle,
        l_reduce_bounds: gpu.BindGroupLayoutHandle,
        g_u_resolve: gpu.BindGroupHandle,
        g_u_reduce: gpu.BindGroupHandle,
    };

    /// Ray-marched (or froxel) volumetric fog, temporal resolve and physically based composite.
    pub const Volumetric = struct {
        fog: gpu.RenderPipelineHandle,
        resolve: gpu.RenderPipelineHandle,
        composite: gpu.RenderPipelineHandle,
        transmittance: gpu.RenderPipelineHandle,
        froxel: gpu.RenderPipelineHandle,
        l_fog: gpu.BindGroupLayoutHandle,
        l_resolve: gpu.BindGroupLayoutHandle,
        l_composite: gpu.BindGroupLayoutHandle,
        l_froxel: gpu.BindGroupLayoutHandle,
        g_u_fog: gpu.BindGroupHandle,
        g_u_resolve: gpu.BindGroupHandle,
        g_u_composite: gpu.BindGroupHandle,
        g_u_froxel: gpu.BindGroupHandle,
    };

    /// Histogram + adaptation compute passes of the automatic exposure.
    pub const Exposure = struct {
        hist: gpu.ComputePipelineHandle,
        adapt: gpu.ComputePipelineHandle,
        l_hist_hdr: gpu.BindGroupLayoutHandle,
        /// Static: the histogram buffer for the histogram pass (group 1).
        g_hist_buffer: gpu.BindGroupHandle,
        /// Static: exposure storage texture + histogram buffer for the adaptation pass (group 1).
        g_adapt_out: gpu.BindGroupHandle,
        /// Dynamic-offset uniform groups over the renderer's uniform ring (group 2).
        g_hist_uniform: gpu.BindGroupHandle,
        g_adapt_uniform: gpu.BindGroupHandle,
    };

    pub fn init(allocator: std.mem.Allocator, device: gpu.GpuDevice) !*Gpu {
        const self = try allocator.create(Gpu);
        self.* = .{ .allocator = allocator, .device = device };
        errdefer {
            self.deinit();
        }
        try self.build();
        return self;
    }

    pub fn deinit(self: *Gpu) void {
        const allocator = self.allocator;
        self.rollbackTracked(0);
        self.tracked.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn rollbackTracked(self: *Gpu, checkpoint: usize) void {
        var i = self.tracked.items.len;
        while (i > checkpoint) {
            i -= 1;
            switch (self.tracked.items[i]) {
                .shader => |h| self.device.destroyShaderModule(h),
                .bgl => |h| self.device.destroyBindGroupLayout(h),
                .bg => |h| self.device.destroyBindGroup(h),
                .pl => |h| self.device.destroyPipelineLayout(h),
                .rp => |h| self.device.destroyRenderPipeline(h),
                .cp => |h| self.device.destroyComputePipeline(h),
                .sampler => |h| self.device.destroySampler(h),
                .texture => |h| self.device.destroyTexture(h),
                .view => |h| self.device.destroyTextureView(h),
                .buffer => |h| self.device.destroyBuffer(h),
            }
        }
        self.tracked.shrinkRetainingCapacity(checkpoint);
    }

    // ------------------------------------------------------------ tracked creators

    pub fn newShader(self: *Gpu, label: []const u8, source: []const u8) !gpu.ShaderModuleHandle {
        const h = try self.device.createShaderModule(.{ .label = label, .wgsl = source });
        errdefer self.device.destroyShaderModule(h);
        try self.tracked.append(self.allocator, .{ .shader = h });
        return h;
    }

    pub fn newLayout(self: *Gpu, entries: []const gpu.BindGroupLayoutEntry) !gpu.BindGroupLayoutHandle {
        const h = try self.device.createBindGroupLayout(.{ .entries = entries });
        errdefer self.device.destroyBindGroupLayout(h);
        try self.tracked.append(self.allocator, .{ .bgl = h });
        return h;
    }

    pub fn newPipelineLayout(self: *Gpu, groups: []const gpu.BindGroupLayoutHandle) !gpu.PipelineLayoutHandle {
        const h = try self.device.createPipelineLayout(.{ .bind_group_layouts = groups });
        errdefer self.device.destroyPipelineLayout(h);
        try self.tracked.append(self.allocator, .{ .pl = h });
        return h;
    }

    pub fn newRender(self: *Gpu, desc: gpu.RenderPipelineDesc) !gpu.RenderPipelineHandle {
        const h = try self.device.createRenderPipeline(desc);
        errdefer self.device.destroyRenderPipeline(h);
        try self.tracked.append(self.allocator, .{ .rp = h });
        return h;
    }

    pub fn newCompute(self: *Gpu, desc: gpu.ComputePipelineDesc) !gpu.ComputePipelineHandle {
        const h = try self.device.createComputePipeline(desc);
        errdefer self.device.destroyComputePipeline(h);
        try self.tracked.append(self.allocator, .{ .cp = h });
        return h;
    }

    pub fn newSampler(self: *Gpu, desc: gpu.SamplerDesc) !gpu.SamplerHandle {
        const h = try self.device.createSampler(desc);
        errdefer self.device.destroySampler(h);
        try self.tracked.append(self.allocator, .{ .sampler = h });
        return h;
    }

    pub fn newBuffer(self: *Gpu, desc: gpu.BufferDesc) !gpu.BufferHandle {
        const h = try self.device.createBuffer(desc);
        errdefer self.device.destroyBuffer(h);
        try self.tracked.append(self.allocator, .{ .buffer = h });
        return h;
    }

    pub fn newBindGroup(self: *Gpu, desc: gpu.BindGroupDesc) !gpu.BindGroupHandle {
        const h = try self.device.createBindGroup(desc);
        errdefer self.device.destroyBindGroup(h);
        try self.tracked.append(self.allocator, .{ .bg = h });
        return h;
    }

    pub fn newImage(self: *Gpu, desc: gpu.TextureDesc) !Image {
        const t = try self.device.createTexture(desc);
        errdefer self.device.destroyTexture(t);
        const v = try self.device.createTextureView(.{ .texture = t });
        errdefer self.device.destroyTextureView(v);
        try self.tracked.ensureUnusedCapacity(self.allocator, 2);
        self.tracked.appendAssumeCapacity(.{ .texture = t });
        self.tracked.appendAssumeCapacity(.{ .view = v });
        return .{ .texture = t, .view = v };
    }

    /// Uploads one level of tightly packed texels.
    pub fn upload(self: *Gpu, image: Image, mip: u32, width: u32, height: u32, bytes: []const u8, bytes_per_texel: u32) !void {
        try self.device.writeTexture(.{ .texture = image.texture, .mip_level = mip }, bytes, .{ .bytes_per_row = width * bytes_per_texel, .rows_per_image = height }, .{ .width = width, .height = height });
    }

    fn solid(self: *Gpu, rgba: [4]u8) !Image {
        const image = try self.newImage(.{ .width = 1, .height = 1, .format = .rgba8_unorm, .usage = .{ .texture_binding = true, .copy_dst = true } });
        try self.upload(image, 0, 1, 1, &rgba, 4);
        return image;
    }

    // ----------------------------------------------------------------- build

    fn build(self: *Gpu) !void {
        const f = frag;
        // --- samplers (same sampling as the legacy backend)
        self.shadow_cmp = try self.newSampler(.{ .mag_filter = .linear, .min_filter = .linear, .mipmap_filter = .nearest, .compare = .less_equal });
        self.material = try self.newSampler(.{ .address_u = .repeat, .address_v = .repeat, .address_w = .repeat, .max_anisotropy = 8, .lod_max = 16 });
        self.ibl = try self.newSampler(.{ .address_u = .repeat, .lod_max = 16 });
        self.linear = try self.newSampler(.{ .lod_max = 16 });
        self.nearest = try self.newSampler(.{ .mag_filter = .nearest, .min_filter = .nearest, .mipmap_filter = .nearest });

        // --- layouts
        self.l_empty = try self.newLayout(&.{});
        self.empty_group = try self.newBindGroup(.{ .layout = self.l_empty, .entries = &.{} });
        self.l_material = try self.newLayout(&.{
            tex(0, .float, f),  samp(32, .filtering, f),
            tex(1, .float, f),  samp(33, .filtering, f),
            tex(2, .float, f),  samp(34, .filtering, f),
            tex(8, .float, f),  samp(40, .filtering, f),
            tex(9, .float, f),  samp(41, .filtering, f),
        });
        self.l_vs_pbr = try self.newLayout(&.{ubo(0, @sizeOf(layout.PbrVertUniforms), vert)});
        self.l_frame = try self.newLayout(&.{
            tex(3, .depth, f),         samp(35, .comparison, f),
            tex(4, .float, f),         samp(36, .filtering, f),
            tex(5, .float, f),         samp(37, .filtering, f),
            tex(6, .float, f),         samp(38, .filtering, f),
            tex(7, .depth, f),         samp(39, .comparison, f),
            tex(10, .unfilterable, f), samp(42, .non_filtering, f),
            tex(11, .unfilterable, f), samp(43, .non_filtering, f),
            tex(12, .float, f),        samp(44, .filtering, f),
            tex(13, .unfilterable, f), samp(45, .non_filtering, f),
            sbo(14, true, f),          sbo(15, true, f),
            sbo(16, true, f),          sbo(17, true, f),
        });
        self.l_fs_pbr = try self.newLayout(&.{ubo(0, @sizeOf(layout.PbrFragUniforms), f)});
        self.l_vs_shadow = try self.newLayout(&.{ubo(0, 64, vert)});
        self.l_mask_tex = try self.newLayout(&.{ tex(0, .float, f), samp(32, .filtering, f) });
        self.l_mask_params = try self.newLayout(&.{ubo(0, @sizeOf(layout.ShadowMaskParams), f)});

        // --- shader modules
        self.m_fullscreen_vs = try self.newShader("fullscreen", sh.fullscreen_vs);
        const pbr_vs = try self.newShader("pbr vs", sh.pbr_vs);
        const pbr_fs = try self.newShader("pbr fs", sh.pbr_fs);
        self.m_shadow_vs = try self.newShader("shadow vs", sh.shadow_vs);
        const shadow_fs = try self.newShader("shadow fs", sh.shadow_fs);
        const shadow_mask_fs = try self.newShader("shadow mask fs", sh.shadow_mask_fs);

        // --- lit pass pipelines
        const pbr_pl = try self.newPipelineLayout(&.{ self.l_material, self.l_vs_pbr, self.l_frame, self.l_fs_pbr });
        self.pbr_opaque = try self.pbrPipeline(pbr_pl, pbr_vs, pbr_fs, false, false, false, false);
        self.pbr_double_sided = try self.pbrPipeline(pbr_pl, pbr_vs, pbr_fs, true, false, false, false);
        self.pbr_blend = try self.pbrPipeline(pbr_pl, pbr_vs, pbr_fs, true, true, false, false);
        self.pbr_reuse = try self.pbrPipeline(pbr_pl, pbr_vs, pbr_fs, false, false, true, false);
        self.pbr_reuse_double_sided = try self.pbrPipeline(pbr_pl, pbr_vs, pbr_fs, true, false, true, false);

        // --- depth-only pipelines
        const shadow_pl = try self.newPipelineLayout(&.{ self.l_empty, self.l_vs_shadow });
        const mask_pl = try self.newPipelineLayout(&.{ self.l_empty, self.l_vs_shadow, self.l_mask_tex, self.l_mask_params });
        self.shadow_opaque = try self.shadowPipeline(shadow_pl, shadow_fs, false);
        self.shadow_double_sided = try self.shadowPipeline(shadow_pl, shadow_fs, true);
        self.shadow_mask = try self.shadowPipeline(mask_pl, shadow_mask_fs, false);
        self.shadow_mask_double_sided = try self.shadowPipeline(mask_pl, shadow_mask_fs, true);
        // Fullscreen triangle that always passes and writes far depth: with a scissor it clears one atlas region.
        self.depth_clear = try self.newRender(.{
            .label = "depth clear",
            .layout = try self.newPipelineLayout(&.{}),
            .shader = self.m_fullscreen_vs,
            .fragment_shader = shadow_fs,
            .vertex_entry = "main",
            .fragment_entry = null,
            .depth_stencil = .{ .format = depth_format, .depth_write = true, .depth_compare = .always },
        });

        // --- fullscreen chain
        self.l_sky = try self.newLayout(&.{ tex(0, .float, f), samp(32, .filtering, f) });
        self.l_ssao = try self.newLayout(&.{ tex(0, .unfilterable, f), samp(32, .non_filtering, f) });
        self.l_ssao_blur = try self.newLayout(&.{ tex(0, .float, f), samp(32, .filtering, f), tex(1, .unfilterable, f), samp(33, .non_filtering, f) });
        self.l_float1 = try self.newLayout(&.{ tex(0, .float, f), samp(32, .filtering, f) });
        self.l_post = try self.newLayout(&.{ tex(0, .float, f), samp(32, .filtering, f), tex(1, .float, f), samp(33, .filtering, f), tex(2, .unfilterable, f), samp(34, .non_filtering, f) });
        self.l_u_sky = try self.newLayout(&.{ubo(0, @sizeOf(layout.SkyUniforms), f)});
        self.l_u_ssao = try self.newLayout(&.{ubo(0, @sizeOf(layout.SsaoParams), f)});
        self.l_u_blur = try self.newLayout(&.{ubo(0, @sizeOf(layout.SsaoBlurParams), f)});
        self.l_u_bloom = try self.newLayout(&.{ubo(0, @sizeOf(layout.BloomParams), f)});
        self.l_u_post = try self.newLayout(&.{ubo(0, @sizeOf(layout.PostFxParams), f)});

        self.sky = try self.fullscreen("sky", sh.sky_fs, &.{ self.l_sky, self.l_u_sky }, hdr_format, .none);
        self.ssao = try self.fullscreen("ssao", sh.ssao_fs, &.{ self.l_ssao, self.l_u_ssao }, ao_format, .none);
        self.ssao_blur = try self.fullscreen("ssao blur", sh.ssao_blur_fs, &.{ self.l_ssao_blur, self.l_u_blur }, ao_format, .none);
        self.bloom_down = try self.fullscreen("bloom down", sh.bloom_down_fs, &.{ self.l_float1, self.l_u_bloom }, hdr_format, .none);
        self.bloom_up = try self.fullscreen("bloom up", sh.bloom_up_fs, &.{ self.l_float1, self.l_u_bloom }, hdr_format, .additive);

        self.postfx_pl = try self.newPipelineLayout(&.{ self.l_post, self.l_u_post });
        self.m_postfx_fs = try self.newShader("postfx fs", sh.postfx_fs);

        try self.buildStatic();
    }

    pub const Blend = enum { none, additive, multiply };

    /// Creates a fullscreen pipeline from a fragment shader source, reusing the shared fullscreen vertex shader.
    pub fn fullscreen(self: *Gpu, label: []const u8, fs_source: []const u8, groups: []const gpu.BindGroupLayoutHandle, format: gpu.TextureFormat, blend: Blend) !gpu.RenderPipelineHandle {
        const fs = try self.newShader(label, fs_source);
        const pl = try self.newPipelineLayout(groups);
        return self.fullscreenWith(label, fs, pl, format, blend);
    }

    pub fn fullscreenWith(self: *Gpu, label: []const u8, fs: gpu.ShaderModuleHandle, pl: gpu.PipelineLayoutHandle, format: gpu.TextureFormat, blend: Blend) !gpu.RenderPipelineHandle {
        return self.newRender(.{
            .label = label,
            .layout = pl,
            .shader = self.m_fullscreen_vs,
            .fragment_shader = fs,
            .vertex_entry = "main",
            .fragment_entry = "main",
            .color_targets = &.{.{ .format = format, .blend = switch (blend) {
                .none => null,
                .additive => gpu.BlendState.additive,
                // dst = dst * src; alpha is left alone so the transmittance pass cannot change HDR alpha.
                .multiply => .{
                    .color = .{ .operation = .add, .src_factor = .zero, .dst_factor = .src },
                    .alpha = .{ .operation = .add, .src_factor = .zero, .dst_factor = .one },
                },
            } }},
        });
    }

    /// `transport` adds the three screen-transport metadata targets (never blended: a blended draw rewrites them as "no data").
    fn pbrPipeline(self: *Gpu, pl: gpu.PipelineLayoutHandle, vs: gpu.ShaderModuleHandle, fs: gpu.ShaderModuleHandle, double_sided: bool, alpha_blend: bool, depth_equal_ok: bool, transport: bool) !gpu.RenderPipelineHandle {
        const hdr_target: gpu.ColorTargetState = .{ .format = hdr_format, .blend = if (alpha_blend) gpu.BlendState.alpha_blend else null };
        const targets = [_]gpu.ColorTargetState{ hdr_target, .{ .format = .rgba32_float }, .{ .format = hdr_format }, .{ .format = hdr_format } };
        return self.newRender(.{
            .label = "pbr",
            .layout = pl,
            .shader = vs,
            .fragment_shader = fs,
            .vertex_entry = "main",
            .fragment_entry = "main",
            .vertex_buffers = &mesh_vertex_buffers,
            .color_targets = if (transport) &targets else targets[0..1],
            // Blended surfaces test depth but do not write it.
            .depth_stencil = .{ .format = depth_format, .depth_write = !alpha_blend, .depth_compare = if (depth_equal_ok) .less_equal else .less },
            .cull_mode = if (double_sided) .none else .back,
        });
    }

    fn shadowPipeline(self: *Gpu, pl: gpu.PipelineLayoutHandle, fs: gpu.ShaderModuleHandle, double_sided: bool) !gpu.RenderPipelineHandle {
        return self.newRender(.{
            .label = "shadow",
            .layout = pl,
            .shader = self.m_shadow_vs,
            .fragment_shader = fs,
            .vertex_entry = "main",
            .fragment_entry = "main",
            .vertex_buffers = &mesh_vertex_buffers,
            .depth_stencil = .{ .format = depth_format, .depth_write = true, .depth_compare = .less },
            .cull_mode = if (double_sided) .none else .back,
        });
    }

    /// Persistent GPU data that never changes after startup.
    fn buildStatic(self: *Gpu) !void {
        self.white = try self.solid(.{ 255, 255, 255, 255 });
        self.black = try self.solid(.{ 0, 0, 0, 255 });
        self.flat_normal = try self.solid(.{ 128, 128, 255, 255 });

        const depth_usage: gpu.TextureUsage = .{ .render_attachment = true, .texture_binding = true };
        self.shadow_atlas = try self.newImage(.{ .label = "shadow atlas", .width = layout.SHADOW_W, .height = layout.SHADOW_H, .format = depth_format, .usage = depth_usage });
        self.local_shadow = try self.newImage(.{ .label = "local shadow atlas", .width = 2048, .height = 2048, .format = depth_format, .usage = depth_usage });
        self.exposure = try self.newImage(.{ .label = "exposure", .width = 1, .height = 1, .format = .r32_float, .usage = .{ .texture_binding = true, .storage_binding = true, .copy_dst = true, .copy_src = true } });
        try self.upload(self.exposure, 0, 1, 1, &std.mem.toBytes(@as(f32, 1.0)), 4);

        // BRDF lookup table generated on the CPU (unchanged algorithm).
        const lut = try ibl.generateBrdfLutRgba8(self.allocator, layout.BRDF_LUT_SIZE);
        defer self.allocator.free(lut);
        self.brdf_lut = try self.newImage(.{ .label = "brdf lut", .width = layout.BRDF_LUT_SIZE, .height = layout.BRDF_LUT_SIZE, .format = .rgba8_unorm, .usage = .{ .texture_binding = true, .copy_dst = true } });
        try self.upload(self.brdf_lut, 0, layout.BRDF_LUT_SIZE, layout.BRDF_LUT_SIZE, lut, 4);

        // LTC table (16x32 RGBA32F). It is optional: a failure leaves area lights on the quadrature path.
        if (ltc_table.len == 16 * 32 * 16) {
            if (self.newImage(.{ .label = "ltc", .width = 16, .height = 32, .format = .rgba32_float, .usage = .{ .texture_binding = true, .copy_dst = true } })) |image| {
                self.upload(image, 0, 16, 32, ltc_table, 16) catch {};
                self.ltc = image;
            } else |_| {}
        }

        self.env_prefilter = try self.newImage(.{ .label = "env prefilter", .width = layout.ENV_W, .height = layout.ENV_H, .mip_levels = layout.ENV_MIPS, .format = .rgba16_float, .usage = .{ .texture_binding = true, .copy_dst = true } });

        const storage: gpu.BufferUsage = .{ .storage = true, .copy_dst = true };
        self.cluster_lights = try self.newBuffer(.{ .label = "cluster lights", .size = @sizeOf(layout.ClusterLightsBuffer), .usage = .{ .storage = true, .copy_dst = true, .copy_src = true } });
        self.cluster_grid = try self.newBuffer(.{ .label = "cluster grid", .size = cluster.CLUSTER_COUNT * @sizeOf(cluster.ClusterEntry), .usage = storage });
        self.cluster_indices = try self.newBuffer(.{ .label = "cluster indices", .size = 65536 * 4, .usage = storage });
        self.local_shadow_buf = try self.newBuffer(.{ .label = "local shadow", .size = @sizeOf(layout.LocalShadowBuffer), .usage = storage });
        self.histogram = try self.newBuffer(.{ .label = "exposure histogram", .size = 66 * 4, .usage = .{ .storage = true, .copy_dst = true } });
        const zeros = std.mem.zeroes([66 * 4]u8);
        try self.device.writeBuffer(self.histogram, 0, &zeros);
    }

    /// True when the adapter can hold the four colour attachments of the transport lit pass.
    pub fn supportsScreenTransport(self: *const Gpu) bool {
        const limits = self.device.capabilities().limits;
        return limits.max_color_attachments >= 4 and limits.max_color_attachment_bytes_per_sample >= screen_color_bytes;
    }

    /// Builds the screen-transport pipelines the first time a view enables SSR/SSGI.
    pub fn ensureScreen(self: *Gpu, ring_buffer: gpu.BufferHandle) !*const Screen {
        if (self.screen_gpu) |*s| return s;
        const checkpoint = self.tracked.items.len;
        errdefer self.rollbackTracked(checkpoint);
        const f = frag;
        const c = comp;
        const pbr_vs = try self.newShader("pbr vs (transport)", sh.pbr_vs);
        const pbr_fs = try self.newShader("pbr fs (transport)", sh.pbr_screen_fs);
        const pbr_pl = try self.newPipelineLayout(&.{ self.l_material, self.l_vs_pbr, self.l_frame, self.l_fs_pbr });
        const l_resolve = try self.newLayout(&.{
            tex(0, .float, f),        samp(32, .filtering, f),
            tex(1, .unfilterable, f), samp(33, .non_filtering, f),
            tex(2, .unfilterable, f), samp(34, .non_filtering, f),
            tex(3, .unfilterable, f), samp(35, .non_filtering, f),
            tex(4, .unfilterable, f), samp(36, .non_filtering, f),
            tex(5, .float, f),        samp(37, .filtering, f),
            sbo(6, true, f),
        });
        const l_u_resolve = try self.newLayout(&.{ubo(0, @sizeOf(screen_transport.Params), f)});
        const l_reduce_depth = try self.newLayout(&.{ tex(0, .unfilterable, c), samp(32, .non_filtering, c) });
        const l_reduce_bounds = try self.newLayout(&.{sbo(0, false, c)});
        const l_u_reduce = try self.newLayout(&.{ubo(0, @sizeOf(screen_transport.ReduceParams), c)});
        const reduce_pl = try self.newPipelineLayout(&.{ l_reduce_depth, l_reduce_bounds, l_u_reduce });
        self.screen_gpu = .{
            .pbr_opaque = try self.pbrPipeline(pbr_pl, pbr_vs, pbr_fs, false, false, false, true),
            .pbr_double_sided = try self.pbrPipeline(pbr_pl, pbr_vs, pbr_fs, true, false, false, true),
            .pbr_blend = try self.pbrPipeline(pbr_pl, pbr_vs, pbr_fs, true, true, false, true),
            .pbr_reuse = try self.pbrPipeline(pbr_pl, pbr_vs, pbr_fs, false, false, true, true),
            .pbr_reuse_double_sided = try self.pbrPipeline(pbr_pl, pbr_vs, pbr_fs, true, false, true, true),
            .resolve = try self.fullscreen("screen transport", sh.screen_transport_fs, &.{ l_resolve, l_u_resolve }, hdr_format, .none),
            .reduce = try self.newCompute(.{ .label = "hiz reduce", .layout = reduce_pl, .shader = try self.newShader("hiz reduce", sh.hiz_reduce_cs), .entry = "main" }),
            .l_resolve = l_resolve,
            .l_reduce_depth = l_reduce_depth,
            .l_reduce_bounds = l_reduce_bounds,
            .g_u_resolve = try self.ringGroup(l_u_resolve, ring_buffer, @sizeOf(screen_transport.Params)),
            .g_u_reduce = try self.ringGroup(l_u_reduce, ring_buffer, @sizeOf(screen_transport.ReduceParams)),
        };
        return &self.screen_gpu.?;
    }

    /// Builds the volumetric pipelines the first time fog is rendered.
    pub fn ensureVolumetric(self: *Gpu, ring_buffer: gpu.BufferHandle) !*const Volumetric {
        if (self.volumetric_gpu) |*v| return v;
        const checkpoint = self.tracked.items.len;
        errdefer self.rollbackTracked(checkpoint);
        const f = frag;
        const l_fog = try self.newLayout(&.{ tex(0, .unfilterable, f), samp(32, .non_filtering, f), tex(1, .depth, f), samp(33, .comparison, f), tex(2, .depth, f), samp(34, .comparison, f) });
        const l_resolve = try self.newLayout(&.{ tex(0, .float, f), samp(32, .filtering, f), tex(1, .float, f), samp(33, .filtering, f), tex(2, .unfilterable, f), samp(34, .non_filtering, f) });
        const l_composite = try self.newLayout(&.{ tex(0, .float, f), samp(32, .filtering, f), tex(1, .unfilterable, f), samp(33, .non_filtering, f) });
        const l_froxel = try self.newLayout(&.{ tex(0, .float, f), samp(32, .filtering, f), tex(1, .unfilterable, f), samp(33, .non_filtering, f) });
        const l_u_fog = try self.newLayout(&.{ubo(0, @sizeOf(layout.VolFogParams), f)});
        const l_u_resolve = try self.newLayout(&.{ubo(0, @sizeOf(layout.VolResolveParams), f)});
        const l_u_composite = try self.newLayout(&.{ubo(0, @sizeOf(layout.VolCompositeParams), f)});
        const l_u_froxel = try self.newLayout(&.{ubo(0, @sizeOf(layout.FroxelIntegrateParams), f)});
        const composite_fs = try self.newShader("volumetric composite", sh.volumetric_composite_fs);
        const composite_pl = try self.newPipelineLayout(&.{ l_composite, l_u_composite });
        self.volumetric_gpu = .{
            // The ray march writes into a cleared target, so it does not need additive blending.
            .fog = try self.fullscreen("volumetric fog", sh.volumetric_fog_fs, &.{ l_fog, l_u_fog }, hdr_format, .none),
            .resolve = try self.fullscreen("volumetric resolve", sh.volumetric_resolve_fs, &.{ l_resolve, l_u_resolve }, hdr_format, .none),
            .composite = try self.fullscreenWith("volumetric composite", composite_fs, composite_pl, hdr_format, .additive),
            .transmittance = try self.fullscreenWith("volumetric transmittance", composite_fs, composite_pl, hdr_format, .multiply),
            .froxel = try self.fullscreen("froxel integrate", sh.froxel_integrate_fs, &.{ l_froxel, l_u_froxel }, hdr_format, .none),
            .l_fog = l_fog,
            .l_resolve = l_resolve,
            .l_composite = l_composite,
            .l_froxel = l_froxel,
            .g_u_fog = try self.ringGroup(l_u_fog, ring_buffer, @sizeOf(layout.VolFogParams)),
            .g_u_resolve = try self.ringGroup(l_u_resolve, ring_buffer, @sizeOf(layout.VolResolveParams)),
            .g_u_composite = try self.ringGroup(l_u_composite, ring_buffer, @sizeOf(layout.VolCompositeParams)),
            .g_u_froxel = try self.ringGroup(l_u_froxel, ring_buffer, @sizeOf(layout.FroxelIntegrateParams)),
        };
        return &self.volumetric_gpu.?;
    }

    /// Bind group exposing `size` bytes of the uniform ring through a dynamic-offset binding.
    pub fn ringGroup(self: *Gpu, lay: gpu.BindGroupLayoutHandle, ring_buffer: gpu.BufferHandle, size: u64) !gpu.BindGroupHandle {
        return self.newBindGroup(.{ .layout = lay, .entries = &.{.{ .binding = 0, .resource = .{ .buffer = .{ .buffer = ring_buffer, .size = size } } }} });
    }

    /// Builds the exposure compute pipelines the first time automatic exposure is used.
    pub fn ensureExposure(self: *Gpu, ring_buffer: gpu.BufferHandle) !*const Exposure {
        if (self.exposure_gpu) |*e| return e;
        const checkpoint = self.tracked.items.len;
        errdefer self.rollbackTracked(checkpoint);
        const c = comp;
        const l_hdr = try self.newLayout(&.{tex(0, .unfilterable, c)});
        const l_hist_buf = try self.newLayout(&.{sbo(0, false, c)});
        const l_adapt_out = try self.newLayout(&.{
            .{ .binding = 0, .visibility = c, .kind = .{ .storage_texture = .{ .access = .write_only, .format = .r32_float } } },
            sbo(1, false, c),
        });
        const l_u_hist = try self.newLayout(&.{ubo(0, @sizeOf(layout.HistParams), c)});
        const l_u_adapt = try self.newLayout(&.{ubo(0, @sizeOf(layout.AdaptParams), c)});
        const hist_pl = try self.newPipelineLayout(&.{ l_hdr, l_hist_buf, l_u_hist });
        const adapt_pl = try self.newPipelineLayout(&.{ self.l_empty, l_adapt_out, l_u_adapt });
        const hist = try self.newCompute(.{ .label = "exposure histogram", .layout = hist_pl, .shader = try self.newShader("exposure hist", sh.exposure_hist_cs), .entry = "main" });
        const adapt = try self.newCompute(.{ .label = "exposure adapt", .layout = adapt_pl, .shader = try self.newShader("exposure adapt", sh.exposure_adapt_cs), .entry = "main" });
        self.exposure_gpu = .{
            .hist = hist,
            .adapt = adapt,
            .l_hist_hdr = l_hdr,
            .g_hist_buffer = try self.newBindGroup(.{ .layout = l_hist_buf, .entries = &.{.{ .binding = 0, .resource = .{ .buffer = .{ .buffer = self.histogram } } }} }),
            .g_adapt_out = try self.newBindGroup(.{ .layout = l_adapt_out, .entries = &.{
                .{ .binding = 0, .resource = .{ .texture_view = self.exposure.view } },
                .{ .binding = 1, .resource = .{ .buffer = .{ .buffer = self.histogram } } },
            } }),
            .g_hist_uniform = try self.newBindGroup(.{ .layout = l_u_hist, .entries = &.{.{ .binding = 0, .resource = .{ .buffer = .{ .buffer = ring_buffer, .size = @sizeOf(layout.HistParams) } } }} }),
            .g_adapt_uniform = try self.newBindGroup(.{ .layout = l_u_adapt, .entries = &.{.{ .binding = 0, .resource = .{ .buffer = .{ .buffer = ring_buffer, .size = @sizeOf(layout.AdaptParams) } } }} }),
        };
        return &self.exposure_gpu.?;
    }

    /// Returns the post-process pipeline for `format`, rebuilding it if the target format changed.
    pub fn postfxFor(self: *Gpu, format: gpu.TextureFormat) !gpu.RenderPipelineHandle {
        if (self.postfx) |existing| {
            if (self.postfx_format == format) return existing;
            self.device.destroyRenderPipeline(existing);
            self.untrackRender(existing);
            self.postfx = null;
        }
        const pipeline = try self.fullscreenWith("postfx", self.m_postfx_fs, self.postfx_pl, format, .none);
        self.postfx = pipeline;
        self.postfx_format = format;
        return pipeline;
    }

    /// Removes a pipeline from the tracker after it was destroyed explicitly (format rebuilds).
    fn untrackRender(self: *Gpu, handle: gpu.RenderPipelineHandle) void {
        for (self.tracked.items, 0..) |item, i| switch (item) {
            .rp => |h| if (h.eql(handle)) {
                _ = self.tracked.orderedRemove(i);
                return;
            },
            else => {},
        };
    }
};
