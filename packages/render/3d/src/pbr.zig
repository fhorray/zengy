//! Agnostic PBR Materials, Lights, Sky/Atmosphere, & Post-Processing Contracts (`packages/render/3d/src/pbr.zig`).
//!
//! Defines backend-neutral ECS components, resources, and `PbrBackendVTable`
//! so any GPU backend (e.g. `official.graphics.sdlgpu`) or headless mock can
//! implement PBR lighting, shadows, auto exposure, bloom, and tonemapping.

const std = @import("std");
const engine = @import("engine");

/// Generational handle to a `StandardMaterial` in `MaterialRegistry`.
pub const MaterialHandle = packed struct(u64) {
    index: u32,
    generation: u32,

    pub const default: MaterialHandle = .{ .index = 0, .generation = 1 };
    pub const invalid: MaterialHandle = .{ .index = 0, .generation = 0 };
};

/// Alpha blending mode for `StandardMaterial`.
pub const AlphaMode = enum {
    opaque_,
    mask,
    blend,
};

/// Physically-based metallic-roughness material (glTF 2.0 compatible).
/// Number of usable render layers. Masks are 24-bit so the GPU can carry them exactly in a float.
pub const LAYER_COUNT: u5 = 24;
/// Mask with every layer set; the default for lights, so existing scenes light everything as before.
pub const ALL_LAYERS: u32 = 0x00FF_FFFF;
/// Layer of a mesh without a `RenderLayers` component (bit 0).
pub const DEFAULT_LAYER: u32 = 1;

/// Layer membership of a mesh. A light affects a mesh only when their masks share a bit, and a mesh only casts
/// into a light's shadow maps under the same rule. Lights default to `ALL_LAYERS`, meshes to `DEFAULT_LAYER`.
/// Layers do not affect volumetric fog scattering, reflection probes or the sky.
pub const RenderLayers = struct {
    mask: u32 = DEFAULT_LAYER,
};

/// True when a light with layer mask `light` affects (and is shadowed by) a mesh with layer mask `mesh`.
pub fn layersOverlap(light: u32, mesh: u32) bool {
    return (light & mesh & ALL_LAYERS) != 0;
}

pub const StandardMaterial = struct {
    base_color: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    emissive: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 },
    emissive_exposure_weight: f32 = 0.0,
    metallic: f32 = 0.0,
    roughness: f32 = 0.5,
    reflectance: f32 = 0.5,
    ao_strength: f32 = 1.0,
    normal_scale: f32 = 1.0,
    alpha_mode: AlphaMode = .opaque_,
    alpha_cutoff: f32 = 0.5,
    double_sided: bool = false,
    unlit: bool = false,
    /// Optional opaque texture asset IDs (`0` = none).
    base_color_tex: u64 = 0,
    normal_tex: u64 = 0,
    metallic_roughness_tex: u64 = 0,
    ao_tex: u64 = 0,
    emissive_tex: u64 = 0,
};

const MaterialSlot = struct {
    generation: u32 = 1,
    alive: bool = false,
    dirty: bool = true,
    mat: StandardMaterial = .{},
};

