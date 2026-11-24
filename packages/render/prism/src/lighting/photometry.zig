//! Stage 05 Physical Photometry, Attenuation & Specular AA (`packages/render/prism/src/lighting/photometry.zig`).
//!
//! Canonical SI-unit lighting math shared across Prism Forward+, volumetrics, and Helios:
//! - Camera EV100 & physically calibrated exposure
//! - Point / spot luminous intensity conversion (lumens -> candela)
//! - Smooth finite-range inverse-square attenuation & cone falloff
//! - Specular anti-aliasing roughness filtering

const std = @import("std");

/// Computes camera EV100 from physical aperture `N` (f-stop), shutter speed `t` (seconds), and `iso`.
pub fn ev100FromCamera(aperture_fstop: f32, shutter_seconds: f32, iso: f32) f32 {
    const n = @max(aperture_fstop, 0.5);
    const t = @max(shutter_seconds, 1e-6);
    const s = @max(iso, 1.0);
    return std.math.log2((n * n) / t * 100.0 / s);
}

/// Converts `ev100` into a linear scene-radiance exposure multiplier (`1 / (1.2 * 2^EV100)`).
pub fn exposureFromEv100(ev100: f32) f32 {
    const max_luminance = 1.2 * std.math.pow(f32, 2.0, ev100);
    return 1.0 / @max(max_luminance, 1e-6);
}

/// Converts isotropic point-light luminous flux (lumens) to luminous intensity (candela).
pub fn pointLuminousIntensity(lumens: f32) f32 {
    return @max(lumens, 0.0) / (4.0 * std.math.pi);
}

/// Converts spotlight luminous flux (lumens) to candela normalized by its cone solid angle.
pub fn spotLuminousIntensity(lumens: f32, outer_half_angle_rad: f32) f32 {
    const cos_outer = @cos(std.math.clamp(outer_half_angle_rad, 0.01, std.math.pi * 0.5));
    const solid_angle = 2.0 * std.math.pi * @max(1.0 - cos_outer, 1e-4);
    return @max(lumens, 0.0) / solid_angle;
}

/// Smooth finite-range inverse-square attenuation window (`0` at `distance >= range`).
pub fn smoothDistanceAttenuation(distance: f32, range: f32) f32 {
    if (range <= 1e-4 or distance >= range) return 0.0;
    const d2 = distance * distance;
    const r_ratio = distance / range;
    const r2 = r_ratio * r_ratio;
    const factor = @max(0.0, 1.0 - r2 * r2);
    return (factor * factor) / (d2 + 1e-4);
}

/// Smooth angular spotlight falloff between `inner_half_angle_rad` and `outer_half_angle_rad`.
pub fn spotAngularAttenuation(cos_theta: f32, inner_half_angle_rad: f32, outer_half_angle_rad: f32) f32 {
    const cos_outer = @cos(outer_half_angle_rad);
    const cos_inner = @cos(@min(inner_half_angle_rad, outer_half_angle_rad));
    const denom = @max(cos_inner - cos_outer, 1e-4);
    const t = std.math.clamp((cos_theta - cos_outer) / denom, 0.0, 1.0);
    return t * t;
}

/// Specular anti-aliasing roughness filter (increases perceptual roughness proportionally to normal variance).
pub fn specularAaRoughness(perceptual_roughness: f32, normal_variance: f32, max_kernel_variance: f32) f32 {
    const r = std.math.clamp(perceptual_roughness, 0.045, 1.0);
    const a2 = r * r * r * r;
    const kernel = @min(2.0 * @max(normal_variance, 0.0), @max(max_kernel_variance, 0.0));
    const filtered_a2 = @min(1.0, a2 + kernel);
    return std.math.pow(f32, filtered_a2, 0.25);
}
