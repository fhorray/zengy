//! SDL_GPU PBR, Sky, Shadow, Compute Auto-Exposure, Bloom, & Tonemapping Backend.
//!
//! Implements `render_3d.pbr.PbrBackendVTable` inside `official.graphics.sdlgpu`.

const std = @import("std");
const engine = @import("engine");
const render_3d = @import("render_3d");
const gpu_resources = @import("gpu_resources.zig");
const volumetric_lights = @import("volumetric_lights.zig");
const shadow_cull = @import("shadow_cull.zig");
const capture = @import("capture.zig");
const c = @import("sdl3_c");

const pbr = render_3d.pbr;
const ibl = render_3d.ibl;
const cluster = render_3d.cluster;
const math3d = render_3d.math3d;

const PBR_VERT_SPV = @embedFile("shaders/pbr.vert.spv");
const PBR_FRAG_SPV = @embedFile("shaders/pbr.frag.spv");
const SKY_VERT_SPV = @embedFile("shaders/sky.vert.spv");
const SKY_FRAG_SPV = @embedFile("shaders/sky.frag.spv");
const SHADOW_VERT_SPV = @embedFile("shaders/shadow.vert.spv");
const SHADOW_FRAG_SPV = @embedFile("shaders/shadow.frag.spv");
const SHADOW_MASK_FRAG_SPV = @embedFile("shaders/shadow_mask.frag.spv");
const VOL_COMPOSITE_FRAG_SPV = @embedFile("shaders/volumetric_composite.frag.spv");
const HIST_COMP_SPV = @embedFile("shaders/auto_exposure_hist.comp.spv");
const ADAPT_COMP_SPV = @embedFile("shaders/auto_exposure_adapt.comp.spv");
const BLOOM_DOWN_SPV = @embedFile("shaders/bloom_downsample.frag.spv");
const BLOOM_UP_SPV = @embedFile("shaders/bloom_upsample.frag.spv");
const POSTFX_FRAG_SPV = @embedFile("shaders/postfx.frag.spv");
const SSAO_FRAG_SPV = @embedFile("shaders/ssao.frag.spv");
const SSAO_BLUR_SPV = @embedFile("shaders/ssao_blur.frag.spv");
const VOL_FOG_SPV = @embedFile("shaders/volumetric_fog.frag.spv");

const SHADOW_W: u32 = 2048;
const SHADOW_H: u32 = 2048;
const BLOOM_MIPS: usize = 4;
const ENV_W: u32 = 128;
const ENV_H: u32 = 64;
const ENV_MIPS: u32 = 5;
const BRDF_LUT_SIZE: u32 = 128;

const PbrVertUniforms = extern struct {
    model: [16]f32,
    normal_matrix: [16]f32,
    mvp: [16]f32,
    light_vp: [4][16]f32,
};

const PbrFragUniforms = extern struct {
    camera_pos_fog: [4]f32,
    base_color: [4]f32,
    emissive_weight: [4]f32,
    mat_params: [4]f32,
    mat_flags: [4]f32,
    ambient_sky: [4]f32,
    fog_color_start: [4]f32,
    dir_light_dir: [4]f32,
    dir_light_col: [4]f32,
    point_pos: [4][4]f32,
    point_col: [4][4]f32,
    sky_zenith: [4]f32,
    sky_horizon: [4]f32,
    spot_pos: [2][4]f32,
    spot_dir: [2][4]f32,
    spot_col: [2][4]f32,
    sh_coeffs: [9][4]f32,
    camera_fwd_overlap: [4]f32,
    cascade_splits: [4]f32,
    cascade_depth_ranges: [4]f32,
    cluster_factors: [4]f32,
    probe_volumetric: [4]f32,
    cascade_info: [4]f32,
};

const SsaoParams = extern struct {
    proj: [16]f32,
    inv_proj: [16]f32,
    params: [4]f32,
    sun_view_dir: [4]f32,
    contact_params: [4]f32,
    fade_range: [4]f32,
};

/// Uniforms for `ssao_blur.frag`; layout must match its std140 block.
const SsaoBlurParams = extern struct {
    depth_range: [4]f32,
};

/// Uniforms for `volumetric_fog.frag`; field order must match its std140 block.
const VolFogParams = extern struct {
    inv_view_proj: [16]f32,
    light_vp: [4][16]f32,
    cam_pos_density: [4]f32,
    sun_dir_int: [4]f32,
    sun_col_aniso: [4]f32,
    fog_col_scat: [4]f32,
    cascade_splits: [4]f32,
    cam_fwd_maxd: [4]f32,
    spot_pos_range: [4][4]f32,
    spot_dir_cos: [4][4]f32,
    spot_col_on: [4][4]f32,
    spot_shadow: [4][4]f32,
    point_pos: [4][4]f32,
    point_col: [4][4]f32,
    point_shadow: [4][4]f32,
    local_vp: [16][16]f32,
    local_rect: [16][4]f32,
    cascade_info: [4]f32,
};

/// Uniforms for `volumetric_composite.frag`; layout must match its std140 block.
const VolCompositeParams = extern struct {
    inv_view_proj: [16]f32,
    cam_pos: [4]f32,
    vol_size_dist: [4]f32,
    fog_color_density: [4]f32,
};

const GpuPointLight = extern struct {
    pos_range: [4]f32 = .{ 0, 0, 0, 1 },
    col_radius: [4]f32 = .{ 0, 0, 0, -1 },
};

const GpuSpotLight = extern struct {
    pos_range: [4]f32 = .{ 0, 0, 0, 1 },
    dir_cos_inner: [4]f32 = .{ 0, -1, 0, 0.9 },
    col_cos_outer: [4]f32 = .{ 0, 0, 0, 0.8 },
    shadow_params: [4]f32 = .{ -1, 0.02, 0, 0 },
};

const GpuRectLight = extern struct {
    pos_range: [4]f32 = .{ 0, 0, 0, 1 },
    dir_two: [4]f32 = .{ 0, 0, -1, 0 },
    right_hx: [4]f32 = .{ 1, 0, 0, 1 },
    up_hy: [4]f32 = .{ 0, 1, 0, 0.5 },
    col_pad: [4]f32 = .{ 0, 0, 0, 0 },
};

const GpuReflectionProbe = extern struct {
    pos_int: [4]f32 = .{ 0, 0, 0, 0 },
    half_blend: [4]f32 = .{ 1, 1, 1, 1 },
    sky_box: [4]f32 = .{ 0, 0, 0, 1 },
    ground_pad: [4]f32 = .{ 0, 0, 0, 0 },
};

const ClusterLightsBuffer = extern struct {
    points: [256]GpuPointLight = @splat(.{}),
    spots: [256]GpuSpotLight = @splat(.{}),
    rects: [64]GpuRectLight = @splat(.{}),
    probes: [32]GpuReflectionProbe = @splat(.{}),
};

const LocalShadowBuffer = extern struct {
    shadow_vp: [16][16]f32 = @splat(math3d.Mat4.identity().m),
    atlas_rect: [16][4]f32 = @splat(.{ 0, 0, 0.25, 0.25 }),
};

const SkyUniforms = extern struct {
    inv_view_proj: [16]f32,
    sun_dir_size: [4]f32,
    sky_zenith_thick: [4]f32,
    sky_horizon_mode: [4]f32,
    ground_solid: [4]f32,
    sun_col_intensity: [4]f32,
    hdri_rotation: [4]f32,
};

/// Cheap content fingerprint of an HDRI: samples about 256 pixels spread over the image.
/// The cache compares pointers as well, but a buffer rewritten in place keeps its pointer.
fn hdriSampleHash(pixels: ?[]const [4]f32) u64 {
    const px = pixels orelse return 0;
    if (px.len == 0) return 0;
    var h: u64 = 0xcbf29ce484222325;
    const stride = @max(px.len / 256, 1);
    var i: usize = 0;
    while (i < px.len) : (i += stride) {
        for (px[i]) |v| {
            h = (h ^ @as(u64, @as(u32, @bitCast(v)))) *% 0x100000001b3;
        }
    }
    return h;
}

const HistParams = extern struct {
    range_params: [4]f32,
};

const AdaptParams = extern struct {
    ev_bounds: [4]f32,
    speed_dt: [4]f32,
    hist_range: [4]f32,
};

const BloomParams = extern struct {
    p: [4]f32,
};

const PostFxParams = extern struct {
    bloom_tint_int: [4]f32,
    grade_params: [4]f32,
    grade_tint_look: [4]f32,
    vignette_params: [4]f32,
    vignette_extra: [4]f32,
};

/// One entry of the lit-pass submission order, with the sort keys computed once per frame.
/// A GPU-to-CPU readback that has been recorded but whose submission has not completed yet.
const PendingCapture = struct {
    transfer: *c.SDL_GPUTransferBuffer,
    width: u32,
    height: u32,
    format: c.SDL_GPUTextureFormat,
};

const DrawOrderEntry = struct {
    index: u32,
    depth: f32,
    blend: bool,
    double_sided: bool,
};

/// Opaque draws first (front to back, double-sided last so single-sided batches stay together);
/// transparent draws after them, back to front. Ties fall back to submission order, so the order is deterministic.
fn drawOrderLess(_: void, a: DrawOrderEntry, b: DrawOrderEntry) bool {
    if (a.blend != b.blend) return !a.blend;
    if (a.blend) {
        if (a.depth != b.depth) return a.depth > b.depth;
        return a.index < b.index;
    }
    if (a.double_sided != b.double_sided) return !a.double_sided;
    if (a.depth != b.depth) return a.depth < b.depth;
    return a.index < b.index;
}

pub const QueuedPbrDraw = struct {
    mesh_asset: u64,
    model_matrix: [16]f32,
    mvp_matrix: [16]f32,
    material: pbr.StandardMaterial,
    tint: [4]f32,
};

pub const QueuedShadowCaster = struct {
    mesh_asset: u64,
    model_matrix: [16]f32,
};

/// Fragment uniforms for `shadow_mask.frag`; layout must match its std140 block.
const ShadowMaskParams = extern struct {
    base_color: [4]f32,
    params: [4]f32,
};

/// Which pass is consuming the queued material draws.
const ShadowDrawKind = enum {
    /// Directional cascade or local light tile: uses the light view-projection, includes shadow casters.
    light,
    /// Depth prepass for SSAO and contact shadows: uses the camera MVP, skips transparent materials.
    depth_prepass,
};

