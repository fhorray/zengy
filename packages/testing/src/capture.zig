//! Offscreen Render Capture & Software Framebuffer (`official.testing.capture`).
//!
//! Provides `CaptureService` (`engine.testing.capture/1`) for headless visual
//! regression testing without requiring a physical OS window or GPU.
//!
//! Features:
//! - Deterministic RGBA8 software rasterizer over `graphics.DrawCommand` lists (`clear`, `rect`).
//! - `readPixel(x, y)` for exact color assertions.
//! - `computeHash()` for fast golden-frame regression checks.
//! - `encodePpm()` to export standard P6 PPM image bytes for inspection.

const std = @import("std");
const graphics = @import("graphics");

/// Offscreen RGBA8 software framebuffer used for deterministic visual testing.
pub const CaptureService = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    pixels: []u8,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !CaptureService {
        const len = @as(usize, width) * @as(usize, height) * 4;
        const pixels = try allocator.alloc(u8, len);
        @memset(pixels, 0);
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .pixels = pixels,
        };
    }

    pub fn deinit(self: *CaptureService) void {
        self.allocator.free(self.pixels);
    }

    fn floatToU8(v: f32) u8 {
        const clamped = @max(@as(f32, 0.0), @min(@as(f32, 1.0), v));
        return @intFromFloat(@round(clamped * 255.0));
    }

    fn blendPixel(self: *CaptureService, x: u32, y: u32, sr: u8, sg: u8, sb: u8, sa: u8) void {
        if (x >= self.width or y >= self.height or sa == 0) return;
        const idx = (@as(usize, y) * @as(usize, self.width) + @as(usize, x)) * 4;
        if (sa == 255) {
            self.pixels[idx] = sr;
            self.pixels[idx + 1] = sg;
            self.pixels[idx + 2] = sb;
            self.pixels[idx + 3] = 255;
            return;
        }
        const a: u32 = sa;
        const inv_a: u32 = 255 - a;
        self.pixels[idx] = @intCast((@as(u32, sr) * a + @as(u32, self.pixels[idx]) * inv_a) / 255);
        self.pixels[idx + 1] = @intCast((@as(u32, sg) * a + @as(u32, self.pixels[idx + 1]) * inv_a) / 255);
        self.pixels[idx + 2] = @intCast((@as(u32, sb) * a + @as(u32, self.pixels[idx + 2]) * inv_a) / 255);
        self.pixels[idx + 3] = @intCast(@min(@as(u32, 255), a + (@as(u32, self.pixels[idx + 3]) * inv_a) / 255));
    }

    const ClipBounds = struct {
        x0: i32,
        y0: i32,
        x1: i32,
        y1: i32,

        fn intersect(a: @This(), b: @This()) @This() {
            const ix0 = @max(a.x0, b.x0);
            const iy0 = @max(a.y0, b.y0);
            return .{
                .x0 = ix0,
                .y0 = iy0,
                .x1 = @max(ix0, @min(a.x1, b.x1)),
                .y1 = @max(iy0, @min(a.y1, b.y1)),
            };
        }
    };

    fn blendPixelClipped(self: *CaptureService, x: i32, y: i32, clip: ClipBounds, sr: u8, sg: u8, sb: u8, sa: u8) void {
        if (x < clip.x0 or y < clip.y0 or x >= clip.x1 or y >= clip.y1) return;
        self.blendPixel(@intCast(x), @intCast(y), sr, sg, sb, sa);
    }

    fn hueDegToRgb(hue_deg: f32) graphics.Color {
        const h = @mod(hue_deg, 360.0) / 60.0;
        const f = h - @floor(h);
        const sector: u32 = @intFromFloat(@floor(h));
        return switch (sector) {
            0 => .{ .r = 1.0, .g = f, .b = 0.0, .a = 1.0 },
            1 => .{ .r = 1.0 - f, .g = 1.0, .b = 0.0, .a = 1.0 },
            2 => .{ .r = 0.0, .g = 1.0, .b = f, .a = 1.0 },
            3 => .{ .r = 0.0, .g = 1.0 - f, .b = 1.0, .a = 1.0 },
            4 => .{ .r = f, .g = 0.0, .b = 1.0, .a = 1.0 },
            else => .{ .r = 1.0, .g = 0.0, .b = 1.0 - f, .a = 1.0 },
        };
    }

    fn lerpColor(a: graphics.Color, b: graphics.Color, t: f32) graphics.Color {
        return .{
            .r = a.r + (b.r - a.r) * t,
            .g = a.g + (b.g - a.g) * t,
            .b = a.b + (b.b - a.b) * t,
            .a = a.a + (b.a - a.a) * t,
        };
    }

    fn toClipBounds(self: *const CaptureService, r: graphics.ClipRect) ClipBounds {
        const ix0: i32 = @intFromFloat(@max(@as(f32, 0.0), @floor(r.x)));
        const iy0: i32 = @intFromFloat(@max(@as(f32, 0.0), @floor(r.y)));
        const ix1: i32 = @intFromFloat(@min(@as(f32, @floatFromInt(self.width)), @ceil(r.x + r.width)));
        const iy1: i32 = @intFromFloat(@min(@as(f32, @floatFromInt(self.height)), @ceil(r.y + r.height)));
        return .{ .x0 = ix0, .y0 = iy0, .x1 = @max(ix0, ix1), .y1 = @max(iy0, iy1) };
    }

    /// Rasterizes a slice of `graphics.DrawCommand`s into the offscreen RGBA8 buffer.
    pub fn rasterize(self: *CaptureService, cmds: []const graphics.DrawCommand) void {
        const full_clip = ClipBounds{
            .x0 = 0,
            .y0 = 0,
            .x1 = @intCast(self.width),
            .y1 = @intCast(self.height),
        };
        var clip_stack: [32]ClipBounds = undefined;
        var clip_depth: usize = 0;
        var active_clip = full_clip;

        for (cmds) |cmd| {
            switch (cmd) {
                .clear => |col| {
                    const r = floatToU8(col.r);
                    const g = floatToU8(col.g);
                    const b = floatToU8(col.b);
                    const a = floatToU8(col.a);
                    var i: usize = 0;
                    while (i < self.pixels.len) : (i += 4) {
                        self.pixels[i] = r;
                        self.pixels[i + 1] = g;
                        self.pixels[i + 2] = b;
                        self.pixels[i + 3] = a;
                    }
                },
                .rect => |rc| {
                    if (!std.math.isFinite(rc.x) or !std.math.isFinite(rc.y) or
                        !std.math.isFinite(rc.width) or !std.math.isFinite(rc.height))
                    {
                        continue;
                    }
                    if (rc.width <= 0.0 or rc.height <= 0.0) continue;

                    const r = floatToU8(rc.color.r);
                    const g = floatToU8(rc.color.g);
                    const b = floatToU8(rc.color.b);
                    const a = floatToU8(rc.color.a);

                    const x0 = @max(active_clip.x0, @as(i32, @intFromFloat(@floor(rc.x))));
                    const y0 = @max(active_clip.y0, @as(i32, @intFromFloat(@floor(rc.y))));
                    const x1 = @min(active_clip.x1, @as(i32, @intFromFloat(@ceil(rc.x + rc.width))));
                    const y1 = @min(active_clip.y1, @as(i32, @intFromFloat(@ceil(rc.y + rc.height))));
                    if (x0 >= x1 or y0 >= y1) continue;

                    var py = y0;
                    while (py < y1) : (py += 1) {
                        var px = x0;
                        while (px < x1) : (px += 1) {
                            self.blendPixel(@intCast(px), @intCast(py), r, g, b, a);
                        }
                    }
                },
                .rounded_rect => |rr| {
                    if (rr.width <= 0.0 or rr.height <= 0.0) continue;
                    const x0 = @max(active_clip.x0, @as(i32, @intFromFloat(@floor(rr.x))));
                    const y0 = @max(active_clip.y0, @as(i32, @intFromFloat(@floor(rr.y))));
                    const x1 = @min(active_clip.x1, @as(i32, @intFromFloat(@ceil(rr.x + rr.width))));
                    const y1 = @min(active_clip.y1, @as(i32, @intFromFloat(@ceil(rr.y + rr.height))));
                    if (x0 >= x1 or y0 >= y1) continue;

                    const fr = floatToU8(rr.color.r);
                    const fg = floatToU8(rr.color.g);
                    const fb = floatToU8(rr.color.b);
                    const fa = floatToU8(rr.color.a);
                    const br = floatToU8(rr.border_color.r);
                    const bg = floatToU8(rr.border_color.g);
                    const bb = floatToU8(rr.border_color.b);
                    const ba = floatToU8(rr.border_color.a);

                    const max_r = @min(rr.width, rr.height) * 0.5;
                    const rads = [4]f32{
                        @min(max_r, @max(@as(f32, 0.0), rr.corner_radii[0])),
                        @min(max_r, @max(@as(f32, 0.0), rr.corner_radii[1])),
                        @min(max_r, @max(@as(f32, 0.0), rr.corner_radii[2])),
                        @min(max_r, @max(@as(f32, 0.0), rr.corner_radii[3])),
                    };

                    var py = y0;
                    while (py < y1) : (py += 1) {
                        const fy = @as(f32, @floatFromInt(py)) + 0.5 - rr.y;
                        var px = x0;
                        while (px < x1) : (px += 1) {
                            const fx = @as(f32, @floatFromInt(px)) + 0.5 - rr.x;
                            // Corner rounding test
                            var inside = true;
                            if (fx < rads[0] and fy < rads[0]) {
                                const dx = rads[0] - fx;
                                const dy = rads[0] - fy;
                                inside = (dx * dx + dy * dy) <= rads[0] * rads[0];
                            } else if (fx > rr.width - rads[1] and fy < rads[1]) {
                                const dx = fx - (rr.width - rads[1]);
                                const dy = rads[1] - fy;
                                inside = (dx * dx + dy * dy) <= rads[1] * rads[1];
                            } else if (fx > rr.width - rads[2] and fy > rr.height - rads[2]) {
                                const dx = fx - (rr.width - rads[2]);
                                const dy = fy - (rr.height - rads[2]);
                                inside = (dx * dx + dy * dy) <= rads[2] * rads[2];
                            } else if (fx < rads[3] and fy > rr.height - rads[3]) {
                                const dx = rads[3] - fx;
                                const dy = fy - (rr.height - rads[3]);
                                inside = (dx * dx + dy * dy) <= rads[3] * rads[3];
                            }
                            if (!inside) continue;

                            const is_border = ba > 0 and (fy < rr.border_widths[0] or
                                fx > rr.width - rr.border_widths[1] or
                                fy > rr.height - rr.border_widths[2] or
                                fx < rr.border_widths[3]);
                            if (is_border) {
                                self.blendPixel(@intCast(px), @intCast(py), br, bg, bb, ba);
                            } else if (fa > 0) {
                                self.blendPixel(@intCast(px), @intCast(py), fr, fg, fb, fa);
                            }
                        }
                    }
                },
                .gradient_rect => |gr| {
                    if (gr.width <= 0.0 or gr.height <= 0.0) continue;
                    const x0 = @max(active_clip.x0, @as(i32, @intFromFloat(@floor(gr.x))));
                    const y0 = @max(active_clip.y0, @as(i32, @intFromFloat(@floor(gr.y))));
                    const x1 = @min(active_clip.x1, @as(i32, @intFromFloat(@ceil(gr.x + gr.width))));
                    const y1 = @min(active_clip.y1, @as(i32, @intFromFloat(@ceil(gr.y + gr.height))));
                    if (x0 >= x1 or y0 >= y1) continue;

                    var py = y0;
                    while (py < y1) : (py += 1) {
                        const ty = @max(@as(f32, 0.0), @min(@as(f32, 1.0), (@as(f32, @floatFromInt(py)) + 0.5 - gr.y) / gr.height));
                        var px = x0;
                        while (px < x1) : (px += 1) {
                            const tx = @max(@as(f32, 0.0), @min(@as(f32, 1.0), (@as(f32, @floatFromInt(px)) + 0.5 - gr.x) / gr.width));
                            const col: graphics.Color = switch (gr.kind) {
                                .linear_horizontal => lerpColor(gr.stops[0], gr.stops[1], tx),
                                .linear_vertical => lerpColor(gr.stops[0], gr.stops[1], ty),
                                .linear_horizontal_3 => if (tx < 0.5)
                                    lerpColor(gr.stops[0], gr.stops[1], tx * 2.0)
                                else
                                    lerpColor(gr.stops[1], gr.stops[2], (tx - 0.5) * 2.0),
                                .bilinear => lerpColor(
                                    lerpColor(gr.stops[0], gr.stops[1], tx),
                                    lerpColor(gr.stops[3], gr.stops[2], tx),
                                    ty,
                                ),
                                .hue_horizontal => hueDegToRgb(tx * 360.0),
                                .checkerboard => blk: {
                                    const cx_i: usize = @intFromFloat(@floor((@as(f32, @floatFromInt(px)) - gr.x) / 6.0));
                                    const cy_i: usize = @intFromFloat(@floor((@as(f32, @floatFromInt(py)) - gr.y) / 6.0));
                                    break :blk if ((cx_i + cy_i) % 2 == 0) gr.stops[0] else gr.stops[1];
                                },
                            };
                            self.blendPixel(@intCast(px), @intCast(py), floatToU8(col.r), floatToU8(col.g), floatToU8(col.b), floatToU8(col.a));
                        }
                    }
                },
                .color_wheel => |cw| {
                    if (cw.size <= 4.0) continue;
                    const cx = cw.x + cw.size * 0.5;
                    const cy = cw.y + cw.size * 0.5;
                    const outer_r = cw.size * 0.5;
                    const inner_r = @max(@as(f32, 2.0), outer_r - cw.ring_width);
                    const x0 = @max(active_clip.x0, @as(i32, @intFromFloat(@floor(cw.x))));
                    const y0 = @max(active_clip.y0, @as(i32, @intFromFloat(@floor(cw.y))));
                    const x1 = @min(active_clip.x1, @as(i32, @intFromFloat(@ceil(cw.x + cw.size))));
                    const y1 = @min(active_clip.y1, @as(i32, @intFromFloat(@ceil(cw.y + cw.size))));
                    var py = y0;
                    while (py < y1) : (py += 1) {
                        const dy = (@as(f32, @floatFromInt(py)) + 0.5) - cy;
                        var px = x0;
                        while (px < x1) : (px += 1) {
                            const dx = (@as(f32, @floatFromInt(px)) + 0.5) - cx;
                            const dist = @sqrt(dx * dx + dy * dy);
                            if (dist >= inner_r and dist <= outer_r) {
                                var deg = std.math.atan2(dy, dx) * (180.0 / std.math.pi);
                                if (deg < 0.0) deg += 360.0;
                                const col = hueDegToRgb(deg);
                                self.blendPixel(@intCast(px), @intCast(py), floatToU8(col.r), floatToU8(col.g), floatToU8(col.b), 255);
                            }
                        }
                    }
                },
                .icon => |ic| {
                    if (ic.size <= 1.0 or ic.color.a <= 0.0) continue;
                    const cx: i32 = @intFromFloat(@round(ic.x + ic.size * 0.5));
                    const cy: i32 = @intFromFloat(@round(ic.y + ic.size * 0.5));
                    self.blendPixelClipped(cx, cy, active_clip, floatToU8(ic.color.r), floatToU8(ic.color.g), floatToU8(ic.color.b), floatToU8(ic.color.a));
                },
                // Deterministic 3x5 monochrome glyph blocks for visible text presence checks.
                .text => |tx| {
                    if (!std.math.isFinite(tx.x) or !std.math.isFinite(tx.y)) continue;
                    const fh: f32 = @floatFromInt(self.height);
                    const fw: f32 = @floatFromInt(self.width);
                    if (tx.y < -8.0 or tx.y >= fh) continue;

                    const r = floatToU8(tx.color.r);
                    const g = floatToU8(tx.color.g);
                    const b = floatToU8(tx.color.b);
                    const a = floatToU8(tx.color.a);

                    const gy0: i32 = @intFromFloat(@round(tx.y));
                    var cursor_x = tx.x;
                    for (tx.content) |ch| {
                        if (cursor_x >= fw) break;
                        if (ch != ' ' and cursor_x >= -4.0) {
                            const gx0: i32 = @intFromFloat(@round(cursor_x));
                            for (0..5) |dy| {
                                for (0..3) |dx| {
                                    // Deterministic glyph mask derived from character code
                                    const bit = ((@as(u32, ch) >> @intCast((dy + dx) % 7)) & 1) == 1 or (dy == 0 or dy == 4);
                                    if (bit) {
                                        const px = gx0 + @as(i32, @intCast(dx));
                                        const py = gy0 + @as(i32, @intCast(dy));
                                        self.blendPixelClipped(px, py, active_clip, r, g, b, a);
                                    }
                                }
                            }
                        }
                        cursor_x += 4.0;
                    }
                },
                .clip_rect => |cr| {
                    clip_depth = 0;
                    if (cr) |r| {
                        const cb = self.toClipBounds(r);
                        clip_stack[0] = cb;
                        clip_depth = 1;
                        active_clip = cb;
                    } else {
                        active_clip = full_clip;
                    }
                },
                .clip_push => |r| {
                    const cb = self.toClipBounds(r);
                    const next = active_clip.intersect(cb);
                    if (clip_depth < clip_stack.len) {
                        clip_stack[clip_depth] = next;
                        clip_depth += 1;
                    }
                    active_clip = next;
                },
                .clip_pop => {
                    if (clip_depth > 0) clip_depth -= 1;
                    active_clip = if (clip_depth > 0) clip_stack[clip_depth - 1] else full_clip;
                },
            }
        }
    }

    /// Returns the RGBA8 pixel value at `(x, y)`, or `null` if out of bounds.
    pub fn readPixel(self: *const CaptureService, x: u32, y: u32) ?[4]u8 {
        if (x >= self.width or y >= self.height) return null;
        const idx = (@as(usize, y) * @as(usize, self.width) + @as(usize, x)) * 4;
        return .{
            self.pixels[idx],
            self.pixels[idx + 1],
            self.pixels[idx + 2],
            self.pixels[idx + 3],
        };
    }

    /// Computes a deterministic 64-bit hash of the entire framebuffer for golden comparisons.
    pub fn computeHash(self: *const CaptureService) u64 {
        return std.hash.Wyhash.hash(0, self.pixels);
    }

    /// Encodes the framebuffer as a binary PPM (P6) image buffer owned by `allocator`.
    pub fn encodePpm(self: *const CaptureService, allocator: std.mem.Allocator) ![]u8 {
        const header = try std.fmt.allocPrint(allocator, "P6\n{d} {d}\n255\n", .{ self.width, self.height });
        defer allocator.free(header);

        const rgb_len = @as(usize, self.width) * @as(usize, self.height) * 3;
        const out = try allocator.alloc(u8, header.len + rgb_len);
        @memcpy(out[0..header.len], header);

        var dst: usize = header.len;
        var src: usize = 0;
        while (src < self.pixels.len) : (src += 4) {
            out[dst] = self.pixels[src];
            out[dst + 1] = self.pixels[src + 1];
            out[dst + 2] = self.pixels[src + 2];
            dst += 3;
        }
        return out;
    }
};
