//! Backend-neutral 2D draw command vocabulary shared by UI, 2D renderers and providers.
//!
//! Kept free of any engine or backend import so renderers and tests can use it on its own.

/// RGBA color in linear or sRGB [0..1] component space.
pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32 = 1.0,
};

/// Logical rectangle used for clipping and UI drawing commands.
pub const ClipRect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

/// Gradient fill modes supported by `DrawCommand.gradient_rect`.
pub const GradientKind = enum {
    /// Horizontal 2-stop gradient (stops[0] left -> stops[1] right).
    linear_horizontal,
    /// Vertical 2-stop gradient (stops[0] top -> stops[1] bottom).
    linear_vertical,
    /// Horizontal 3-stop gradient (stops[0] left -> stops[1] mid -> stops[2] right).
    linear_horizontal_3,
    /// Bilinear 4-corner gradient (tl, tr, br, bl).
    bilinear,
    /// Full 0..360 degree HSL hue rainbow strip.
    hue_horizontal,
    /// Alpha transparency checkerboard pattern (uses stops[0] and stops[1]).
    checkerboard,
};

/// Geometric Lucide-style vector icon shapes rendered without external image assets.
pub const IconKind = enum {
    check,
    chevron_down,
    chevron_left,
    chevron_right,
    chevron_up,
    close_x,
    grip_vertical,
    color_wheel,
    plus,
    minus,
    search,
    settings,
    eye,
    eye_off,
    droplet,
    opacity,
    corner_radius,
    maximize_2,
    grid_2x2,
    sliders_horizontal,
    align_left,
    align_center,
    align_right,
    align_justify,
    align_top,
    align_middle,
    align_bottom,
    underline,
    strikethrough,
    list_bullet,
    list_ordered,
    trash_2,
    copy,
    folder,
    file,
    play,
    pause,
    refresh_cw,
    help_circle,
    info,
    alert_triangle,
    check_circle,
};

/// Backend-neutral 2D draw command emitted by UI and 2D renderers.
pub const DrawCommand = union(enum) {
    clear: Color,
    rect: struct {
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        color: Color,
    },
    rounded_rect: struct {
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        color: Color,
        border_color: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        /// Border thicknesses in logical pixels: top, right, bottom, left.
        border_widths: [4]f32 = .{ 0, 0, 0, 0 },
        /// Corner radii in logical pixels: top_left, top_right, bottom_right, bottom_left.
        corner_radii: [4]f32 = .{ 0, 0, 0, 0 },
    },
    gradient_rect: struct {
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        kind: GradientKind,
        stops: [4]Color = .{
            .{ .r = 0, .g = 0, .b = 0, .a = 1 },
            .{ .r = 1, .g = 1, .b = 1, .a = 1 },
            .{ .r = 1, .g = 1, .b = 1, .a = 1 },
            .{ .r = 0, .g = 0, .b = 0, .a = 1 },
        },
        corner_radii: [4]f32 = .{ 0, 0, 0, 0 },
    },
    color_wheel: struct {
        x: f32,
        y: f32,
        size: f32,
        hue_deg: f32,
        ring_width: f32 = 12.0,
        bg_color: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    },
    icon: struct {
        x: f32,
        y: f32,
        size: f32,
        kind: IconKind,
        color: Color,
    },
    text: struct {
        x: f32,
        y: f32,
        content: []const u8,
        color: Color,
        /// Bitmap glyph scale factor (1.0 = 8px, 2.0 = 16px).
        scale: f32 = 2.0,
        /// Optional horizontal alignment within `box_width` when > 0.
        align_mode: enum { left, center, right } = .left,
        box_width: f32 = 0.0,
    },
    clip_rect: ?ClipRect,
    clip_push: ClipRect,
    clip_pop: void,
};