pub const PbrGpuState = struct {
    allocator: std.mem.Allocator,
    device: *c.SDL_GPUDevice,
    diag: *engine.Diagnostics,

    pbr_pipeline: *c.SDL_GPUGraphicsPipeline,
    pbr_double_sided_pipeline: *c.SDL_GPUGraphicsPipeline,
    pbr_blend_pipeline: *c.SDL_GPUGraphicsPipeline,
    sky_pipeline: *c.SDL_GPUGraphicsPipeline,
    shadow_pipeline: *c.SDL_GPUGraphicsPipeline,
    /// Opaque casters with culling disabled (double-sided materials cast from both sides).
    shadow_double_sided_pipeline: *c.SDL_GPUGraphicsPipeline,
    /// Alpha-masked casters: `shadow_mask.frag` discards holes using the material's base color texture.
    shadow_mask_pipeline: *c.SDL_GPUGraphicsPipeline,
    shadow_mask_double_sided_pipeline: *c.SDL_GPUGraphicsPipeline,
    ssao_pipeline: *c.SDL_GPUGraphicsPipeline,
    ssao_blur_pipeline: *c.SDL_GPUGraphicsPipeline,
    /// Ray-marches scattering into `vol_texture` (RGB in-scatter, A marched distance).
    volumetric_pipeline: *c.SDL_GPUGraphicsPipeline,
    /// Depth-aware upsample of `vol_texture` into the HDR target, additive.
    volumetric_composite_pipeline: *c.SDL_GPUGraphicsPipeline,
    /// Multiplies the HDR scene by the per-pixel transmittance T (`dst *= T`) before the scatter is added.
    volumetric_transmittance_pipeline: *c.SDL_GPUGraphicsPipeline,
    bloom_down_pipeline: *c.SDL_GPUGraphicsPipeline,
    bloom_up_pipeline: *c.SDL_GPUGraphicsPipeline,
    postfx_pipeline: *c.SDL_GPUGraphicsPipeline,
    hist_pipeline: *c.SDL_GPUComputePipeline,
    adapt_pipeline: *c.SDL_GPUComputePipeline,

    shadow_texture: *c.SDL_GPUTexture,
    local_shadow_texture: *c.SDL_GPUTexture,
    exposure_texture: *c.SDL_GPUTexture,
    flat_normal_texture: *c.SDL_GPUTexture,
    black_texture: *c.SDL_GPUTexture,
    brdf_lut_texture: *c.SDL_GPUTexture,
    env_prefilter_texture: *c.SDL_GPUTexture,
    hdri_sky_texture: ?*c.SDL_GPUTexture = null,
    last_hdri_ptr: usize = 0,
    last_hdri_hash: u64 = 0,
    last_hdri_rot: f32 = 0.0,
    last_sun_size: f32 = 0.0,
    last_sun_disk: pbr.SunDisk = .none,
    shadow_sampler: *c.SDL_GPUSampler,
    /// Material textures: repeat addressing so UVs past [0, 1] tile instead of smearing the edge texel.
    material_sampler: *c.SDL_GPUSampler,
    ibl_sampler: *c.SDL_GPUSampler,
    histogram_buffer: *c.SDL_GPUBuffer,
    cluster_lights_buffer: *c.SDL_GPUBuffer,
    cluster_grid_buffer: *c.SDL_GPUBuffer,
    cluster_indices_buffer: *c.SDL_GPUBuffer,
    local_shadow_buffer: *c.SDL_GPUBuffer,
    cluster_transfer_buffer: *c.SDL_GPUTransferBuffer,

    sky_sh: ibl.SkyDiffuseSH = .{},
    ibl_initialized: bool = false,
    last_sun_dir: [3]f32 = .{ 0, 0, 0 },
    last_sun_col: [3]f32 = .{ 0, 0, 0 },
    last_sun_int: f32 = -1.0,
    last_sky_kind: pbr.SkyboxKind = .procedural,
    last_sky_tint: [3]f32 = .{ 0, 0, 0 },
    last_horizon_tint: [3]f32 = .{ 0, 0, 0 },
    last_ground_albedo: [3]f32 = .{ 0, 0, 0 },
    last_solid_color: [3]f32 = .{ 0, 0, 0 },
    last_atmo_thick: f32 = -1.0,
    last_hdri_ev: f32 = 0.0,

    hdr_texture: ?*c.SDL_GPUTexture = null,
    ssao_texture: ?*c.SDL_GPUTexture = null,
    /// Volumetric scatter target; resolution follows `VolumetricFogConfig.half_resolution`.
    vol_texture: ?*c.SDL_GPUTexture = null,
    vol_w: u32 = 0,
    vol_h: u32 = 0,
    ssao_blur_texture: ?*c.SDL_GPUTexture = null,
    hdr_w: u32 = 0,
    hdr_h: u32 = 0,
    bloom_textures: [BLOOM_MIPS]?*c.SDL_GPUTexture = @splat(null),
    bloom_sizes: [BLOOM_MIPS][2]u32 = @splat(.{ 0, 0 }),

    queued_draws: std.ArrayList(QueuedPbrDraw) = .empty,
    /// Format of the swapchain, needed to read a final-frame capture back correctly.
    swapchain_format: c.SDL_GPUTextureFormat = c.SDL_GPU_TEXTUREFORMAT_INVALID,
    /// Pending request for the next frame, consumed by `renderFrame`.
    capture_request: ?capture.Target = null,
    /// Offscreen copy of the final frame (without the 2D overlay); only allocated while captures are used.
    capture_final_tex: ?*c.SDL_GPUTexture = null,
    capture_final_w: u32 = 0,
    capture_final_h: u32 = 0,
    capture_pending: ?PendingCapture = null,
    capture_result: ?capture.Image = null,
    /// Reused across frames so cluster construction does not allocate in steady state.
    cluster_scratch: cluster.ClusterScratch = .{},
    /// Lit-pass submission order, rebuilt every frame; reused to avoid per-frame allocation.
    draw_order: std.ArrayList(DrawOrderEntry) = .empty,
    /// Last reported dropped-reference count, to log budget overflow on change only.
    last_cluster_drops: u32 = 0,
    shadow_casters: std.ArrayList(QueuedShadowCaster) = .empty,
    frame_active: bool = false,
    frame_data: pbr.ExtractedPbrFrame = .{},
    dir_lights_copy: std.ArrayList(pbr.ExtractedDirectionalLight) = .empty,
    point_lights_copy: std.ArrayList(pbr.ExtractedPointLight) = .empty,
    spot_lights_copy: std.ArrayList(pbr.ExtractedSpotLight) = .empty,
    rect_lights_copy: std.ArrayList(pbr.ExtractedRectLight) = .empty,
    reflection_probes_copy: std.ArrayList(pbr.ExtractedReflectionProbe) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        device: *c.SDL_GPUDevice,
        diag: *engine.Diagnostics,
        swapchain_format: c.SDL_GPUTextureFormat,
        depth_format: c.SDL_GPUTextureFormat,
    ) !PbrGpuState {
        const hdr_format = c.SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT;
        const ao_format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;

        const pbr_vs = try createShader(device, diag, c.SDL_GPU_SHADERSTAGE_VERTEX, PBR_VERT_SPV, 0, 1);
        defer c.SDL_ReleaseGPUShader(device, pbr_vs);
        const pbr_fs = try createShaderEx(device, diag, c.SDL_GPU_SHADERSTAGE_FRAGMENT, PBR_FRAG_SPV, 10, 4, 1);
        defer c.SDL_ReleaseGPUShader(device, pbr_fs);
        const pbr_pipe = try createMeshPbrPipeline(device, pbr_vs, pbr_fs, hdr_format, depth_format, false, false);
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, pbr_pipe);
        const pbr_ds_pipe = try createMeshPbrPipeline(device, pbr_vs, pbr_fs, hdr_format, depth_format, true, false);
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, pbr_ds_pipe);
        const pbr_blend_pipe = try createMeshPbrPipeline(device, pbr_vs, pbr_fs, hdr_format, depth_format, true, true);
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, pbr_blend_pipe);

        const sky_vs = try createShader(device, diag, c.SDL_GPU_SHADERSTAGE_VERTEX, SKY_VERT_SPV, 0, 0);
        defer c.SDL_ReleaseGPUShader(device, sky_vs);
        const sky_fs = try createShader(device, diag, c.SDL_GPU_SHADERSTAGE_FRAGMENT, SKY_FRAG_SPV, 1, 1);
        defer c.SDL_ReleaseGPUShader(device, sky_fs);
        const sky_pipe = try createFullscreenPipeline(device, sky_vs, sky_fs, hdr_format, false);
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, sky_pipe);

        const sh_vs = try createShader(device, diag, c.SDL_GPU_SHADERSTAGE_VERTEX, SHADOW_VERT_SPV, 0, 1);
        defer c.SDL_ReleaseGPUShader(device, sh_vs);
        const sh_fs = try createShader(device, diag, c.SDL_GPU_SHADERSTAGE_FRAGMENT, SHADOW_FRAG_SPV, 0, 0);
        defer c.SDL_ReleaseGPUShader(device, sh_fs);
        const sh_pipe = try createShadowPipeline(device, sh_vs, sh_fs, depth_format, false);
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, sh_pipe);
        const sh_ds_pipe = try createShadowPipeline(device, sh_vs, sh_fs, depth_format, true);
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, sh_ds_pipe);

        const sh_mask_fs = try createShader(device, diag, c.SDL_GPU_SHADERSTAGE_FRAGMENT, SHADOW_MASK_FRAG_SPV, 1, 1);
        defer c.SDL_ReleaseGPUShader(device, sh_mask_fs);
        const sh_mask_pipe = try createShadowPipeline(device, sh_vs, sh_mask_fs, depth_format, false);
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, sh_mask_pipe);
        const sh_mask_ds_pipe = try createShadowPipeline(device, sh_vs, sh_mask_fs, depth_format, true);
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, sh_mask_ds_pipe);

        const ssao_fs = try createShader(device, diag, c.SDL_GPU_SHADERSTAGE_FRAGMENT, SSAO_FRAG_SPV, 1, 1);
        defer c.SDL_ReleaseGPUShader(device, ssao_fs);
        const ssao_pipe = try createFullscreenPipeline(device, sky_vs, ssao_fs, ao_format, false);
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, ssao_pipe);

        const ssao_blur_fs = try createShader(device, diag, c.SDL_GPU_SHADERSTAGE_FRAGMENT, SSAO_BLUR_SPV, 2, 1);
        defer c.SDL_ReleaseGPUShader(device, ssao_blur_fs);
        const ssao_blur_pipe = try createFullscreenPipeline(device, sky_vs, ssao_blur_fs, ao_format, false);
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, ssao_blur_pipe);

        const vol_fs = try createShader(device, diag, c.SDL_GPU_SHADERSTAGE_FRAGMENT, VOL_FOG_SPV, 3, 1);
        defer c.SDL_ReleaseGPUShader(device, vol_fs);
        // Raymarch writes into a cleared target, so it does not need additive blending.
        const vol_pipe = try createFullscreenPipeline(device, sky_vs, vol_fs, hdr_format, false);
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, vol_pipe);

        const vol_comp_fs = try createShader(device, diag, c.SDL_GPU_SHADERSTAGE_FRAGMENT, VOL_COMPOSITE_FRAG_SPV, 2, 1);
        defer c.SDL_ReleaseGPUShader(device, vol_comp_fs);
        const vol_comp_pipe = try createFullscreenPipeline(device, sky_vs, vol_comp_fs, hdr_format, true);
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, vol_comp_pipe);
        const vol_trans_pipe = try createMultiplyFullscreenPipeline(device, sky_vs, vol_comp_fs, hdr_format);
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, vol_trans_pipe);

        const bd_fs = try createShader(device, diag, c.SDL_GPU_SHADERSTAGE_FRAGMENT, BLOOM_DOWN_SPV, 1, 1);
        defer c.SDL_ReleaseGPUShader(device, bd_fs);
        const bd_pipe = try createFullscreenPipeline(device, sky_vs, bd_fs, hdr_format, false);
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, bd_pipe);

        const bu_fs = try createShader(device, diag, c.SDL_GPU_SHADERSTAGE_FRAGMENT, BLOOM_UP_SPV, 1, 1);
        defer c.SDL_ReleaseGPUShader(device, bu_fs);
        const bu_pipe = try createFullscreenPipeline(device, sky_vs, bu_fs, hdr_format, true);
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, bu_pipe);

        const pf_fs = try createShader(device, diag, c.SDL_GPU_SHADERSTAGE_FRAGMENT, POSTFX_FRAG_SPV, 3, 1);
        defer c.SDL_ReleaseGPUShader(device, pf_fs);
        const pf_pipe = try createFullscreenPipeline(device, sky_vs, pf_fs, swapchain_format, false);
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, pf_pipe);

        const hist_pipe = try createComputePipeline(device, HIST_COMP_SPV, 1, 0, 1, 1);
        errdefer c.SDL_ReleaseGPUComputePipeline(device, hist_pipe);
        const adapt_pipe = try createComputePipeline(device, ADAPT_COMP_SPV, 0, 1, 1, 1);
        errdefer c.SDL_ReleaseGPUComputePipeline(device, adapt_pipe);

        const shadow_tex = c.SDL_CreateGPUTexture(device, &std.mem.zeroInit(c.SDL_GPUTextureCreateInfo, .{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = depth_format,
            .usage = c.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET | c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = SHADOW_W,
            .height = SHADOW_H,
            .layer_count_or_depth = 1,
            .num_levels = 1,
        })) orelse return error.SdlGpuFailure;
        errdefer c.SDL_ReleaseGPUTexture(device, shadow_tex);

        const local_shadow_tex = c.SDL_CreateGPUTexture(device, &std.mem.zeroInit(c.SDL_GPUTextureCreateInfo, .{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = depth_format,
            .usage = c.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET | c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = 2048,
            .height = 2048,
            .layer_count_or_depth = 1,
            .num_levels = 1,
        })) orelse return error.SdlGpuFailure;
        errdefer c.SDL_ReleaseGPUTexture(device, local_shadow_tex);

        const exp_tex = c.SDL_CreateGPUTexture(device, &std.mem.zeroInit(c.SDL_GPUTextureCreateInfo, .{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = c.SDL_GPU_TEXTUREFORMAT_R32_FLOAT,
            .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER | c.SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_WRITE,
            .width = 1,
            .height = 1,
            .layer_count_or_depth = 1,
            .num_levels = 1,
        })) orelse return error.SdlGpuFailure;
        errdefer c.SDL_ReleaseGPUTexture(device, exp_tex);

        const flat_n = try upload1x1(device, .{ 128, 128, 255, 255 });
        errdefer c.SDL_ReleaseGPUTexture(device, flat_n);
        const black_t = try upload1x1(device, .{ 0, 0, 0, 255 });
        errdefer c.SDL_ReleaseGPUTexture(device, black_t);

        const brdf_lut = try uploadBrdfLut(allocator, device, BRDF_LUT_SIZE);
        errdefer c.SDL_ReleaseGPUTexture(device, brdf_lut);

        const env_tex = c.SDL_CreateGPUTexture(device, &std.mem.zeroInit(c.SDL_GPUTextureCreateInfo, .{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = hdr_format,
            .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = ENV_W,
            .height = ENV_H,
            .layer_count_or_depth = 1,
            .num_levels = ENV_MIPS,
        })) orelse return error.SdlGpuFailure;
        errdefer c.SDL_ReleaseGPUTexture(device, env_tex);

        const shadow_smp = c.SDL_CreateGPUSampler(device, &std.mem.zeroInit(c.SDL_GPUSamplerCreateInfo, .{
            .min_filter = c.SDL_GPU_FILTER_LINEAR,
            .mag_filter = c.SDL_GPU_FILTER_LINEAR,
            .mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST,
            .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .compare_op = c.SDL_GPU_COMPAREOP_LESS_OR_EQUAL,
            .enable_compare = true,
        })) orelse return error.SdlGpuFailure;
        errdefer c.SDL_ReleaseGPUSampler(device, shadow_smp);

        const material_smp = c.SDL_CreateGPUSampler(device, &std.mem.zeroInit(c.SDL_GPUSamplerCreateInfo, .{
            .min_filter = c.SDL_GPU_FILTER_LINEAR,
            .mag_filter = c.SDL_GPU_FILTER_LINEAR,
            .mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_LINEAR,
            .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_REPEAT,
            .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_REPEAT,
            .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_REPEAT,
            .max_anisotropy = 8.0,
            .enable_anisotropy = true,
            .max_lod = 16.0,
        })) orelse return error.SdlGpuFailure;
        errdefer c.SDL_ReleaseGPUSampler(device, material_smp);

        const ibl_smp = c.SDL_CreateGPUSampler(device, &std.mem.zeroInit(c.SDL_GPUSamplerCreateInfo, .{
            .min_filter = c.SDL_GPU_FILTER_LINEAR,
            .mag_filter = c.SDL_GPU_FILTER_LINEAR,
            .mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_LINEAR,
            .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_REPEAT,
            .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .max_lod = 16.0,
        })) orelse return error.SdlGpuFailure;
        errdefer c.SDL_ReleaseGPUSampler(device, ibl_smp);

        const hist_buf = c.SDL_CreateGPUBuffer(device, &std.mem.zeroInit(c.SDL_GPUBufferCreateInfo, .{
            .usage = c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ | c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE,
            .size = 66 * 4,
        })) orelse return error.SdlGpuFailure;
        try zeroBuffer(device, hist_buf, 66 * 4);

        const cl_lights_buf = c.SDL_CreateGPUBuffer(device, &std.mem.zeroInit(c.SDL_GPUBufferCreateInfo, .{
            .usage = c.SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ,
            .size = @sizeOf(ClusterLightsBuffer),
        })) orelse return error.SdlGpuFailure;
        errdefer c.SDL_ReleaseGPUBuffer(device, cl_lights_buf);

        const cl_grid_buf = c.SDL_CreateGPUBuffer(device, &std.mem.zeroInit(c.SDL_GPUBufferCreateInfo, .{
            .usage = c.SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ,
            .size = @as(u32, @intCast(cluster.CLUSTER_COUNT * @sizeOf(cluster.ClusterEntry))),
        })) orelse return error.SdlGpuFailure;
        errdefer c.SDL_ReleaseGPUBuffer(device, cl_grid_buf);

        const cl_indices_buf = c.SDL_CreateGPUBuffer(device, &std.mem.zeroInit(c.SDL_GPUBufferCreateInfo, .{
            .usage = c.SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ,
            .size = 65536 * 4,
        })) orelse return error.SdlGpuFailure;
        errdefer c.SDL_ReleaseGPUBuffer(device, cl_indices_buf);

        const local_sh_buf = c.SDL_CreateGPUBuffer(device, &std.mem.zeroInit(c.SDL_GPUBufferCreateInfo, .{
            .usage = c.SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ,
            .size = @sizeOf(LocalShadowBuffer),
        })) orelse return error.SdlGpuFailure;
        errdefer c.SDL_ReleaseGPUBuffer(device, local_sh_buf);

        // Single persistent staging buffer for all per-frame cluster & local shadow uploads.
        const total_staging_bytes: u32 = @intCast(@sizeOf(ClusterLightsBuffer) + cluster.CLUSTER_COUNT * @sizeOf(cluster.ClusterEntry) + 65536 * 4 + @sizeOf(LocalShadowBuffer));
        const cl_tb = c.SDL_CreateGPUTransferBuffer(device, &std.mem.zeroInit(c.SDL_GPUTransferBufferCreateInfo, .{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = total_staging_bytes,
        })) orelse return error.SdlGpuFailure;
        errdefer c.SDL_ReleaseGPUTransferBuffer(device, cl_tb);

        return .{
            .allocator = allocator,
            .device = device,
            .diag = diag,
            .swapchain_format = swapchain_format,
            .pbr_pipeline = pbr_pipe,
            .pbr_double_sided_pipeline = pbr_ds_pipe,
            .pbr_blend_pipeline = pbr_blend_pipe,
            .sky_pipeline = sky_pipe,
            .shadow_pipeline = sh_pipe,
            .shadow_double_sided_pipeline = sh_ds_pipe,
            .shadow_mask_pipeline = sh_mask_pipe,
            .shadow_mask_double_sided_pipeline = sh_mask_ds_pipe,
            .ssao_pipeline = ssao_pipe,
            .ssao_blur_pipeline = ssao_blur_pipe,
            .volumetric_pipeline = vol_pipe,
            .volumetric_composite_pipeline = vol_comp_pipe,
            .volumetric_transmittance_pipeline = vol_trans_pipe,
            .bloom_down_pipeline = bd_pipe,
            .bloom_up_pipeline = bu_pipe,
            .postfx_pipeline = pf_pipe,
            .hist_pipeline = hist_pipe,
            .adapt_pipeline = adapt_pipe,
            .shadow_texture = shadow_tex,
            .local_shadow_texture = local_shadow_tex,
            .exposure_texture = exp_tex,
            .flat_normal_texture = flat_n,
            .black_texture = black_t,
            .brdf_lut_texture = brdf_lut,
            .env_prefilter_texture = env_tex,
            .shadow_sampler = shadow_smp,
            .material_sampler = material_smp,
            .ibl_sampler = ibl_smp,
            .histogram_buffer = hist_buf,
            .cluster_lights_buffer = cl_lights_buf,
            .cluster_grid_buffer = cl_grid_buf,
            .cluster_indices_buffer = cl_indices_buf,
            .local_shadow_buffer = local_sh_buf,
            .cluster_transfer_buffer = cl_tb,
        };
    }

    pub fn deinit(self: *PbrGpuState) void {
        self.queued_draws.deinit(self.allocator);
        self.cluster_scratch.deinit(self.allocator);
        if (self.capture_pending) |p| c.SDL_ReleaseGPUTransferBuffer(self.device, p.transfer);
        if (self.capture_result) |*img| img.deinit(self.allocator);
        if (self.capture_final_tex) |t| c.SDL_ReleaseGPUTexture(self.device, t);
        self.draw_order.deinit(self.allocator);
        self.shadow_casters.deinit(self.allocator);
        self.dir_lights_copy.deinit(self.allocator);
        self.point_lights_copy.deinit(self.allocator);
        self.spot_lights_copy.deinit(self.allocator);
        self.rect_lights_copy.deinit(self.allocator);
        self.reflection_probes_copy.deinit(self.allocator);

        if (self.hdr_texture) |t| c.SDL_ReleaseGPUTexture(self.device, t);
        if (self.vol_texture) |t| c.SDL_ReleaseGPUTexture(self.device, t);
        if (self.ssao_texture) |t| c.SDL_ReleaseGPUTexture(self.device, t);
        if (self.ssao_blur_texture) |t| c.SDL_ReleaseGPUTexture(self.device, t);
        if (self.hdri_sky_texture) |t| c.SDL_ReleaseGPUTexture(self.device, t);
        for (self.bloom_textures) |bt| if (bt) |t| c.SDL_ReleaseGPUTexture(self.device, t);
        c.SDL_ReleaseGPUTransferBuffer(self.device, self.cluster_transfer_buffer);
        c.SDL_ReleaseGPUBuffer(self.device, self.local_shadow_buffer);
        c.SDL_ReleaseGPUBuffer(self.device, self.cluster_indices_buffer);
        c.SDL_ReleaseGPUBuffer(self.device, self.cluster_grid_buffer);
        c.SDL_ReleaseGPUBuffer(self.device, self.cluster_lights_buffer);
        c.SDL_ReleaseGPUBuffer(self.device, self.histogram_buffer);
        c.SDL_ReleaseGPUSampler(self.device, self.ibl_sampler);
        c.SDL_ReleaseGPUSampler(self.device, self.shadow_sampler);
        c.SDL_ReleaseGPUSampler(self.device, self.material_sampler);
        c.SDL_ReleaseGPUTexture(self.device, self.env_prefilter_texture);
        c.SDL_ReleaseGPUTexture(self.device, self.brdf_lut_texture);
        c.SDL_ReleaseGPUTexture(self.device, self.black_texture);
        c.SDL_ReleaseGPUTexture(self.device, self.flat_normal_texture);
        c.SDL_ReleaseGPUTexture(self.device, self.exposure_texture);
        c.SDL_ReleaseGPUTexture(self.device, self.local_shadow_texture);
        c.SDL_ReleaseGPUTexture(self.device, self.shadow_texture);

        c.SDL_ReleaseGPUComputePipeline(self.device, self.adapt_pipeline);
        c.SDL_ReleaseGPUComputePipeline(self.device, self.hist_pipeline);
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.postfx_pipeline);
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.bloom_up_pipeline);
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.bloom_down_pipeline);
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.volumetric_transmittance_pipeline);
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.volumetric_composite_pipeline);
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.volumetric_pipeline);
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.ssao_blur_pipeline);
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.ssao_pipeline);
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.shadow_mask_double_sided_pipeline);
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.shadow_mask_pipeline);
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.shadow_double_sided_pipeline);
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.shadow_pipeline);
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.sky_pipeline);
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.pbr_blend_pipeline);
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.pbr_double_sided_pipeline);
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, self.pbr_pipeline);
    }

    pub fn vtable(self: *PbrGpuState) pbr.PbrBackendVTable {
        return .{
            .ctx = self,
            .beginPbrFrame = beginPbrFrame,
            .submitLitMesh = submitLitMesh,
            .submitShadowCaster = submitShadowCaster,
            .endPbrFrame = endPbrFrame,
        };
    }

    fn beginPbrFrame(raw: *anyopaque, frame: *const pbr.ExtractedPbrFrame) anyerror!void {
        const self: *PbrGpuState = @ptrCast(@alignCast(raw));
        self.queued_draws.clearRetainingCapacity();
        self.shadow_casters.clearRetainingCapacity();
        self.dir_lights_copy.clearRetainingCapacity();
        self.point_lights_copy.clearRetainingCapacity();
        self.spot_lights_copy.clearRetainingCapacity();
        self.rect_lights_copy.clearRetainingCapacity();
        self.reflection_probes_copy.clearRetainingCapacity();
        try self.dir_lights_copy.appendSlice(self.allocator, frame.directional_lights);
        try self.point_lights_copy.appendSlice(self.allocator, frame.point_lights);
        try self.spot_lights_copy.appendSlice(self.allocator, frame.spot_lights);
        try self.rect_lights_copy.appendSlice(self.allocator, frame.rect_lights);
        try self.reflection_probes_copy.appendSlice(self.allocator, frame.reflection_probes);
        self.frame_data = frame.*;
        self.frame_data.directional_lights = self.dir_lights_copy.items;
        self.frame_data.point_lights = self.point_lights_copy.items;
        self.frame_data.spot_lights = self.spot_lights_copy.items;
        self.frame_data.rect_lights = self.rect_lights_copy.items;
        self.frame_data.reflection_probes = self.reflection_probes_copy.items;
        self.frame_active = true;
    }

    fn submitLitMesh(
        raw: *anyopaque,
        mesh_asset: u64,
        model_matrix: [16]f32,
        mvp_matrix: [16]f32,
        material: pbr.StandardMaterial,
        tint: [4]f32,
    ) anyerror!void {
        const self: *PbrGpuState = @ptrCast(@alignCast(raw));
        try self.queued_draws.append(self.allocator, .{
            .mesh_asset = mesh_asset,
            .model_matrix = model_matrix,
            .mvp_matrix = mvp_matrix,
            .material = material,
            .tint = tint,
        });
    }

    fn submitShadowCaster(raw: *anyopaque, mesh_asset: u64, model_matrix: [16]f32) anyerror!void {
        const self: *PbrGpuState = @ptrCast(@alignCast(raw));
        try self.shadow_casters.append(self.allocator, .{
            .mesh_asset = mesh_asset,
            .model_matrix = model_matrix,
        });
    }

    /// Picks the shadow-family pipeline for a queued material: alpha masks sample the base color, double-sided disables culling.
    fn shadowPipelineFor(self: *const PbrGpuState, mat: pbr.StandardMaterial) *c.SDL_GPUGraphicsPipeline {
        if (mat.alpha_mode == .mask) {
            return if (mat.double_sided) self.shadow_mask_double_sided_pipeline else self.shadow_mask_pipeline;
        }
        return if (mat.double_sided) self.shadow_double_sided_pipeline else self.shadow_pipeline;
    }

    /// Draws queued materials (and, for `.light`, untyped shadow casters) into an open depth-only pass.
    /// Pipelines and alpha-mask parameters are bound per draw; callers only set viewport and scissor.
    fn drawShadowQueue(
        self: *PbrGpuState,
        cmd_buf: *c.SDL_GPUCommandBuffer,
        pass: *c.SDL_GPURenderPass,
        kind: ShadowDrawKind,
        light_vp: math3d.Mat4,
        meshes: anytype,
        textures: anytype,
        white_tex: *c.SDL_GPUTexture,
        sampler: *c.SDL_GPUSampler,
    ) void {
        var active: ?*c.SDL_GPUGraphicsPipeline = null;
        for (self.queued_draws.items) |qm| {
            // Transparent surfaces must not write depth in the prepass, or SSAO and contact shadows treat them as solid.
            if (kind == .depth_prepass and qm.material.alpha_mode == .blend) continue;
            const gm = meshes.get(@bitCast(qm.mesh_asset)) orelse continue;
            // Casters fully outside this light's frustum cannot put a shadow inside it.
            if (kind == .light and shadow_cull.sphereOutsideLightFrustum(light_vp.m, shadow_cull.transformSphere(qm.model_matrix, gm.bounds))) continue;
            const pipe = self.shadowPipelineFor(qm.material);
            if (active != pipe) {
                c.SDL_BindGPUGraphicsPipeline(pass, pipe);
                active = pipe;
            }
            if (qm.material.alpha_mode == .mask) {
                const base_t = if (qm.material.base_color_tex != 0) (textures.get(@bitCast(qm.material.base_color_tex)) orelse white_tex) else white_tex;
                const samplers = [_]c.SDL_GPUTextureSamplerBinding{.{ .texture = base_t, .sampler = sampler }};
                c.SDL_BindGPUFragmentSamplers(pass, 0, &samplers, samplers.len);
                // Same alpha inputs as pbr.frag (base color * tint, texture alpha) so casters match what is shaded.
                const mask_params = ShadowMaskParams{
                    .base_color = .{
                        qm.material.base_color[0] * qm.tint[0],
                        qm.material.base_color[1] * qm.tint[1],
                        qm.material.base_color[2] * qm.tint[2],
                        qm.material.base_color[3] * qm.tint[3],
                    },
                    .params = .{ qm.material.alpha_cutoff, 0, 0, 0 },
                };
                c.SDL_PushGPUFragmentUniformData(cmd_buf, 0, &mask_params, @sizeOf(ShadowMaskParams));
            }
            const mvp: [16]f32 = switch (kind) {
                .light => math3d.Mat4.mul(light_vp, .{ .m = qm.model_matrix }).m,
                .depth_prepass => qm.mvp_matrix,
            };
            c.SDL_BindGPUVertexBuffers(pass, 0, &.{ .buffer = gm.vertex_buffer, .offset = 0 }, 1);
            c.SDL_BindGPUIndexBuffer(pass, &.{ .buffer = gm.index_buffer, .offset = 0 }, c.SDL_GPU_INDEXELEMENTSIZE_32BIT);
            c.SDL_PushGPUVertexUniformData(cmd_buf, 0, &mvp, @sizeOf([16]f32));
            c.SDL_DrawGPUIndexedPrimitives(pass, gm.index_count, 1, 0, 0, 0);
        }
        if (kind != .light) return;

        for (self.shadow_casters.items) |sc| {
            const gm = meshes.get(@bitCast(sc.mesh_asset)) orelse continue;
            if (shadow_cull.sphereOutsideLightFrustum(light_vp.m, shadow_cull.transformSphere(sc.model_matrix, gm.bounds))) continue;
            // Casters carry no material, so they always use the opaque, back-face-culled pipeline.
            if (active != self.shadow_pipeline) {
                c.SDL_BindGPUGraphicsPipeline(pass, self.shadow_pipeline);
                active = self.shadow_pipeline;
            }
            const lmvp = math3d.Mat4.mul(light_vp, .{ .m = sc.model_matrix });
            c.SDL_BindGPUVertexBuffers(pass, 0, &.{ .buffer = gm.vertex_buffer, .offset = 0 }, 1);
            c.SDL_BindGPUIndexBuffer(pass, &.{ .buffer = gm.index_buffer, .offset = 0 }, c.SDL_GPU_INDEXELEMENTSIZE_32BIT);
            c.SDL_PushGPUVertexUniformData(cmd_buf, 0, &lmvp.m, @sizeOf([16]f32));
            c.SDL_DrawGPUIndexedPrimitives(pass, gm.index_count, 1, 0, 0, 0);
        }
    }

    fn endPbrFrame(_: *anyopaque) anyerror!void {}

    /// Keeps the volumetric scatter target at `w x h`, recreating it only when the size changes.
    fn ensureVolumetricTarget(self: *PbrGpuState, w: u32, h: u32) !void {
        if (self.vol_texture != null and self.vol_w == w and self.vol_h == h) return;
        const new_vol = c.SDL_CreateGPUTexture(self.device, &std.mem.zeroInit(c.SDL_GPUTextureCreateInfo, .{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = c.SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT,
            .usage = c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = w,
            .height = h,
            .layer_count_or_depth = 1,
            .num_levels = 1,
        })) orelse return error.SdlGpuFailure;
        if (self.vol_texture) |t| c.SDL_ReleaseGPUTexture(self.device, t);
        self.vol_texture = new_vol;
        self.vol_w = w;
        self.vol_h = h;
    }

    fn ensureHdrTargets(self: *PbrGpuState, w: u32, h: u32) !void {
        if (self.hdr_texture == null or self.hdr_w != w or self.hdr_h != h) {
            const new_hdr = c.SDL_CreateGPUTexture(self.device, &std.mem.zeroInit(c.SDL_GPUTextureCreateInfo, .{
                .type = c.SDL_GPU_TEXTURETYPE_2D,
                .format = c.SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT,
                .usage = c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
                .width = w,
                .height = h,
                .layer_count_or_depth = 1,
                .num_levels = 1,
            })) orelse return error.SdlGpuFailure;
            errdefer c.SDL_ReleaseGPUTexture(self.device, new_hdr);

            const ao_w = @max(w / 2, 1);
            const ao_h = @max(h / 2, 1);
            const new_ssao = c.SDL_CreateGPUTexture(self.device, &std.mem.zeroInit(c.SDL_GPUTextureCreateInfo, .{
                .type = c.SDL_GPU_TEXTURETYPE_2D,
                .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
                .usage = c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
                .width = ao_w,
                .height = ao_h,
                .layer_count_or_depth = 1,
                .num_levels = 1,
            })) orelse return error.SdlGpuFailure;
            errdefer c.SDL_ReleaseGPUTexture(self.device, new_ssao);

            const new_ssao_blur = c.SDL_CreateGPUTexture(self.device, &std.mem.zeroInit(c.SDL_GPUTextureCreateInfo, .{
                .type = c.SDL_GPU_TEXTURETYPE_2D,
                .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
                .usage = c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
                .width = w,
                .height = h,
                .layer_count_or_depth = 1,
                .num_levels = 1,
            })) orelse return error.SdlGpuFailure;
            errdefer c.SDL_ReleaseGPUTexture(self.device, new_ssao_blur);

            var new_blooms: [BLOOM_MIPS]?*c.SDL_GPUTexture = @splat(null);
            var new_sizes: [BLOOM_MIPS][2]u32 = undefined;
            errdefer for (new_blooms) |bt| if (bt) |t| c.SDL_ReleaseGPUTexture(self.device, t);
            var mw = @max(w / 2, 1);
            var mh = @max(h / 2, 1);
            for (0..BLOOM_MIPS) |i| {
                new_blooms[i] = c.SDL_CreateGPUTexture(self.device, &std.mem.zeroInit(c.SDL_GPUTextureCreateInfo, .{
                    .type = c.SDL_GPU_TEXTURETYPE_2D,
                    .format = c.SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT,
                    .usage = c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
                    .width = mw,
                    .height = mh,
                    .layer_count_or_depth = 1,
                    .num_levels = 1,
                })) orelse return error.SdlGpuFailure;
                new_sizes[i] = .{ mw, mh };
                mw = @max(mw / 2, 1);
                mh = @max(mh / 2, 1);
            }

            if (self.hdr_texture) |t| c.SDL_ReleaseGPUTexture(self.device, t);
            if (self.ssao_texture) |t| c.SDL_ReleaseGPUTexture(self.device, t);
            if (self.ssao_blur_texture) |t| c.SDL_ReleaseGPUTexture(self.device, t);
            for (self.bloom_textures) |bt| if (bt) |t| c.SDL_ReleaseGPUTexture(self.device, t);

            self.hdr_texture = new_hdr;
            self.hdr_w = w;
            self.hdr_h = h;
            self.ssao_texture = new_ssao;
            self.ssao_blur_texture = new_ssao_blur;
            self.bloom_textures = new_blooms;
            self.bloom_sizes = new_sizes;
        }
    }

    pub fn renderFrame(
        self: *PbrGpuState,
        cmd_buf: *c.SDL_GPUCommandBuffer,
        target_tex: *c.SDL_GPUTexture,
        depth_tex: *c.SDL_GPUTexture,
        tex_w: u32,
        tex_h: u32,
        white_tex: *c.SDL_GPUTexture,
        linear_sampler: *c.SDL_GPUSampler,
        nearest_sampler: *c.SDL_GPUSampler,
        meshes: anytype,
        textures: anytype,
    ) !void {
        defer {
            self.queued_draws.clearRetainingCapacity();
            self.shadow_casters.clearRetainingCapacity();
            self.frame_active = false;
        }
        try self.ensureHdrTargets(tex_w, tex_h);
        const hdr_tex = self.hdr_texture.?;
        const pp = self.frame_data.post_process;

        const sun_dir: [3]f32 = if (self.frame_data.directional_lights.len > 0)
            .{ -self.frame_data.directional_lights[0].direction[0], -self.frame_data.directional_lights[0].direction[1], -self.frame_data.directional_lights[0].direction[2] }
        else
            .{ 0.4, 0.8, 0.45 };
        const sun_col: [3]f32 = if (self.frame_data.directional_lights.len > 0)
            self.frame_data.directional_lights[0].color
        else
            .{ 1.0, 0.96, 0.90 };
        const sun_int: f32 = if (self.frame_data.directional_lights.len > 0)
            self.frame_data.directional_lights[0].illuminance_lux / 10_000.0
        else
            1.0;

        // 0. Rebuild equirectangular IBL + SH9 when sun, sky, or HDRI changes
        const sky_cfg = self.frame_data.sky;
        const hdri_ptr: usize = if (sky_cfg.hdri_pixels) |px| @intFromPtr(px.ptr) else 0;
        const hdri_hash = hdriSampleHash(sky_cfg.hdri_pixels);
        const dsun = @abs(sun_dir[0] - self.last_sun_dir[0]) + @abs(sun_dir[1] - self.last_sun_dir[1]) + @abs(sun_dir[2] - self.last_sun_dir[2]);
        const sun_moved_enough = (sky_cfg.kind == .procedural) and (dsun > 0.15 or !std.mem.eql(f32, &self.last_sun_col, &sun_col) or @abs(sun_int - self.last_sun_int) > 0.15);
        const sky_changed = !self.ibl_initialized or
            sun_moved_enough or
            self.last_sky_kind != sky_cfg.kind or
            !std.mem.eql(f32, &self.last_sky_tint, &sky_cfg.sky_tint) or
            !std.mem.eql(f32, &self.last_horizon_tint, &sky_cfg.horizon_tint) or
            !std.mem.eql(f32, &self.last_ground_albedo, &sky_cfg.ground_albedo) or
            !std.mem.eql(f32, &self.last_solid_color, &sky_cfg.solid_color) or
            self.last_atmo_thick != sky_cfg.atmosphere_thickness or
            self.last_hdri_ev != sky_cfg.hdri_exposure_ev or
            hdri_ptr != self.last_hdri_ptr or
            hdri_hash != self.last_hdri_hash or
            self.last_hdri_rot != sky_cfg.hdri_rotation_rad or
            self.last_sun_size != sky_cfg.sun_size or
            self.last_sun_disk != sky_cfg.sun_disk;
        if (sky_changed) {
            try self.updateEnvIbl(sun_dir, sun_col, sun_int);
            self.last_sun_dir = sun_dir;
            self.last_sun_col = sun_col;
            self.last_sun_int = sun_int;
            self.last_sky_kind = sky_cfg.kind;
            self.last_sky_tint = sky_cfg.sky_tint;
            self.last_horizon_tint = sky_cfg.horizon_tint;
            self.last_ground_albedo = sky_cfg.ground_albedo;
            self.last_solid_color = sky_cfg.solid_color;
            self.last_atmo_thick = sky_cfg.atmosphere_thickness;
            self.last_hdri_ev = sky_cfg.hdri_exposure_ev;
            self.last_hdri_ptr = hdri_ptr;
            self.last_hdri_hash = hdri_hash;
            self.last_hdri_rot = sky_cfg.hdri_rotation_rad;
            self.last_sun_size = sky_cfg.sun_size;
            self.last_sun_disk = sky_cfg.sun_disk;
            self.ibl_initialized = true;
        }

        // 1. 4-Cascade Exponential Directional Shadow Map Atlas Pass (2x2 quadrants of 1024x1024)
        var light_vps: [4]math3d.Mat4 = @splat(math3d.Mat4.identity());
        var cascade_splits: [4]f32 = .{ 10.0, 23.0, 52.0, 120.0 };
        var cascade_depth_ranges: [4]f32 = .{ 80.0, 100.0, 140.0, 220.0 };
        var cascade_overlap: f32 = 0.18;
        var shadows_enabled: f32 = 0.0;
        // Cascades rendered this frame; shaders must not sample beyond this count.
        var cascade_count: f32 = 0.0;
        var shadow_bias: f32 = 0.005;
        if (self.frame_data.directional_lights.len > 0 and self.frame_data.directional_lights[0].shadows_enabled) {
            const dl = self.frame_data.directional_lights[0];
            shadows_enabled = 1.0;
            shadow_bias = dl.shadow_depth_bias;
            cascade_splits = dl.cascade_bounds;
            cascade_overlap = dl.overlap_proportion;
            const ldir = math3d.Vec3.normalize(.{ .x = dl.direction[0], .y = dl.direction[1], .z = dl.direction[2] });
            const cam_p = math3d.Vec3{ .x = self.frame_data.camera_position[0], .y = self.frame_data.camera_position[1], .z = self.frame_data.camera_position[2] };
            const cam_f = math3d.Vec3.normalize(.{ .x = self.frame_data.camera_forward[0], .y = self.frame_data.camera_forward[1], .z = self.frame_data.camera_forward[2] });

            const sh_depth = std.mem.zeroInit(c.SDL_GPUDepthStencilTargetInfo, .{
                .texture = self.shadow_texture,
                .clear_depth = 1.0,
                .load_op = c.SDL_GPU_LOADOP_CLEAR,
                .store_op = c.SDL_GPU_STOREOP_STORE,
                .stencil_load_op = c.SDL_GPU_LOADOP_DONT_CARE,
                .stencil_store_op = c.SDL_GPU_STOREOP_DONT_CARE,
            });
            const sh_pass = c.SDL_BeginGPURenderPass(cmd_buf, null, 0, &sh_depth) orelse return error.SdlGpuFailure;
            c.SDL_BindGPUGraphicsPipeline(sh_pass, self.shadow_pipeline);

            const half_w: f32 = @floatFromInt(SHADOW_W / 2);
            const half_h: f32 = @floatFromInt(SHADOW_H / 2);
            var prev_b: f32 = dl.minimum_distance;
            const active_cascades: usize = @min(dl.cascade_count, 4);
            cascade_count = @floatFromInt(active_cascades);
            for (0..active_cascades) |ci| {
                const far_b = cascade_splits[ci];
                const center_d = (prev_b + far_b) * 0.5;
                const center = math3d.Vec3{
                    .x = cam_p.x + cam_f.x * center_d,
                    .y = cam_p.y + cam_f.y * center_d,
                    .z = cam_p.z + cam_f.z * center_d,
                };
                const half_ext = @max(far_b * 1.25, 12.0);
                const d_range = @max(far_b * 2.5, 100.0);
                cascade_depth_ranges[ci] = d_range;
                light_vps[ci] = computeCascadeMatrix(ldir, center, half_ext, half_w, d_range);
                prev_b = far_b;

                const qx_i: i32 = @intCast((ci & 1) * (SHADOW_W / 2));
                const qy_i: i32 = @intCast((ci >> 1) * (SHADOW_H / 2));
                c.SDL_SetGPUViewport(sh_pass, &.{ .x = @floatFromInt(qx_i), .y = @floatFromInt(qy_i), .w = half_w, .h = half_h, .min_depth = 0, .max_depth = 1 });
                c.SDL_SetGPUScissor(sh_pass, &.{ .x = qx_i, .y = qy_i, .w = @intCast(SHADOW_W / 2), .h = @intCast(SHADOW_H / 2) });
                self.drawShadowQueue(cmd_buf, sh_pass, .light, light_vps[ci], meshes, textures, white_tex, linear_sampler);
            }
            c.SDL_EndGPURenderPass(sh_pass);
        }

        // 1.2 Local Shadow Atlas (4x4 tiles of 512x512) + Clustered Forward+ Light/Probe Buffers
        const cl_lights = try self.allocator.create(ClusterLightsBuffer);
        defer self.allocator.destroy(cl_lights);
        cl_lights.* = .{};
        var local_sh_data = LocalShadowBuffer{};
        var next_tile: u32 = 0;

        const pt_count = @min(self.frame_data.point_lights.len, 256);
        for (0..pt_count) |i| {
            const pl = self.frame_data.point_lights[i];
            const sc = pl.intensity_lumens / 100.0;
            var tile_id: f32 = -1.0;
            if (pl.shadows_enabled and next_tile + 6 <= 16) {
                tile_id = @floatFromInt(next_tile);
                const dirs = [6]math3d.Vec3{
                    .{ .x = 1, .y = 0, .z = 0 },  .{ .x = -1, .y = 0, .z = 0 },
                    .{ .x = 0, .y = 1, .z = 0 },  .{ .x = 0, .y = -1, .z = 0 },
                    .{ .x = 0, .y = 0, .z = 1 },  .{ .x = 0, .y = 0, .z = -1 },
                };
                const ups = [6]math3d.Vec3{
                    .{ .x = 0, .y = 1, .z = 0 },  .{ .x = 0, .y = 1, .z = 0 },
                    .{ .x = 0, .y = 0, .z = -1 }, .{ .x = 0, .y = 0, .z = 1 },
                    .{ .x = 0, .y = 1, .z = 0 },  .{ .x = 0, .y = 1, .z = 0 },
                };
                // Slightly >90 deg FOV (92 deg) provides an 8-texel overlap margin to eliminate 45-degree cubemap seams.
                const p_proj = perspectiveMat(std.math.pi * 0.512, 1.0, 0.1, @max(pl.range, 1.0));
                const eye = math3d.Vec3{ .x = pl.position[0], .y = pl.position[1], .z = pl.position[2] };
                for (0..6) |f| {
                    const tidx = next_tile + f;
                    const tgt = math3d.Vec3{ .x = eye.x + dirs[f].x, .y = eye.y + dirs[f].y, .z = eye.z + dirs[f].z };
                    local_sh_data.shadow_vp[tidx] = math3d.Mat4.mul(p_proj, math3d.Mat4.lookAt(eye, tgt, ups[f])).m;
                    const tx: f32 = @floatFromInt(tidx % 4);
                    const ty: f32 = @floatFromInt(tidx / 4);
                    local_sh_data.atlas_rect[tidx] = .{ tx * 0.25, ty * 0.25, 0.25, 0.25 };
                }
                next_tile += 6;
            }
            cl_lights.points[i] = .{
                .pos_range = .{ pl.position[0], pl.position[1], pl.position[2], pl.range },
                .col_radius = .{ pl.color[0] * sc, pl.color[1] * sc, pl.color[2] * sc, tile_id },
            };
        }

        const sp_count = @min(self.frame_data.spot_lights.len, 256);
        for (0..sp_count) |i| {
            const sl = self.frame_data.spot_lights[i];
            const sc = sl.intensity_lumens / 100.0;
            var tile_id: f32 = -1.0;
            if (sl.shadows_enabled and next_tile < 16) {
                tile_id = @floatFromInt(next_tile);
                const eye = math3d.Vec3{ .x = sl.position[0], .y = sl.position[1], .z = sl.position[2] };
                const dir = math3d.Vec3.normalize(.{ .x = sl.direction[0], .y = sl.direction[1], .z = sl.direction[2] });
                const up = math3d.Vec3{ .x = 0, .y = if (@abs(dir.y) > 0.95) 0.0 else 1.0, .z = if (@abs(dir.y) > 0.95) 1.0 else 0.0 };
                const tgt = math3d.Vec3{ .x = eye.x + dir.x, .y = eye.y + dir.y, .z = eye.z + dir.z };
                const s_proj = perspectiveMat(std.math.clamp(sl.outer_angle_rad * 2.0, 0.2, std.math.pi * 0.9), 1.0, 0.1, @max(sl.range, 1.0));
                local_sh_data.shadow_vp[next_tile] = math3d.Mat4.mul(s_proj, math3d.Mat4.lookAt(eye, tgt, up)).m;
                const tx: f32 = @floatFromInt(next_tile % 4);
                const ty: f32 = @floatFromInt(next_tile / 4);
                local_sh_data.atlas_rect[next_tile] = .{ tx * 0.25, ty * 0.25, 0.25, 0.25 };
                next_tile += 1;
            }
            cl_lights.spots[i] = .{
                .pos_range = .{ sl.position[0], sl.position[1], sl.position[2], sl.range },
                .dir_cos_inner = .{ sl.direction[0], sl.direction[1], sl.direction[2], @cos(sl.inner_angle_rad) },
                .col_cos_outer = .{ sl.color[0] * sc, sl.color[1] * sc, sl.color[2] * sc, @cos(sl.outer_angle_rad) },
                .shadow_params = .{ tile_id, sl.shadow_depth_bias, 0, 0 },
            };
        }

        const rc_count = @min(self.frame_data.rect_lights.len, 64);
        for (0..rc_count) |i| {
            const rl = self.frame_data.rect_lights[i];
            const sc = rl.intensity_lumens / 100.0;
            cl_lights.rects[i] = .{
                .pos_range = .{ rl.position[0], rl.position[1], rl.position[2], rl.range },
                .dir_two = .{ rl.direction[0], rl.direction[1], rl.direction[2], if (rl.two_sided) 1.0 else 0.0 },
                .right_hx = .{ rl.right[0], rl.right[1], rl.right[2], rl.half_extents[0] },
                .up_hy = .{ rl.up[0], rl.up[1], rl.up[2], rl.half_extents[1] },
                .col_pad = .{ rl.color[0] * sc, rl.color[1] * sc, rl.color[2] * sc, 0 },
            };
        }

        const pr_count = @min(self.frame_data.reflection_probes.len, 32);
        for (0..pr_count) |i| {
            const pr = self.frame_data.reflection_probes[i];
            cl_lights.probes[i] = .{
                .pos_int = .{ pr.position[0], pr.position[1], pr.position[2], pr.intensity },
                .half_blend = .{ pr.half_extents[0], pr.half_extents[1], pr.half_extents[2], pr.blend_distance },
                .sky_box = .{ pr.sky_tint[0], pr.sky_tint[1], pr.sky_tint[2], if (pr.box_projection) 1.0 else 0.0 },
                .ground_pad = .{ pr.ground_tint[0], pr.ground_tint[1], pr.ground_tint[2], 0 },
            };
        }

        if (next_tile > 0) {
            const lsh_depth = std.mem.zeroInit(c.SDL_GPUDepthStencilTargetInfo, .{
                .texture = self.local_shadow_texture,
                .clear_depth = 1.0,
                .load_op = c.SDL_GPU_LOADOP_CLEAR,
                .store_op = c.SDL_GPU_STOREOP_STORE,
                .stencil_load_op = c.SDL_GPU_LOADOP_DONT_CARE,
                .stencil_store_op = c.SDL_GPU_STOREOP_DONT_CARE,
            });
            const lsh_pass = c.SDL_BeginGPURenderPass(cmd_buf, null, 0, &lsh_depth) orelse return error.SdlGpuFailure;
            c.SDL_BindGPUGraphicsPipeline(lsh_pass, self.shadow_pipeline);
            for (0..next_tile) |tidx| {
                const tx: i32 = @intCast(tidx % 4);
                const ty: i32 = @intCast(tidx / 4);
                c.SDL_SetGPUViewport(lsh_pass, &.{ .x = @floatFromInt(tx * 512), .y = @floatFromInt(ty * 512), .w = 512.0, .h = 512.0, .min_depth = 0, .max_depth = 1 });
                c.SDL_SetGPUScissor(lsh_pass, &.{ .x = tx * 512, .y = ty * 512, .w = 512, .h = 512 });
                const lvp = math3d.Mat4{ .m = local_sh_data.shadow_vp[tidx] };
                self.drawShadowQueue(cmd_buf, lsh_pass, .light, lvp, meshes, textures, white_tex, linear_sampler);
            }
            c.SDL_EndGPURenderPass(lsh_pass);
        }

        // Near/far come from the active camera's projection, so the depth slicing matches what is rendered.
        const cluster_range = cluster.perspectiveNearFar(self.frame_data.proj_matrix) orelse cluster.NearFar{ .near = 0.1, .far = 200.0 };
        const built_clusters = try cluster.buildClustersInto(
            &self.cluster_scratch,
            self.allocator,
            self.frame_data.view_matrix,
            self.frame_data.proj_matrix,
            cluster_range.near,
            cluster_range.far,
            self.frame_data.point_lights[0..pt_count],
            self.frame_data.spot_lights[0..sp_count],
            self.frame_data.rect_lights[0..rc_count],
        );
        // Log only when the drop count changes; a budget that stays exceeded would otherwise log every frame.
        if (built_clusters.dropped_refs != self.last_cluster_drops) {
            self.last_cluster_drops = built_clusters.dropped_refs;
            if (built_clusters.dropped_refs > 0) {
                var msg_buf: [96]u8 = undefined;
                const msg = std.fmt.bufPrint(&msg_buf, "cluster light references dropped: {d}", .{built_clusters.dropped_refs}) catch "cluster light references dropped";
                self.diag.log(.warn, "graphics-sdlgpu", msg) catch {};
            }
        }

        // Batch all 4 SSBO uploads into a single persistent transfer buffer and copy pass.
        {
            const lights_bytes = std.mem.asBytes(cl_lights);
            const grid_bytes = std.mem.sliceAsBytes(built_clusters.entries);
            const idx_raw = std.mem.sliceAsBytes(built_clusters.indices);
            const idx_bytes = idx_raw[0..@min(idx_raw.len, 65536 * 4)];
            const lsh_bytes = std.mem.asBytes(&local_sh_data);

            const off_lights: u32 = 0;
            const off_grid: u32 = off_lights + @as(u32, @intCast(lights_bytes.len));
            const off_idx: u32 = off_grid + @as(u32, @intCast(grid_bytes.len));
            const off_lsh: u32 = off_idx + @as(u32, @intCast(idx_bytes.len));

            const ptr = c.SDL_MapGPUTransferBuffer(self.device, self.cluster_transfer_buffer, true) orelse return error.SdlGpuFailure;
            const dst: [*]u8 = @ptrCast(ptr);
            @memcpy(dst[off_lights..][0..lights_bytes.len], lights_bytes);
            @memcpy(dst[off_grid..][0..grid_bytes.len], grid_bytes);
            @memcpy(dst[off_idx..][0..idx_bytes.len], idx_bytes);
            @memcpy(dst[off_lsh..][0..lsh_bytes.len], lsh_bytes);
            c.SDL_UnmapGPUTransferBuffer(self.device, self.cluster_transfer_buffer);

            const cp = c.SDL_BeginGPUCopyPass(cmd_buf) orelse return error.SdlGpuFailure;
            c.SDL_UploadToGPUBuffer(cp, &.{ .transfer_buffer = self.cluster_transfer_buffer, .offset = off_lights }, &.{ .buffer = self.cluster_lights_buffer, .offset = 0, .size = @intCast(lights_bytes.len) }, false);
            c.SDL_UploadToGPUBuffer(cp, &.{ .transfer_buffer = self.cluster_transfer_buffer, .offset = off_grid }, &.{ .buffer = self.cluster_grid_buffer, .offset = 0, .size = @intCast(grid_bytes.len) }, false);
            c.SDL_UploadToGPUBuffer(cp, &.{ .transfer_buffer = self.cluster_transfer_buffer, .offset = off_idx }, &.{ .buffer = self.cluster_indices_buffer, .offset = 0, .size = @intCast(idx_bytes.len) }, false);
            c.SDL_UploadToGPUBuffer(cp, &.{ .transfer_buffer = self.cluster_transfer_buffer, .offset = off_lsh }, &.{ .buffer = self.local_shadow_buffer, .offset = 0, .size = @intCast(lsh_bytes.len) }, false);
            c.SDL_EndGPUCopyPass(cp);
        }

        // 1.5 Depth Prepass + SSAO + Contact Shadows + Bilateral Blur
        if (pp.ssao.enabled or pp.contact_shadows.enabled) {
            const pre_depth = std.mem.zeroInit(c.SDL_GPUDepthStencilTargetInfo, .{
                .texture = depth_tex,
                .clear_depth = 1.0,
                .load_op = c.SDL_GPU_LOADOP_CLEAR,
                .store_op = c.SDL_GPU_STOREOP_STORE,
                .stencil_load_op = c.SDL_GPU_LOADOP_DONT_CARE,
                .stencil_store_op = c.SDL_GPU_STOREOP_DONT_CARE,
            });
            const dp_pass = c.SDL_BeginGPURenderPass(cmd_buf, null, 0, &pre_depth) orelse return error.SdlGpuFailure;
            c.SDL_SetGPUViewport(dp_pass, &.{ .x = 0, .y = 0, .w = @floatFromInt(tex_w), .h = @floatFromInt(tex_h), .min_depth = 0, .max_depth = 1 });
            self.drawShadowQueue(cmd_buf, dp_pass, .depth_prepass, math3d.Mat4.identity(), meshes, textures, white_tex, linear_sampler);
            c.SDL_EndGPURenderPass(dp_pass);

            const ao_w = @max(tex_w / 2, 1);
            const ao_h = @max(tex_h / 2, 1);
            const ssao_col = std.mem.zeroInit(c.SDL_GPUColorTargetInfo, .{
                .texture = self.ssao_texture.?,
                .load_op = c.SDL_GPU_LOADOP_DONT_CARE,
                .store_op = c.SDL_GPU_STOREOP_STORE,
            });
            const ssao_pass = c.SDL_BeginGPURenderPass(cmd_buf, &ssao_col, 1, null) orelse return error.SdlGpuFailure;
            c.SDL_SetGPUViewport(ssao_pass, &.{ .x = 0, .y = 0, .w = @floatFromInt(ao_w), .h = @floatFromInt(ao_h), .min_depth = 0, .max_depth = 1 });
            c.SDL_BindGPUGraphicsPipeline(ssao_pass, self.ssao_pipeline);
            const ssao_samplers = [_]c.SDL_GPUTextureSamplerBinding{.{ .texture = depth_tex, .sampler = nearest_sampler }};
            c.SDL_BindGPUFragmentSamplers(ssao_pass, 0, &ssao_samplers, 1);
            const vw = self.frame_data.view_matrix;
            const sd_w = if (self.frame_data.directional_lights.len > 0)
                [3]f32{ -self.frame_data.directional_lights[0].direction[0], -self.frame_data.directional_lights[0].direction[1], -self.frame_data.directional_lights[0].direction[2] }
            else
                [3]f32{ 0.4, 0.8, 0.45 };
            const sun_view = [3]f32{
                vw[0] * sd_w[0] + vw[4] * sd_w[1] + vw[8] * sd_w[2],
                vw[1] * sd_w[0] + vw[5] * sd_w[1] + vw[9] * sd_w[2],
                vw[2] * sd_w[0] + vw[6] * sd_w[1] + vw[10] * sd_w[2],
            };
            const ssao_u = SsaoParams{
                .proj = self.frame_data.proj_matrix,
                .inv_proj = invertMat4(self.frame_data.proj_matrix),
                .params = .{ pp.ssao.radius, pp.ssao.bias, pp.ssao.intensity, if (pp.ssao.enabled) 1.0 else 0.0 },
                .sun_view_dir = .{ sun_view[0], sun_view[1], sun_view[2], pp.contact_shadows.length },
                .contact_params = .{ pp.contact_shadows.opacity, pp.contact_shadows.thickness, @floatFromInt(pp.contact_shadows.sample_count), if (pp.contact_shadows.enabled) 1.0 else 0.0 },
                .fade_range = .{ pp.contact_shadows.distance_fade * 0.5, pp.contact_shadows.distance_fade, 0, 0 },
            };
            c.SDL_PushGPUFragmentUniformData(cmd_buf, 0, &ssao_u, @sizeOf(SsaoParams));
            c.SDL_DrawGPUPrimitives(ssao_pass, 3, 1, 0, 0);
            c.SDL_EndGPURenderPass(ssao_pass);

            const blur_col = std.mem.zeroInit(c.SDL_GPUColorTargetInfo, .{
                .texture = self.ssao_blur_texture.?,
                .load_op = c.SDL_GPU_LOADOP_DONT_CARE,
                .store_op = c.SDL_GPU_STOREOP_STORE,
            });
            // The blur is also the bilateral upsample, so it writes full resolution.
            const blur_pass = c.SDL_BeginGPURenderPass(cmd_buf, &blur_col, 1, null) orelse return error.SdlGpuFailure;
            c.SDL_SetGPUViewport(blur_pass, &.{ .x = 0, .y = 0, .w = @floatFromInt(tex_w), .h = @floatFromInt(tex_h), .min_depth = 0, .max_depth = 1 });
            c.SDL_BindGPUGraphicsPipeline(blur_pass, self.ssao_blur_pipeline);
            const blur_samplers = [_]c.SDL_GPUTextureSamplerBinding{
                .{ .texture = self.ssao_texture.?, .sampler = nearest_sampler },
                .{ .texture = depth_tex, .sampler = nearest_sampler },
            };
            c.SDL_BindGPUFragmentSamplers(blur_pass, 0, &blur_samplers, blur_samplers.len);
            const blur_nf = cluster.perspectiveNearFar(self.frame_data.proj_matrix) orelse cluster.NearFar{ .near = 0.1, .far = 200.0 };
            const blur_u = SsaoBlurParams{ .depth_range = .{ blur_nf.near, blur_nf.far, 0, 0 } };
            c.SDL_PushGPUFragmentUniformData(cmd_buf, 0, &blur_u, @sizeOf(SsaoBlurParams));
            c.SDL_DrawGPUPrimitives(blur_pass, 3, 1, 0, 0);
            c.SDL_EndGPURenderPass(blur_pass);
        }

        // 2. Sky Pass into HDR target
        {
            const sky_col = std.mem.zeroInit(c.SDL_GPUColorTargetInfo, .{
                .texture = hdr_tex,
                .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
                .load_op = c.SDL_GPU_LOADOP_CLEAR,
                .store_op = c.SDL_GPU_STOREOP_STORE,
            });
            const sky_pass = c.SDL_BeginGPURenderPass(cmd_buf, &sky_col, 1, null) orelse return error.SdlGpuFailure;
            c.SDL_SetGPUViewport(sky_pass, &.{ .x = 0, .y = 0, .w = @floatFromInt(tex_w), .h = @floatFromInt(tex_h), .min_depth = 0, .max_depth = 1 });
            c.SDL_BindGPUGraphicsPipeline(sky_pass, self.sky_pipeline);
            const sky = self.frame_data.sky;
            const sky_mode: f32 = switch (sky.kind) {
                .procedural => 0.0,
                .solid_color => 1.0,
                .hdri => 2.0,
            };
            const sky_u = SkyUniforms{
                .inv_view_proj = invertMat4(self.frame_data.view_proj),
                .sun_dir_size = .{ sun_dir[0], sun_dir[1], sun_dir[2], sky.sun_size },
                .sky_zenith_thick = .{ sky.sky_tint[0], sky.sky_tint[1], sky.sky_tint[2], sky.atmosphere_thickness },
                .sky_horizon_mode = .{ sky.horizon_tint[0], sky.horizon_tint[1], sky.horizon_tint[2], sky_mode },
                .ground_solid = .{
                    if (sky.kind == .solid_color) sky.solid_color[0] else sky.ground_albedo[0],
                    if (sky.kind == .solid_color) sky.solid_color[1] else sky.ground_albedo[1],
                    if (sky.kind == .solid_color) sky.solid_color[2] else sky.ground_albedo[2],
                    @floatFromInt(@intFromEnum(sky.sun_disk)),
                },
                .sun_col_intensity = .{ sun_col[0], sun_col[1], sun_col[2], if (sky.kind == .hdri) sky.hdri_exposure_ev else sun_int },
                .hdri_rotation = .{ sky.hdri_rotation_rad / (2.0 * std.math.pi), 0, 0, 0 },
            };
            const sky_samplers = [_]c.SDL_GPUTextureSamplerBinding{.{ .texture = self.hdri_sky_texture orelse self.black_texture, .sampler = self.ibl_sampler }};
            c.SDL_BindGPUFragmentSamplers(sky_pass, 0, &sky_samplers, 1);
            c.SDL_PushGPUFragmentUniformData(cmd_buf, 0, &sky_u, @sizeOf(SkyUniforms));
            c.SDL_DrawGPUPrimitives(sky_pass, 3, 1, 0, 0);
            c.SDL_EndGPURenderPass(sky_pass);
        }

        // 3. PBR Lit Meshes Pass into HDR target
        {
            const hdr_col = std.mem.zeroInit(c.SDL_GPUColorTargetInfo, .{
                .texture = hdr_tex,
                .load_op = c.SDL_GPU_LOADOP_LOAD,
                .store_op = c.SDL_GPU_STOREOP_STORE,
            });
            const hdr_depth = std.mem.zeroInit(c.SDL_GPUDepthStencilTargetInfo, .{
                .texture = depth_tex,
                .clear_depth = 1.0,
                // The prepass depth is not reused: silhouette pixels can fail the equal-depth test against it
                // and let the sky show through as a speckled outline. Clear and redraw for a stable image.
                .load_op = c.SDL_GPU_LOADOP_CLEAR,
                .store_op = c.SDL_GPU_STOREOP_STORE,
                .stencil_load_op = c.SDL_GPU_LOADOP_DONT_CARE,
                .stencil_store_op = c.SDL_GPU_STOREOP_DONT_CARE,
            });
            const pbr_pass = c.SDL_BeginGPURenderPass(cmd_buf, &hdr_col, 1, &hdr_depth) orelse return error.SdlGpuFailure;
            c.SDL_SetGPUViewport(pbr_pass, &.{ .x = 0, .y = 0, .w = @floatFromInt(tex_w), .h = @floatFromInt(tex_h), .min_depth = 0, .max_depth = 1 });
            c.SDL_BindGPUGraphicsPipeline(pbr_pass, self.pbr_pipeline);

            var pt_pos: [4][4]f32 = @splat(.{ 0, 0, 0, 1 });
            var pt_col: [4][4]f32 = @splat(.{ 0, 0, 0, 0 });
            const p_n = @min(self.frame_data.point_lights.len, 4);
            for (0..p_n) |i| {
                const pl = self.frame_data.point_lights[i];
                const sc = pl.intensity_lumens / 100.0;
                pt_pos[i] = .{ pl.position[0], pl.position[1], pl.position[2], pl.range };
                pt_col[i] = .{ pl.color[0] * sc, pl.color[1] * sc, pl.color[2] * sc, pl.radius };
            }

            var sp_pos: [2][4]f32 = @splat(.{ 0, 0, 0, 1 });
            var sp_dir: [2][4]f32 = @splat(.{ 0, -1, 0, 0.9 });
            var sp_col: [2][4]f32 = @splat(.{ 0, 0, 0, 0.8 });
            const s_n = @min(self.frame_data.spot_lights.len, 2);
            for (0..s_n) |i| {
                const sl = self.frame_data.spot_lights[i];
                const sc = sl.intensity_lumens / 100.0;
                sp_pos[i] = .{ sl.position[0], sl.position[1], sl.position[2], sl.range };
                sp_dir[i] = .{ sl.direction[0], sl.direction[1], sl.direction[2], @cos(sl.inner_angle_rad) };
                sp_col[i] = .{ sl.color[0] * sc, sl.color[1] * sc, sl.color[2] * sc, @cos(sl.outer_angle_rad) };
            }

            const has_dir = self.frame_data.directional_lights.len > 0;
            const dl_dir: [3]f32 = if (has_dir) .{ -self.frame_data.directional_lights[0].direction[0], -self.frame_data.directional_lights[0].direction[1], -self.frame_data.directional_lights[0].direction[2] } else .{ 0.4, 0.8, 0.45 };
            const dl_col: [3]f32 = if (has_dir) self.frame_data.directional_lights[0].color else .{ 1, 1, 1 };
            const dl_int: f32 = if (has_dir) self.frame_data.directional_lights[0].illuminance_lux / 2500.0 else 0.0;

            var sh_arr: [9][4]f32 = undefined;
            for (0..9) |i| {
                sh_arr[i] = .{ self.sky_sh.coeffs[i][0], self.sky_sh.coeffs[i][1], self.sky_sh.coeffs[i][2], 0.0 };
            }
            sh_arr[0][3] = if (pp.ssao.enabled) 1.0 else 0.0;
            sh_arr[1][3] = 1.0 / @as(f32, @floatFromInt(tex_w));
            sh_arr[2][3] = 1.0 / @as(f32, @floatFromInt(tex_h));
            sh_arr[3][3] = if (pp.contact_shadows.enabled) 1.0 else 0.0;
            const ssao_tex = if (pp.ssao.enabled or pp.contact_shadows.enabled) (self.ssao_blur_texture orelse white_tex) else white_tex;
            const pcss_on: f32 = if (has_dir and self.frame_data.directional_lights[0].pcss_enabled) 1.0 else 0.0;
            const vol_on: f32 = if (self.frame_data.fog.volumetric.enabled) 1.0 else 0.0;

            const pbr_ssbos = [_]*c.SDL_GPUBuffer{
                self.cluster_lights_buffer,
                self.cluster_grid_buffer,
                self.cluster_indices_buffer,
                self.local_shadow_buffer,
            };
            c.SDL_BindGPUFragmentStorageBuffers(pbr_pass, 0, &pbr_ssbos, pbr_ssbos.len);

            // Opaque before transparent; transparent back to front, so alpha blending composes correctly.
            self.draw_order.clearRetainingCapacity();
            try self.draw_order.ensureTotalCapacity(self.allocator, self.queued_draws.items.len);
            const cam_p = self.frame_data.camera_position;
            for (self.queued_draws.items, 0..) |qm, i| {
                const dx = qm.model_matrix[12] - cam_p[0];
                const dy = qm.model_matrix[13] - cam_p[1];
                const dz = qm.model_matrix[14] - cam_p[2];
                self.draw_order.appendAssumeCapacity(.{
                    .index = @intCast(i),
                    .depth = dx * dx + dy * dy + dz * dz,
                    .blend = qm.material.alpha_mode == .blend,
                    .double_sided = qm.material.double_sided,
                });
            }
            std.mem.sort(DrawOrderEntry, self.draw_order.items, {}, drawOrderLess);

            var active_pipe: ?*c.SDL_GPUGraphicsPipeline = null;
            for (self.draw_order.items) |entry| {
                const qm = self.queued_draws.items[entry.index];
                const gm = meshes.get(@bitCast(qm.mesh_asset)) orelse continue;
                const mat = qm.material;
                const want_pipe: *c.SDL_GPUGraphicsPipeline = if (mat.alpha_mode == .blend)
                    self.pbr_blend_pipeline
                else if (mat.double_sided)
                    self.pbr_double_sided_pipeline
                else
                    self.pbr_pipeline;
                if (active_pipe != want_pipe) {
                    c.SDL_BindGPUGraphicsPipeline(pbr_pass, want_pipe);
                    active_pipe = want_pipe;
                }
                const base_t = if (mat.base_color_tex != 0) (textures.get(@bitCast(mat.base_color_tex)) orelse white_tex) else white_tex;
                const norm_t = if (mat.normal_tex != 0) (textures.get(@bitCast(mat.normal_tex)) orelse self.flat_normal_texture) else self.flat_normal_texture;
                const mr_t = if (mat.metallic_roughness_tex != 0) (textures.get(@bitCast(mat.metallic_roughness_tex)) orelse white_tex) else white_tex;
                const ao_t = if (mat.ao_tex != 0) (textures.get(@bitCast(mat.ao_tex)) orelse white_tex) else white_tex;
                const em_t = if (mat.emissive_tex != 0) (textures.get(@bitCast(mat.emissive_tex)) orelse white_tex) else white_tex;

                c.SDL_BindGPUVertexBuffers(pbr_pass, 0, &.{ .buffer = gm.vertex_buffer, .offset = 0 }, 1);
                c.SDL_BindGPUIndexBuffer(pbr_pass, &.{ .buffer = gm.index_buffer, .offset = 0 }, c.SDL_GPU_INDEXELEMENTSIZE_32BIT);

                const vu = PbrVertUniforms{
                    .model = qm.model_matrix,
                    .normal_matrix = normalMatrixFromModel(qm.model_matrix),
                    .mvp = qm.mvp_matrix,
                    .light_vp = .{ light_vps[0].m, light_vps[1].m, light_vps[2].m, light_vps[3].m },
                };
                c.SDL_PushGPUVertexUniformData(cmd_buf, 0, &vu, @sizeOf(PbrVertUniforms));

                const fu = PbrFragUniforms{
                    .camera_pos_fog = .{ self.frame_data.camera_position[0], self.frame_data.camera_position[1], self.frame_data.camera_position[2], if (self.frame_data.fog.enabled) 1.0 else 0.0 },
                    .base_color = .{ mat.base_color[0] * qm.tint[0], mat.base_color[1] * qm.tint[1], mat.base_color[2] * qm.tint[2], mat.base_color[3] * qm.tint[3] },
                    .emissive_weight = .{ mat.emissive[0], mat.emissive[1], mat.emissive[2], mat.emissive_exposure_weight },
                    .mat_params = .{ mat.metallic, mat.roughness, mat.reflectance, mat.ao_strength },
                    .mat_flags = .{ if (mat.unlit) 1.0 else 0.0, if (mat.normal_tex != 0) mat.normal_scale else 0.0, shadow_bias, shadows_enabled },
                    .ambient_sky = .{ self.frame_data.ambient.color[0] * self.frame_data.ambient.brightness, self.frame_data.ambient.color[1] * self.frame_data.ambient.brightness, self.frame_data.ambient.color[2] * self.frame_data.ambient.brightness, self.frame_data.fog.density },
                    .fog_color_start = .{ self.frame_data.fog.color[0], self.frame_data.fog.color[1], self.frame_data.fog.color[2], self.frame_data.fog.start_distance },
                    .dir_light_dir = .{ dl_dir[0], dl_dir[1], dl_dir[2], dl_int },
                    .dir_light_col = .{ dl_col[0], dl_col[1], dl_col[2], @floatFromInt(p_n) },
                    .point_pos = pt_pos,
                    .point_col = pt_col,
                    .sky_zenith = .{ self.frame_data.sky.sky_tint[0], self.frame_data.sky.sky_tint[1], self.frame_data.sky.sky_tint[2], @floatFromInt(s_n) },
                    .sky_horizon = .{ self.frame_data.sky.horizon_tint[0], self.frame_data.sky.horizon_tint[1], self.frame_data.sky.horizon_tint[2], @floatFromInt(ENV_MIPS - 1) },
                    .spot_pos = sp_pos,
                    .spot_dir = sp_dir,
                    .spot_col = sp_col,
                    .sh_coeffs = sh_arr,
                    .camera_fwd_overlap = .{ self.frame_data.camera_forward[0], self.frame_data.camera_forward[1], self.frame_data.camera_forward[2], cascade_overlap },
                    .cascade_splits = cascade_splits,
                    .cascade_depth_ranges = cascade_depth_ranges,
                    .cluster_factors = .{ built_clusters.factors.z_scale, built_clusters.factors.z_bias, 1.0, if (mat.alpha_mode == .mask) mat.alpha_cutoff else -1.0 },
                    .probe_volumetric = .{ @floatFromInt(pr_count), pcss_on, vol_on, self.frame_data.fog.volumetric.scattering },
                    .cascade_info = .{ cascade_count, 0, 0, 0 },
                };
                c.SDL_PushGPUFragmentUniformData(cmd_buf, 0, &fu, @sizeOf(PbrFragUniforms));
                const pbr_samplers = [_]c.SDL_GPUTextureSamplerBinding{
                    .{ .texture = base_t, .sampler = self.material_sampler },
                    .{ .texture = norm_t, .sampler = self.material_sampler },
                    .{ .texture = mr_t, .sampler = self.material_sampler },
                    .{ .texture = self.shadow_texture, .sampler = self.shadow_sampler },
                    .{ .texture = self.env_prefilter_texture, .sampler = self.ibl_sampler },
                    .{ .texture = self.brdf_lut_texture, .sampler = linear_sampler },
                    .{ .texture = ssao_tex, .sampler = linear_sampler },
                    .{ .texture = self.local_shadow_texture, .sampler = self.shadow_sampler },
                    .{ .texture = ao_t, .sampler = self.material_sampler },
                    .{ .texture = em_t, .sampler = self.material_sampler },
                };
                c.SDL_BindGPUFragmentSamplers(pbr_pass, 0, &pbr_samplers, pbr_samplers.len);
                c.SDL_DrawGPUIndexedPrimitives(pbr_pass, gm.index_count, 1, 0, 0, 0);
            }
            c.SDL_EndGPURenderPass(pbr_pass);
        }

        // 3.5 Volumetric Fog & God Rays (additive ray-marched scattering into HDR target)
        if (self.frame_data.fog.enabled and self.frame_data.fog.volumetric.enabled) {
            // Ray-march at half resolution by default; the composite pass upsamples depth-aware (~4x fewer marched pixels).
            const vol_half = self.frame_data.fog.volumetric.half_resolution;
            const vol_w: u32 = if (vol_half) @max(tex_w / 2, 1) else tex_w;
            const vol_h: u32 = if (vol_half) @max(tex_h / 2, 1) else tex_h;
            try self.ensureVolumetricTarget(vol_w, vol_h);

            const vf_col = std.mem.zeroInit(c.SDL_GPUColorTargetInfo, .{
                .texture = self.vol_texture.?,
                .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .load_op = c.SDL_GPU_LOADOP_CLEAR,
                .store_op = c.SDL_GPU_STOREOP_STORE,
            });
            const vf_pass = c.SDL_BeginGPURenderPass(cmd_buf, &vf_col, 1, null) orelse return error.SdlGpuFailure;
            c.SDL_SetGPUViewport(vf_pass, &.{ .x = 0, .y = 0, .w = @floatFromInt(vol_w), .h = @floatFromInt(vol_h), .min_depth = 0, .max_depth = 1 });
            c.SDL_BindGPUGraphicsPipeline(vf_pass, self.volumetric_pipeline);

            const has_dir_vf = self.frame_data.directional_lights.len > 0;
            const vf_sun_dir: [3]f32 = if (has_dir_vf)
                .{ -self.frame_data.directional_lights[0].direction[0], -self.frame_data.directional_lights[0].direction[1], -self.frame_data.directional_lights[0].direction[2] }
            else
                .{ 0.4, 0.8, 0.45 };
            const vf_sun_col: [3]f32 = if (has_dir_vf) self.frame_data.directional_lights[0].color else .{ 1, 1, 1 };
            const vf_sun_int: f32 = if (has_dir_vf) self.frame_data.directional_lights[0].illuminance_lux / 2500.0 else 0.0;

            // Spot lights get the same relevance ranking as point lights, with one local-atlas tile per shadowed slot.
            var vf_sp_pos: [4][4]f32 = @splat(.{ 0, 0, 0, 1 });
            var vf_sp_dir: [4][4]f32 = @splat(.{ 0, -1, 0, 0.8 });
            var vf_sp_col: [4][4]f32 = @splat(.{ 0, 0, 0, 0 });
            var vf_sp_shadow: [4][4]f32 = @splat(.{ 0, 0, 0, 0 });
            const vf_spick = volumetric_lights.selectRelevantLights(self.frame_data.spot_lights[0..sp_count], self.frame_data.camera_position);
            for (0..vf_spick.count) |slot| {
                const li = vf_spick.idx[slot];
                const sl = self.frame_data.spot_lights[li];
                const sc = sl.intensity_lumens / 100.0;
                vf_sp_pos[slot] = .{ sl.position[0], sl.position[1], sl.position[2], sl.range };
                vf_sp_dir[slot] = .{ sl.direction[0], sl.direction[1], sl.direction[2], @cos(sl.outer_angle_rad) };
                vf_sp_col[slot] = .{ sl.color[0] * sc, sl.color[1] * sc, sl.color[2] * sc, 1.0 };
                const tile = cl_lights.spots[li].shadow_params[0];
                if (tile >= 0.0) vf_sp_shadow[slot] = .{ tile, 1.0, 0.0, 0.0 };
            }

            var vf_pt_pos: [4][4]f32 = @splat(.{ 0, 0, 0, 1 });
            var vf_pt_col: [4][4]f32 = @splat(.{ 0, 0, 0, 0 });
            var vf_pt_shadow: [4][4]f32 = @splat(.{ 0, 0, 0, 0 });
            // Only lights that received a cluster entry this frame are candidates, so `cl_lights` indices stay valid.
            const vf_pick = volumetric_lights.selectRelevantLights(self.frame_data.point_lights[0..pt_count], self.frame_data.camera_position);
            for (0..vf_pick.count) |slot| {
                const li = vf_pick.idx[slot];
                const pl = self.frame_data.point_lights[li];
                const sc = pl.intensity_lumens / 100.0;
                vf_pt_pos[slot] = .{ pl.position[0], pl.position[1], pl.position[2], pl.range };
                vf_pt_col[slot] = .{ pl.color[0] * sc, pl.color[1] * sc, pl.color[2] * sc, 1.0 };
                // Local-atlas tile of the first cube face (six consecutive tiles), or -1 when unshadowed.
                const tile = cl_lights.points[li].col_radius[3];
                if (tile >= 0.0) vf_pt_shadow[slot] = .{ tile, 1.0, 0.0, 0.0 };
            }

            const vfp = VolFogParams{
                .inv_view_proj = invertMat4(self.frame_data.view_proj),
                .light_vp = .{ light_vps[0].m, light_vps[1].m, light_vps[2].m, light_vps[3].m },
                .cam_pos_density = .{ self.frame_data.camera_position[0], self.frame_data.camera_position[1], self.frame_data.camera_position[2], self.frame_data.fog.density },
                .sun_dir_int = .{ vf_sun_dir[0], vf_sun_dir[1], vf_sun_dir[2], vf_sun_int },
                .sun_col_aniso = .{ vf_sun_col[0], vf_sun_col[1], vf_sun_col[2], self.frame_data.fog.volumetric.anisotropy },
                .fog_col_scat = .{ self.frame_data.fog.color[0], self.frame_data.fog.color[1], self.frame_data.fog.color[2], self.frame_data.fog.volumetric.scattering },
                .cascade_splits = if (shadows_enabled > 0.5) cascade_splits else .{ -1.0, -1.0, -1.0, -1.0 },
                .cam_fwd_maxd = .{ self.frame_data.camera_forward[0], self.frame_data.camera_forward[1], self.frame_data.camera_forward[2], self.frame_data.fog.volumetric.max_distance },
                .spot_pos_range = vf_sp_pos,
                .spot_dir_cos = vf_sp_dir,
                .spot_col_on = vf_sp_col,
                .spot_shadow = vf_sp_shadow,
                .point_pos = vf_pt_pos,
                .point_col = vf_pt_col,
                .local_vp = local_sh_data.shadow_vp,
                .local_rect = local_sh_data.atlas_rect,
                .point_shadow = vf_pt_shadow,
                .cascade_info = .{ cascade_count, 0, 0, 0 },
            };
            const vf_samplers = [_]c.SDL_GPUTextureSamplerBinding{
                .{ .texture = depth_tex, .sampler = nearest_sampler },
                .{ .texture = self.shadow_texture, .sampler = self.shadow_sampler },
                .{ .texture = self.local_shadow_texture, .sampler = self.shadow_sampler },
            };
            c.SDL_BindGPUFragmentSamplers(vf_pass, 0, &vf_samplers, vf_samplers.len);
            c.SDL_PushGPUFragmentUniformData(cmd_buf, 0, &vfp, @sizeOf(VolFogParams));
            c.SDL_DrawGPUPrimitives(vf_pass, 3, 1, 0, 0);
            c.SDL_EndGPURenderPass(vf_pass);

            // Physically based composition on the HDR scene: L = L_scene * T + L_scatter.
            // Pass 0 multiplies by T; pass 1 adds the upsampled in-scatter plus the ambient fog colour (1 - T) * C.
            const vc_base = VolCompositeParams{
                .inv_view_proj = invertMat4(self.frame_data.view_proj),
                .cam_pos = .{ self.frame_data.camera_position[0], self.frame_data.camera_position[1], self.frame_data.camera_position[2], 0 },
                .vol_size_dist = .{ @floatFromInt(vol_w), @floatFromInt(vol_h), self.frame_data.fog.volumetric.max_distance, 0 },
                .fog_color_density = .{ self.frame_data.fog.color[0], self.frame_data.fog.color[1], self.frame_data.fog.color[2], self.frame_data.fog.density },
            };
            const vc_samplers = [_]c.SDL_GPUTextureSamplerBinding{
                .{ .texture = self.vol_texture.?, .sampler = nearest_sampler },
                .{ .texture = depth_tex, .sampler = nearest_sampler },
            };
            inline for (.{ .{ 0.0, self.volumetric_transmittance_pipeline }, .{ 1.0, self.volumetric_composite_pipeline } }) |pass_desc| {
                const vc_col = std.mem.zeroInit(c.SDL_GPUColorTargetInfo, .{
                    .texture = hdr_tex,
                    .load_op = c.SDL_GPU_LOADOP_LOAD,
                    .store_op = c.SDL_GPU_STOREOP_STORE,
                });
                const vc_pass = c.SDL_BeginGPURenderPass(cmd_buf, &vc_col, 1, null) orelse return error.SdlGpuFailure;
                c.SDL_SetGPUViewport(vc_pass, &.{ .x = 0, .y = 0, .w = @floatFromInt(tex_w), .h = @floatFromInt(tex_h), .min_depth = 0, .max_depth = 1 });
                c.SDL_BindGPUGraphicsPipeline(vc_pass, pass_desc[1]);
                c.SDL_BindGPUFragmentSamplers(vc_pass, 0, &vc_samplers, vc_samplers.len);
                var vcp = vc_base;
                vcp.vol_size_dist[3] = pass_desc[0];
                c.SDL_PushGPUFragmentUniformData(cmd_buf, 0, &vcp, @sizeOf(VolCompositeParams));
                c.SDL_DrawGPUPrimitives(vc_pass, 3, 1, 0, 0);
                c.SDL_EndGPURenderPass(vc_pass);
            }
        }

        // 4. Compute Auto-Exposure (Histogram -> EV100 Adaptation)
        const min_log2: f32 = -8.0;
        const max_log2: f32 = 8.0;
        const log2_range = max_log2 - min_log2;
        if (pp.auto_exposure.enabled) {
            const hist_rw_bufs = [_]c.SDL_GPUStorageBufferReadWriteBinding{.{ .buffer = self.histogram_buffer, .cycle = false }};
            const c_pass = c.SDL_BeginGPUComputePass(
                cmd_buf,
                null,
                0,
                &hist_rw_bufs,
                1,
            ) orelse return error.SdlGpuFailure;
            c.SDL_BindGPUComputePipeline(c_pass, self.hist_pipeline);
            const hist_samplers = [_]c.SDL_GPUTextureSamplerBinding{.{ .texture = hdr_tex, .sampler = linear_sampler }};
            c.SDL_BindGPUComputeSamplers(c_pass, 0, &hist_samplers, 1);
            const hp = HistParams{ .range_params = .{ min_log2, 1.0 / log2_range, @floatFromInt(tex_w), @floatFromInt(tex_h) } };
            c.SDL_PushGPUComputeUniformData(cmd_buf, 0, &hp, @sizeOf(HistParams));
            c.SDL_DispatchGPUCompute(c_pass, (tex_w + 15) / 16, (tex_h + 15) / 16, 1);
            c.SDL_EndGPUComputePass(c_pass);

            const exp_rw_tex = [_]c.SDL_GPUStorageTextureReadWriteBinding{.{ .texture = self.exposure_texture, .mip_level = 0, .layer = 0, .cycle = false }};
            const adapt_rw_bufs = [_]c.SDL_GPUStorageBufferReadWriteBinding{.{ .buffer = self.histogram_buffer, .cycle = false }};
            const a_pass = c.SDL_BeginGPUComputePass(
                cmd_buf,
                &exp_rw_tex,
                1,
                &adapt_rw_bufs,
                1,
            ) orelse return error.SdlGpuFailure;
            c.SDL_BindGPUComputePipeline(a_pass, self.adapt_pipeline);
            const ap = AdaptParams{
                .ev_bounds = .{ pp.auto_exposure.min_ev100, pp.auto_exposure.max_ev100, pp.auto_exposure.low_percent, pp.auto_exposure.high_percent },
                .speed_dt = .{ pp.auto_exposure.speed_brighten, pp.auto_exposure.speed_darken, @max(self.frame_data.dt, 1.0 / 120.0), pp.auto_exposure.compensation_ev },
                .hist_range = .{ min_log2, log2_range, 1.0, 0.0 },
            };
            c.SDL_PushGPUComputeUniformData(cmd_buf, 0, &ap, @sizeOf(AdaptParams));
            c.SDL_DispatchGPUCompute(a_pass, 1, 1, 1);
            c.SDL_EndGPUComputePass(a_pass);
        }

        // 5. Bloom Downsample + Additive Upsample
        const bloom_tex: *c.SDL_GPUTexture = if (pp.bloom.enabled) blk: {
            for (0..BLOOM_MIPS) |i| {
                const src_t = if (i == 0) hdr_tex else self.bloom_textures[i - 1].?;
                const src_w: f32 = @floatFromInt(if (i == 0) tex_w else self.bloom_sizes[i - 1][0]);
                const src_h: f32 = @floatFromInt(if (i == 0) tex_h else self.bloom_sizes[i - 1][1]);
                const dst_t = self.bloom_textures[i].?;
                const dst_w = self.bloom_sizes[i][0];
                const dst_h = self.bloom_sizes[i][1];
                const b_col = std.mem.zeroInit(c.SDL_GPUColorTargetInfo, .{
                    .texture = dst_t,
                    .load_op = c.SDL_GPU_LOADOP_DONT_CARE,
                    .store_op = c.SDL_GPU_STOREOP_STORE,
                });
                const bp = c.SDL_BeginGPURenderPass(cmd_buf, &b_col, 1, null) orelse return error.SdlGpuFailure;
                c.SDL_SetGPUViewport(bp, &.{ .x = 0, .y = 0, .w = @floatFromInt(dst_w), .h = @floatFromInt(dst_h), .min_depth = 0, .max_depth = 1 });
                c.SDL_BindGPUGraphicsPipeline(bp, self.bloom_down_pipeline);
                const bd_samplers = [_]c.SDL_GPUTextureSamplerBinding{.{ .texture = src_t, .sampler = linear_sampler }};
                c.SDL_BindGPUFragmentSamplers(bp, 0, &bd_samplers, 1);
                const bp_u = BloomParams{ .p = .{ 1.0 / src_w, 1.0 / src_h, pp.bloom.threshold, if (i == 0) 1.0 else 0.0 } };
                c.SDL_PushGPUFragmentUniformData(cmd_buf, 0, &bp_u, @sizeOf(BloomParams));
                c.SDL_DrawGPUPrimitives(bp, 3, 1, 0, 0);
                c.SDL_EndGPURenderPass(bp);
            }
            var i = BLOOM_MIPS - 1;
            while (i > 0) : (i -= 1) {
                const src_t = self.bloom_textures[i].?;
                const src_w: f32 = @floatFromInt(self.bloom_sizes[i][0]);
                const src_h: f32 = @floatFromInt(self.bloom_sizes[i][1]);
                const dst_t = self.bloom_textures[i - 1].?;
                const dst_w = self.bloom_sizes[i - 1][0];
                const dst_h = self.bloom_sizes[i - 1][1];
                const u_col = std.mem.zeroInit(c.SDL_GPUColorTargetInfo, .{
                    .texture = dst_t,
                    .load_op = c.SDL_GPU_LOADOP_LOAD,
                    .store_op = c.SDL_GPU_STOREOP_STORE,
                });
                const up_pass = c.SDL_BeginGPURenderPass(cmd_buf, &u_col, 1, null) orelse return error.SdlGpuFailure;
                c.SDL_SetGPUViewport(up_pass, &.{ .x = 0, .y = 0, .w = @floatFromInt(dst_w), .h = @floatFromInt(dst_h), .min_depth = 0, .max_depth = 1 });
                c.SDL_BindGPUGraphicsPipeline(up_pass, self.bloom_up_pipeline);
                const bu_samplers = [_]c.SDL_GPUTextureSamplerBinding{.{ .texture = src_t, .sampler = linear_sampler }};
                c.SDL_BindGPUFragmentSamplers(up_pass, 0, &bu_samplers, 1);
                const up_u = BloomParams{ .p = .{ 1.0 / src_w, 1.0 / src_h, pp.bloom.scatter, 0.0 } };
                c.SDL_PushGPUFragmentUniformData(cmd_buf, 0, &up_u, @sizeOf(BloomParams));
                c.SDL_DrawGPUPrimitives(up_pass, 3, 1, 0, 0);
                c.SDL_EndGPURenderPass(up_pass);
            }
            break :blk self.bloom_textures[0].?;
        } else self.black_texture;

        // 6. PostFX Composite + Tonemap -> Swapchain (and, when a final capture is pending, an offscreen copy)
        const capture_final = self.capture_request != null and self.capture_request.? == .final;
        if (capture_final) try self.ensureCaptureFinal(tex_w, tex_h);
        for (0..(if (capture_final) @as(usize, 2) else 1)) |post_pass_index| {
            const out_col = std.mem.zeroInit(c.SDL_GPUColorTargetInfo, .{
                .texture = if (post_pass_index == 0) target_tex else self.capture_final_tex.?,
                .load_op = c.SDL_GPU_LOADOP_DONT_CARE,
                .store_op = c.SDL_GPU_STOREOP_STORE,
            });
            const pf_pass = c.SDL_BeginGPURenderPass(cmd_buf, &out_col, 1, null) orelse return error.SdlGpuFailure;
            c.SDL_SetGPUViewport(pf_pass, &.{ .x = 0, .y = 0, .w = @floatFromInt(tex_w), .h = @floatFromInt(tex_h), .min_depth = 0, .max_depth = 1 });
            c.SDL_BindGPUGraphicsPipeline(pf_pass, self.postfx_pipeline);
            const pf_samplers = [_]c.SDL_GPUTextureSamplerBinding{
                .{ .texture = hdr_tex, .sampler = linear_sampler },
                .{ .texture = bloom_tex, .sampler = linear_sampler },
                .{ .texture = self.exposure_texture, .sampler = nearest_sampler },
            };
            c.SDL_BindGPUFragmentSamplers(pf_pass, 0, &pf_samplers, pf_samplers.len);
            const pf_u = PostFxParams{
                .bloom_tint_int = .{ pp.bloom.tint[0], pp.bloom.tint[1], pp.bloom.tint[2], if (pp.bloom.enabled) pp.bloom.intensity else 0.0 },
                .grade_params = .{ pp.color_adjustments.exposure_ev, pp.color_adjustments.contrast, pp.color_adjustments.saturation, @floatFromInt(@intFromEnum(pp.tonemap_mode)) },
                .grade_tint_look = .{ pp.color_adjustments.filter_tint[0], pp.color_adjustments.filter_tint[1], pp.color_adjustments.filter_tint[2], if (pp.tonemap_look == .punchy) 1.0 else 0.0 },
                .vignette_params = .{ pp.vignette.color[0], pp.vignette.color[1], pp.vignette.color[2], if (pp.vignette.enabled) pp.vignette.intensity else 0.0 },
                .vignette_extra = .{ pp.vignette.smoothness, if (pp.auto_exposure.enabled) 1.0 else 0.0, if (pp.anti_aliasing == .fxaa) 1.0 else 0.0, 0.0 },
            };
            c.SDL_PushGPUFragmentUniformData(cmd_buf, 0, &pf_u, @sizeOf(PostFxParams));
            c.SDL_DrawGPUPrimitives(pf_pass, 3, 1, 0, 0);
            c.SDL_EndGPURenderPass(pf_pass);
        }

        if (self.capture_request) |target| {
            self.capture_request = null;
            switch (target) {
                .final => try self.enqueueCapture(cmd_buf, self.capture_final_tex.?, tex_w, tex_h, self.swapchain_format),
                .hdr => try self.enqueueCapture(cmd_buf, hdr_tex, tex_w, tex_h, c.SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT),
                .ssao => if (self.ssao_blur_texture) |t| try self.enqueueCapture(cmd_buf, t, tex_w, tex_h, c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM),
            }
        }
    }

    /// Asks the next rendered frame to read back `target`. The image is available from `takeCapture` after
    /// that frame has been submitted and `finishCapture` has run.
    pub fn requestCapture(self: *PbrGpuState, target: capture.Target) void {
        self.capture_request = target;
    }

    /// Moves the finished capture out of the backend. The caller owns the image.
    pub fn takeCapture(self: *PbrGpuState) ?capture.Image {
        const img = self.capture_result orelse return null;
        self.capture_result = null;
        return img;
    }

    fn ensureCaptureFinal(self: *PbrGpuState, w: u32, h: u32) !void {
        if (self.capture_final_tex != null and self.capture_final_w == w and self.capture_final_h == h) return;
        const tex = c.SDL_CreateGPUTexture(self.device, &std.mem.zeroInit(c.SDL_GPUTextureCreateInfo, .{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = self.swapchain_format,
            .usage = c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = w,
            .height = h,
            .layer_count_or_depth = 1,
            .num_levels = 1,
        })) orelse return error.SdlGpuFailure;
        if (self.capture_final_tex) |old| c.SDL_ReleaseGPUTexture(self.device, old);
        self.capture_final_tex = tex;
        self.capture_final_w = w;
        self.capture_final_h = h;
    }

    fn bytesPerPixel(format: c.SDL_GPUTextureFormat) ?u32 {
        if (format == c.SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT) return 8;
        if (format == c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM or format == c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM_SRGB or
            format == c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM or format == c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM_SRGB) return 4;
        return null;
    }

    /// Records a texture-to-transfer-buffer copy in `cmd_buf`. The data is only valid after the command
    /// buffer has been submitted and the GPU is idle, which `finishCapture` waits for.
    fn enqueueCapture(self: *PbrGpuState, cmd_buf: *c.SDL_GPUCommandBuffer, src: *c.SDL_GPUTexture, w: u32, h: u32, format: c.SDL_GPUTextureFormat) !void {
        const bpp = bytesPerPixel(format) orelse return error.UnsupportedCaptureFormat;
        if (self.capture_pending) |old| c.SDL_ReleaseGPUTransferBuffer(self.device, old.transfer);
        self.capture_pending = null;
        const tb = c.SDL_CreateGPUTransferBuffer(self.device, &std.mem.zeroInit(c.SDL_GPUTransferBufferCreateInfo, .{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD,
            .size = w * h * bpp,
        })) orelse return error.SdlGpuFailure;
        const cp = c.SDL_BeginGPUCopyPass(cmd_buf) orelse {
            c.SDL_ReleaseGPUTransferBuffer(self.device, tb);
            return error.SdlGpuFailure;
        };
        c.SDL_DownloadFromGPUTexture(
            cp,
            &.{ .texture = src, .mip_level = 0, .layer = 0, .x = 0, .y = 0, .z = 0, .w = w, .h = h, .d = 1 },
            &.{ .transfer_buffer = tb, .offset = 0, .pixels_per_row = w, .rows_per_layer = h },
        );
        c.SDL_EndGPUCopyPass(cp);
        self.capture_pending = .{ .transfer = tb, .width = w, .height = h, .format = format };
    }

    /// Completes a recorded capture: waits for the GPU, converts the pixels to float RGBA and stores them.
    /// Call after the frame's command buffer has been submitted. A no-op when nothing is pending.
    pub fn finishCapture(self: *PbrGpuState) void {
        const p = self.capture_pending orelse return;
        self.capture_pending = null;
        defer c.SDL_ReleaseGPUTransferBuffer(self.device, p.transfer);
        if (!c.SDL_WaitForGPUIdle(self.device)) return;
        const ptr = c.SDL_MapGPUTransferBuffer(self.device, p.transfer, false) orelse return;
        defer c.SDL_UnmapGPUTransferBuffer(self.device, p.transfer);

        const px: usize = @as(usize, p.width) * p.height;
        const rgba = self.allocator.alloc(f32, px * 4) catch return;
        const bytes: [*]const u8 = @ptrCast(ptr);
        if (p.format == c.SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT) {
            const halves: [*]const f16 = @ptrCast(@alignCast(ptr));
            for (0..px * 4) |i| rgba[i] = @floatCast(halves[i]);
        } else {
            const bgra = p.format == c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM or p.format == c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM_SRGB;
            for (0..px) |i| {
                const b0: f32 = @floatFromInt(bytes[i * 4 + 0]);
                const b1: f32 = @floatFromInt(bytes[i * 4 + 1]);
                const b2: f32 = @floatFromInt(bytes[i * 4 + 2]);
                const b3: f32 = @floatFromInt(bytes[i * 4 + 3]);
                rgba[i * 4 + 0] = (if (bgra) b2 else b0) / 255.0;
                rgba[i * 4 + 1] = b1 / 255.0;
                rgba[i * 4 + 2] = (if (bgra) b0 else b2) / 255.0;
                rgba[i * 4 + 3] = b3 / 255.0;
            }
        }
        if (self.capture_result) |*old| old.deinit(self.allocator);
        self.capture_result = .{ .width = p.width, .height = p.height, .rgba = rgba };
    }

    fn updateEnvIbl(self: *PbrGpuState, sun_dir: [3]f32, sun_col: [3]f32, sun_int: f32) !void {
        const sky_f32: [][4]f32 = if (self.frame_data.sky.kind == .hdri and self.frame_data.sky.hdri_pixels != null and self.frame_data.sky.hdri_width > 0 and self.frame_data.sky.hdri_height > 0) blk: {
            const hp = self.frame_data.sky.hdri_pixels.?;
            const hw = self.frame_data.sky.hdri_width;
            const hh = self.frame_data.sky.hdri_height;
            if (self.hdri_sky_texture) |t| c.SDL_ReleaseGPUTexture(self.device, t);
            const htex = c.SDL_CreateGPUTexture(self.device, &std.mem.zeroInit(c.SDL_GPUTextureCreateInfo, .{
                .type = c.SDL_GPU_TEXTURETYPE_2D,
                .format = c.SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT,
                .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
                .width = hw,
                .height = hh,
                .layer_count_or_depth = 1,
                .num_levels = 1,
            })) orelse return error.SdlGpuFailure;
            self.hdri_sky_texture = htex;

            const px_count: usize = @as(usize, hw) * @as(usize, hh);
            const byte_len: u32 = @intCast(px_count * 4 * @sizeOf(f16));
            const tb = c.SDL_CreateGPUTransferBuffer(self.device, &std.mem.zeroInit(c.SDL_GPUTransferBufferCreateInfo, .{
                .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
                .size = byte_len,
            })) orelse return error.SdlGpuFailure;
            defer c.SDL_ReleaseGPUTransferBuffer(self.device, tb);
            const ptr = c.SDL_MapGPUTransferBuffer(self.device, tb, false) orelse return error.SdlGpuFailure;
            const dst: [*]f16 = @ptrCast(@alignCast(ptr));
            for (0..px_count) |k| {
                dst[k * 4 + 0] = clampToF16(hp[k][0]);
                dst[k * 4 + 1] = clampToF16(hp[k][1]);
                dst[k * 4 + 2] = clampToF16(hp[k][2]);
                dst[k * 4 + 3] = clampToF16(hp[k][3]);
            }
            c.SDL_UnmapGPUTransferBuffer(self.device, tb);
            const cmd_h = c.SDL_AcquireGPUCommandBuffer(self.device) orelse return error.SdlGpuFailure;
            const cp_h = c.SDL_BeginGPUCopyPass(cmd_h) orelse return error.SdlGpuFailure;
            c.SDL_UploadToGPUTexture(
                cp_h,
                &.{ .transfer_buffer = tb, .offset = 0, .pixels_per_row = hw, .rows_per_layer = hh },
                &.{ .texture = htex, .mip_level = 0, .layer = 0, .x = 0, .y = 0, .z = 0, .w = hw, .h = hh, .d = 1 },
                false,
            );
            c.SDL_EndGPUCopyPass(cp_h);
            _ = c.SDL_SubmitGPUCommandBuffer(cmd_h);

            const ds = try ibl.downsampleEquirectRgba32f(self.allocator, hp, hw, hh, ENV_W, ENV_H);
            // Same rotation as the sky shader, so reflections and the visible sky agree.
            try ibl.rotateEquirectColumns(self.allocator, ds, ENV_W, ENV_H, self.frame_data.sky.hdri_rotation_rad / (2.0 * std.math.pi));
            const ev_scale = std.math.pow(f32, 2.0, self.frame_data.sky.hdri_exposure_ev);
            if (@abs(ev_scale - 1.0) > 1e-4) {
                for (ds) |*px_val| {
                    px_val[0] *= ev_scale;
                    px_val[1] *= ev_scale;
                    px_val[2] *= ev_scale;
                }
            }
            break :blk ds;
        } else try ibl.generateProceduralEquirectSky(
            self.allocator,
            self.frame_data.sky,
            sun_dir,
            sun_col,
            sun_int,
            ENV_W,
            ENV_H,
        );
        defer self.allocator.free(sky_f32);

        self.sky_sh = ibl.projectSkyDiffuse(sky_f32, ENV_W, ENV_H);

        const mips = try ibl.buildPrefilteredEnvMips(self.allocator, sky_f32, ENV_W, ENV_H, ENV_MIPS);
        defer {
            for (mips) |m| self.allocator.free(m);
            self.allocator.free(mips);
        }

        const cmd = c.SDL_AcquireGPUCommandBuffer(self.device) orelse return error.SdlGpuFailure;
        const cp = c.SDL_BeginGPUCopyPass(cmd) orelse return error.SdlGpuFailure;
        var mw = ENV_W;
        var mh = ENV_H;
        for (0..ENV_MIPS) |lvl| {
            const px_count: usize = @as(usize, mw) * @as(usize, mh);
            const byte_len: u32 = @intCast(px_count * 4 * @sizeOf(f16));
            const tb = c.SDL_CreateGPUTransferBuffer(self.device, &std.mem.zeroInit(c.SDL_GPUTransferBufferCreateInfo, .{
                .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
                .size = byte_len,
            })) orelse return error.SdlGpuFailure;
            defer c.SDL_ReleaseGPUTransferBuffer(self.device, tb);

            const ptr = c.SDL_MapGPUTransferBuffer(self.device, tb, false) orelse return error.SdlGpuFailure;
            const dst: [*]f16 = @ptrCast(@alignCast(ptr));
            for (0..px_count) |k| {
                const px = mips[lvl][k];
                dst[k * 4 + 0] = clampToF16(px[0]);
                dst[k * 4 + 1] = clampToF16(px[1]);
                dst[k * 4 + 2] = clampToF16(px[2]);
                dst[k * 4 + 3] = clampToF16(px[3]);
            }
            c.SDL_UnmapGPUTransferBuffer(self.device, tb);

            c.SDL_UploadToGPUTexture(
                cp,
                &.{ .transfer_buffer = tb, .offset = 0, .pixels_per_row = mw, .rows_per_layer = mh },
                &.{ .texture = self.env_prefilter_texture, .mip_level = @intCast(lvl), .layer = 0, .x = 0, .y = 0, .z = 0, .w = mw, .h = mh, .d = 1 },
                false,
            );
            mw = @max(mw / 2, 1);
            mh = @max(mh / 2, 1);
        }
        c.SDL_EndGPUCopyPass(cp);
        _ = c.SDL_SubmitGPUCommandBuffer(cmd);
    }
};