/// Resource storing registered `StandardMaterial`s with generational handles and dirty tracking.
pub const MaterialRegistry = struct {
    allocator: std.mem.Allocator,
    slots: std.ArrayList(MaterialSlot) = .empty,

    /// Initializes `MaterialRegistry` with a default material at `MaterialHandle.default` (index 0).
    pub fn init(allocator: std.mem.Allocator) !MaterialRegistry {
        var reg = MaterialRegistry{ .allocator = allocator };
        try reg.slots.append(allocator, .{ .generation = 1, .alive = true, .dirty = true, .mat = .{} });
        return reg;
    }

    pub fn deinit(self: *MaterialRegistry) void {
        self.slots.deinit(self.allocator);
        self.slots = .empty;
    }

    /// Registers a new `StandardMaterial` and returns its generational handle.
    pub fn add(self: *MaterialRegistry, mat: StandardMaterial) !MaterialHandle {
        for (self.slots.items[1..], 1..) |*slot, i| {
            if (!slot.alive) {
                if (slot.generation == 0) slot.generation = 1;
                slot.alive = true;
                slot.dirty = true;
                slot.mat = mat;
                return .{ .index = @intCast(i), .generation = slot.generation };
            }
        }
        const idx: u32 = @intCast(self.slots.items.len);
        try self.slots.append(self.allocator, .{
            .generation = 1,
            .alive = true,
            .dirty = true,
            .mat = mat,
        });
        return .{ .index = idx, .generation = 1 };
    }

    /// Returns a const pointer to the material for `handle`, or `null` if stale/invalid.
    pub fn getConst(self: *const MaterialRegistry, handle: MaterialHandle) ?*const StandardMaterial {
        if (handle.index >= self.slots.items.len) return null;
        const slot = &self.slots.items[handle.index];
        if (!slot.alive or slot.generation != handle.generation) return null;
        return &slot.mat;
    }

    /// Updates an existing material and marks it dirty for GPU upload.
    pub fn update(self: *MaterialRegistry, handle: MaterialHandle, mat: StandardMaterial) bool {
        if (handle.index >= self.slots.items.len) return false;
        const slot = &self.slots.items[handle.index];
        if (!slot.alive or slot.generation != handle.generation) return false;
        slot.mat = mat;
        slot.dirty = true;
        return true;
    }

    /// Removes a material (except slot 0 `MaterialHandle.default`) and bumps generation.
    pub fn remove(self: *MaterialRegistry, handle: MaterialHandle) bool {
        if (handle.index == 0 or handle.index >= self.slots.items.len) return false;
        const slot = &self.slots.items[handle.index];
        if (!slot.alive or slot.generation != handle.generation) return false;
        slot.alive = false;
        slot.generation +%= 1;
        return true;
    }
};

/// Exponential directional shadow cascade configuration.
pub const CascadeShadowConfig = struct {
    cascade_count: u8 = 4,
    minimum_distance: f32 = 0.1,
    maximum_distance: f32 = 120.0,
    first_cascade_far_bound: f32 = 10.0,
    overlap_proportion: f32 = 0.18,
};

/// Computes up to 4 exponentially spaced far distances for directional shadow cascades.
pub fn calculateCascadeBounds(cfg: CascadeShadowConfig) [4]f32 {
    var bounds = [4]f32{ cfg.maximum_distance, cfg.maximum_distance, cfg.maximum_distance, cfg.maximum_distance };
    const count = std.math.clamp(cfg.cascade_count, 1, 4);
    if (count == 1) return bounds;
    const near_b = @max(cfg.first_cascade_far_bound, 0.5);
    const far_b = @max(cfg.maximum_distance, near_b + 1.0);
    const base = std.math.pow(f32, far_b / near_b, 1.0 / @as(f32, @floatFromInt(count - 1)));
    for (0..count) |i| {
        bounds[i] = near_b * std.math.pow(f32, base, @as(f32, @floatFromInt(i)));
    }
    return bounds;
}

/// Directional light component (sun/moon). Direction is derived from `Transform3D` forward (`-Z` rotated) or explicit `direction`.
pub const DirectionalLight = struct {
    color: [3]f32 = .{ 1.0, 0.98, 0.94 },
    illuminance_lux: f32 = 10_000.0,
    direction: [3]f32 = .{ -0.4, -0.8, -0.45 },
    shadows_enabled: bool = true,
    shadow_depth_bias: f32 = 0.005,
    /// Receiver normal offset strength: `shadow_normal_bias * 50` shadow texels at grazing angles (needs
    /// `ShadowQuality.normal_offset`). 0.05 removes acne at zero depth bias in the acne study scenarios.
    shadow_normal_bias: f32 = 0.05,
    /// Layers this light affects (see `RenderLayers`).
    layers: u32 = ALL_LAYERS,
    pcss_enabled: bool = false,
    /// Tangent of the light's apparent half-size for blocker-search PCSS (`ShadowQuality.pcss`); larger values give
    /// wider penumbrae. 0.03 is a soft, readable default; the real sun is about 0.005.
    pcss_light_size: f32 = 0.03,
    cascade_count: u8 = 4,
    cascades: CascadeShadowConfig = .{},
};

