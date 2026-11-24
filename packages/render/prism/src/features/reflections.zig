//! Stage 06 Reflections, Box-Projected Probes, SSR Blending & Dynamic Resolution (`packages/render/prism/src/features/reflections.zig`).
//!
//! Provides pure-Zig reflection and image-stability policies shared across Prism passes:
//! - Box-projected parallax correction for local cubemap reflection probes
//! - Smooth influence blending with sky IBL fallback (no double-counting)
//! - SSR hit confidence (edge fade + roughness cutoff) and probe blending
//! - Specular occlusion from diffuse AO, NdotV, and roughness
//! - Per-view hysteresis `DynamicResolutionController`

const std = @import("std");

/// Local box-projected cubemap reflection probe descriptor.
pub const ReflectionProbe = struct {
    id: u64,
    position: [3]f32,
    box_min: [3]f32,
    box_max: [3]f32,
    blend_distance: f32 = 1.0,
    priority: i32 = 0,
};

/// Applies box-projected parallax correction to `reflect_dir` from `world_pos` inside `[box_min, box_max]`.
pub fn boxProjectReflection(
    world_pos: [3]f32,
    reflect_dir: [3]f32,
    box_min: [3]f32,
    box_max: [3]f32,
    probe_pos: [3]f32,
) [3]f32 {
    var t_min: f32 = std.math.inf(f32);
    inline for (0..3) |i| {
        if (@abs(reflect_dir[i]) > 1e-6) {
            const inv = 1.0 / reflect_dir[i];
            const t1 = (box_max[i] - world_pos[i]) * inv;
            const t2 = (box_min[i] - world_pos[i]) * inv;
            const t_far = @max(t1, t2);
            if (t_far > 0.0) t_min = @min(t_min, t_far);
        }
    }
    if (!std.math.isFinite(t_min)) return reflect_dir;
    const hit = [3]f32{
        world_pos[0] + reflect_dir[0] * t_min,
        world_pos[1] + reflect_dir[1] * t_min,
        world_pos[2] + reflect_dir[2] * t_min,
    };
    const v = [3]f32{ hit[0] - probe_pos[0], hit[1] - probe_pos[1], hit[2] - probe_pos[2] };
    const len = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (len < 1e-6) return reflect_dir;
    return .{ v[0] / len, v[1] / len, v[2] / len };
}

/// Computes smooth `[0..1]` influence weight of `probe` at `world_pos`.
pub fn probeInfluenceWeight(probe: ReflectionProbe, world_pos: [3]f32) f32 {
    var min_dist: f32 = std.math.inf(f32);
    inline for (0..3) |i| {
        if (world_pos[i] < probe.box_min[i] or world_pos[i] > probe.box_max[i]) return 0.0;
        const d = @min(world_pos[i] - probe.box_min[i], probe.box_max[i] - world_pos[i]);
        min_dist = @min(min_dist, d);
    }
    if (probe.blend_distance <= 1e-5) return 1.0;
    return std.math.clamp(min_dist / probe.blend_distance, 0.0, 1.0);
}

/// Computes SSR confidence `[0..1]` from hit UV, surface roughness, and max SSR roughness cutoff.
pub fn computeSsrConfidence(hit_uv: [2]f32, roughness: f32, max_roughness: f32, edge_fade: f32) f32 {
    if (roughness >= max_roughness) return 0.0;
    if (hit_uv[0] < 0.0 or hit_uv[0] > 1.0 or hit_uv[1] < 0.0 or hit_uv[1] > 1.0) return 0.0;
    const ef = @max(edge_fade, 1e-4);
    const ex = @min(hit_uv[0], 1.0 - hit_uv[0]) / ef;
    const ey = @min(hit_uv[1], 1.0 - hit_uv[1]) / ef;
    const edge_w = std.math.clamp(@min(ex, ey), 0.0, 1.0);
    const rough_w = std.math.clamp(1.0 - (roughness / @max(max_roughness, 1e-4)), 0.0, 1.0);
    return edge_w * rough_w;
}

/// Blends SSR radiance with probe/IBL fallback using `confidence` without double-adding energy.
pub fn blendSsrWithProbe(ssr_rgb: [3]f32, probe_rgb: [3]f32, confidence: f32) [3]f32 {
    const c = std.math.clamp(confidence, 0.0, 1.0);
    return .{
        probe_rgb[0] * (1.0 - c) + ssr_rgb[0] * c,
        probe_rgb[1] * (1.0 - c) + ssr_rgb[1] * c,
        probe_rgb[2] * (1.0 - c) + ssr_rgb[2] * c,
    };
}

/// Computes Lagarde specular occlusion from diffuse AO, view angle `ndotv`, and perceptual `roughness`.
pub fn computeSpecularOcclusion(diffuse_ao: f32, ndotv: f32, roughness: f32) f32 {
    const ao = std.math.clamp(diffuse_ao, 0.0, 1.0);
    const nv = std.math.clamp(ndotv, 0.0, 1.0);
    const r = std.math.clamp(roughness, 0.045, 1.0);
    const val = std.math.pow(f32, nv + ao, std.math.exp2(-16.0 * r - 1.0)) - 1.0 + ao;
    return std.math.clamp(val, 0.0, 1.0);
}

/// Per-view dynamic resolution controller with hysteresis to prevent frame-to-frame scale oscillation.
pub const DynamicResolutionController = struct {
    min_scale: f32 = 0.5,
    max_scale: f32 = 1.0,
    current_scale: f32 = 1.0,
    target_ms: f32 = 13.0,
    hysteresis_ms: f32 = 1.2,
    step_down: f32 = 0.05,
    step_up: f32 = 0.025,
    stable_frames_before_up: u32 = 8,
    below_budget_streak: u32 = 0,

    /// Updates `current_scale` given the latest GPU frame time in milliseconds.
    pub fn update(self: *DynamicResolutionController, frame_ms: f32) f32 {
        if (frame_ms > self.target_ms + self.hysteresis_ms) {
            self.below_budget_streak = 0;
            self.current_scale = @max(self.min_scale, self.current_scale - self.step_down);
        } else if (frame_ms < self.target_ms - self.hysteresis_ms) {
            self.below_budget_streak += 1;
            if (self.below_budget_streak >= self.stable_frames_before_up) {
                self.current_scale = @min(self.max_scale, self.current_scale + self.step_up);
                self.below_budget_streak = 0;
            }
        } else {
            self.below_budget_streak = 0;
        }
        return self.current_scale;
    }
};