fn computeCascadeMatrix(ldir: math3d.Vec3, center: math3d.Vec3, half_ext: f32, tex_size: f32, depth_range: f32) math3d.Mat4 {
    const up = math3d.Vec3{ .x = 0, .y = if (@abs(ldir.y) > 0.95) 0.0 else 1.0, .z = if (@abs(ldir.y) > 0.95) 1.0 else 0.0 };
    const eye = math3d.Vec3{
        .x = center.x - ldir.x * (depth_range * 0.5),
        .y = center.y - ldir.y * (depth_range * 0.5),
        .z = center.z - ldir.z * (depth_range * 0.5),
    };
    const lview = math3d.Mat4.lookAt(eye, center, up);
    // Texel-snap the light-space origin to prevent shadow shimmering during camera motion.
    const texel_world = (half_ext * 2.0) / tex_size;
    const ox = lview.m[12];
    const oy = lview.m[13];
    const sx = @floor(ox / texel_world) * texel_world - ox;
    const sy = @floor(oy / texel_world) * texel_world - oy;
    var snapped = lview;
    snapped.m[12] += sx;
    snapped.m[13] += sy;
    const lproj = orthoMat(-half_ext, half_ext, -half_ext, half_ext, 0.5, depth_range);
    return math3d.Mat4.mul(lproj, snapped);
}

