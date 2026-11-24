//! Agnostic Split-Sum Image-Based Lighting (`packages/render/3d/src/ibl.zig`).
//!
//! Computes backend-neutral:
//! - Band 0-2 Spherical Harmonic (SH9) diffuse irradiance coefficients
//! - Procedural equirectangular HDR sky maps + prefiltered specular mip chains
//! - 2D GGX BRDF integration LUT (`F0 * scale + bias`)

const std = @import("std");
const pbr = @import("pbr.zig");

/// 9 RGB spherical-harmonic coefficients (bands 0-2) pre-convolved with the Lambertian cosine lobe.
pub const SkyDiffuseSH = struct {
    coeffs: [9][3]f32 = @splat(.{ 0, 0, 0 }),
};

/// Evaluates the 9 real spherical-harmonic basis functions for a normalized direction `n`.
pub fn evaluateShBasis(n: [3]f32) [9]f32 {
    const x = n[0];
    const y = n[1];
    const z = n[2];
    return .{
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
}

/// Evaluates diffuse irradiance from `sh` along surface normal `normal`.
pub fn evaluateSkyDiffuse(sh: *const SkyDiffuseSH, normal: [3]f32) [3]f32 {
    const b = evaluateShBasis(normal);
    var out = [3]f32{ 0, 0, 0 };
    for (0..9) |i| {
        out[0] += sh.coeffs[i][0] * b[i];
        out[1] += sh.coeffs[i][1] * b[i];
        out[2] += sh.coeffs[i][2] * b[i];
    }
    return .{ @max(out[0], 0.0), @max(out[1], 0.0), @max(out[2], 0.0) };
}

/// Maps equirectangular UV `(u, v)` in `[0, 1]^2` to a unit world direction.
pub fn skyDirectionFromUv(u: f32, v: f32) [3]f32 {
    const phi = (u - 0.5) * 2.0 * std.math.pi;
    const theta = v * std.math.pi;
    const sin_t = @sin(theta);
    return .{
        sin_t * @sin(phi),
        @cos(theta),
        -sin_t * @cos(phi),
    };
}

fn dot3(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn normalize3(v: [3]f32) [3]f32 {
    const len = @sqrt(dot3(v, v));
    if (len < 1e-6) return .{ 0, 1, 0 };
    return .{ v[0] / len, v[1] / len, v[2] / len };
}

/// Generates a linear HDR `[4]f32` equirectangular sky image matching `sky.frag`.
pub fn generateProceduralEquirectSky(
    allocator: std.mem.Allocator,
    sky: pbr.SkyEnvironment,
    sun_dir_raw: [3]f32,
    sun_col: [3]f32,
    sun_intensity: f32,
    width: u32,
    height: u32,
) ![][4]f32 {
    const pixels = try allocator.alloc([4]f32, @as(usize, width) * @as(usize, height));
    const sun_dir = normalize3(sun_dir_raw);
    const sun_elev = std.math.clamp(1.0 - @abs(sun_dir[1]) * 2.0, 0.0, 1.0);

    for (0..height) |y| {
        const v = (@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(height));
        for (0..width) |x| {
            const u = (@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(width));
            const dir = skyDirectionFromUv(u, v);

            var col: [3]f32 = undefined;
            if (sky.kind == .solid_color) {
                col = sky.solid_color;
            } else {
                const h = std.math.clamp(dir[1], -1.0, 1.0);
                if (h >= 0.0) {
                    const t = std.math.pow(f32, h, 0.55);
                    for (0..3) |c_i| {
                        col[c_i] = sky.horizon_tint[c_i] + (sky.sky_tint[c_i] - sky.horizon_tint[c_i]) * t;
                    }
                } else {
                    const t = std.math.clamp(-h * 4.0, 0.0, 1.0);
                    for (0..3) |c_i| {
                        col[c_i] = sky.horizon_tint[c_i] + (sky.ground_albedo[c_i] - sky.horizon_tint[c_i]) * t;
                    }
                }

                const sunset_w = std.math.pow(f32, 1.0 - @abs(h), 4.0) * sun_elev * 0.45 * sky.atmosphere_thickness;
                const sunset = [3]f32{ 1.4, 0.77, 0.35 };
                for (0..3) |c_i| {
                    col[c_i] += (sunset[c_i] - col[c_i]) * sunset_w;
                }

                if (sky.sun_disk != .none) {
                    const cos_theta = std.math.clamp(dot3(dir, sun_dir), 0.0, 1.0);
                    const halo = if (sky.sun_disk == .high_quality) std.math.pow(f32, cos_theta, 32.0) * 0.45 else 0.0;
                    const r = @max(sky.sun_size, 0.005);
                    const ang = std.math.acos(cos_theta);
                    const disc: f32 = if (ang < r) 1.0 else 0.0;
                    for (0..3) |c_i| {
                        col[c_i] += sun_col[c_i] * (disc * sun_intensity * 3.5 + halo * sun_intensity);
                    }
                }
            }
            pixels[y * width + x] = .{ @max(col[0], 0.0), @max(col[1], 0.0), @max(col[2], 0.0), 1.0 };
        }
    }
    return pixels;
}

/// Projects an equirectangular HDR sky image into cosine-convolved SH9 irradiance coefficients.
pub fn projectSkyDiffuse(pixels: []const [4]f32, width: u32, height: u32) SkyDiffuseSH {
    // Cosine lobe zonal harmonics weights (Ramamoorthi & Hanrahan 2001), divided by pi.
    const a0: f32 = 1.0;
    const a1: f32 = 2.0 / 3.0;
    const a2: f32 = 0.25;
    const band_weights = [9]f32{ a0, a1, a1, a1, a2, a2, a2, a2, a2 };

    var sh = SkyDiffuseSH{};
    const d_phi = (2.0 * std.math.pi) / @as(f32, @floatFromInt(width));
    const d_theta = std.math.pi / @as(f32, @floatFromInt(height));

    for (0..height) |y| {
        const v = (@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(height));
        const sin_theta = @sin(v * std.math.pi);
        const d_omega = sin_theta * d_phi * d_theta;
        for (0..width) |x| {
            const u = (@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(width));
            const dir = skyDirectionFromUv(u, v);
            const b = evaluateShBasis(dir);
            const px = pixels[y * width + x];
            for (0..9) |i| {
                const w = b[i] * d_omega;
                sh.coeffs[i][0] += px[0] * w;
                sh.coeffs[i][1] += px[1] * w;
                sh.coeffs[i][2] += px[2] * w;
            }
        }
    }
    for (0..9) |i| {
        for (0..3) |c_i| {
            sh.coeffs[i][c_i] *= band_weights[i];
        }
    }
    return sh;
}

/// Generates a separable box/gaussian-blurred prefiltered mip chain from base `pixels` (`width x height`).
/// Caller owns the returned slice of mip slices (free each with `allocator.free`, then `allocator.free(mips)`).
pub fn buildPrefilteredEnvMips(
    allocator: std.mem.Allocator,
    base_pixels: []const [4]f32,
    base_w: u32,
    base_h: u32,
    levels: u32,
) ![][][4]f32 {
    const mips = try allocator.alloc([][4]f32, levels);
    var initialized: usize = 0;
    errdefer {
        for (mips[0..initialized]) |m| allocator.free(m);
        allocator.free(mips);
    }

    mips[0] = try allocator.dupe([4]f32, base_pixels);
    initialized += 1;

    var prev_w = base_w;
    var prev_h = base_h;
    const sample_count: u32 = 16;
    for (1..levels) |lvl| {
        const cur_w = @max(prev_w / 2, 2);
        const cur_h = @max(prev_h / 2, 2);
        const dst = try allocator.alloc([4]f32, @as(usize, cur_w) * @as(usize, cur_h));
        const roughness = @as(f32, @floatFromInt(lvl)) / @as(f32, @floatFromInt(@max(levels - 1, 1)));

        for (0..cur_h) |y| {
            const v = (@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(cur_h));
            for (0..cur_w) |x| {
                const u = (@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(cur_w));
                const N = skyDirectionFromUv(u, v);
                const up = if (@abs(N[1]) < 0.999) [3]f32{ 0, 1, 0 } else [3]f32{ 1, 0, 0 };
                // Tangent = normalize(cross(up, N))
                const tx_raw = [3]f32{
                    up[1] * N[2] - up[2] * N[1],
                    up[2] * N[0] - up[0] * N[2],
                    up[0] * N[1] - up[1] * N[0],
                };
                const T = normalize3(tx_raw);
                const B = [3]f32{
                    N[1] * T[2] - N[2] * T[1],
                    N[2] * T[0] - N[0] * T[2],
                    N[0] * T[1] - N[1] * T[0],
                };

                var sum = [3]f32{ 0, 0, 0 };
                var weight_total: f32 = 0.0;
                for (0..sample_count) |s_i| {
                    const xi = [2]f32{
                        @as(f32, @floatFromInt(s_i)) / @as(f32, @floatFromInt(sample_count)),
                        radicalInverseVdC(@intCast(s_i)),
                    };
                    const H_t = importanceSampleGGX(xi, @max(roughness, 0.08));
                    const H = normalize3(.{
                        T[0] * H_t[0] + B[0] * H_t[1] + N[0] * H_t[2],
                        T[1] * H_t[0] + B[1] * H_t[1] + N[1] * H_t[2],
                        T[2] * H_t[0] + B[2] * H_t[1] + N[2] * H_t[2],
                    });
                    const n_dot_h = @max(dot3(N, H), 0.0);
                    const L = normalize3(.{
                        2.0 * n_dot_h * H[0] - N[0],
                        2.0 * n_dot_h * H[1] - N[1],
                        2.0 * n_dot_h * H[2] - N[2],
                    });
                    const n_dot_l = @max(dot3(N, L), 0.0);
                    if (n_dot_l > 0.0) {
                        const su = std.math.atan2(L[0], -L[2]) / (2.0 * std.math.pi) + 0.5;
                        const sv = std.math.acos(std.math.clamp(L[1], -1.0, 1.0)) / std.math.pi;
                        const sx: usize = @intCast(@mod(@as(isize, @intFromFloat(su * @as(f32, @floatFromInt(base_w)))), @as(isize, @intCast(base_w))));
                        const sy: usize = @intCast(std.math.clamp(@as(isize, @intFromFloat(sv * @as(f32, @floatFromInt(base_h)))), 0, @as(isize, @intCast(base_h - 1))));
                        const p = base_pixels[sy * base_w + sx];
                        sum[0] += p[0] * n_dot_l;
                        sum[1] += p[1] * n_dot_l;
                        sum[2] += p[2] * n_dot_l;
                        weight_total += n_dot_l;
                    }
                }
                const inv_w = if (weight_total > 1e-5) 1.0 / weight_total else 1.0;
                dst[y * cur_w + x] = .{ sum[0] * inv_w, sum[1] * inv_w, sum[2] * inv_w, 1.0 };
            }
        }
        mips[lvl] = dst;
        initialized += 1;
        prev_w = cur_w;
        prev_h = cur_h;
    }
    return mips;
}

fn radicalInverseVdC(bits_in: u32) f32 {
    var bits = bits_in;
    bits = (bits << 16) | (bits >> 16);
    bits = ((bits & 0x55555555) << 1) | ((bits & 0xAAAAAAAA) >> 1);
    bits = ((bits & 0x33333333) << 2) | ((bits & 0xCCCCCCCC) >> 2);
    bits = ((bits & 0x0F0F0F0F) << 4) | ((bits & 0xF0F0F0F0) >> 4);
    bits = ((bits & 0x00FF00FF) << 8) | ((bits & 0xFF00FF00) >> 8);
    return @as(f32, @floatFromInt(bits)) * 2.3283064365386963e-10;
}

fn importanceSampleGGX(xi: [2]f32, roughness: f32) [3]f32 {
    const a = roughness * roughness;
    const phi = 2.0 * std.math.pi * xi[0];
    const cos_theta = @sqrt((1.0 - xi[1]) / (1.0 + (a * a - 1.0) * xi[1]));
    const sin_theta = @sqrt(@max(0.0, 1.0 - cos_theta * cos_theta));
    return .{ @cos(phi) * sin_theta, @sin(phi) * sin_theta, cos_theta };
}

fn geometrySchlickGGXIBL(NdotV: f32, roughness: f32) f32 {
    const k = (roughness * roughness) / 2.0;
    return NdotV / @max(NdotV * (1.0 - k) + k, 1e-4);
}

/// Generates an RGBA8 `size x size` 2D GGX BRDF integration LUT (`R = scale`, `G = bias`).
pub fn generateBrdfLutRgba8(allocator: std.mem.Allocator, size: u32) ![]u8 {
    const out = try allocator.alloc(u8, @as(usize, size) * @as(usize, size) * 4);
    const sample_count: u32 = 64;

    for (0..size) |y| {
        const roughness = (@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(size));
        for (0..size) |x| {
            const n_dot_v = @max((@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(size)), 0.01);
            const V = [3]f32{ @sqrt(@max(0.0, 1.0 - n_dot_v * n_dot_v)), 0.0, n_dot_v };

            var a_sum: f32 = 0.0;
            var b_sum: f32 = 0.0;
            for (0..sample_count) |i| {
                const xi = [2]f32{
                    @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sample_count)),
                    radicalInverseVdC(@intCast(i)),
                };
                const H = importanceSampleGGX(xi, roughness);
                const v_dot_h = @max(dot3(V, H), 0.0);
                const L = [3]f32{
                    2.0 * v_dot_h * H[0] - V[0],
                    2.0 * v_dot_h * H[1] - V[1],
                    2.0 * v_dot_h * H[2] - V[2],
                };
                const n_dot_l = @max(L[2], 0.0);
                const n_dot_h = @max(H[2], 0.0);
                if (n_dot_l > 0.0) {
                    const g = geometrySchlickGGXIBL(n_dot_v, roughness) * geometrySchlickGGXIBL(n_dot_l, roughness);
                    const g_vis = (g * v_dot_h) / @max(n_dot_h * n_dot_v, 1e-4);
                    const fc = std.math.pow(f32, 1.0 - v_dot_h, 5.0);
                    a_sum += (1.0 - fc) * g_vis;
                    b_sum += fc * g_vis;
                }
            }
            const scale = std.math.clamp(a_sum / @as(f32, @floatFromInt(sample_count)), 0.0, 1.0);
            const bias = std.math.clamp(b_sum / @as(f32, @floatFromInt(sample_count)), 0.0, 1.0);
            const idx = (y * size + x) * 4;
            out[idx + 0] = @intFromFloat(scale * 255.0);
            out[idx + 1] = @intFromFloat(bias * 255.0);
            out[idx + 2] = 0;
            out[idx + 3] = 255;
        }
    }
    return out;
}

