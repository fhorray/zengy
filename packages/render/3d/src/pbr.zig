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
    shadow_normal_bias: f32 = 0.02,
    pcss_enabled: bool = false,
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
};

/// Cone spotlight component (intensity in lumens, angles in radians).
pub const SpotLight = struct {
    color: [3]f32 = .{ 1.0, 1.0, 1.0 },
    intensity_lumens: f32 = 1200.0,
    range: f32 = 25.0,
    direction: [3]f32 = .{ 0.0, -1.0, 0.0 },
    inner_angle_rad: f32 = 0.35,
    outer_angle_rad: f32 = 0.65,
    shadows_enabled: bool = false,
    shadow_depth_bias: f32 = 0.02,
};

/// Rectangular area light component (intensity in lumens).
pub const RectLight = struct {
    color: [3]f32 = .{ 1.0, 1.0, 1.0 },
    intensity_lumens: f32 = 1500.0,
    width: f32 = 2.0,
    height: f32 = 1.0,
    range: f32 = 20.0,
    two_sided: bool = false,
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
    /// Ray-march at half resolution and upsample depth-aware (about 4x fewer marched pixels).
    /// Off by default: full resolution keeps thin shafts sharp; opt in on GPUs where the cost matters.
    half_resolution: bool = false,
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

/// Histogram-based automatic camera exposure settings.
pub const AutoExposureSettings = struct {
    enabled: bool = false,
    min_ev100: f32 = -4.0,
    max_ev100: f32 = 8.0,
    low_percent: f32 = 0.10,
    high_percent: f32 = 0.90,
    speed_brighten: f32 = 3.0,
    speed_darken: f32 = 1.0,
    compensation_ev: f32 = 0.0,
    metering_mask_tex: u64 = 0,
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
    half_extents: [3]f32 = .{ 6.0, 4.0, 6.0 },
    blend_distance: f32 = 1.5,
    intensity: f32 = 1.0,
    box_projection: bool = true,
    sky_tint: [3]f32 = .{ 0.25, 0.28, 0.34 },
    ground_tint: [3]f32 = .{ 0.12, 0.11, 0.10 },
};

/// Extracted reflection probe snapshot for backend submission.
pub const ExtractedReflectionProbe = struct {
    position: [3]f32,
    half_extents: [3]f32,
    blend_distance: f32,
    intensity: f32,
    box_projection: bool,
    sky_tint: [3]f32,
    ground_tint: [3]f32,
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

/// Quality and cost switches that do not change what the scene means, only how the backend renders it.
pub const RenderQuality = struct {
    /// Reuse the depth prepass (written for SSAO and contact shadows) as the depth buffer of the lit pass, so
    /// opaque fragments are shaded once. Only takes effect while the prepass runs. Off by default until the
    /// capture suite shows identical silhouettes on the target GPUs.
    reuse_depth_prepass: bool = false,
    ibl_rebuild_budget: IblRebuildBudget = .unlimited,
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
    shadows_enabled: bool,
    shadow_depth_bias: f32 = 0.02,
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
};

/// Per-frame extracted PBR lighting, environment, and post-processing view.
pub const ExtractedPbrFrame = struct {
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
    endPbrFrame: *const fn (ctx: *anyopaque) anyerror!void,
};
