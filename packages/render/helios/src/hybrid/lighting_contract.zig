//! Helios Unified Indirect Lighting Contract (`packages/render/helios/src/hybrid/lighting_contract.zig`).
//!
//! Defines energy-conserving indirect diffuse/specular outputs, confidence-weighted
//! fallback blending (preventing Sky IBL / Probe / SSGI double-counting), and
//! per-view Helios quality & debug settings.

const std = @import("std");

/// Per-view Helios hybrid lighting quality tier.
pub const HeliosQualityTier = enum(u8) {
    off = 0,
    low = 1,
    medium = 2,
    high = 3,
};

/// Diagnostic visualization modes exposed by Helios.
pub const HeliosDebugMode = enum(u8) {
    none = 0,
    hit_confidence = 1,
    ray_steps = 2,
    cache_occupancy = 3,
    probe_contribution = 4,
    indirect_only = 5,
};

/// Per-view configuration for Helios hybrid indirect illumination.
pub const HeliosViewSettings = struct {
    tier: HeliosQualityTier = .medium,
    debug_mode: HeliosDebugMode = .none,
    ssgi_half_resolution: bool = true,
    ssgi_max_steps: u32 = 16,
    ssgi_thickness: f32 = 0.08,
    allow_probe_fallback: bool = true,
};

/// Unified indirect lighting output produced by a Helios evaluation.
pub const IndirectLightingOutput = struct {
    diffuse_rgb: [3]f32 = .{ 0, 0, 0 },
    specular_rgb: [3]f32 = .{ 0, 0, 0 },
    diffuse_confidence: f32 = 0.0,
    specular_confidence: f32 = 0.0,
    ray_steps_used: u32 = 0,
};

/// Combines SSGI, baked probe irradiance, and sky IBL using confidence-weighted replacement
/// so indirect lighting never double-counts energy.
pub fn combineIndirectDiffuse(
    ssgi_rgb: [3]f32,
    ssgi_confidence: f32,
    probe_rgb: [3]f32,
    probe_weight: f32,
    sky_ibl_rgb: [3]f32,
) [3]f32 {
    const pw = std.math.clamp(probe_weight, 0.0, 1.0);
    const fallback = [3]f32{
        sky_ibl_rgb[0] * (1.0 - pw) + probe_rgb[0] * pw,
        sky_ibl_rgb[1] * (1.0 - pw) + probe_rgb[1] * pw,
        sky_ibl_rgb[2] * (1.0 - pw) + probe_rgb[2] * pw,
    };
    const sc = std.math.clamp(ssgi_confidence, 0.0, 1.0);
    return .{
        fallback[0] * (1.0 - sc) + ssgi_rgb[0] * sc,
        fallback[1] * (1.0 - sc) + ssgi_rgb[1] * sc,
        fallback[2] * (1.0 - sc) + ssgi_rgb[2] * sc,
    };
}
