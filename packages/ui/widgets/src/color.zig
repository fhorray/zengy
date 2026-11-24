//! Color Space Math & Conversions (`official.ui.widgets`).
//!
//! Provides gimbal-lock-free conversions between `graphics.Color` (sRGBA),
//! `Hsla`, `Hsva`, `Hwba`, `Oklcha`, hex `#RRGGBB`/`#RRGGBBAA` parsing/formatting,
//! and perceptual lightening/darkening helpers.

const std = @import("std");
const graphics = @import("graphics");

/// Hue/Saturation/Lightness/Alpha color (hue in degrees `[0, 360)`).
pub const Hsla = struct {
    h: f32 = 0,
    s: f32 = 0,
    l: f32 = 0,
    a: f32 = 1,
};

/// Hue/Saturation/Value/Alpha color (hue in degrees `[0, 360)`).
pub const Hsva = struct {
    h: f32 = 0,
    s: f32 = 0,
    v: f32 = 0,
    a: f32 = 1,
};

/// Hue/Whiteness/Blackness/Alpha color (hue in degrees `[0, 360)`).
pub const Hwba = struct {
    h: f32 = 0,
    w: f32 = 0,
    b: f32 = 0,
    a: f32 = 1,
};

/// Transparent color constant.
pub const TRANSPARENT = graphics.Color{ .r = 0, .g = 0, .b = 0, .a = 0 };

/// Returns `c` with its alpha replaced by `alpha` clamped to `[0, 1]`.
pub fn withAlpha(c: graphics.Color, alpha: f32) graphics.Color {
    return .{
        .r = c.r,
        .g = c.g,
        .b = c.b,
        .a = std.math.clamp(alpha, 0.0, 1.0),
    };
}

/// Linearly interpolates between `a` and `b` by `t` in `[0, 1]`.
pub fn lerp(a: graphics.Color, b: graphics.Color, t: f32) graphics.Color {
    const k = std.math.clamp(t, 0.0, 1.0);
    return .{
        .r = a.r + (b.r - a.r) * k,
        .g = a.g + (b.g - a.g) * k,
        .b = a.b + (b.b - a.b) * k,
        .a = a.a + (b.a - a.a) * k,
    };
}

/// Lightens `c` by blending towards white in sRGB space.
pub fn lighter(c: graphics.Color, amount: f32) graphics.Color {
    const k = std.math.clamp(amount, 0.0, 1.0);
    return .{
        .r = c.r + (1.0 - c.r) * k,
        .g = c.g + (1.0 - c.g) * k,
        .b = c.b + (1.0 - c.b) * k,
        .a = c.a,
    };
}

/// Darkens `c` by scaling RGB towards black.
pub fn darker(c: graphics.Color, amount: f32) graphics.Color {
    const k = 1.0 - std.math.clamp(amount, 0.0, 1.0);
    return .{
        .r = c.r * k,
        .g = c.g * k,
        .b = c.b * k,
        .a = c.a,
    };
}

/// Converts OKLCH (perceptual lightness `l` in `[0,1]`, chroma `c`, hue `h_deg`) to sRGBA.
pub fn oklch(l: f32, c_chroma: f32, h_deg: f32, alpha: f32) graphics.Color {
    const h_rad = h_deg * (std.math.pi / 180.0);
    const a_ok = c_chroma * @cos(h_rad);
    const b_ok = c_chroma * @sin(h_rad);

    const l_ = l + 0.3963377774 * a_ok + 0.2158037573 * b_ok;
    const m_ = l - 0.1055613458 * a_ok - 0.0638541728 * b_ok;
    const s_ = l - 0.0894841775 * a_ok - 1.2914855480 * b_ok;

    const l3 = l_ * l_ * l_;
    const m3 = m_ * m_ * m_;
    const s3 = s_ * s_ * s_;

    const lr = 4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3;
    const lg = -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3;
    const lb = -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3;

    return .{
        .r = linearToSrgb(lr),
        .g = linearToSrgb(lg),
        .b = linearToSrgb(lb),
        .a = std.math.clamp(alpha, 0.0, 1.0),
    };
}

fn linearToSrgb(x: f32) f32 {
    const v = std.math.clamp(x, 0.0, 1.0);
    if (v <= 0.0031308) return v * 12.92;
    return 1.055 * std.math.pow(f32, v, 1.0 / 2.4) - 0.055;
}

/// Converts sRGBA to HSLA.
pub fn srgbaToHsla(c: graphics.Color) Hsla {
    const max_c = @max(c.r, @max(c.g, c.b));
    const min_c = @min(c.r, @min(c.g, c.b));
    const l = (max_c + min_c) * 0.5;
    const d = max_c - min_c;
    if (d <= 1e-6) return .{ .h = 0, .s = 0, .l = l, .a = c.a };

    const s = if (l > 0.5) d / (2.0 - max_c - min_c) else d / (max_c + min_c);
    var h: f32 = 0;
    if (max_c == c.r) {
        h = (c.g - c.b) / d + (if (c.g < c.b) @as(f32, 6.0) else @as(f32, 0.0));
    } else if (max_c == c.g) {
        h = (c.b - c.r) / d + 2.0;
    } else {
        h = (c.r - c.g) / d + 4.0;
    }
    h *= 60.0;
    return .{ .h = @mod(h, 360.0), .s = std.math.clamp(s, 0.0, 1.0), .l = std.math.clamp(l, 0.0, 1.0), .a = c.a };
}

