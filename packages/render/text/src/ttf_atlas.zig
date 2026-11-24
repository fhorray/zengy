//! Anti-aliased TrueType Font Atlas (`official.text`).
//!
//! Bakes an embedded TTF font (such as `FiraSans-Regular.ttf`) into an RGBA8
//! alpha-masked glyph atlas using `stb_truetype` with proportional advances.

const std = @import("std");
const graphics = @import("graphics");
const text_pkg = @import("text.zig");

const ZengyBakedChar = extern struct {
    x0: u16,
    y0: u16,
    x1: u16,
    y1: u16,
    xoff: f32,
    yoff: f32,
    xadvance: f32,
};

extern fn zengy_ttf_bake(
    ttf_data: [*]const u8,
    pixel_height: f32,
    out_alpha: [*]u8,
    pw: c_int,
    ph: c_int,
    out_chars: [*]ZengyBakedChar,
    out_ascent: *f32,
) c_int;

extern fn zengy_ttf_bake_codepoints(
    ttf_data: [*]const u8,
    pixel_height: f32,
    out_alpha: [*]u8,
    pw: c_int,
    ph: c_int,
    codepoints: [*]const c_int,
    count: c_int,
    out_chars: [*]ZengyBakedChar,
) c_int;

extern fn zengy_ttf_bake_extra(
    ttf_data: [*]const u8,
    pixel_height: f32,
    out_alpha: [*]u8,
    pw: c_int,
    ph: c_int,
    start_y: c_int,
    codepoints: [*]const c_int,
    count: c_int,
    out_chars: [*]ZengyBakedChar,
) c_int;

/// Code points baked beyond ASCII, sorted ascending: Latin-1 Supplement, Latin Extended-A,
/// common punctuation and currency, Greek, and Cyrillic. Code points the font lacks fall back to `?`.
pub const extra_codepoints: [extra_count]c_int = blk: {
    @setEvalBranchQuota(10_000);
    var out: [extra_count]c_int = undefined;
    var n: usize = 0;
    // Ascending ranges only: `glyph` binary-searches this table.
    for (0xA0..0x180) |c| {
        out[n] = @intCast(c);
        n += 1;
    }
    for (0x391..0x3CA) |c| {
        out[n] = @intCast(c);
        n += 1;
    }
    for (0x400..0x460) |c| {
        out[n] = @intCast(c);
        n += 1;
    }
    for ([_]c_int{ 0x2013, 0x2014, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2026, 0x20AC, 0x2122 }) |c| {
        out[n] = c;
        n += 1;
    }
    std.debug.assert(n == extra_count);
    for (1..n) |i| std.debug.assert(out[i - 1] < out[i]);
    break :blk out;
};
const extra_count: usize = (0x180 - 0xA0) + 10 + (0x3CA - 0x391) + (0x460 - 0x400);

/// Embedded Fira Sans Regular TTF bytes (SIL Open Font License 1.1).
pub const FIRA_SANS_REGULAR: []const u8 = @embedFile("FiraSans-Regular.ttf");

/// Embedded official Lucide Icons TTF bytes (ISC License).
pub const LUCIDE_TTF: []const u8 = @embedFile("lucide.ttf");

/// Line pitch as a multiple of the text height, shared by measurement and drawing.
const line_spacing: f32 = 1.25;

