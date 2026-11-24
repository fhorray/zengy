//! Frame capture, image statistics and image comparison for render regression tests (`graphics-sdlgpu`).
//!
//! Pure Zig with no GPU or SDL dependency: the backend fills an `Image`, and everything here (PNG IO,
//! statistics, comparison) is unit-tested headlessly.
//!
//! PNG support is limited to what the harness needs: 8-bit RGB, non-interlaced, zlib-compressed via
//! `std.compress.flate`. The reader handles every standard scanline filter and rejects other variants
//! explicitly instead of guessing.

const std = @import("std");

/// A captured render target converted to linear-or-display float RGBA.
/// `final` captures hold display values in `[0, 1]`; `hdr` captures hold scene-linear radiance.
pub const Image = struct {
    width: u32,
    height: u32,
    /// `width * height * 4` floats, row-major, top row first.
    rgba: []f32,

    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        allocator.free(self.rgba);
        self.* = undefined;
    }
};

/// Which render target a capture request reads back.
pub const Target = enum { final, hdr, ssao };

// ---------------------------------------------------------------------------------------------------------
// Conversions
// ---------------------------------------------------------------------------------------------------------

fn toByte(v: f32) u8 {
    const c = std.math.clamp(v, 0.0, 1.0);
    return @intFromFloat(@round(c * 255.0));
}

/// Display-referred RGBA floats in `[0, 1]` to tightly packed RGB8.
pub fn displayToRgb8(allocator: std.mem.Allocator, img: Image) ![]u8 {
    const px = @as(usize, img.width) * img.height;
    const out = try allocator.alloc(u8, px * 3);
    for (0..px) |i| {
        out[i * 3 + 0] = toByte(img.rgba[i * 4 + 0]);
        out[i * 3 + 1] = toByte(img.rgba[i * 4 + 1]);
        out[i * 3 + 2] = toByte(img.rgba[i * 4 + 2]);
    }
    return out;
}

/// Scene-linear HDR to a viewable RGB8 preview (Reinhard + gamma 2.2). NaN renders as magenta, Inf as cyan,
/// so broken pixels are visible in the preview rather than silently clamped.
pub fn hdrPreviewRgb8(allocator: std.mem.Allocator, img: Image) ![]u8 {
    const px = @as(usize, img.width) * img.height;
    const out = try allocator.alloc(u8, px * 3);
    for (0..px) |i| {
        const r = img.rgba[i * 4 + 0];
        const g = img.rgba[i * 4 + 1];
        const b = img.rgba[i * 4 + 2];
        if (std.math.isNan(r) or std.math.isNan(g) or std.math.isNan(b)) {
            out[i * 3 + 0] = 255;
            out[i * 3 + 1] = 0;
            out[i * 3 + 2] = 255;
            continue;
        }
        if (std.math.isInf(r) or std.math.isInf(g) or std.math.isInf(b)) {
            out[i * 3 + 0] = 0;
            out[i * 3 + 1] = 255;
            out[i * 3 + 2] = 255;
            continue;
        }
        inline for (.{ r, g, b }, 0..) |v, k| {
            const m = @max(v, 0.0);
            out[i * 3 + k] = toByte(std.math.pow(f32, m / (1.0 + m), 1.0 / 2.2));
        }
    }
    return out;
}

fn luma8(r: u8, g: u8, b: u8) f32 {
    return 0.2126 * @as(f32, @floatFromInt(r)) + 0.7152 * @as(f32, @floatFromInt(g)) + 0.0722 * @as(f32, @floatFromInt(b));
}

// ---------------------------------------------------------------------------------------------------------
// PNG
// ---------------------------------------------------------------------------------------------------------

const PNG_SIGNATURE = [8]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };

fn appendU32Be(list: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .big);
    try list.appendSlice(allocator, &b);
}

