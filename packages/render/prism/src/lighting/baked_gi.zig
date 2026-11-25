//! Stage 08 Baked GI, SH9 Irradiance & Probe Volumes (`packages/render/prism/src/lighting/baked_gi.zig`).
//!
//! Provides backend-agnostic baked illumination data and sampling:
//! - Persistent `BakedLightAssetHeader` with revision hashes for incremental invalidation (no GPU pointers)
//! - L2 Spherical Harmonics (`Sh9Irradiance`) projection & normal evaluation
//! - 3D `IrradianceProbeVolume` with normal-aware & validity-weighted trilinear interpolation (leak mitigation)
//! - Lightmap seam dilation (`dilateLightmapRgb`) for mip-safe padding

const std = @import("std");

/// Persistent baked-lighting asset metadata (serializable, zero device handles).
pub const BakedLightAssetHeader = struct {
    format_version: u32 = 1,
    scene_revision: u64 = 0,
    light_revision: u64 = 0,
    material_revision: u64 = 0,
    atlas_width: u32 = 0,
    atlas_height: u32 = 0,
    direct_baked: bool = false,

    /// Returns `true` when any input revision differs from the baked snapshot.
    pub fn isStale(self: BakedLightAssetHeader, scene_rev: u64, light_rev: u64, material_rev: u64) bool {
        return self.scene_revision != scene_rev or
            self.light_revision != light_rev or
            self.material_revision != material_rev;
    }
};

/// 9-band L2 Spherical Harmonics RGB irradiance coefficients.
pub const Sh9Irradiance = struct {
    coeffs: [9][3]f32 = @splat(.{ 0, 0, 0 }),

    /// Accumulates a directional radiance sample `(dir, rgb, weight)` into L2 SH9.
    pub fn addDirectional(self: *Sh9Irradiance, dir: [3]f32, rgb: [3]f32, weight: f32) void {
        const x = dir[0];
        const y = dir[1];
        const z = dir[2];
        const basis = [9]f32{
            0.282095,
            0.488603 * y,
            0.488603 * z,
            0.488603 * x,
            1.092548 * x * y,
            1.092548 * y * z,
            0.315392 * (3.0 * z * z - 1.0),
            1.092548 * x * z,
            0.546274 * (x * x - y * y),
        };
        for (0..9) |b| {
            const w = basis[b] * weight;
            self.coeffs[b][0] += rgb[0] * w;
            self.coeffs[b][1] += rgb[1] * w;
            self.coeffs[b][2] += rgb[2] * w;
        }
    }

    /// Evaluates cosine-convolved diffuse irradiance for unit surface `normal`.
    pub fn evaluate(self: Sh9Irradiance, normal: [3]f32) [3]f32 {
        const x = normal[0];
        const y = normal[1];
        const z = normal[2];
        // Cosine lobe convolution factors: A0 = pi, A1 = 2*pi/3, A2 = pi/4
        const c0: f32 = 0.282095 * std.math.pi;
        const c1: f32 = 0.488603 * (2.0 * std.math.pi / 3.0);
        const c2: f32 = 0.25 * std.math.pi;
        const basis = [9]f32{
            c0,
            c1 * y,
            c1 * z,
            c1 * x,
            c2 * 1.092548 * x * y,
            c2 * 1.092548 * y * z,
            c2 * 0.315392 * (3.0 * z * z - 1.0),
            c2 * 1.092548 * x * z,
            c2 * 0.546274 * (x * x - y * y),
        };

        var out = [3]f32{ 0, 0, 0 };
        for (0..9) |b| {
            out[0] += self.coeffs[b][0] * basis[b];
            out[1] += self.coeffs[b][1] * basis[b];
            out[2] += self.coeffs[b][2] * basis[b];
        }
        return .{ @max(out[0], 0.0), @max(out[1], 0.0), @max(out[2], 0.0) };
    }
};