/// Omnidirectional point light component (intensity in lumens).
pub const PointLight = struct {
    color: [3]f32 = .{ 1.0, 1.0, 1.0 },
    intensity_lumens: f32 = 800.0,
    range: f32 = 20.0,
    radius: f32 = 0.05,
    shadows_enabled: bool = false,
    shadow_depth_bias: f32 = 0.02,
    /// Layers this light affects (see `RenderLayers`).
    layers: u32 = ALL_LAYERS,
    /// Scale of the specular lobe: 1 is a normal light, 0 makes it diffuse-only (indirect bounce lights).
    specular_scale: f32 = 1.0,
};

/// Cone spotlight component (intensity in lumens, angles in radians).
pub const SpotLight = struct {
    color: [3]f32 = .{ 1.0, 1.0, 1.0 },
    intensity_lumens: f32 = 1200.0,
    range: f32 = 25.0,
    direction: [3]f32 = .{ 0.0, -1.0, 0.0 },
    inner_angle_rad: f32 = 0.35,
    outer_angle_rad: f32 = 0.65,
    /// Physical size of the light source in metres; sets the penumbra width with `ShadowQuality.pcss`.
    radius: f32 = 0.05,
    shadows_enabled: bool = false,
    shadow_depth_bias: f32 = 0.02,
    /// Layers this light affects (see `RenderLayers`).
    layers: u32 = ALL_LAYERS,
};

/// Rectangular area light component (intensity in lumens).
pub const RectLight = struct {
    color: [3]f32 = .{ 1.0, 1.0, 1.0 },
    intensity_lumens: f32 = 1500.0,
    width: f32 = 2.0,
    height: f32 = 1.0,
    range: f32 = 20.0,
    two_sided: bool = false,
    /// Layers this light affects (see `RenderLayers`).
    layers: u32 = ALL_LAYERS,
};

/// Global ambient light resource (or hemisphere fallback when sky ambient is disabled).
pub const AmbientLight = struct {
    color: [3]f32 = .{ 0.85, 0.90, 1.0 },
    brightness: f32 = 0.18,
};

/// Skybox rendering mode.
pub const SkyboxKind = enum {
    procedural,
    solid_color,
    hdri,
};

/// Sun disc rendering quality in procedural sky mode.
pub const SunDisk = enum {
    none,
    simple,
    high_quality,
};

/// Scene sky & atmospheric scattering resource.
pub const SkyEnvironment = struct {
    kind: SkyboxKind = .procedural,
    sun_disk: SunDisk = .high_quality,
    sun_size: f32 = 0.035,
    atmosphere_thickness: f32 = 1.0,
    rayleigh_scale: f32 = 1.0,
    mie_scale: f32 = 1.0,
    sky_tint: [3]f32 = .{ 0.08, 0.24, 0.62 },
    horizon_tint: [3]f32 = .{ 0.38, 0.52, 0.72 },
    ground_albedo: [3]f32 = .{ 0.06, 0.06, 0.07 },
    solid_color: [3]f32 = .{ 0.07, 0.09, 0.13 },
    hdri_texture: u64 = 0,
    hdri_pixels: ?[]const [4]f32 = null,
    hdri_width: u32 = 0,
    hdri_height: u32 = 0,
    hdri_exposure_ev: f32 = 0.0,
    hdri_rotation_rad: f32 = 0.0,
};

/// Volumetric froxel fog configuration.
pub const VolumetricFogConfig = struct {
    enabled: bool = false,
    anisotropy: f32 = 0.6,
    scattering: f32 = 0.04,
    max_distance: f32 = 80.0,
    /// Ray-march budget per pixel, clamped to 8..128 by the backend.
    raymarch_steps: u32 = 64,
    froxel_enabled: bool = false,
    froxel_pixel_size: u32 = 12,
    froxel_slices: u32 = 32,
    /// Treat scattering as a single-scattering albedo fraction of extinction.
    physical_scattering: bool = false,
    /// Ray-march at half resolution and upsample depth-aware (about 4x fewer marched pixels).
    /// Off by default: full resolution keeps thin shafts sharp; opt in on GPUs where the cost matters.
    half_resolution: bool = false,
    /// Accumulate the scatter over frames: the ray-march jitter changes every frame and the previous result is
    /// reprojected, clamped to the current neighbourhood and blended. Smooths the sampling noise of 64 steps.
    /// Off by default; history is dropped on resize, camera cuts and when the effect is toggled.
    temporal: bool = false,
    /// Weight of the current frame in the temporal blend (0.05 = smooth and laggy, 1.0 = no history).
    temporal_blend: f32 = 0.1,
};