fn appendChunk(list: *std.ArrayList(u8), allocator: std.mem.Allocator, kind: *const [4]u8, data: []const u8) !void {
    try appendU32Be(list, allocator, @intCast(data.len));
    try list.appendSlice(allocator, kind);
    try list.appendSlice(allocator, data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    try appendU32Be(list, allocator, crc.final());
}

/// Encodes tightly packed RGB8 as a PNG (zlib-compressed; filter Sub on the first row, Up on the others).
/// Caller owns the returned bytes.
pub fn encodePngRgb8(allocator: std.mem.Allocator, width: u32, height: u32, rgb: []const u8) ![]u8 {
    const w: usize = width;
    const h: usize = height;
    if (rgb.len != w * h * 3) return error.InvalidImageSize;
    const stride = w * 3;

    // Filtered scanlines: one filter-type byte followed by the row.
    const raw = try allocator.alloc(u8, h * (stride + 1));
    defer allocator.free(raw);
    for (0..h) |y| {
        const dst = raw[y * (stride + 1) ..][0 .. stride + 1];
        const cur = rgb[y * stride ..][0..stride];
        if (y == 0) {
            dst[0] = 1; // Sub
            for (0..stride) |i| dst[1 + i] = cur[i] -% (if (i >= 3) cur[i - 3] else 0);
        } else {
            dst[0] = 2; // Up
            const up = rgb[(y - 1) * stride ..][0..stride];
            for (0..stride) |i| dst[1 + i] = cur[i] -% up[i];
        }
    }

    var z = try std.Io.Writer.Allocating.initCapacity(allocator, 1 << 16);
    defer z.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var comp = try std.compress.flate.Compress.init(&z.writer, &window, .zlib, .default);
    try comp.writer.writeAll(raw);
    try comp.finish();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, &PNG_SIGNATURE);
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 2; // colour type: RGB
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try appendChunk(&out, allocator, "IHDR", &ihdr);
    try appendChunk(&out, allocator, "IDAT", z.written());
    try appendChunk(&out, allocator, "IEND", &.{});
    return out.toOwnedSlice(allocator);
}

/// Decoded RGB8 image.
pub const Rgb8 = struct {
    width: u32,
    height: u32,
    rgb: []u8,

    pub fn deinit(self: *Rgb8, allocator: std.mem.Allocator) void {
        allocator.free(self.rgb);
        self.* = undefined;
    }
};

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p: i32 = @as(i32, a) + @as(i32, b) - @as(i32, c);
    const pa = @abs(p - @as(i32, a));
    const pb = @abs(p - @as(i32, b));
    const pc = @abs(p - @as(i32, c));
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

/// Decodes an 8-bit RGB, non-interlaced PNG with any standard filter. Other variants return
/// `error.UnsupportedPng`; malformed data returns `error.InvalidPng`.
pub fn decodePngRgb8(allocator: std.mem.Allocator, bytes: []const u8) !Rgb8 {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], &PNG_SIGNATURE)) return error.InvalidPng;
    var pos: usize = 8;
    var width: u32 = 0;
    var height: u32 = 0;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(allocator);
    while (pos + 12 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        const kind = bytes[pos + 4 ..][0..4];
        const data_start = pos + 8;
        if (data_start + len + 4 > bytes.len) return error.InvalidPng;
        const data = bytes[data_start..][0..len];
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (len != 13) return error.InvalidPng;
            width = std.mem.readInt(u32, data[0..4], .big);
            height = std.mem.readInt(u32, data[4..8], .big);
            if (data[8] != 8 or data[9] != 2 or data[10] != 0 or data[11] != 0 or data[12] != 0) return error.UnsupportedPng;
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(allocator, data);
        } else if (std.mem.eql(u8, kind, "IEND")) {
            break;
        }
        pos = data_start + len + 4;
    }
    if (width == 0 or height == 0) return error.InvalidPng;

    const w: usize = width;
    const h: usize = height;
    const stride = w * 3;
    const raw = try allocator.alloc(u8, h * (stride + 1));
    defer allocator.free(raw);
    {
        var reader: std.Io.Reader = .fixed(idat.items);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var dec = std.compress.flate.Decompress.init(&reader, .zlib, &window);
        dec.reader.readSliceAll(raw) catch return error.InvalidPng;
    }

    const rgb = try allocator.alloc(u8, h * stride);
    errdefer allocator.free(rgb);
    for (0..h) |y| {
        const ft = raw[y * (stride + 1)];
        const src = raw[y * (stride + 1) + 1 ..][0..stride];
        const dst = rgb[y * stride ..][0..stride];
        const prev: ?[]const u8 = if (y > 0) rgb[(y - 1) * stride ..][0..stride] else null;
        for (0..stride) |i| {
            const a: u8 = if (i >= 3) dst[i - 3] else 0;
            const b: u8 = if (prev) |pr| pr[i] else 0;
            const c: u8 = if (prev != null and i >= 3) prev.?[i - 3] else 0;
            dst[i] = switch (ft) {
                0 => src[i],
                1 => src[i] +% a,
                2 => src[i] +% b,
                3 => src[i] +% @as(u8, @intCast((@as(u16, a) + @as(u16, b)) / 2)),
                4 => src[i] +% paeth(a, b, c),
                else => return error.UnsupportedPng,
            };
        }
    }
    return .{ .width = width, .height = height, .rgb = rgb };
}

