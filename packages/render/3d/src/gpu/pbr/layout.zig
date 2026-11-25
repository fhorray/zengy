//! Uniform/storage block layouts and queue types of the PBR renderer.
//!
//! Every `extern struct` mirrors a std140/std430 block in the WGSL shaders field for field. All members are
//! vec4/mat4 (or arrays of them), so there is no implicit padding and the layouts match across languages.

const std = @import("std");
const render_3d = @import("render_3d");

const pbr = render_3d.pbr;
const math3d = render_3d.math3d;

pub const SHADOW_W: u32 = 2048;
pub const SHADOW_H: u32 = 2048;
pub const BLOOM_MIPS: usize = 4;
pub const ENV_W: u32 = 128;
pub const ENV_H: u32 = 64;
pub const ENV_MIPS: u32 = 5;
pub const BRDF_LUT_SIZE: u32 = 128;
/// HDRI texels converted to half floats per frame while an environment rebuild is time-sliced.
pub const HDRI_PIXELS_PER_SLICE: usize = 1 << 18;

pub const PbrVertUniforms = extern struct {
    model: [16]f32,
    normal_matrix: [16]f32,
    mvp: [16]f32,
    light_vp: [4][16]f32,
    /// x = normal-offset strength in shadow texels (0 = off).
    shadow_offset: [4]f32 = .{ 0, 0, 0, 0 },
    /// World-space size of one shadow texel for each cascade.
    cascade_texel: [4]f32 = .{ 0, 0, 0, 0 },
    /// xyz = direction to the sun.
    to_sun: [4]f32 = .{ 0, 1, 0, 0 },
};

/// Uniforms for `volumetric_resolve.frag`; field order must match its std140 block.
pub const VolResolveParams = extern struct {
    inv_view_proj: [16]f32,
    prev_view_proj: [16]f32,
    cam_pos_max: [4]f32,
    size_blend: [4]f32,
};

pub const PbrFragUniforms = extern struct {
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
    /// x = receiver layer mask, y = sun layer mask.
    layer_info: [4]f32,
    cascade_info: [4]f32,
};

pub const SsaoParams = extern struct {
    proj: [16]f32,
    inv_proj: [16]f32,
    params: [4]f32,
    sun_view_dir: [4]f32,
    contact_params: [4]f32,
    fade_range: [4]f32,
};

/// Uniforms for `ssao_blur.frag`; layout must match its std140 block.
pub const SsaoBlurParams = extern struct {
    depth_range: [4]f32,
};

/// Uniforms for `volumetric_fog.frag`; field order must match its std140 block.
pub const VolFogParams = extern struct {
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
    froxel_params: [4]f32,
};

/// Uniforms for `volumetric_composite.frag`; layout must match its std140 block.
pub const VolCompositeParams = extern struct {
    inv_view_proj: [16]f32,
    cam_pos: [4]f32,
    vol_size_dist: [4]f32,
    fog_color_density: [4]f32,
};

pub const GpuPointLight = extern struct {
    pos_range: [4]f32 = .{ 0, 0, 0, 1 },
    col_radius: [4]f32 = .{ 0, 0, 0, -1 },
    /// x = light source radius in metres, y = layer mask, z = specular scale.
    shadow_params: [4]f32 = .{ 0, @floatFromInt(pbr.ALL_LAYERS), 1, 0 },
};

pub const GpuSpotLight = extern struct {
    pos_range: [4]f32 = .{ 0, 0, 0, 1 },
    dir_cos_inner: [4]f32 = .{ 0, -1, 0, 0.9 },
    col_cos_outer: [4]f32 = .{ 0, 0, 0, 0.8 },
    /// x = shadow tile, y = depth bias, z = light source radius, w = layer mask.
    shadow_params: [4]f32 = .{ -1, 0.02, 0, @floatFromInt(pbr.ALL_LAYERS) },
};