/// Coarse distance moments for one directional probe sector. Populate using
/// unbiased geometry rays; uninitialized moments keep the legacy behavior.
pub const ProbeVisibilityMoments = struct {
    mean_distance: f32 = 0.0,
    mean_distance_squared: f32 = 0.0,
    valid: bool = false,

    pub fn weight(self: ProbeVisibilityMoments, distance: f32) f32 {
        if (!self.valid) return 1.0;
        if (!std.math.isFinite(distance) or !std.math.isFinite(self.mean_distance) or
            !std.math.isFinite(self.mean_distance_squared) or self.mean_distance < 0.0) return 0.0;
        const delta = @max(distance - self.mean_distance - 0.02, 0.0);
        if (delta <= 0.0) return 1.0;
        const variance = @max(self.mean_distance_squared - self.mean_distance * self.mean_distance, 1e-5);
        const p = variance / (variance + delta * delta);
        return p * p * p;
    }
};

/// Sector order: +X, -X, +Y, -Y, +Z, -Z.
pub fn probeVisibilitySector(direction: [3]f32) usize {
    var axis: usize = 0;
    if (@abs(direction[1]) > @abs(direction[axis])) axis = 1;
    if (@abs(direction[2]) > @abs(direction[axis])) axis = 2;
    return axis * 2 + @as(usize, if (direction[axis] >= 0.0) 0 else 1);
}

/// Single irradiance probe inside a 3D `IrradianceProbeVolume`.
pub const IrradianceProbe = struct {
    sh: Sh9Irradiance = .{},
    validity: f32 = 1.0,
    relocation_offset: [3]f32 = .{ 0, 0, 0 },
    visibility: [6]ProbeVisibilityMoments = @splat(.{}),
};

/// 3D grid of irradiance probes with normal-aware, validity-weighted trilinear sampling.
pub const IrradianceProbeVolume = struct {
    allocator: std.mem.Allocator,
    origin: [3]f32,
    spacing: [3]f32,
    dims: [3]u32,
    probes: []IrradianceProbe,

    /// Allocates a 3D probe volume with `dims = .{ nx, ny, nz }`.
    pub fn init(allocator: std.mem.Allocator, origin: [3]f32, spacing: [3]f32, dims: [3]u32) !IrradianceProbeVolume {
        const total = @as(usize, dims[0]) * @as(usize, dims[1]) * @as(usize, dims[2]);
        const probes = try allocator.alloc(IrradianceProbe, total);
        @memset(probes, .{});
        return .{
            .allocator = allocator,
            .origin = origin,
            .spacing = spacing,
            .dims = dims,
            .probes = probes,
        };
    }

    /// Frees probe storage.
    pub fn deinit(self: *IrradianceProbeVolume) void {
        self.allocator.free(self.probes);
    }

    /// Returns a mutable pointer to probe `(ix, iy, iz)`.
    pub fn probePtr(self: *IrradianceProbeVolume, ix: u32, iy: u32, iz: u32) ?*IrradianceProbe {
        if (ix >= self.dims[0] or iy >= self.dims[1] or iz >= self.dims[2]) return null;
        const idx = (@as(usize, iz) * self.dims[1] + iy) * self.dims[0] + ix;
        return &self.probes[idx];
    }

    /// Samples diffuse irradiance at `world_pos` for unit `normal` using normal-aware,
    /// validity-weighted trilinear interpolation to prevent thin-wall light leaking.
    pub fn sampleIrradiance(self: *const IrradianceProbeVolume, world_pos: [3]f32, normal: [3]f32) [3]f32 {
        if (self.probes.len == 0) return .{ 0, 0, 0 };

        var grid_f: [3]f32 = undefined;
        var base: [3]u32 = undefined;
        var frac: [3]f32 = undefined;
        inline for (0..3) |i| {
            const sp = @max(self.spacing[i], 1e-4);
            const max_c: f32 = @floatFromInt(if (self.dims[i] > 1) self.dims[i] - 1 else 0);
            grid_f[i] = std.math.clamp((world_pos[i] - self.origin[i]) / sp, 0.0, max_c);
            const lo: u32 = @intFromFloat(@floor(grid_f[i]));
            base[i] = lo;
            frac[i] = grid_f[i] - @as(f32, @floatFromInt(lo));
        }

        var sum_rgb = [3]f32{ 0, 0, 0 };
        var sum_w: f32 = 0.0;

        for (0..8) |corner| {
            const ox: u32 = @intCast(corner & 1);
            const oy: u32 = @intCast((corner >> 1) & 1);
            const oz: u32 = @intCast((corner >> 2) & 1);

            const ix = @min(base[0] + ox, self.dims[0] - 1);
            const iy = @min(base[1] + oy, self.dims[1] - 1);
            const iz = @min(base[2] + oz, self.dims[2] - 1);
            const idx = (@as(usize, iz) * self.dims[1] + iy) * self.dims[0] + ix;
            const p = self.probes[idx];
            if (p.validity <= 1e-4) continue;

            const wx = if (ox == 0) (1.0 - frac[0]) else frac[0];
            const wy = if (oy == 0) (1.0 - frac[1]) else frac[1];
            const wz = if (oz == 0) (1.0 - frac[2]) else frac[2];
            const tri_w = wx * wy * wz;

            // Normal-aware backface weighting mitigates leaks through thin walls.
            const px = self.origin[0] + @as(f32, @floatFromInt(ix)) * self.spacing[0] + p.relocation_offset[0];
            const py = self.origin[1] + @as(f32, @floatFromInt(iy)) * self.spacing[1] + p.relocation_offset[1];
            const pz = self.origin[2] + @as(f32, @floatFromInt(iz)) * self.spacing[2] + p.relocation_offset[2];
            const dx = px - world_pos[0];
            const dy = py - world_pos[1];
            const dz = pz - world_pos[2];
            const dlen = @sqrt(dx * dx + dy * dy + dz * dz);
            const norm_w: f32 = if (dlen > 1e-4) blk: {
                const cos_a = (dx * normal[0] + dy * normal[1] + dz * normal[2]) / dlen;
                const smooth = (cos_a + 1.0) * 0.5;
                break :blk @max(0.05, smooth * smooth);
            } else 1.0;

            const w = tri_w * p.validity * norm_w;
            if (w <= 1e-6) continue;

            const sector = probeVisibilitySector(.{ -dx, -dy, -dz });
            const vis = p.visibility[sector].weight(dlen);
            const irr = p.sh.evaluate(normal);
            // Normalize geometric weights, but do not normalize away occlusion.
            // This conservative reference can darken partial coverage; a full DDGI
            // implementation must track coverage and fallback confidence separately.
            sum_rgb[0] += irr[0] * w * vis;
            sum_rgb[1] += irr[1] * w * vis;
            sum_rgb[2] += irr[2] * w * vis;
            sum_w += w;
        }

        if (sum_w <= 1e-6) return .{ 0, 0, 0 };
        return .{ sum_rgb[0] / sum_w, sum_rgb[1] / sum_w, sum_rgb[2] / sum_w };
    }
};