// ---------------------------------------------------------------------------------------------------------
// Statistics
// ---------------------------------------------------------------------------------------------------------

/// Frame statistics from a scene-linear HDR capture. Non-finite pixels are counted and excluded from the rest.
pub const HdrStats = struct {
    nan_count: u64 = 0,
    inf_count: u64 = 0,
    mean_luma: f32 = 0,
    p50_luma: f32 = 0,
    p95_luma: f32 = 0,
};

pub fn hdrStats(allocator: std.mem.Allocator, img: Image) !HdrStats {
    const px = @as(usize, img.width) * img.height;
    var stats: HdrStats = .{};
    const lumas = try allocator.alloc(f32, px);
    defer allocator.free(lumas);
    var n: usize = 0;
    var sum: f64 = 0;
    for (0..px) |i| {
        const r = img.rgba[i * 4 + 0];
        const g = img.rgba[i * 4 + 1];
        const b = img.rgba[i * 4 + 2];
        if (std.math.isNan(r) or std.math.isNan(g) or std.math.isNan(b)) {
            stats.nan_count += 1;
            continue;
        }
        if (std.math.isInf(r) or std.math.isInf(g) or std.math.isInf(b)) {
            stats.inf_count += 1;
            continue;
        }
        const l = 0.2126 * r + 0.7152 * g + 0.0722 * b;
        lumas[n] = l;
        n += 1;
        sum += l;
    }
    if (n == 0) return stats;
    std.mem.sort(f32, lumas[0..n], {}, std.sort.asc(f32));
    stats.mean_luma = @floatCast(sum / @as(f64, @floatFromInt(n)));
    stats.p50_luma = lumas[n / 2];
    stats.p95_luma = lumas[@min(n - 1, n * 95 / 100)];
    return stats;
}

/// Counts isolated bright pixels: a pixel whose luma exceeds every one of its 8 neighbours by more than
/// `margin` (0..255). Real highlights span several pixels, so a high count points at speckle, dotted
/// silhouettes or NaN/Inf leakage rather than at scene content.
pub fn speckleCount(rgb: []const u8, width: u32, height: u32, margin: f32) u64 {
    const w: usize = width;
    const h: usize = height;
    if (w < 3 or h < 3 or rgb.len < w * h * 3) return 0;
    var count: u64 = 0;
    for (1..h - 1) |y| {
        for (1..w - 1) |x| {
            const c = luma8(rgb[(y * w + x) * 3], rgb[(y * w + x) * 3 + 1], rgb[(y * w + x) * 3 + 2]);
            var max_n: f32 = 0;
            for ([_]isize{ -1, 0, 1 }) |dy| {
                for ([_]isize{ -1, 0, 1 }) |dx| {
                    if (dx == 0 and dy == 0) continue;
                    const nx: usize = @intCast(@as(isize, @intCast(x)) + dx);
                    const ny: usize = @intCast(@as(isize, @intCast(y)) + dy);
                    const i = (ny * w + nx) * 3;
                    max_n = @max(max_n, luma8(rgb[i], rgb[i + 1], rgb[i + 2]));
                }
            }
            if (c > max_n + margin) count += 1;
        }
    }
    return count;
}

/// Luma spread (p95 - p5, 0..255) of an RGB8 image. A drop against the baseline means a washed-out frame.
pub fn contrastSpread(allocator: std.mem.Allocator, rgb: []const u8) !f32 {
    const px = rgb.len / 3;
    if (px == 0) return 0;
    var hist: [256]u64 = @splat(0);
    for (0..px) |i| {
        const l = luma8(rgb[i * 3], rgb[i * 3 + 1], rgb[i * 3 + 2]);
        hist[@intFromFloat(std.math.clamp(@round(l), 0, 255))] += 1;
    }
    _ = allocator;
    const lo_target = px * 5 / 100;
    const hi_target = px * 95 / 100;
    var acc: u64 = 0;
    var lo: usize = 0;
    var hi: usize = 255;
    var lo_set = false;
    for (hist, 0..) |c, v| {
        acc += c;
        if (!lo_set and acc > lo_target) {
            lo = v;
            lo_set = true;
        }
        if (acc >= hi_target) {
            hi = v;
            break;
        }
    }
    return @floatFromInt(hi -| lo);
}