pub const GpuRectLight = extern struct {
    pos_range: [4]f32 = .{ 0, 0, 0, 1 },
    dir_two: [4]f32 = .{ 0, 0, -1, 0 },
    right_hx: [4]f32 = .{ 1, 0, 0, 1 },
    up_hy: [4]f32 = .{ 0, 1, 0, 0.5 },
    col_pad: [4]f32 = .{ 0, 0, 0, 0 },
};

pub const GpuReflectionProbe = extern struct {
    pos_int: [4]f32 = .{ 0, 0, 0, 0 },
    half_blend: [4]f32 = .{ 1, 1, 1, 1 },
    sky_box: [4]f32 = .{ 0, 0, 0, 1 },
    ground_pad: [4]f32 = .{ 0, 0, 0, 0 },
    environment_info: [4]f32 = .{0,0,0,0},
};

pub const ClusterLightsBuffer = extern struct {
    points: [256]GpuPointLight = @splat(.{}),
    spots: [256]GpuSpotLight = @splat(.{}),
    rects: [64]GpuRectLight = @splat(.{}),
    probes: [32]GpuReflectionProbe = @splat(.{}),
    gi: pbr.DynamicGiGrid = .{},
};

pub const LocalShadowBuffer = extern struct {
    shadow_vp: [16][16]f32 = @splat(math3d.Mat4.identity().m),
    atlas_rect: [16][4]f32 = @splat(.{ 0, 0, 0.25, 0.25 }),
    /// Per tile: x = tan(half fov), y = near, z = far of the tile's perspective projection.
    info: [16][4]f32 = @splat(.{ 1, 0.1, 1, 0 }),
};

pub const SkyUniforms = extern struct {
    inv_view_proj: [16]f32,
    sun_dir_size: [4]f32,
    sky_zenith_thick: [4]f32,
    sky_horizon_mode: [4]f32,
    ground_solid: [4]f32,
    sun_col_intensity: [4]f32,
    hdri_rotation: [4]f32,
};

pub const HistParams = extern struct {
    range_params: [4]f32,
    metering_params: [4]f32,
};

pub const AdaptParams = extern struct {
    ev_bounds: [4]f32,
    speed_dt: [4]f32,
    hist_range: [4]f32,
    physical_params: [4]f32,
};

pub const BloomParams = extern struct {
    p: [4]f32,
};

pub const PostFxParams = extern struct {
    bloom_tint_int: [4]f32,
    grade_params: [4]f32,
    grade_tint_look: [4]f32,
    vignette_params: [4]f32,
    vignette_extra: [4]f32,
    local_exposure: [4]f32,
};

pub const DrawOrderEntry = struct {
    index: u32,
    depth: f32,
    blend: bool,
    double_sided: bool,
};

/// Opaque draws first (front to back, double-sided last so single-sided batches stay together);
/// transparent draws after them, back to front. Ties fall back to submission order, so the order is deterministic.
pub fn drawOrderLess(_: void, a: DrawOrderEntry, b: DrawOrderEntry) bool {
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
    layers: u32 = pbr.DEFAULT_LAYER,
};

pub const QueuedShadowCaster = struct {
    mesh_asset: u64,
    model_matrix: [16]f32,
    layers: u32 = pbr.DEFAULT_LAYER,
};

/// Fragment uniforms for `shadow_mask.frag`; layout must match its std140 block.
pub const ShadowMaskParams = extern struct {
    base_color: [4]f32,
    params: [4]f32,
};

/// Which pass is consuming the queued material draws.
pub const ShadowDrawKind = enum {
    /// Directional cascade or local light tile: uses the light view-projection, includes shadow casters.
    light,
    /// Depth prepass for SSAO and contact shadows: uses the camera MVP, skips transparent materials.
    depth_prepass,
};


/// Uniforms for `froxel_integrate.frag`.
pub const FroxelIntegrateParams = extern struct { inv_view_proj: [16]f32, cam_max: [4]f32, dimensions: [4]f32 };