/// Exponential/height distance fog resource.
pub const FogSettings = struct {
    enabled: bool = false,
    color: [3]f32 = .{ 0.72, 0.77, 0.84 },
    density: f32 = 0.015,
    start_distance: f32 = 10.0,
    height_falloff: f32 = 0.0,
    volumetric: VolumetricFogConfig = .{},
};

/// Opt-in physical camera model; scale converts one existing scene RGB luminance
/// unit to cd/m². It does not recalibrate light emitters or the GI transport.
pub const PhysicalExposureSettings = struct {
    enabled: bool = false,
    luminance_scale: f32 = 1.0,
    /// Internal scene buffer gain in stops; zero leaves storage unchanged.
    pre_exposure_stops: f32 = 0.0,
    /// Optional bounded spatial metering after global exposure; 0 disables it.
    local_exposure_strength: f32 = 0.0,
    local_exposure_radius: f32 = 0.05,
    local_exposure_max_stops: f32 = 1.0,
    aperture: f32 = 4.0,
    shutter_seconds: f32 = 1.0 / 60.0,
    iso: f32 = 100.0,
    min_ev100: f32 = -6.0,
    max_ev100: f32 = 20.0,

    pub fn scaleLog2(self: PhysicalExposureSettings) f32 {
        const scale = if (std.math.isFinite(self.luminance_scale)) std.math.clamp(self.luminance_scale, 1e-6, 1e6) else 1.0;
        return @log2(scale);
    }

    pub fn manualEv100(self: PhysicalExposureSettings) f32 {
        const aperture = if (std.math.isFinite(self.aperture)) std.math.clamp(self.aperture, 0.5, 64.0) else 4.0;
        const shutter = if (std.math.isFinite(self.shutter_seconds)) std.math.clamp(self.shutter_seconds, 1e-6, 60.0) else 1.0 / 60.0;
        const iso = if (std.math.isFinite(self.iso)) std.math.clamp(self.iso, 1.0, 204800.0) else 100.0;
        return @log2(aperture * aperture / shutter * 100.0 / iso);
    }
};

/// Histogram-based automatic camera exposure settings.
pub const AutoExposureSettings = struct {
    physical: PhysicalExposureSettings = .{},
    history_epoch: u64 = 0,
    enabled: bool = false,
    min_ev100: f32 = -4.0,
    max_ev100: f32 = 8.0,
    low_percent: f32 = 0.10,
    high_percent: f32 = 0.90,
    /// Adaptation speed (stops/s in hybrid mode, 1/s in legacy mode) while exposure gain rises (moving into the
    /// dark). Human eyes adapt to darkness slowly, so this is the smaller default.
    speed_brighten: f32 = 1.0,
    /// Adaptation speed (stops/s in hybrid mode, 1/s in legacy mode) while exposure gain falls (moving into light).
    speed_darken: f32 = 3.0,
    compensation_ev: f32 = 0.0,
    metering_mask_tex: u64 = 0,
    /// One sample per stride x stride pixels; 1 restores full-resolution metering.
    metering_stride: u32 = 4,
    histogram_min_log2: f32 = -12.0,
    histogram_max_log2: f32 = 12.0,
    /// 0 = uniform histogram; 1 = strong center weighting.
    metering_center_weight: f32 = 0.0,
    /// 0 preserves exponential adaptation (rates in 1/s). Positive values use stops/s.
    hybrid_transition_stops: f32 = 0.0,
    /// Set for a single frame on a camera cut; do not leave enabled every frame.
    reset_history: bool = false,
};

/// HDR bloom settings.
pub const BloomSettings = struct {
    enabled: bool = true,
    intensity: f32 = 0.3,
    threshold: f32 = 1.0,
    scatter: f32 = 0.7,
    tint: [3]f32 = .{ 1.0, 1.0, 1.0 },
};

/// Tonemapping curve applied during HDR -> SDR composite.
pub const TonemapMode = enum {
    none,
    neutral,
    aces,
    agx,
    pbr_neutral,
};

