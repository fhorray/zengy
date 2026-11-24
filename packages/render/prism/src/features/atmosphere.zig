//! Stage 07 Physical Atmosphere, Froxel Slicing & Local Fog Volumes (`packages/render/prism/src/features/atmosphere.zig`).
//!
//! Provides pure-Zig atmospheric scattering, logarithmic froxel depth slicing,
//! physically consistent transmittance composition, and local fog volume evaluation.

const std = @import("std");

/// Physical atmosphere parameters for Rayleigh + Mie sky scattering.
pub const AtmosphereSettings = struct {
    rayleigh_coeff: [3]f32 = .{ 5.8e-3, 13.5e-3, 33.1e-3 },
    mie_coeff: f32 = 21.0e-3,
    mie_anisotropy: f32 = 0.76,
    sun_intensity: f32 = 20.0,
    ground_albedo: [3]f32 = .{ 0.25, 0.24, 0.22 },
};

/// Rayleigh scattering phase function for cosine scattering angle `cos_theta`.
pub fn rayleighPhase(cos_theta: f32) f32 {
    const c = std.math.clamp(cos_theta, -1.0, 1.0);
    return (3.0 / (16.0 * std.math.pi)) * (1.0 + c * c);
}

/// Henyey-Greenstein Mie phase function with anisotropy `g` in `(-1, 1)`.
pub fn henyeyGreensteinPhase(cos_theta: f32, g_in: f32) f32 {
    const c = std.math.clamp(cos_theta, -1.0, 1.0);
    const g = std.math.clamp(g_in, -0.95, 0.95);
    const g2 = g * g;
    const denom = @max(1.0 + g2 - 2.0 * g * c, 1e-4);
    return (1.0 - g2) / (4.0 * std.math.pi * std.math.pow(f32, denom, 1.5));
}

/// Evaluates single-scattering sky radiance for unit `view_dir` and unit `sun_dir`.
pub fn evaluateSkyRadiance(cfg: AtmosphereSettings, view_dir: [3]f32, sun_dir: [3]f32) [3]f32 {
    const cos_theta = view_dir[0] * sun_dir[0] + view_dir[1] * sun_dir[1] + view_dir[2] * sun_dir[2];
    const zenith = @max(view_dir[1], 0.02);
    const optical_depth = 1.0 / (zenith + 0.15);

    const pr = rayleighPhase(cos_theta);
    const pm = henyeyGreensteinPhase(cos_theta, cfg.mie_anisotropy);

    var out: [3]f32 = undefined;
    inline for (0..3) |i| {
        const scatter = cfg.rayleigh_coeff[i] * pr + cfg.mie_coeff * pm;
        const ext = @exp(-(cfg.rayleigh_coeff[i] + cfg.mie_coeff) * optical_depth * 6.0);
        out[i] = @max(0.0, scatter * optical_depth * cfg.sun_intensity * (1.0 - ext * 0.5));
    }
    if (view_dir[1] < 0.0) {
        const g_fade = std.math.clamp(-view_dir[1] * 4.0, 0.0, 1.0);
        inline for (0..3) |i| {
            out[i] = out[i] * (1.0 - g_fade) + cfg.ground_albedo[i] * g_fade * 0.35;
        }
    }
    return out;
}

/// Computes world-space depth at the end of logarithmic froxel slice `slice` in `[0..num_slices]`.
pub fn froxelSliceDepth(slice: u32, num_slices: u32, near: f32, far: f32) f32 {
    const n = @max(near, 0.05);
    const f = @max(far, n + 0.1);
    const s_frac = @as(f32, @floatFromInt(@min(slice, num_slices))) / @as(f32, @floatFromInt(@max(num_slices, 1)));
    return n * std.math.pow(f32, f / n, s_frac);
}

/// Maps positive linear view depth to normalized froxel slice coordinate `[0..1]`.
pub fn depthToFroxelUv(linear_depth: f32, near: f32, far: f32) f32 {
    const n = @max(near, 0.05);
    const f = @max(far, n + 0.1);
    const d = std.math.clamp(linear_depth, n, f);
    return std.math.log2(d / n) / std.math.log2(f / n);
}

/// Physically consistent fog composition: `L_out = T * L_scene + L_scatter`.
/// Guarantees identity (`L_out == L_scene`) when `transmittance == 1` and `scatter == 0`.
pub fn composeFogRadiance(scene_rgb: [3]f32, scatter_rgb: [3]f32, transmittance: f32) [3]f32 {
    const t = std.math.clamp(transmittance, 0.0, 1.0);
    return .{
        scene_rgb[0] * t + scatter_rgb[0],
        scene_rgb[1] * t + scatter_rgb[1],
        scene_rgb[2] * t + scatter_rgb[2],
    };
}

/// Shape of a local fog volume.
pub const FogVolumeShape = enum(u8) {
    box = 0,
    sphere = 1,
};

/// Local fog volume with height falloff and edge feathering.
pub const LocalFogVolume = struct {
    shape: FogVolumeShape = .box,
    center: [3]f32 = .{ 0, 0, 0 },
    half_extents: [3]f32 = .{ 5, 3, 5 },
    density: f32 = 0.05,
    height_falloff: f32 = 0.0,
    edge_fade: f32 = 0.5,
};

/// Evaluates local fog density contributed by `vol` at `world_pos`.
pub fn evaluateLocalFogDensity(vol: LocalFogVolume, world_pos: [3]f32) f32 {
    if (vol.density <= 0.0) return 0.0;
    const dx = @abs(world_pos[0] - vol.center[0]);
    const dy = @abs(world_pos[1] - vol.center[1]);
    const dz = @abs(world_pos[2] - vol.center[2]);

    var shape_w: f32 = 0.0;
    switch (vol.shape) {
        .box => {
            if (dx > vol.half_extents[0] or dy > vol.half_extents[1] or dz > vol.half_extents[2]) return 0.0;
            const d_edge = @min(vol.half_extents[0] - dx, @min(vol.half_extents[1] - dy, vol.half_extents[2] - dz));
            shape_w = if (vol.edge_fade > 1e-4) std.math.clamp(d_edge / vol.edge_fade, 0.0, 1.0) else 1.0;
        },
        .sphere => {
            const r = @max(vol.half_extents[0], 1e-4);
            const dist = @sqrt(dx * dx + dy * dy + dz * dz);
            if (dist >= r) return 0.0;
            shape_w = if (vol.edge_fade > 1e-4) std.math.clamp((r - dist) / vol.edge_fade, 0.0, 1.0) else 1.0;
        },
    }

    const h_above = @max(0.0, world_pos[1] - (vol.center[1] - vol.half_extents[1]));
    const h_atten = if (vol.height_falloff > 0.0) @exp(-vol.height_falloff * h_above) else 1.0;
    return vol.density * shape_w * h_atten;
}