fn uploadBrdfLut(allocator: std.mem.Allocator, device: *c.SDL_GPUDevice, size: u32) !*c.SDL_GPUTexture {
    const pixels = try ibl.generateBrdfLutRgba8(allocator, size);
    defer allocator.free(pixels);

    const tex = c.SDL_CreateGPUTexture(device, &std.mem.zeroInit(c.SDL_GPUTextureCreateInfo, .{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
        .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
        .width = size,
        .height = size,
        .layer_count_or_depth = 1,
        .num_levels = 1,
    })) orelse return error.SdlGpuFailure;
    errdefer c.SDL_ReleaseGPUTexture(device, tex);

    const tb = c.SDL_CreateGPUTransferBuffer(device, &std.mem.zeroInit(c.SDL_GPUTransferBufferCreateInfo, .{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = @as(u32, @intCast(pixels.len)),
    })) orelse return error.SdlGpuFailure;
    defer c.SDL_ReleaseGPUTransferBuffer(device, tb);

    const ptr = c.SDL_MapGPUTransferBuffer(device, tb, false) orelse return error.SdlGpuFailure;
    @memcpy(@as([*]u8, @ptrCast(ptr))[0..pixels.len], pixels);
    c.SDL_UnmapGPUTransferBuffer(device, tb);

    const cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse return error.SdlGpuFailure;
    const cp = c.SDL_BeginGPUCopyPass(cmd) orelse return error.SdlGpuFailure;
    c.SDL_UploadToGPUTexture(
        cp,
        &.{ .transfer_buffer = tb, .offset = 0, .pixels_per_row = size, .rows_per_layer = size },
        &.{ .texture = tex, .mip_level = 0, .layer = 0, .x = 0, .y = 0, .z = 0, .w = size, .h = size, .d = 1 },
        false,
    );
    c.SDL_EndGPUCopyPass(cp);
    _ = c.SDL_SubmitGPUCommandBuffer(cmd);
    return tex;
}