// ---------------------------------------------------------------------------------------------------------
// Comparison
// ---------------------------------------------------------------------------------------------------------

/// Pixel-wise comparison result between two RGB8 images of identical size.
pub const Diff = struct {
    total: u64 = 0,
    /// Pixels with any channel differing by more than the threshold.
    differing: u64 = 0,
    max_delta: u8 = 0,

    pub fn differingFraction(self: Diff) f64 {
        if (self.total == 0) return 0;
        return @as(f64, @floatFromInt(self.differing)) / @as(f64, @floatFromInt(self.total));
    }
};

pub fn compareRgb8(a: []const u8, b: []const u8, threshold: u8) !Diff {
    if (a.len != b.len or a.len % 3 != 0) return error.SizeMismatch;
    var d: Diff = .{ .total = a.len / 3 };
    var i: usize = 0;
    while (i < a.len) : (i += 3) {
        var px_max: u8 = 0;
        for (0..3) |k| {
            const delta: u8 = if (a[i + k] > b[i + k]) a[i + k] - b[i + k] else b[i + k] - a[i + k];
            px_max = @max(px_max, delta);
        }
        d.max_delta = @max(d.max_delta, px_max);
        if (px_max > threshold) d.differing += 1;
    }
    return d;
}

/// Diff visualisation: differing pixels are red, the rest is the first image dimmed to 25%.
pub fn diffImageRgb8(allocator: std.mem.Allocator, a: []const u8, b: []const u8, threshold: u8) ![]u8 {
    if (a.len != b.len or a.len % 3 != 0) return error.SizeMismatch;
    const out = try allocator.alloc(u8, a.len);
    var i: usize = 0;
    while (i < a.len) : (i += 3) {
        var px_max: u8 = 0;
        for (0..3) |k| {
            const delta: u8 = if (a[i + k] > b[i + k]) a[i + k] - b[i + k] else b[i + k] - a[i + k];
            px_max = @max(px_max, delta);
        }
        if (px_max > threshold) {
            out[i] = 255;
            out[i + 1] = 0;
            out[i + 2] = 0;
        } else {
            out[i] = a[i] / 4;
            out[i + 1] = a[i + 1] / 4;
            out[i + 2] = a[i + 2] / 4;
        }
    }
    return out;
}

/// Reads `key=value` from a stats text file (one pair per line). Returns `null` when absent or malformed.
pub fn statValue(text: []const u8, key: []const u8) ?f64 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \r");
        if (t.len > key.len and std.mem.startsWith(u8, t, key) and t[key.len] == '=') {
            return std.fmt.parseFloat(f64, t[key.len + 1 ..]) catch null;
        }
    }
    return null;
}

test "statValue reads key=value lines and ignores partial key matches" {
    const text = "name=x\nspeckle=12\nspeckle_total=99\ncontrast=118.5\r\n";
    try std.testing.expectEqual(@as(?f64, 12), statValue(text, "speckle"));
    try std.testing.expectEqual(@as(?f64, 118.5), statValue(text, "contrast"));
    try std.testing.expectEqual(@as(?f64, null), statValue(text, "missing"));
}

// ---------------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------------

test "PNG round trip preserves pixels and compresses flat images" {
    const a = std.testing.allocator;
    // 200 x 120 x 3 = 72000 raw bytes: larger than one deflate window chunk of the stream buffer.
    const w: u32 = 200;
    const h: u32 = 120;
    const rgb = try a.alloc(u8, w * h * 3);
    defer a.free(rgb);
    for (rgb, 0..) |*v, i| v.* = @truncate(i * 7 + i / 31);

    const png = try encodePngRgb8(a, w, h, rgb);
    defer a.free(png);
    var dec = try decodePngRgb8(a, png);
    defer dec.deinit(a);
    try std.testing.expectEqual(w, dec.width);
    try std.testing.expectEqual(h, dec.height);
    try std.testing.expectEqualSlices(u8, rgb, dec.rgb);
}