/// AgX creative grade look.
pub const TonemapLook = enum {
    base,
    punchy,
};

/// Color grading adjustments applied post-tonemap/composite.
pub const ColorAdjustments = struct {
    exposure_ev: f32 = 0.0,
    contrast: f32 = 1.0,
    saturation: f32 = 1.0,
    filter_tint: [3]f32 = .{ 1.0, 1.0, 1.0 },
};

/// Screen-edge vignette settings.
pub const VignetteSettings = struct {
    enabled: bool = false,
    intensity: f32 = 0.35,
    smoothness: f32 = 0.45,
    color: [3]f32 = .{ 0.0, 0.0, 0.0 },
};

/// Screen-space ambient occlusion settings.
pub const SsaoSettings = struct {
    /// Horizon-direction AO alternative to legacy hemisphere sampling.
    horizon_based: bool = false,
    enabled: bool = false,
    radius: f32 = 0.5,
    intensity: f32 = 1.0,
    bias: f32 = 0.025,
};

/// Screen-space ray-marched contact shadow settings.
pub const ContactShadowSettings = struct {
    enabled: bool = false,
    length: f32 = 0.45,
    thickness: f32 = 0.12,
    opacity: f32 = 0.85,
    sample_count: u32 = 12,
    distance_fade: f32 = 35.0,
};

/// Local box-projected reflection & irradiance probe component.
pub const ReflectionProbe = struct {
    environment_texture: u64 = 0,
    environment_mips: u32 = 1,
    half_extents: [3]f32 = .{ 6.0, 4.0, 6.0 },
    blend_distance: f32 = 1.5,
    intensity: f32 = 1.0,
    box_projection: bool = true,
    sky_tint: [3]f32 = .{ 0.25, 0.28, 0.34 },
    ground_tint: [3]f32 = .{ 0.12, 0.11, 0.10 },
    /// Scale of the probe's diffuse irradiance (reflections are not scaled). A sealed room wants almost no diffuse
    /// ambient, so the outside sky cannot light it, but still wants visible reflections of its dim interior.
    diffuse_scale: f32 = 1.0,
};

/// Extracted reflection probe snapshot for backend submission.
pub const ExtractedReflectionProbe = struct {
    environment_texture: u64 = 0,
    environment_mips: u32 = 1,
    position: [3]f32,
    half_extents: [3]f32,
    blend_distance: f32,
    intensity: f32,
    box_projection: bool,
    sky_tint: [3]f32,
    ground_tint: [3]f32,
    diffuse_scale: f32 = 1.0,
};

/// Camera component configuring the HDR & post-processing stack.
/// Screen-space anti-aliasing applied in the post-process pass. Future modes (SMAA, TAA) extend this enum.
pub const AntiAliasingMode = enum(u32) {
    none = 0,
    fxaa = 1,
};

/// How the CPU work of an environment (IBL) rebuild is scheduled.
pub const IblRebuildBudget = enum(u32) {
    /// Rebuild everything in the frame that notices the change. Simple, but a large HDRI causes one long frame.
    unlimited = 0,
    /// Spread the rebuild over several frames (HDRI conversion in slices, one prefiltered mip per frame).
    /// The old environment stays visible until the new one is complete, then both swap in one frame.
    sliced = 1,
};

/// Shadow scalability switches. Every field defaults to the established behaviour.
pub const ShadowQuality = struct {
    /// Offset the receiver along its normal before the cascade lookup, by `shadow_normal_bias * 50` shadow texels
    /// scaled by the surface slope. Removes acne without a large depth bias that would detach contacts.
    normal_offset: bool = false,
    /// Give the limited local shadow tiles to the most relevant lights (intensity attenuated by distance to the
    /// light's range sphere) instead of the first ones submitted.
    prioritize_local_lights: bool = false,
    /// Re-render the cascades and the local atlas only when casters, lights or cascade frustums changed.
    static_cache: bool = false,
    /// Choose each local light's tile size (256..1024) from its apparent size instead of a fixed 512.
    adaptive_atlas: bool = false,
    /// Contact-hardening penumbra from a blocker search. Directional lights need `pcss_enabled` (size from
    /// `pcss_light_size`); point and spot lights use their `radius` as the source size. Without this switch
    /// `pcss_enabled` only widens the sun's filter with distance and local lights keep a fixed filter.
    pcss: bool = false,
    /// Smallest depth bias, in metres, applied to the cascade lookup. The default is conservative enough to hide
    /// acne on any surface; lowering it (with a normal offset) tightens contact shadows.
    depth_bias_floor_m: f32 = 0.055,
};