/// Baked proportional TTF glyph atlas for ASCII 32..126.
pub const TtfAtlas = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    baked_px_h: f32,
    ascent_px: f32,
    chars: [95]ZengyBakedChar,
    /// Glyphs for `extra_codepoints` (same order); `xadvance < 0` marks a missing glyph.
    extra: [extra_count]ZengyBakedChar,
    rgba_pixels: []u8,

    /// Returns the glyph drawn for `cp`: the baked glyph, or `?` when the code point is not in the
    /// atlas (outside ASCII and the extra ranges, missing from the font, or out of atlas space).
    pub fn glyph(self: *const TtfAtlas, cp: u21) *const ZengyBakedChar {
        if (cp >= 32 and cp <= 126) return &self.chars[cp - 32];
        const key: c_int = @intCast(cp);
        const idx = std.sort.binarySearch(c_int, &extra_codepoints, key, struct {
            fn order(k: c_int, item: c_int) std.math.Order {
                return std.math.order(k, item);
            }
        }.order);
        if (idx) |i| {
            if (self.extra[i].xadvance >= 0) return &self.extra[i];
        }
        return &self.chars['?' - 32];
    }

    /// Bakes `ttf_bytes` at `baked_px_h` into a `1024x1024` white RGBA8 texture (ASCII on top,
    /// extended glyphs below).
    pub fn bake(allocator: std.mem.Allocator, ttf_bytes: []const u8, baked_px_h: f32) !TtfAtlas {
        const w: u32 = 1024;
        const h: u32 = 1024;
        const alpha_buf = try allocator.alloc(u8, w * h);
        defer allocator.free(alpha_buf);
        @memset(alpha_buf, 0);

        var chars: [95]ZengyBakedChar = undefined;
        var ascent_px: f32 = baked_px_h * 0.8;
        if (zengy_ttf_bake(
            ttf_bytes.ptr,
            baked_px_h,
            alpha_buf.ptr,
            @intCast(w),
            @intCast(h),
            &chars,
            &ascent_px,
        ) == 0) {
            return error.FontBakeFailed;
        }

        // The extended glyphs go below the last row used by the ASCII bake.
        var ascii_bottom: u32 = 0;
        for (chars) |c| ascii_bottom = @max(ascii_bottom, c.y1);
        var extra: [extra_count]ZengyBakedChar = undefined;
        _ = zengy_ttf_bake_extra(
            ttf_bytes.ptr,
            baked_px_h,
            alpha_buf.ptr,
            @intCast(w),
            @intCast(h),
            @intCast(ascii_bottom + 3),
            &extra_codepoints,
            @intCast(extra_count),
            &extra,
        );

        const rgba = try allocator.alloc(u8, w * h * 4);
        for (alpha_buf, 0..) |a, i| {
            const base = i * 4;
            rgba[base] = 255;
            rgba[base + 1] = 255;
            rgba[base + 2] = 255;
            rgba[base + 3] = a;
        }

        return .{
            .allocator = allocator,
            .width = w,
            .height = h,
            .baked_px_h = baked_px_h,
            .ascent_px = ascent_px,
            .chars = chars,
            .extra = extra,
            .rgba_pixels = rgba,
        };
    }

    /// Frees the baked RGBA8 pixel buffer.
    pub fn deinit(self: *TtfAtlas) void {
        self.allocator.free(self.rgba_pixels);
    }

    /// Measures proportional text bounding box at `target_px_h`.
    pub fn measureText(self: *const TtfAtlas, text: []const u8, target_px_h: f32) text_pkg.TextSize {
        const s = target_px_h / self.baked_px_h;
        var max_w: f32 = 0;
        var cur_w: f32 = 0;
        var lines: f32 = 1;
        var i: usize = 0;
        while (i < text.len) {
            const cp = text_pkg.nextCodepoint(text, &i);
            if (cp == '\n') {
                if (cur_w > max_w) max_w = cur_w;
                cur_w = 0;
                lines += 1;
            } else {
                cur_w += self.glyph(cp).xadvance * s;
            }
        }
        if (cur_w > max_w) max_w = cur_w;
        // Same line pitch (`line_spacing`) as emitTextQuads so measured and drawn heights agree.
        return .{ .width = max_w, .height = target_px_h + (lines - 1) * target_px_h * line_spacing };
    }

    /// Emits proportional textured quads for `text` at target pixel height `target_px_h`.
    pub fn emitTextQuads(
        self: *const TtfAtlas,
        allocator: std.mem.Allocator,
        out_quads: *std.ArrayList(text_pkg.TextQuad),
        x: f32,
        y: f32,
        text: []const u8,
        target_px_h: f32,
        color: graphics.Color,
    ) !void {
        const s = target_px_h / self.baked_px_h;
        var pen_x = x;
        var pen_y = y + self.ascent_px * s;
        const aw: f32 = @floatFromInt(self.width);
        const ah: f32 = @floatFromInt(self.height);

        var i: usize = 0;
        while (i < text.len) {
            const cp = text_pkg.nextCodepoint(text, &i);
            if (cp == '\n') {
                pen_x = x;
                pen_y += target_px_h * line_spacing;
                continue;
            }
            const bc = self.glyph(cp).*;
            if (cp != ' ') {
                const gw = @as(f32, @floatFromInt(bc.x1 - bc.x0)) * s;
                const gh = @as(f32, @floatFromInt(bc.y1 - bc.y0)) * s;
                if (gw > 0 and gh > 0) {
                    try out_quads.append(allocator, .{
                        .x = pen_x + bc.xoff * s,
                        .y = pen_y + bc.yoff * s,
                        .width = gw,
                        .height = gh,
                        .u0 = @as(f32, @floatFromInt(bc.x0)) / aw,
                        .v0 = @as(f32, @floatFromInt(bc.y0)) / ah,
                        .u1 = @as(f32, @floatFromInt(bc.x1)) / aw,
                        .v1 = @as(f32, @floatFromInt(bc.y1)) / ah,
                        .color = color,
                    });
                }
            }
            pen_x += bc.xadvance * s;
        }
    }
};