test "PNG decoder rejects non-PNG data and unsupported variants" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidPng, decodePngRgb8(a, "not a png"));
    const rgb = [_]u8{ 1, 2, 3 };
    const png = try encodePngRgb8(a, 1, 1, &rgb);
    defer a.free(png);
    const bad = try a.dupe(u8, png);
    defer a.free(bad);
    bad[25] = 6; // colour type RGBA, which the reader does not support
    try std.testing.expectError(error.UnsupportedPng, decodePngRgb8(a, bad));
}

test "hdrStats counts NaN and Inf and excludes them from luminance" {
    const a = std.testing.allocator;
    var px = [_]f32{
        1, 1, 1, 1,
        1, 1, 1, 1,
        std.math.nan(f32), 0, 0, 1,
        std.math.inf(f32), 0, 0, 1,
    };
    const img = Image{ .width = 2, .height = 2, .rgba = &px };
    const s = try hdrStats(a, img);
    try std.testing.expectEqual(@as(u64, 1), s.nan_count);
    try std.testing.expectEqual(@as(u64, 1), s.inf_count);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), s.mean_luma, 1e-5);
}

test "speckleCount flags isolated bright pixels but not smooth gradients or blobs" {
    const a = std.testing.allocator;
    const w = 8;
    const h = 8;
    const rgb = try a.alloc(u8, w * h * 3);
    defer a.free(rgb);
    @memset(rgb, 20);
    try std.testing.expectEqual(@as(u64, 0), speckleCount(rgb, w, h, 40));

    // One isolated bright pixel.
    @memset(rgb[(3 * w + 3) * 3 ..][0..3], 255);
    try std.testing.expectEqual(@as(u64, 1), speckleCount(rgb, w, h, 40));

    // A 2x2 blob is not isolated: each pixel has a bright neighbour.
    @memset(rgb[(3 * w + 4) * 3 ..][0..3], 255);
    @memset(rgb[(4 * w + 3) * 3 ..][0..3], 255);
    @memset(rgb[(4 * w + 4) * 3 ..][0..3], 255);
    try std.testing.expectEqual(@as(u64, 0), speckleCount(rgb, w, h, 40));
}

test "contrastSpread drops for a flat image" {
    const a = std.testing.allocator;
    var flat: [300]u8 = @splat(128);
    try std.testing.expectEqual(@as(f32, 0), try contrastSpread(a, &flat));
    var ramp: [300]u8 = undefined;
    for (0..100) |i| {
        const v: u8 = @intCast(i * 255 / 99);
        ramp[i * 3] = v;
        ramp[i * 3 + 1] = v;
        ramp[i * 3 + 2] = v;
    }
    try std.testing.expect(try contrastSpread(a, &ramp) > 150);
}

test "compareRgb8 and diff image report differing pixels over a threshold" {
    const a = std.testing.allocator;
    const x = [_]u8{ 10, 10, 10, 200, 200, 200 };
    const y = [_]u8{ 12, 10, 10, 100, 200, 200 };
    const d = try compareRgb8(&x, &y, 5);
    try std.testing.expectEqual(@as(u64, 2), d.total);
    try std.testing.expectEqual(@as(u64, 1), d.differing);
    try std.testing.expectEqual(@as(u8, 100), d.max_delta);
    const img = try diffImageRgb8(a, &x, &y, 5);
    defer a.free(img);
    try std.testing.expectEqual(@as(u8, 255), img[3]);
    try std.testing.expectEqual(@as(u8, 2), img[0]);
    try std.testing.expectError(error.SizeMismatch, compareRgb8(&x, y[0..3], 5));
}

test "hdrPreviewRgb8 marks NaN magenta and Inf cyan" {
    const a = std.testing.allocator;
    var px = [_]f32{
        std.math.nan(f32), 0, 0, 1,
        std.math.inf(f32), 0, 0, 1,
    };
    const rgb = try hdrPreviewRgb8(a, .{ .width = 2, .height = 1, .rgba = &px });
    defer a.free(rgb);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 255, 0, 255, 255 }, rgb);
}

test "PNG encoder really compresses: a flat 128x128 frame is far smaller than its raw size" {
    const a = std.testing.allocator;
    const rgb = try a.alloc(u8, 128 * 128 * 3);
    defer a.free(rgb);
    @memset(rgb, 90);
    const png = try encodePngRgb8(a, 128, 128, rgb);
    defer a.free(png);
    try std.testing.expect(png.len < 1024);
    var dec = try decodePngRgb8(a, png);
    defer dec.deinit(a);
    try std.testing.expectEqualSlices(u8, rgb, dec.rgb);
}