/// Quality and cost switches that do not change what the scene means, only how the backend renders it.
pub const ScreenTransportSettings = struct {
    ssr_strength: f32 = 0.0,
    ssgi_strength: f32 = 0.0,
    max_distance: f32 = 20.0,
    thickness: f32 = 0.15,
    max_iterations: u32 = 48,
    diffuse_rays: u32 = 1,
};

pub const RenderQuality = struct {
    screen_transport: ScreenTransportSettings = .{},
    /// Four finite emitter samples instead of the legacy closest-point approximation.
    area_light_quadrature: bool = false,
    ltc_area_lights: bool = false,
    specular_aa: bool = false,
    /// Reuse the depth prepass (written for SSAO and contact shadows) as the depth buffer of the lit pass, so
    /// opaque fragments are shaded once. Only takes effect while the prepass runs. Off by default until the
    /// capture suite shows identical silhouettes on the target GPUs.
    reuse_depth_prepass: bool = false,
    ibl_rebuild_budget: IblRebuildBudget = .unlimited,
    /// Keep the sun disc and halo out of the diffuse (SH9) irradiance of a procedural sky when a directional light
    /// already lights the scene. The sun is then added once, by the shadowed analytic light, instead of twice (the
    /// second time unshadowed). Reflections keep the disc. HDRI skies cannot be separated and are unaffected.
    sun_in_ibl_diffuse: bool = false,
    shadows: ShadowQuality = .{},
};

pub const PostProcessSettings = struct {
    auto_exposure: AutoExposureSettings = .{},
    bloom: BloomSettings = .{},
    tonemap_mode: TonemapMode = .agx,
    tonemap_look: TonemapLook = .base,
    color_adjustments: ColorAdjustments = .{},
    vignette: VignetteSettings = .{},
    ssao: SsaoSettings = .{},
    contact_shadows: ContactShadowSettings = .{},
    anti_aliasing: AntiAliasingMode = .fxaa,
    quality: RenderQuality = .{},
};

/// Extracted directional light snapshot for backend submission.
pub const ExtractedDirectionalLight = struct {
    direction: [3]f32,
    color: [3]f32,
    illuminance_lux: f32,
    shadows_enabled: bool,
    shadow_depth_bias: f32,
    shadow_normal_bias: f32,
    pcss_enabled: bool = false,
    pcss_light_size: f32 = 0.03,
    layers: u32 = ALL_LAYERS,
    cascade_count: u8,
    cascade_bounds: [4]f32 = .{ 10.0, 23.0, 52.0, 120.0 },
    overlap_proportion: f32 = 0.18,
    minimum_distance: f32 = 0.1,
};

/// Extracted point light snapshot for backend submission.
pub const ExtractedPointLight = struct {
    position: [3]f32,
    color: [3]f32,
    intensity_lumens: f32,
    range: f32,
    radius: f32,
    shadows_enabled: bool,
    shadow_depth_bias: f32 = 0.02,
    layers: u32 = ALL_LAYERS,
    specular_scale: f32 = 1.0,
};

/// Extracted spotlight snapshot for backend submission.
pub const ExtractedSpotLight = struct {
    position: [3]f32,
    direction: [3]f32,
    color: [3]f32,
    intensity_lumens: f32,
    range: f32,
    inner_angle_rad: f32,
    outer_angle_rad: f32,
    radius: f32 = 0.05,
    shadows_enabled: bool,
    shadow_depth_bias: f32 = 0.02,
    layers: u32 = ALL_LAYERS,
};

/// Extracted rectangular area light snapshot for backend submission.
pub const ExtractedRectLight = struct {
    position: [3]f32,
    direction: [3]f32,
    right: [3]f32,
    up: [3]f32,
    color: [3]f32,
    intensity_lumens: f32,
    half_extents: [2]f32,
    range: f32,
    two_sided: bool,
    layers: u32 = ALL_LAYERS,
};