/// Decoded linear HDR equirectangular image.
pub const HdriImage = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    pixels: [][4]f32,

    pub fn deinit(self: *HdriImage) void {
        self.allocator.free(self.pixels);
    }
};

fn rgbeToLinear(r: u8, g: u8, b: u8, e: u8) [4]f32 {
    if (e == 0) return .{ 0, 0, 0, 1 };
    const f = std.math.ldexp(@as(f32, 1.0), @as(i32, e) - 128 - 8);
    return .{
        @as(f32, @floatFromInt(r)) * f,
        @as(f32, @floatFromInt(g)) * f,
        @as(f32, @floatFromInt(b)) * f,
        1.0,
    };
}

/// Decodes a Radiance `.hdr` (RGBE / RLE) image from memory into linear `[4]f32` pixels.
pub fn loadRadianceHdrFromMemory(allocator: std.mem.Allocator, data: []const u8) !HdriImage {
    var pos: usize = 0;
    // Skip header lines until blank line.
    while (pos < data.len) {
        const nl = std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse return error.InvalidHdriHeader;
        const line = std.mem.trimEnd(u8, data[pos..nl], "\r");
        pos = nl + 1;
        if (line.len == 0) break;
    }
    const res_nl = std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse return error.InvalidHdriHeader;
    const res_line = std.mem.trim(u8, data[pos..res_nl], " \r\t");
    pos = res_nl + 1;

    var it = std.mem.tokenizeScalar(u8, res_line, ' ');
    _ = it.next() orelse return error.InvalidHdriHeader; // -Y
    const h_str = it.next() orelse return error.InvalidHdriHeader;
    _ = it.next() orelse return error.InvalidHdriHeader; // +X
    const w_str = it.next() orelse return error.InvalidHdriHeader;
    const height = try std.fmt.parseInt(u32, h_str, 10);
    const width = try std.fmt.parseInt(u32, w_str, 10);

    const pixels = try allocator.alloc([4]f32, @as(usize, width) * @as(usize, height));
    errdefer allocator.free(pixels);
    const scanline = try allocator.alloc(u8, @as(usize, width) * 4);
    defer allocator.free(scanline);

    for (0..height) |y| {
        if (pos + 4 > data.len) return error.UnexpectedEof;
        if (data[pos] == 2 and data[pos + 1] == 2 and width >= 8 and width <= 0x7fff) {
            pos += 4;
            for (0..4) |ch| {
                var x: usize = 0;
                while (x < width) {
                    if (pos >= data.len) return error.UnexpectedEof;
                    const cnt = data[pos];
                    pos += 1;
                    if (cnt > 128) {
                        const run: usize = cnt - 128;
                        if (pos >= data.len or x + run > width) return error.UnexpectedEof;
                        const val = data[pos];
                        pos += 1;
                        for (0..run) |k| scanline[(x + k) * 4 + ch] = val;
                        x += run;
                    } else {
                        const run: usize = cnt;
                        if (run == 0 or pos + run > data.len or x + run > width) return error.UnexpectedEof;
                        for (0..run) |k| scanline[(x + k) * 4 + ch] = data[pos + k];
                        pos += run;
                        x += run;
                    }
                }
            }
        } else {
            const bytes = @as(usize, width) * 4;
            if (pos + bytes > data.len) return error.UnexpectedEof;
            @memcpy(scanline, data[pos..][0..bytes]);
            pos += bytes;
        }

        for (0..width) |x| {
            const s = x * 4;
            pixels[y * width + x] = rgbeToLinear(scanline[s], scanline[s + 1], scanline[s + 2], scanline[s + 3]);
        }
    }

    return .{ .allocator = allocator, .width = width, .height = height, .pixels = pixels };
}

