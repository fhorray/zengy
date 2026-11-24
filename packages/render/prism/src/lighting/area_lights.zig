//! Stage 05 Physical Area Lights, IES Profiles, Light Layers & Material Lobes (`packages/render/prism/src/lighting/area_lights.zig`).
//!
//! Pure-Zig physical lighting extensions shared by Prism Forward+, baked GI, and Helios:
//! - Rectangular area light diffuse/specular evaluation (representative point & solid angle)
//! - IES photometric angular intensity profiles
//! - Light/shadow layer masks
//! - Extended PBR material feature flags, clearcoat, and sheen lobes

const std = @import("std");

/// Bitmask controlling which lights and shadow casters interact with a receiver.
pub const LightLayerMask = packed struct(u32) {
    bits: u32 = 0xFFFF_FFFF,

    /// Interacts with all 32 layers.
    pub const ALL: LightLayerMask = .{ .bits = 0xFFFF_FFFF };
    /// Default primary scene layer (layer 0).
    pub const DEFAULT: LightLayerMask = .{ .bits = 1 };

    /// Returns `true` when two layer masks share at least one active layer bit.
    pub fn overlaps(self: LightLayerMask, other: LightLayerMask) bool {
        return (self.bits & other.bits) != 0;
    }
};

/// Feature mask gating optional PBR material lobes so simple materials incur zero extra cost.
pub const MaterialFeatureFlags = packed struct(u32) {
    clearcoat: bool = false,
    sheen: bool = false,
    anisotropy: bool = false,
    thin_transmission: bool = false,
    detail_maps: bool = false,
    parallax: bool = false,
    subsurface: bool = false,
    _reserved: u25 = 0,
};

/// Rectangular area light emitter in SI luminance units (nits = cd/m^2).
pub const RectAreaLight = struct {
    position: [3]f32,
    right: [3]f32 = .{ 1, 0, 0 },
    up: [3]f32 = .{ 0, 1, 0 },
    normal: [3]f32 = .{ 0, 0, -1 },
    half_width: f32 = 1.0,
    half_height: f32 = 0.5,
    color: [3]f32 = .{ 1, 1, 1 },
    luminance_nits: f32 = 1200.0,
    two_sided: bool = false,
    layers: LightLayerMask = LightLayerMask.ALL,

    /// Emitting surface area in square meters.
    pub fn area(self: RectAreaLight) f32 {
        return 4.0 * @max(self.half_width, 0.0) * @max(self.half_height, 0.0);
    }
};