/// Per-frame extracted PBR lighting, environment, and post-processing view.
/// CPU/GPU layout shared with Helios' dynamic six-lobe probe grid.
pub const DynamicGiProbe = extern struct {
    lobes: [6][4]f32 = @splat(.{ 0, 0, 0, 0 }),
    moments: [6][4]f32 = @splat(.{ 0, 0, 0, 0 }),
    offset_validity: [4]f32 = .{ 0, 0, 0, 0 },
};
pub const DynamicGiGrid = extern struct {
    origin_enabled: [4]f32 = .{ 0, 0, 0, 0 },
    spacing: [4]f32 = .{ 1, 1, 1, 0 },
    probes: [64]DynamicGiProbe = @splat(.{}),
};
comptime {
    if (@sizeOf(DynamicGiProbe) != 208 or @sizeOf(DynamicGiGrid) != 13344) @compileError("Dynamic GI GPU layout mismatch");
}

pub const GpuGiNode=extern struct {aabb_min:[3]f32,left_or_first:u32,aabb_max:[3]f32,prim_count:u32};
pub const GpuGiTriangle=extern struct {v0:[3]f32,material:u32,v1:[3]f32,mask:u32,v2:[3]f32,pad:u32=0};
pub const GpuGiMaterial=extern struct {albedo_metal:[4]f32,emissive_rough:[4]f32};
comptime {if(@sizeOf(GpuGiNode)!=32 or @sizeOf(GpuGiTriangle)!=48 or @sizeOf(GpuGiMaterial)!=32)@compileError("GPU GI geometry ABI mismatch");}
/// Borrowed read-only geometry snapshot. Producer must retain slices through render recording.
pub const GpuGiInput=struct {
    enabled:bool=false,
    geometry_revision:u64=0,
    grid_epoch:u64=0,
    nodes:[]const GpuGiNode=&.{},
    triangles:[]const GpuGiTriangle=&.{},
    materials:[]const GpuGiMaterial=&.{},
    rays_per_probe:u32=32,
    probes_per_frame:u32=2,
};
pub const ExtractedPbrFrame = struct {
    gpu_gi:GpuGiInput=.{},
    dynamic_gi: DynamicGiGrid = .{},
    camera_key: u64 = 0,
    camera_position: [3]f32 = .{ 0, 0, 0 },
    camera_forward: [3]f32 = .{ 0, 0, -1 },
    view_matrix: [16]f32 = .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    },
    view_proj: [16]f32 = .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    },
    proj_matrix: [16]f32 = .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    },
    ambient: AmbientLight = .{},
    sky: SkyEnvironment = .{},
    fog: FogSettings = .{},
    post_process: PostProcessSettings = .{},
    directional_lights: []const ExtractedDirectionalLight = &.{},
    point_lights: []const ExtractedPointLight = &.{},
    spot_lights: []const ExtractedSpotLight = &.{},
    rect_lights: []const ExtractedRectLight = &.{},
    reflection_probes: []const ExtractedReflectionProbe = &.{},
    dt: f32 = 0.0,
};

/// Backend-neutral PBR rendering vtable implemented by `official.graphics.sdlgpu` or mocks.
pub const PbrBackendVTable = struct {
    ctx: *anyopaque,
    beginPbrFrame: *const fn (ctx: *anyopaque, frame: *const ExtractedPbrFrame) anyerror!void,
    submitLitMesh: *const fn (
        ctx: *anyopaque,
        mesh_asset: u64,
        model_matrix: [16]f32,
        mvp_matrix: [16]f32,
        material: StandardMaterial,
        tint: [4]f32,
    ) anyerror!void,
    submitShadowCaster: ?*const fn (
        ctx: *anyopaque,
        mesh_asset: u64,
        model_matrix: [16]f32,
    ) anyerror!void = null,
    /// Optional: sets the layer mask of the next `submitLitMesh` / `submitShadowCaster` call; the backend resets it to
    /// `DEFAULT_LAYER` afterwards. Backends without layer support leave it null and treat every mesh as layer 0.
    setDrawLayers: ?*const fn (ctx: *anyopaque, layers: u32) void = null,
    endPbrFrame: *const fn (ctx: *anyopaque) anyerror!void,
};