fn zeroBuffer(device: *c.SDL_GPUDevice, buf: *c.SDL_GPUBuffer, size: u32) !void {
    const tb = c.SDL_CreateGPUTransferBuffer(device, &std.mem.zeroInit(c.SDL_GPUTransferBufferCreateInfo, .{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = size,
    })) orelse return error.SdlGpuFailure;
    defer c.SDL_ReleaseGPUTransferBuffer(device, tb);

    const ptr = c.SDL_MapGPUTransferBuffer(device, tb, false) orelse return error.SdlGpuFailure;
    @memset(@as([*]u8, @ptrCast(ptr))[0..size], 0);
    c.SDL_UnmapGPUTransferBuffer(device, tb);

    const cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse return error.SdlGpuFailure;
    const cp = c.SDL_BeginGPUCopyPass(cmd) orelse return error.SdlGpuFailure;
    c.SDL_UploadToGPUBuffer(cp, &.{ .transfer_buffer = tb, .offset = 0 }, &.{ .buffer = buf, .offset = 0, .size = size }, false);
    c.SDL_EndGPUCopyPass(cp);
    _ = c.SDL_SubmitGPUCommandBuffer(cmd);
}

fn perspectiveMat(fov_rad: f32, aspect: f32, near: f32, far: f32) math3d.Mat4 {
    const f = 1.0 / @tan(fov_rad * 0.5);
    const fn_ = near - far;
    return .{ .m = .{
        f / aspect, 0, 0,                           0,
        0,          f, 0,                           0,
        0,          0, far / fn_,                   -1,
        0,          0, (near * far) / fn_,          0,
    } };
}