/// Official Lucide icon codepoints matching `graphics.IconKind` order.
pub const LUCIDE_ICON_CODEPOINTS = [_]c_int{
    0xe06c, // check
    0xe06d, // chevron_down
    0xe06e, // chevron_left
    0xe06f, // chevron_right
    0xe070, // chevron_up
    0xe1b2, // close_x
    0xe0eb, // grip_vertical
    0xe1dd, // color_wheel (palette)
    0xe13d, // plus
    0xe11c, // minus
    0xe151, // search
    0xe154, // settings
    0xe0ba, // eye
    0xe0bb, // eye_off
    0xe0b4, // droplet
    0xe59c, // opacity (blend)
    0xe257, // corner_radius (scan)
    0xe113, // maximize_2
    0xe0ff, // grid_2x2 (layout-grid)
    0xe29a, // sliders_horizontal
    0xe185, // align_left
    0xe182, // align_center
    0xe183, // align_right
    0xe184, // align_justify
    0xe45b, // align_top (arrow-up-to-line)
    0xe43c, // align_middle (fold-vertical)
    0xe455, // align_bottom (arrow-down-to-line)
    0xe19a, // underline
    0xe177, // strikethrough
    0xe106, // list_bullet
    0xe1d1, // list_ordered
    0xe18e, // trash_2
    0xe09e, // copy
    0xe0d7, // folder
    0xe0c0, // file
    0xe13c, // play
    0xe12e, // pause
    0xe145, // refresh_cw
    0xe082, // help_circle
    0xe0f9, // info
    0xe193, // alert_triangle
    0xe226, // check_circle
};

/// Baked anti-aliased Lucide icon atlas.
pub const IconAtlas = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    baked_px_h: f32,
    chars: [LUCIDE_ICON_CODEPOINTS.len]ZengyBakedChar,
    rgba_pixels: []u8,

    /// Bakes `LUCIDE_TTF` for all `LUCIDE_ICON_CODEPOINTS` into a `512x512` RGBA8 texture.
    pub fn bake(allocator: std.mem.Allocator, baked_px_h: f32) !IconAtlas {
        const w: u32 = 512;
        const h: u32 = 512;
        const alpha = try allocator.alloc(u8, w * h);
        defer allocator.free(alpha);
        @memset(alpha, 0);

        var chars: [LUCIDE_ICON_CODEPOINTS.len]ZengyBakedChar = undefined;
        const ok = zengy_ttf_bake_codepoints(
            LUCIDE_TTF.ptr,
            baked_px_h,
            alpha.ptr,
            @intCast(w),
            @intCast(h),
            &LUCIDE_ICON_CODEPOINTS,
            @intCast(LUCIDE_ICON_CODEPOINTS.len),
            &chars,
        );
        if (ok == 0) return error.TtfBakeFailed;

        const rgba = try allocator.alloc(u8, w * h * 4);
        for (alpha, 0..) |a, i| {
            rgba[i * 4 + 0] = 255;
            rgba[i * 4 + 1] = 255;
            rgba[i * 4 + 2] = 255;
            rgba[i * 4 + 3] = a;
        }
        return .{
            .allocator = allocator,
            .width = w,
            .height = h,
            .baked_px_h = baked_px_h,
            .chars = chars,
            .rgba_pixels = rgba,
        };
    }

    /// Releases the baked icon atlas pixel buffer.
    pub fn deinit(self: *IconAtlas) void {
        self.allocator.free(self.rgba_pixels);
    }

    /// Returns a `TextQuad` for icon `kind_idx` centered inside `(x, y, size, size)`.
    pub fn makeIconQuad(self: *const IconAtlas, kind_idx: usize, x: f32, y: f32, size: f32, color: graphics.Color) ?text_pkg.TextQuad {
        if (kind_idx >= self.chars.len) return null;
        const bc = self.chars[kind_idx];
        const gw: f32 = @floatFromInt(bc.x1 - bc.x0);
        const gh: f32 = @floatFromInt(bc.y1 - bc.y0);
        if (gw <= 0.0 or gh <= 0.0) return null;
        const s = size / self.baked_px_h;
        const qw = gw * s;
        const qh = gh * s;
        const aw: f32 = @floatFromInt(self.width);
        const ah: f32 = @floatFromInt(self.height);
        return .{
            .x = @round(x + (size - qw) * 0.5),
            .y = @round(y + (size - qh) * 0.5),
            .width = qw,
            .height = qh,
            .u0 = @as(f32, @floatFromInt(bc.x0)) / aw,
            .v0 = @as(f32, @floatFromInt(bc.y0)) / ah,
            .u1 = @as(f32, @floatFromInt(bc.x1)) / aw,
            .v1 = @as(f32, @floatFromInt(bc.y1)) / ah,
            .color = color,
        };
    }
};