/// Performs 4-neighbor seam dilation on an RGBA HDR lightmap (`alpha > 0` marks valid texels).
pub fn dilateLightmapRgba(
    allocator: std.mem.Allocator,
    pixels: [][4]f32,
    width: u32,
    height: u32,
    iterations: u32,
) !void {
    if (width == 0 or height == 0 or pixels.len < @as(usize, width) * @as(usize, height)) return;
    const tmp = try allocator.alloc([4]f32, pixels.len);
    defer allocator.free(tmp);

    for (0..iterations) |_| {
        @memcpy(tmp, pixels);
        var y: u32 = 0;
        while (y < height) : (y += 1) {
            var x: u32 = 0;
            while (x < width) : (x += 1) {
                const idx = @as(usize, y) * width + x;
                if (tmp[idx][3] > 0.0) continue;

                var acc = [3]f32{ 0, 0, 0 };
                var count: f32 = 0.0;
                const offsets = [4][2]i32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } };
                for (offsets) |off| {
                    const nx = @as(i32, @intCast(x)) + off[0];
                    const ny = @as(i32, @intCast(y)) + off[1];
                    if (nx < 0 or ny < 0 or nx >= @as(i32, @intCast(width)) or ny >= @as(i32, @intCast(height))) continue;
                    const nidx = @as(usize, @intCast(ny)) * width + @as(usize, @intCast(nx));
                    if (tmp[nidx][3] > 0.0) {
                        acc[0] += tmp[nidx][0];
                        acc[1] += tmp[nidx][1];
                        acc[2] += tmp[nidx][2];
                        count += 1.0;
                    }
                }
                if (count > 0.0) {
                    pixels[idx] = .{ acc[0] / count, acc[1] / count, acc[2] / count, 1.0 };
                }
            }
        }
    }
}