fn clampToF16(v: f32) f16 {
    if (!std.math.isFinite(v)) return 0.0;
    return @floatCast(std.math.clamp(v, -65000.0, 65000.0));
}

fn orthoMat(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) math3d.Mat4 {
    const rl = right - left;
    const tb = top - bottom;
    const fn_ = far - near;
    return .{ .m = .{
        2.0 / rl,              0,                     0,                     0,
        0,                     2.0 / tb,              0,                     0,
        0,                     0,                     -1.0 / fn_,            0,
        -(right + left) / rl,  -(top + bottom) / tb,  -near / fn_,           1,
    } };
}

fn normalMatrixFromModel(m: [16]f32) [16]f32 {
    const a00 = m[0];
    const a01 = m[4];
    const a02 = m[8];
    const a10 = m[1];
    const a11 = m[5];
    const a12 = m[9];
    const a20 = m[2];
    const a21 = m[6];
    const a22 = m[10];
    const c00 = a11 * a22 - a12 * a21;
    const c01 = -(a10 * a22 - a12 * a20);
    const c02 = a10 * a21 - a11 * a20;
    const c10 = -(a01 * a22 - a02 * a21);
    const c11 = a00 * a22 - a02 * a20;
    const c12 = -(a00 * a21 - a01 * a20);
    const c20 = a01 * a12 - a02 * a11;
    const c21 = -(a00 * a12 - a02 * a10);
    const c22 = a00 * a11 - a01 * a10;
    const det = a00 * c00 + a01 * c01 + a02 * c02;
    if (@abs(det) < 1e-8) return math3d.Mat4.identity().m;
    const inv_det = 1.0 / det;
    // Column-major inverse-transpose (cofactor matrix stored row-wise into columns).
    return .{
        c00 * inv_det, c10 * inv_det, c20 * inv_det, 0,
        c01 * inv_det, c11 * inv_det, c21 * inv_det, 0,
        c02 * inv_det, c12 * inv_det, c22 * inv_det, 0,
        0,             0,             0,             1,
    };
}

