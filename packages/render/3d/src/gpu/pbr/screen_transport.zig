//! Optional material-aware screen-space transport (SSR + SSGI). Resources exist only while a view uses it.
//!
//! The lit pass writes surface/diffuse/specular metadata next to the HDR colour; a Hi-Z min/max pyramid of the
//! depth buffer lives in one storage buffer, and a fullscreen pass ray-marches it to replace indirect lighting.
const std = @import("std");

/// Uniform block of `screen_transport_fs.wgsl` (`ScreenParams`).
pub const Params = extern struct {
    view_proj: [16]f32,
    inv_view_proj: [16]f32,
    camera_gain: [4]f32,
    controls: [4]f32,
    levels: [16][4]u32,
    budget: [4]u32,
};

/// Uniform block of `hiz_reduce_cs.wgsl` (`ReduceParams`).
pub const ReduceParams = extern struct { src: [4]u32, dst: [4]u32 };

comptime {
    if (@sizeOf(Params) != 432 or @sizeOf(ReduceParams) != 32) @compileError("Screen transport ABI mismatch");
}

/// Memory layout of the Hi-Z pyramid inside the bounds buffer: level 0 is full resolution, each next level halves
/// (rounding up) until 1x1. Entries are `vec2<f32>` (min, max depth).
pub const Layout = struct {
    /// Per level: offset in texels, width, height, unused.
    levels: [16][4]u32 = @splat(.{ 0, 0, 0, 0 }),
    count: u32 = 0,
    bytes: u32 = 0,

    pub fn init(width: u32, height: u32) !Layout {
        if (width == 0 or height == 0 or width > 16384 or height > 16384) return error.InvalidScreenDimensions;
        var result: Layout = .{};
        var w = width;
        var h = height;
        var offset: u64 = 0;
        while (true) {
            if (result.count >= 16) return error.InvalidScreenDimensions;
            result.levels[result.count] = .{ @intCast(offset), w, h, 0 };
            result.count += 1;
            offset += @as(u64, w) * h;
            if (offset * 8 > 128 * 1024 * 1024) return error.ScreenBufferTooLarge;
            if (w == 1 and h == 1) break;
            w = (w + 1) / 2;
            h = (h + 1) / 2;
        }
        result.bytes = @intCast(offset * 8);
        return result;
    }

    /// Reduce parameters for pyramid level `index`: level 0 reads the depth texture, others the previous level.
    pub fn reduceParams(self: *const Layout, index: usize) ReduceParams {
        var src = if (index == 0) self.levels[0] else self.levels[index - 1];
        src[3] = if (index == 0) 1 else 0;
        return .{ .src = src, .dst = self.levels[index] };
    }
};

test "pyramid halves with ceiling until 1x1" {
    const layout = try Layout.init(5, 3);
    try std.testing.expectEqual(@as(u32, 4), layout.count); // 5x3, 3x2, 2x1, 1x1
    try std.testing.expectEqual(@as(u32, 3), layout.levels[1][1]);
    try std.testing.expectEqual(@as(u32, 2), layout.levels[1][2]);
    try std.testing.expectEqual(@as(u32, 1), layout.levels[3][1]);
    try std.testing.expectEqual(@as(u32, (15 + 6 + 2 + 1) * 8), layout.bytes);
}

test "invalid sizes are rejected" {
    try std.testing.expectError(error.InvalidScreenDimensions, Layout.init(0, 10));
    try std.testing.expectError(error.InvalidScreenDimensions, Layout.init(20000, 10));
}
