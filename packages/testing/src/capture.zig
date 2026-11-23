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

    /// Rasterizes a slice of `graphics.DrawCommand`s into the offscreen RGBA8 buffer.
    pub fn rasterize(self: *CaptureService, cmds: []const graphics.DrawCommand) void {
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

                    const fw: f32 = @floatFromInt(self.width);
                    const fh: f32 = @floatFromInt(self.height);
                    const cx0 = @max(@as(f32, 0.0), @min(fw, rc.x));
                    const cy0 = @max(@as(f32, 0.0), @min(fh, rc.y));
                    const cx1 = @max(@as(f32, 0.0), @min(fw, rc.x + rc.width));
                    const cy1 = @max(@as(f32, 0.0), @min(fh, rc.y + rc.height));

                    const x0: u32 = @intFromFloat(cx0);
                    const y0: u32 = @intFromFloat(cy0);
                    const x1: u32 = @intFromFloat(cx1);
                    const y1: u32 = @intFromFloat(cy1);

                    if (a == 255) {
                        var py = y0;
                        while (py < y1) : (py += 1) {
                            const row_base = @as(usize, py) * @as(usize, self.width);
                            var px = x0;
                            while (px < x1) : (px += 1) {
                                const idx = (row_base + @as(usize, px)) * 4;
                                self.pixels[idx] = r;
                                self.pixels[idx + 1] = g;
                                self.pixels[idx + 2] = b;
                                self.pixels[idx + 3] = 255;
                            }
                        }
                    } else if (a > 0) {
                        var py = y0;
                        while (py < y1) : (py += 1) {
                            var px = x0;
                            while (px < x1) : (px += 1) {
                                self.blendPixel(px, py, r, g, b, a);
                            }
                        }
                    }
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
                                        if (px >= 0 and py >= 0) {
                                            self.blendPixel(@intCast(px), @intCast(py), r, g, b, a);
                                        }
                                    }
                                }
                            }
                        }
                        cursor_x += 4.0;
                    }
                },
                .clip_rect => {},
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