fn invertMat4(m: [16]f32) [16]f32 {
    var inv: [16]f32 = undefined;
    inv[0] = m[5] * m[10] * m[15] - m[5] * m[11] * m[14] - m[9] * m[6] * m[15] + m[9] * m[7] * m[14] + m[13] * m[6] * m[11] - m[13] * m[7] * m[10];
    inv[4] = -m[4] * m[10] * m[15] + m[4] * m[11] * m[14] + m[8] * m[6] * m[15] - m[8] * m[7] * m[14] - m[12] * m[6] * m[11] + m[12] * m[7] * m[10];
    inv[8] = m[4] * m[9] * m[15] - m[4] * m[11] * m[13] - m[8] * m[5] * m[15] + m[8] * m[7] * m[13] + m[12] * m[5] * m[11] - m[12] * m[7] * m[9];
    inv[12] = -m[4] * m[9] * m[14] + m[4] * m[10] * m[13] + m[8] * m[5] * m[14] - m[8] * m[6] * m[13] - m[12] * m[5] * m[10] + m[12] * m[6] * m[9];
    inv[1] = -m[1] * m[10] * m[15] + m[1] * m[11] * m[14] + m[9] * m[2] * m[15] - m[9] * m[3] * m[14] - m[13] * m[2] * m[11] + m[13] * m[3] * m[10];
    inv[5] = m[0] * m[10] * m[15] - m[0] * m[11] * m[14] - m[8] * m[2] * m[15] + m[8] * m[3] * m[14] + m[12] * m[2] * m[11] - m[12] * m[3] * m[10];
    inv[9] = -m[0] * m[9] * m[15] + m[0] * m[11] * m[13] + m[8] * m[1] * m[15] - m[8] * m[3] * m[13] - m[12] * m[1] * m[11] + m[12] * m[3] * m[9];
    inv[13] = m[0] * m[9] * m[14] - m[0] * m[10] * m[13] - m[8] * m[1] * m[14] + m[8] * m[2] * m[13] + m[12] * m[1] * m[10] - m[12] * m[2] * m[9];
    inv[2] = m[1] * m[6] * m[15] - m[1] * m[7] * m[14] - m[5] * m[2] * m[15] + m[5] * m[3] * m[14] + m[13] * m[2] * m[7] - m[13] * m[3] * m[6];
    inv[6] = -m[0] * m[6] * m[15] + m[0] * m[7] * m[14] + m[4] * m[2] * m[15] - m[4] * m[3] * m[14] - m[12] * m[2] * m[7] + m[12] * m[3] * m[6];
    inv[10] = m[0] * m[5] * m[15] - m[0] * m[7] * m[13] - m[4] * m[1] * m[15] + m[4] * m[3] * m[13] + m[12] * m[1] * m[7] - m[12] * m[3] * m[5];
    inv[14] = -m[0] * m[5] * m[14] + m[0] * m[6] * m[13] + m[4] * m[1] * m[14] - m[4] * m[2] * m[13] - m[12] * m[1] * m[6] + m[12] * m[2] * m[5];
    inv[3] = -m[1] * m[6] * m[11] + m[1] * m[7] * m[10] + m[5] * m[2] * m[11] - m[5] * m[3] * m[10] - m[9] * m[2] * m[7] + m[9] * m[3] * m[6];
    inv[7] = m[0] * m[6] * m[11] - m[0] * m[7] * m[10] - m[4] * m[2] * m[11] + m[4] * m[3] * m[10] + m[8] * m[2] * m[7] - m[8] * m[3] * m[6];
    inv[11] = -m[0] * m[5] * m[11] + m[0] * m[7] * m[9] + m[4] * m[1] * m[11] - m[4] * m[3] * m[9] - m[8] * m[1] * m[7] + m[8] * m[3] * m[5];
    inv[15] = m[0] * m[5] * m[10] - m[0] * m[6] * m[9] - m[4] * m[1] * m[10] + m[4] * m[2] * m[9] + m[8] * m[1] * m[6] - m[8] * m[2] * m[5];

    var det = m[0] * inv[0] + m[1] * inv[4] + m[2] * inv[8] + m[3] * inv[12];
    if (@abs(det) < 1e-8) return math3d.Mat4.identity().m;
    det = 1.0 / det;
    for (&inv) |*v| v.* *= det;
    return inv;
}

