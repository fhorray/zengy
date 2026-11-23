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

    fn setPixel(self: *CaptureService, x: u32, y: u32, r: u8, g: u8, b: u8, a: u8) void {
        if (x >= self.width or y >= self.height) return;
        const idx = (@as(usize, y) * @as(usize, self.width) + @as(usize, x)) * 4;
        self.pixels[idx] = r;
        self.pixels[idx + 1] = g;
        self.pixels[idx + 2] = b;
        self.pixels[idx + 3] = a;
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
                    const r = floatToU8(rc.color.r);
                    const g = floatToU8(rc.color.g);
                    const b = floatToU8(rc.color.b);
                    const a = floatToU8(rc.color.a);

                    const x0: u32 = @intFromFloat(@max(@as(f32, 0), rc.x));
                    const y0: u32 = @intFromFloat(@max(@as(f32, 0), rc.y));
                    const x1: u32 = @min(self.width, @as(u32, @intFromFloat(@max(@as(f32, 0), rc.x + rc.width))));
                    const y1: u32 = @min(self.height, @as(u32, @intFromFloat(@max(@as(f32, 0), rc.y + rc.height))));

                    var py = y0;
                    while (py < y1) : (py += 1) {
                        var px = x0;
                        while (px < x1) : (px += 1) {
                            self.setPixel(px, py, r, g, b, a);
                        }
                    }
                },
                .text => {},
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
