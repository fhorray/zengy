//! Standard Plume Color Palette (`official.ui.plume`).

const graphics = @import("graphics");
const color = @import("ui_widgets").color;

pub const TRANSPARENT = graphics.Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
pub const BLACK = graphics.Color{ .r = 0, .g = 0, .b = 0, .a = 1 };
pub const WHITE = graphics.Color{ .r = 1, .g = 1, .b = 1, .a = 1 };

pub const GRAY_0 = color.oklch(0.2414, 0.0095, 285.67, 1.0);
pub const GRAY_1 = color.oklch(0.2866, 0.0072, 285.93, 1.0);
pub const GRAY_2 = color.oklch(0.3373, 0.0071, 274.77, 1.0);
pub const GRAY_3 = color.oklch(0.3992, 0.0101, 278.38, 1.0);
pub const WARM_GRAY_1 = color.oklch(0.3757, 0.0017, 286.32, 1.0);

pub const LIGHT_GRAY_1 = color.oklch(0.7607, 0.0014, 286.37, 1.0);
pub const LIGHT_GRAY_2 = color.oklch(0.6106, 0.0030, 286.31, 1.0);

pub const ACCENT = color.oklch(0.5420, 0.1594, 255.40, 1.0);
pub const X_AXIS = color.oklch(0.5232, 0.1404, 13.84, 1.0);
pub const Y_AXIS = color.oklch(0.5866, 0.1543, 129.84, 1.0);
pub const Z_AXIS = color.oklch(0.4847, 0.1249, 253.08, 1.0);
pub const W_AXIS = color.oklch(0.9000, 0.0100, 95.00, 1.0);