fn createShader(device: *c.SDL_GPUDevice, diag: *engine.Diagnostics, stage: c.SDL_GPUShaderStage, code: []const u8, num_samplers: u32, num_uniforms: u32) !*c.SDL_GPUShader {
    return createShaderEx(device, diag, stage, code, num_samplers, 0, num_uniforms);
}

fn createShaderEx(device: *c.SDL_GPUDevice, _: *engine.Diagnostics, stage: c.SDL_GPUShaderStage, code: []const u8, num_samplers: u32, num_storage_buffers: u32, num_uniforms: u32) !*c.SDL_GPUShader {
    return c.SDL_CreateGPUShader(device, &std.mem.zeroInit(c.SDL_GPUShaderCreateInfo, .{
        .code_size = code.len,
        .code = code.ptr,
        .entrypoint = "main",
        .format = c.SDL_GPU_SHADERFORMAT_SPIRV,
        .stage = stage,
        .num_samplers = num_samplers,
        .num_storage_buffers = num_storage_buffers,
        .num_uniform_buffers = num_uniforms,
    })) orelse error.SdlGpuFailure;
}

fn createComputePipeline(device: *c.SDL_GPUDevice, code: []const u8, samplers: u32, rw_tex: u32, rw_buf: u32, uniforms: u32) !*c.SDL_GPUComputePipeline {
    const lsz: u32 = if (samplers > 0) 16 else 64;
    const lsy: u32 = if (samplers > 0) 16 else 1;
    return c.SDL_CreateGPUComputePipeline(device, &std.mem.zeroInit(c.SDL_GPUComputePipelineCreateInfo, .{
        .code_size = code.len,
        .code = code.ptr,
        .entrypoint = "main",
        .format = c.SDL_GPU_SHADERFORMAT_SPIRV,
        .num_samplers = samplers,
        .num_readwrite_storage_textures = rw_tex,
        .num_readwrite_storage_buffers = rw_buf,
        .num_uniform_buffers = uniforms,
        .threadcount_x = lsz,
        .threadcount_y = lsy,
        .threadcount_z = 1,
    })) orelse error.SdlGpuFailure;
}

fn createMeshPbrPipeline(
    device: *c.SDL_GPUDevice,
    vs: *c.SDL_GPUShader,
    fs: *c.SDL_GPUShader,
    color_fmt: c.SDL_GPUTextureFormat,
    depth_fmt: c.SDL_GPUTextureFormat,
    double_sided: bool,
    alpha_blend: bool,
) !*c.SDL_GPUGraphicsPipeline {
    const vb_desc = [_]c.SDL_GPUVertexBufferDescription{.{
        .slot = 0,
        .pitch = 32,
        .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
        .instance_step_rate = 0,
    }};
    const attrs = [_]c.SDL_GPUVertexAttribute{
        .{ .location = 0, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3, .offset = 0 },
        .{ .location = 1, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3, .offset = 12 },
        .{ .location = 2, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = 24 },
    };
    const targets = [_]c.SDL_GPUColorTargetDescription{.{
        .format = color_fmt,
        .blend_state = if (alpha_blend) std.mem.zeroInit(c.SDL_GPUColorTargetBlendState, .{
            .src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_SRC_ALPHA,
            .dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
            .color_blend_op = c.SDL_GPU_BLENDOP_ADD,
            .src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
            .dst_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
            .alpha_blend_op = c.SDL_GPU_BLENDOP_ADD,
            .enable_blend = true,
        }) else std.mem.zeroes(c.SDL_GPUColorTargetBlendState),
    }};
    return c.SDL_CreateGPUGraphicsPipeline(device, &std.mem.zeroInit(c.SDL_GPUGraphicsPipelineCreateInfo, .{
        .vertex_shader = vs,
        .fragment_shader = fs,
        .vertex_input_state = .{
            .vertex_buffer_descriptions = &vb_desc,
            .num_vertex_buffers = vb_desc.len,
            .vertex_attributes = &attrs,
            .num_vertex_attributes = attrs.len,
        },
        .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
        .rasterizer_state = std.mem.zeroInit(c.SDL_GPURasterizerState, .{
            .fill_mode = c.SDL_GPU_FILLMODE_FILL,
            .cull_mode = @as(c_uint, if (double_sided) c.SDL_GPU_CULLMODE_NONE else c.SDL_GPU_CULLMODE_BACK),
            .front_face = c.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE,
        }),
        .depth_stencil_state = std.mem.zeroInit(c.SDL_GPUDepthStencilState, .{
            .compare_op = c.SDL_GPU_COMPAREOP_LESS,
            .enable_depth_test = true,
            .enable_depth_write = !alpha_blend,
        }),
        .target_info = std.mem.zeroInit(c.SDL_GPUGraphicsPipelineTargetInfo, .{
            .color_target_descriptions = &targets,
            .num_color_targets = 1,
            .depth_stencil_format = depth_fmt,
            .has_depth_stencil_target = true,
        }),
    })) orelse error.SdlGpuFailure;
}

/// Depth-only shadow/prepass pipeline. `double_sided` disables back-face culling so both sides write depth.
fn createShadowPipeline(device: *c.SDL_GPUDevice, vs: *c.SDL_GPUShader, fs: *c.SDL_GPUShader, depth_fmt: c.SDL_GPUTextureFormat, double_sided: bool) !*c.SDL_GPUGraphicsPipeline {
    const vb_desc = [_]c.SDL_GPUVertexBufferDescription{.{
        .slot = 0,
        .pitch = 32,
        .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
        .instance_step_rate = 0,
    }};
    const attrs = [_]c.SDL_GPUVertexAttribute{
        .{ .location = 0, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3, .offset = 0 },
        .{ .location = 1, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3, .offset = 12 },
        .{ .location = 2, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = 24 },
    };
    return c.SDL_CreateGPUGraphicsPipeline(device, &std.mem.zeroInit(c.SDL_GPUGraphicsPipelineCreateInfo, .{
        .vertex_shader = vs,
        .fragment_shader = fs,
        .vertex_input_state = .{
            .vertex_buffer_descriptions = &vb_desc,
            .num_vertex_buffers = vb_desc.len,
            .vertex_attributes = &attrs,
            .num_vertex_attributes = attrs.len,
        },
        .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
        .rasterizer_state = std.mem.zeroInit(c.SDL_GPURasterizerState, .{
            .fill_mode = c.SDL_GPU_FILLMODE_FILL,
            .cull_mode = @as(c_uint, if (double_sided) c.SDL_GPU_CULLMODE_NONE else c.SDL_GPU_CULLMODE_BACK),
            .front_face = c.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE,
        }),
        .depth_stencil_state = std.mem.zeroInit(c.SDL_GPUDepthStencilState, .{
            .compare_op = c.SDL_GPU_COMPAREOP_LESS,
            .enable_depth_test = true,
            .enable_depth_write = true,
        }),
        .target_info = std.mem.zeroInit(c.SDL_GPUGraphicsPipelineTargetInfo, .{
            .num_color_targets = 0,
            .depth_stencil_format = depth_fmt,
            .has_depth_stencil_target = true,
        }),
    })) orelse error.SdlGpuFailure;
}

fn createFullscreenPipeline(device: *c.SDL_GPUDevice, vs: *c.SDL_GPUShader, fs: *c.SDL_GPUShader, color_fmt: c.SDL_GPUTextureFormat, additive: bool) !*c.SDL_GPUGraphicsPipeline {
    var target = std.mem.zeroInit(c.SDL_GPUColorTargetDescription, .{ .format = color_fmt });
    if (additive) {
        target.blend_state = std.mem.zeroInit(c.SDL_GPUColorTargetBlendState, .{
            .enable_blend = true,
            .src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
            .dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
            .color_blend_op = c.SDL_GPU_BLENDOP_ADD,
            .src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
            .dst_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
            .alpha_blend_op = c.SDL_GPU_BLENDOP_ADD,
        });
    }
    const targets = [_]c.SDL_GPUColorTargetDescription{target};
    return c.SDL_CreateGPUGraphicsPipeline(device, &std.mem.zeroInit(c.SDL_GPUGraphicsPipelineCreateInfo, .{
        .vertex_shader = vs,
        .fragment_shader = fs,
        .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
        .rasterizer_state = std.mem.zeroInit(c.SDL_GPURasterizerState, .{
            .fill_mode = c.SDL_GPU_FILLMODE_FILL,
            .cull_mode = c.SDL_GPU_CULLMODE_NONE,
        }),
        .target_info = std.mem.zeroInit(c.SDL_GPUGraphicsPipelineTargetInfo, .{
            .color_target_descriptions = &targets,
            .num_color_targets = 1,
        }),
    })) orelse error.SdlGpuFailure;
}

/// Fullscreen pass whose colour target is multiplied by the shader output: `dst = dst * src`.
/// Alpha is left alone, so the transmittance pass cannot change the HDR alpha channel.
fn createMultiplyFullscreenPipeline(device: *c.SDL_GPUDevice, vs: *c.SDL_GPUShader, fs: *c.SDL_GPUShader, color_fmt: c.SDL_GPUTextureFormat) !*c.SDL_GPUGraphicsPipeline {
    var target = std.mem.zeroInit(c.SDL_GPUColorTargetDescription, .{ .format = color_fmt });
    target.blend_state = std.mem.zeroInit(c.SDL_GPUColorTargetBlendState, .{
        .enable_blend = true,
        .src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ZERO,
        .dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_SRC_COLOR,
        .color_blend_op = c.SDL_GPU_BLENDOP_ADD,
        .src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ZERO,
        .dst_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
        .alpha_blend_op = c.SDL_GPU_BLENDOP_ADD,
    });
    const targets = [_]c.SDL_GPUColorTargetDescription{target};
    return c.SDL_CreateGPUGraphicsPipeline(device, &std.mem.zeroInit(c.SDL_GPUGraphicsPipelineCreateInfo, .{
        .vertex_shader = vs,
        .fragment_shader = fs,
        .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
        .rasterizer_state = std.mem.zeroInit(c.SDL_GPURasterizerState, .{
            .fill_mode = c.SDL_GPU_FILLMODE_FILL,
            .cull_mode = c.SDL_GPU_CULLMODE_NONE,
        }),
        .target_info = std.mem.zeroInit(c.SDL_GPUGraphicsPipelineTargetInfo, .{
            .color_target_descriptions = &targets,
            .num_color_targets = 1,
        }),
    })) orelse error.SdlGpuFailure;
}

fn upload1x1(device: *c.SDL_GPUDevice, rgba: [4]u8) !*c.SDL_GPUTexture {
    const tex = c.SDL_CreateGPUTexture(device, &std.mem.zeroInit(c.SDL_GPUTextureCreateInfo, .{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
        .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
        .width = 1,
        .height = 1,
        .layer_count_or_depth = 1,
        .num_levels = 1,
    })) orelse return error.SdlGpuFailure;
    errdefer c.SDL_ReleaseGPUTexture(device, tex);

    const tb = c.SDL_CreateGPUTransferBuffer(device, &std.mem.zeroInit(c.SDL_GPUTransferBufferCreateInfo, .{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = 4,
    })) orelse return error.SdlGpuFailure;
    defer c.SDL_ReleaseGPUTransferBuffer(device, tb);

    const ptr = c.SDL_MapGPUTransferBuffer(device, tb, false) orelse return error.SdlGpuFailure;
    @memcpy(@as([*]u8, @ptrCast(ptr))[0..4], &rgba);
    c.SDL_UnmapGPUTransferBuffer(device, tb);

    const cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse return error.SdlGpuFailure;
    const cp = c.SDL_BeginGPUCopyPass(cmd) orelse return error.SdlGpuFailure;
    c.SDL_UploadToGPUTexture(
        cp,
        &.{ .transfer_buffer = tb, .offset = 0, .pixels_per_row = 1, .rows_per_layer = 1 },
        &.{ .texture = tex, .mip_level = 0, .layer = 0, .x = 0, .y = 0, .z = 0, .w = 1, .h = 1, .d = 1 },
        false,
    );
    c.SDL_EndGPUCopyPass(cp);
    _ = c.SDL_SubmitGPUCommandBuffer(cmd);
    return tex;
}