/// Resizes an equirectangular HDR image using bilinear filtering for fast IBL projection.
pub fn downsampleEquirectRgba32f(
    allocator: std.mem.Allocator,
    src: []const [4]f32,
    src_w: u32,
    src_h: u32,
    dst_w: u32,
    dst_h: u32,
) ![][4]f32 {
    const dst = try allocator.alloc([4]f32, @as(usize, dst_w) * @as(usize, dst_h));
    for (0..dst_h) |y| {
        const fy = (@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(dst_h)) * @as(f32, @floatFromInt(src_h)) - 0.5;
        const y0: usize = @intCast(std.math.clamp(@as(isize, @intFromFloat(@floor(fy))), 0, @as(isize, @intCast(src_h - 1))));
        const y1: usize = @min(y0 + 1, src_h - 1);
        const wy = std.math.clamp(fy - @floor(fy), 0.0, 1.0);
        for (0..dst_w) |x| {
            const fx = (@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(dst_w)) * @as(f32, @floatFromInt(src_w)) - 0.5;
            const x0: usize = @intCast(@mod(@as(isize, @intFromFloat(@floor(fx))), @as(isize, @intCast(src_w))));
            const x1: usize = (x0 + 1) % src_w;
            const wx = fx - @floor(fx);
            const p00 = src[y0 * src_w + x0];
            const p10 = src[y0 * src_w + x1];
            const p01 = src[y1 * src_w + x0];
            const p11 = src[y1 * src_w + x1];
            var out: [4]f32 = .{ 0, 0, 0, 1 };
            for (0..3) |c_i| {
                const top = p00[c_i] * (1.0 - wx) + p10[c_i] * wx;
                const bot = p01[c_i] * (1.0 - wx) + p11[c_i] * wx;
                out[c_i] = top * (1.0 - wy) + bot * wy;
            }
            dst[y * dst_w + x] = out;
        }
    }
    return dst;
}