fn dot3(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn sub3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

fn normalize3(v: [3]f32) [3]f32 {
    const l = @sqrt(dot3(v, v));
    if (l < 1e-6) return .{ 0, 1, 0 };
    return .{ v[0] / l, v[1] / l, v[2] / l };
}

/// Evaluates diffuse irradiance (RGB) from `light` at `world_pos` with surface `normal`
/// using projected solid-angle form factor integration.
pub fn evaluateRectAreaLightDiffuse(light: RectAreaLight, world_pos: [3]f32, normal: [3]f32) [3]f32 {
    const emit_area = light.area();
    if (emit_area <= 1e-6 or light.luminance_nits <= 0.0) return .{ 0, 0, 0 };

    // Project `world_pos` onto the light plane and clamp to the rectangle to find the closest point.
    const to_p = sub3(world_pos, light.position);
    const local_x = std.math.clamp(dot3(to_p, light.right), -light.half_width, light.half_width);
    const local_y = std.math.clamp(dot3(to_p, light.up), -light.half_height, light.half_height);
    const closest = [3]f32{
        light.position[0] + light.right[0] * local_x + light.up[0] * local_y,
        light.position[1] + light.right[1] * local_x + light.up[1] * local_y,
        light.position[2] + light.right[2] * local_x + light.up[2] * local_y,
    };

    const to_light = sub3(closest, world_pos);
    const dist2 = dot3(to_light, to_light);
    const l_dir = normalize3(to_light);
    const ndotl = @max(dot3(normal, l_dir), 0.0);
    if (ndotl <= 0.0) return .{ 0, 0, 0 };

    const raw_light_cos = dot3(light.normal, .{ -l_dir[0], -l_dir[1], -l_dir[2] });
    const light_cos = if (light.two_sided) @abs(raw_light_cos) else @max(raw_light_cos, 0.0);
    if (light_cos <= 0.0) return .{ 0, 0, 0 };

    // Bounded solid angle: `area * cos_light / (dist^2 + area / pi)`.
    const solid_angle = (emit_area * light_cos) / (dist2 + emit_area / std.math.pi);
    const irr = (light.luminance_nits * solid_angle * ndotl) / std.math.pi;
    return .{ light.color[0] * irr, light.color[1] * irr, light.color[2] * irr };
}

/// Evaluates representative-point GGX specular contribution from `light` at `world_pos`.
pub fn evaluateRectAreaLightSpecular(
    light: RectAreaLight,
    world_pos: [3]f32,
    normal: [3]f32,
    view_dir: [3]f32,
    roughness: f32,
) [3]f32 {
    const emit_area = light.area();
    if (emit_area <= 1e-6 or light.luminance_nits <= 0.0) return .{ 0, 0, 0 };

    const ndotv = @max(dot3(normal, view_dir), 0.001);
    const refl = normalize3(.{
        2.0 * ndotv * normal[0] - view_dir[0],
        2.0 * ndotv * normal[1] - view_dir[1],
        2.0 * ndotv * normal[2] - view_dir[2],
    });

    // Intersect reflection ray with the light plane; fall back to light center when parallel.
    const denom = dot3(refl, light.normal);
    const hit_p = blk: {
        if (@abs(denom) > 1e-4) {
            const t = dot3(sub3(light.position, world_pos), light.normal) / denom;
            if (t > 0.0) {
                const p = [3]f32{
                    world_pos[0] + refl[0] * t,
                    world_pos[1] + refl[1] * t,
                    world_pos[2] + refl[2] * t,
                };
                const rel = sub3(p, light.position);
                const cx = std.math.clamp(dot3(rel, light.right), -light.half_width, light.half_width);
                const cy = std.math.clamp(dot3(rel, light.up), -light.half_height, light.half_height);
                break :blk [3]f32{
                    light.position[0] + light.right[0] * cx + light.up[0] * cy,
                    light.position[1] + light.right[1] * cx + light.up[1] * cy,
                    light.position[2] + light.right[2] * cx + light.up[2] * cy,
                };
            }
        }
        break :blk light.position;
    };

    const to_hit = sub3(hit_p, world_pos);
    const dist = @max(@sqrt(dot3(to_hit, to_hit)), 0.05);
    const l_dir = normalize3(to_hit);
    const h_dir = normalize3(.{ view_dir[0] + l_dir[0], view_dir[1] + l_dir[1], view_dir[2] + l_dir[2] });
    const ndoth = @max(dot3(normal, h_dir), 0.0);
    const ndotl = @max(dot3(normal, l_dir), 0.0);
    if (ndotl <= 0.0) return .{ 0, 0, 0 };

    const a = std.math.clamp(roughness, 0.045, 1.0);
    const a2 = a * a;
    const d_denom = (ndoth * ndoth) * (a2 - 1.0) + 1.0;
    const ggx_d = a2 / @max(std.math.pi * d_denom * d_denom, 1e-5);
    const norm_factor = a2 / @max(a2 + (emit_area / (dist * dist + 1.0)) * 0.25, 1e-4);
    const spec = light.luminance_nits * ggx_d * norm_factor * ndotl * 0.05;
    return .{ light.color[0] * spec, light.color[1] * spec, light.color[2] * spec };
}

/// 1D vertical IES photometric intensity profile (`cos(theta)` from `-1` to `+1`).
pub const IesProfile = struct {
    /// Normalized intensity samples in `[0, 1]` spanning `theta in [0, pi]`.
    samples: []const f32,

    /// Evaluates the interpolated normalized IES intensity for `cos_theta` in `[-1, 1]`.
    pub fn sampleIntensity(self: IesProfile, cos_theta: f32) f32 {
        if (self.samples.len == 0) return 1.0;
        if (self.samples.len == 1) return std.math.clamp(self.samples[0], 0.0, 1.0);
        const angle = std.math.acos(std.math.clamp(cos_theta, -1.0, 1.0));
        const u = std.math.clamp(angle / std.math.pi, 0.0, 1.0) * @as(f32, @floatFromInt(self.samples.len - 1));
        const idx0: usize = @intFromFloat(@floor(u));
        const idx1: usize = @min(idx0 + 1, self.samples.len - 1);
        const f = u - @as(f32, @floatFromInt(idx0));
        return std.math.clamp(self.samples[idx0] * (1.0 - f) + self.samples[idx1] * f, 0.0, 1.0);
    }
};

/// Evaluates an energy-conserving dielectric clearcoat specular lobe (IOR 1.5, `F0 = 0.04`).
pub fn evaluateClearcoatLobe(clearcoat: f32, clearcoat_roughness: f32, ndoth: f32, vdoth: f32) f32 {
    const cc = std.math.clamp(clearcoat, 0.0, 1.0);
    if (cc <= 0.0) return 0.0;
    const a = std.math.clamp(clearcoat_roughness, 0.045, 1.0);
    const a2 = a * a;
    const nh = std.math.clamp(ndoth, 0.0, 1.0);
    const vh = std.math.clamp(vdoth, 0.0, 1.0);
    const d_den = nh * nh * (a2 - 1.0) + 1.0;
    const d = a2 / @max(std.math.pi * d_den * d_den, 1e-5);
    const f = 0.04 + 0.96 * std.math.pow(f32, 1.0 - vh, 5.0);
    return cc * d * f * 0.25;
}

/// Evaluates a Charlie-style fabric sheen grazing lobe.
pub fn evaluateSheenLobe(sheen_color: [3]f32, sheen_roughness: f32, ndoth: f32) [3]f32 {
    const r = std.math.clamp(sheen_roughness, 0.08, 1.0);
    const inv_r = 1.0 / r;
    const nh = std.math.clamp(ndoth, 0.0, 1.0);
    const sin2h = @max(1.0 - nh * nh, 0.0078125);
    const d = (2.0 + inv_r) * std.math.pow(f32, sin2h, inv_r * 0.5) / (2.0 * std.math.pi);
    return .{ sheen_color[0] * d, sheen_color[1] * d, sheen_color[2] * d };
}