fn hue2rgb(p: f32, q: f32, t_in: f32) f32 {
    var t = t_in;
    if (t < 0.0) t += 1.0;
    if (t > 1.0) t -= 1.0;
    if (t < 1.0 / 6.0) return p + (q - p) * 6.0 * t;
    if (t < 0.5) return q;
    if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
    return p;
}

/// Converts HSLA to sRGBA.
pub fn hslaToSrgba(hsla: Hsla) graphics.Color {
    const s = std.math.clamp(hsla.s, 0.0, 1.0);
    const l = std.math.clamp(hsla.l, 0.0, 1.0);
    if (s <= 1e-6) return .{ .r = l, .g = l, .b = l, .a = hsla.a };
    const q = if (l < 0.5) l * (1.0 + s) else l + s - l * s;
    const p = 2.0 * l - q;
    const hn = @mod(hsla.h, 360.0) / 360.0;
    return .{
        .r = hue2rgb(p, q, hn + 1.0 / 3.0),
        .g = hue2rgb(p, q, hn),
        .b = hue2rgb(p, q, hn - 1.0 / 3.0),
        .a = std.math.clamp(hsla.a, 0.0, 1.0),
    };
}

/// Converts HSVA to HWBA.
pub fn hsvaToHwba(hsv: Hsva) Hwba {
    return .{
        .h = hsv.h,
        .w = (1.0 - hsv.s) * hsv.v,
        .b = 1.0 - hsv.v,
        .a = hsv.a,
    };
}

/// Converts HWBA to sRGBA.
pub fn hwbaToSrgba(hwb: Hwba) graphics.Color {
    const w = std.math.clamp(hwb.w, 0.0, 1.0);
    const b = std.math.clamp(hwb.b, 0.0, 1.0);
    const sum = w + b;
    if (sum >= 1.0) {
        const gray = w / sum;
        return .{ .r = gray, .g = gray, .b = gray, .a = hwb.a };
    }
    const pure = hslaToSrgba(.{ .h = hwb.h, .s = 1.0, .l = 0.5, .a = 1.0 });
    const scale = 1.0 - w - b;
    return .{
        .r = pure.r * scale + w,
        .g = pure.g * scale + w,
        .b = pure.b * scale + w,
        .a = std.math.clamp(hwb.a, 0.0, 1.0),
    };
}

/// Converts sRGBA to HWBA.
pub fn srgbaToHwba(c: graphics.Color) Hwba {
    const hsla = srgbaToHsla(c);
    const w = @min(c.r, @min(c.g, c.b));
    const b = 1.0 - @max(c.r, @max(c.g, c.b));
    return .{ .h = hsla.h, .w = w, .b = b, .a = c.a };
}

/// Formats `c` as `#RRGGBBAA` into `buf` (must be at least 9 bytes).
pub fn formatHexRgba(c: graphics.Color, buf: []u8) ![]const u8 {
    const r: u8 = @intFromFloat(@round(std.math.clamp(c.r, 0.0, 1.0) * 255.0));
    const g: u8 = @intFromFloat(@round(std.math.clamp(c.g, 0.0, 1.0) * 255.0));
    const b: u8 = @intFromFloat(@round(std.math.clamp(c.b, 0.0, 1.0) * 255.0));
    const a: u8 = @intFromFloat(@round(std.math.clamp(c.a, 0.0, 1.0) * 255.0));
    return std.fmt.bufPrint(buf, "#{X:0>2}{X:0>2}{X:0>2}{X:0>2}", .{ r, g, b, a });
}

/// Parses `#RRGGBB` or `#RRGGBBAA` (with optional leading `#`).
pub fn parseHexRgba(text: []const u8) ?graphics.Color {
    const s = if (text.len > 0 and text[0] == '#') text[1..] else text;
    if (s.len != 6 and s.len != 8) return null;
    const r = std.fmt.parseInt(u8, s[0..2], 16) catch return null;
    const g = std.fmt.parseInt(u8, s[2..4], 16) catch return null;
    const b = std.fmt.parseInt(u8, s[4..6], 16) catch return null;
    const a: u8 = if (s.len == 8) (std.fmt.parseInt(u8, s[6..8], 16) catch return null) else 255;
    return .{
        .r = @as(f32, @floatFromInt(r)) / 255.0,
        .g = @as(f32, @floatFromInt(g)) / 255.0,
        .b = @as(f32, @floatFromInt(b)) / 255.0,
        .a = @as(f32, @floatFromInt(a)) / 255.0,
    };
}
