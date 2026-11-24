//! Corner rounding helper for segmented buttons and containers (`official.ui.plume`).

/// Specifies which corners of a widget are rounded.
pub const RoundedCorners = enum {
    none,
    all,
    top_left,
    top_right,
    bottom_right,
    bottom_left,
    top,
    right,
    bottom,
    left,

    /// Converts `RoundedCorners` into `[top_left, top_right, bottom_right, bottom_left]` radii.
    pub fn toRadii(self: RoundedCorners, radius: f32) [4]f32 {
        return switch (self) {
            .none => .{ 0, 0, 0, 0 },
            .all => .{ radius, radius, radius, radius },
            .top_left => .{ radius, 0, 0, 0 },
            .top_right => .{ 0, radius, 0, 0 },
            .bottom_right => .{ 0, 0, radius, 0 },
            .bottom_left => .{ 0, 0, 0, radius },
            .top => .{ radius, radius, 0, 0 },
            .right => .{ 0, radius, radius, 0 },
            .bottom => .{ 0, 0, radius, radius },
            .left => .{ radius, 0, 0, radius },
        };
    }
};
