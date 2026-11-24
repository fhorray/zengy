//! Color Picker Ecosystem: Swatch, Slider, Plane, Wheel, Recent Grid & ColorInput (`official.ui.plume`).

const std = @import("std");
const graphics = @import("graphics");
const ui_core = @import("ui_core");
const ui_widgets = @import("ui_widgets");
const theme = @import("../theme.zig");
const rounded = @import("../rounded_corners.zig");

const color_math = ui_widgets.color;

/// Color space tabs supported by `ColorInput`.
pub const ColorInputMode = enum {
    wheel,
    rgb,
    hsl,
};

/// Persistent user preferences for `ColorInput` (sticky mode + 24 recent colors).
pub const ColorInputSettings = struct {
    mode: ColorInputMode = .wheel,
    recent_colors: [24]?graphics.Color = @splat(null),

    /// Pushes `col` to the front of `recent_colors` without duplicates.
    pub fn pushRecent(self: *ColorInputSettings, col: graphics.Color) void {
        var found: ?usize = null;
        for (self.recent_colors, 0..) |maybe_c, i| {
            if (maybe_c) |c| {
                if (@abs(c.r - col.r) < 0.005 and @abs(c.g - col.g) < 0.005 and
                    @abs(c.b - col.b) < 0.005 and @abs(c.a - col.a) < 0.005)
                {
                    found = i;
                    break;
                }
            }
        }
        const limit = found orelse (self.recent_colors.len - 1);
        var i = limit;
        while (i > 0) : (i -= 1) {
            self.recent_colors[i] = self.recent_colors[i - 1];
        }
        self.recent_colors[0] = col;
    }
};

/// Channel types for `colorSlider`.
pub const ColorChannel = enum {
    red,
    green,
    blue,
    hsl_hue,
    hsl_saturation,
    hsl_lightness,
    alpha,
};

/// Visual handles for a `colorSwatch` (checkerboard underlay + tinted overlay).
pub const ColorSwatchHandles = struct {
    root: ui_core.UiNodeId,
    fill: ui_core.UiNodeId,
};

/// Creates a rounded color swatch preview over an alpha checkerboard.
pub fn colorSwatch(
    tree: *ui_core.UiTree,
    parent: ?usize,
    th: *const theme.UiTheme,
    col: graphics.Color,
    width_px: f32,
    height_px: f32,
) !ColorSwatchHandles {
    const root_idx = try tree.createNode(parent, .{
        .id = "",
        .kind = .custom,
        .style = .{
            .width = width_px,
            .height = height_px,
            .min_height = height_px,
            .padding = 0,
            .clip_children = true,
            .border_color = th.color(.field_border, .higher),
            .border_widths = .{ 1, 1, 1, 1 },
            .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.corner_radius),
        },
        .paint_extra = .{
            .gradient = .{
                .kind = .checkerboard,
                .stops = .{
                    .{ .r = 0.28, .g = 0.28, .b = 0.30, .a = 1 },
                    .{ .r = 0.48, .g = 0.48, .b = 0.50, .a = 1 },
                    .{ .r = 0, .g = 0, .b = 0, .a = 1 },
                    .{ .r = 0, .g = 0, .b = 0, .a = 1 },
                },
            },
        },
    });

    const fill_idx = try tree.createNode(root_idx, .{
        .id = "",
        .kind = .custom,
        .style = .{
            .position = .absolute,
            .left = 0,
            .top = 0,
            .width = width_px,
            .height = height_px,
            .min_height = height_px,
            .padding = 0,
            .bg_color = col,
        },
    });

    return .{
        .root = tree.idOf(root_idx).?,
        .fill = tree.idOf(fill_idx).?,
    };
}

/// Visual handles for a `colorSlider`.
pub const ColorSliderHandles = struct {
    root: ui_core.UiNodeId,
    thumb: ui_core.UiNodeId,
    channel: ColorChannel,
};

/// Creates a gradient color channel slider with a circular thumb.
pub fn colorSlider(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    parent: ?usize,
    channel: ColorChannel,
    base_color: graphics.Color,
    value: f64,
    tag: []const u8,
) !ColorSliderHandles {
    const max_val: f64 = if (channel == .hsl_hue) 360.0 else 1.0;
    const h: f32 = 16.0;
    const root_idx = try tree.createNode(parent, .{
        .id = "",
        .kind = .custom,
        .focusable = true,
        .cursor = .ew_resize,
        .style = .{
            .width_spec = .{ .grow = 1.0 },
            .height = h,
            .min_height = h,
            .padding = 0,
            .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.corner_radius),
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
        .paint_extra = makeChannelGradient(channel, base_color),
    });

    const thumb_idx = try tree.createNode(root_idx, .{
        .id = "",
        .kind = .custom,
        .pickable = false,
        .style = .{
            .position = .absolute,
            .left = 0,
            .top = 1,
            .width = 14,
            .height = 14,
            .min_height = 14,
            .padding = 0,
            .bg_color = base_color,
            .border_color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
            .border_widths = .{ 2, 2, 2, 2 },
            .corner_radii = rounded.RoundedCorners.all.toRadii(7.0),
        },
    });

    const root_id = tree.idOf(root_idx).?;
    const thumb_id = tree.idOf(thumb_idx).?;
    _ = try mgr.attach(root_id, tag, .{
        .slider = .{
            .value = value,
            .range = .{ .min = 0, .max = max_val },
            .thumb_node = thumb_id,
        },
    });

    return .{ .root = root_id, .thumb = thumb_id, .channel = channel };
}

fn makeChannelGradient(channel: ColorChannel, base: graphics.Color) ui_core.PaintExtra {
    return switch (channel) {
        .red => .{ .gradient = .{ .kind = .linear_horizontal, .stops = .{ .{ .r = 0, .g = base.g, .b = base.b, .a = 1 }, .{ .r = 1, .g = base.g, .b = base.b, .a = 1 }, base, base } } },
        .green => .{ .gradient = .{ .kind = .linear_horizontal, .stops = .{ .{ .r = base.r, .g = 0, .b = base.b, .a = 1 }, .{ .r = base.r, .g = 1, .b = base.b, .a = 1 }, base, base } } },
        .blue => .{ .gradient = .{ .kind = .linear_horizontal, .stops = .{ .{ .r = base.r, .g = base.g, .b = 0, .a = 1 }, .{ .r = base.r, .g = base.g, .b = 1, .a = 1 }, base, base } } },
        .hsl_hue => .{ .gradient = .{ .kind = .hue_horizontal, .stops = .{ base, base, base, base } } },
        .hsl_saturation => blk: {
            const h = color_math.srgbaToHsla(base);
            const c0 = color_math.hslaToSrgba(.{ .h = h.h, .s = 0, .l = h.l, .a = 1 });
            const c1 = color_math.hslaToSrgba(.{ .h = h.h, .s = 1, .l = h.l, .a = 1 });
            break :blk .{ .gradient = .{ .kind = .linear_horizontal, .stops = .{ c0, c1, base, base } } };
        },
        .hsl_lightness => blk: {
            const h = color_math.srgbaToHsla(base);
            const c0 = graphics.Color{ .r = 0, .g = 0, .b = 0, .a = 1 };
            const cm = color_math.hslaToSrgba(.{ .h = h.h, .s = h.s, .l = 0.5, .a = 1 });
            const c1 = graphics.Color{ .r = 1, .g = 1, .b = 1, .a = 1 };
            break :blk .{ .gradient = .{ .kind = .linear_horizontal_3, .stops = .{ c0, cm, c1, base } } };
        },
        .alpha => .{
            .gradient = .{
                .kind = .linear_horizontal,
                .stops = .{
                    .{ .r = base.r, .g = base.g, .b = base.b, .a = 0 },
                    .{ .r = base.r, .g = base.g, .b = base.b, .a = 1 },
                    base,
                    base,
                },
            },
        },
    };
}

/// Synchronizes a `ColorSlider`'s thumb position and gradient stops.
pub fn syncColorSlider(tree: *ui_core.UiTree, mgr: *ui_widgets.WidgetManager, cs: ColorSliderHandles, base: graphics.Color) void {
    const b = mgr.findByNode(cs.root) orelse return;
    if (b.behavior != .slider) return;
    const sl = b.behavior.slider;
    const r_idx = tree.resolveId(cs.root) orelse return;
    const t_idx = tree.resolveId(cs.thumb) orelse return;

    tree.nodes.items[r_idx].paint_extra = makeChannelGradient(cs.channel, base);
    const span = @max(@as(f64, 1e-6), sl.range.max - sl.range.min);
    const frac: f32 = @floatCast(std.math.clamp((sl.value - sl.range.min) / span, 0.0, 1.0));
    const travel = @max(@as(f32, 0.0), tree.nodes.items[r_idx].layout.width - 14.0);
    tree.nodes.items[t_idx].style.left = frac * travel;
    tree.nodes.items[t_idx].style.bg_color = switch (cs.channel) {
        .hsl_hue => color_math.hslaToSrgba(.{ .h = @floatCast(sl.value), .s = 1.0, .l = 0.5, .a = 1.0 }),
        .alpha => base,
        else => color_math.withAlpha(base, 1.0),
    };
}

/// Creates a 2D bilinear `ColorPlane` (e.g., Red-Green with fixed Blue) with a 2D circle thumb and crosshair cursor.
pub fn colorPlane(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    parent: ?usize,
    height_px: f32,
    fixed_blue: f32,
    tag: []const u8,
) !ui_core.UiNodeId {
    const idx = try tree.createNode(parent, .{
        .id = "",
        .kind = .custom,
        .focusable = true,
        .cursor = .crosshair,
        .style = .{
            .height = height_px,
            .min_height = height_px,
            .padding = 0,
            .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.corner_radius),
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
        .paint_extra = .{
            .gradient = .{
                .kind = .bilinear,
                .stops = .{
                    .{ .r = 0, .g = 1, .b = fixed_blue, .a = 1 }, // TL
                    .{ .r = 1, .g = 1, .b = fixed_blue, .a = 1 }, // TR
                    .{ .r = 1, .g = 0, .b = fixed_blue, .a = 1 }, // BR
                    .{ .r = 0, .g = 0, .b = fixed_blue, .a = 1 }, // BL
                },
            },
        },
    });
    const thumb_idx = try tree.createNode(idx, .{
        .id = "",
        .kind = .custom,
        .pickable = false,
        .style = .{
            .position = .absolute,
            .left = 0,
            .top = 0,
            .width = 12,
            .height = 12,
            .min_height = 12,
            .padding = 0,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0.2 },
            .border_color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
            .border_widths = .{ 2, 2, 2, 2 },
            .corner_radii = rounded.RoundedCorners.all.toRadii(6.0),
        },
    });
    const nid = tree.idOf(idx).?;
    const tid = tree.idOf(thumb_idx).?;
    _ = try mgr.attach(nid, tag, .{ .color_plane = .{ .thumb_node = tid } });
    return nid;
}

/// Synchronizes a `ColorPlane`'s 2D thumb position and background gradient.
pub fn syncColorPlane(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    plane_id: ui_core.UiNodeId,
    x_val: f32,
    y_val: f32,
    fixed_blue: f32,
) void {
    const b = mgr.findByNode(plane_id) orelse return;
    if (b.behavior != .color_plane) return;
    const p_idx = tree.resolveId(plane_id) orelse return;
    b.behavior.color_plane.x_val = x_val;
    b.behavior.color_plane.y_val = y_val;
    tree.nodes.items[p_idx].paint_extra = .{
        .gradient = .{
            .kind = .bilinear,
            .stops = .{
                .{ .r = 0, .g = 1, .b = fixed_blue, .a = 1 },
                .{ .r = 1, .g = 1, .b = fixed_blue, .a = 1 },
                .{ .r = 1, .g = 0, .b = fixed_blue, .a = 1 },
                .{ .r = 0, .g = 0, .b = fixed_blue, .a = 1 },
            },
        },
    };
    const tid = b.behavior.color_plane.thumb_node orelse return;
    const t_idx = tree.resolveId(tid) orelse return;
    const pr = tree.nodes.items[p_idx].layout;
    if (pr.width > 12.0 and pr.height > 12.0) {
        tree.nodes.items[t_idx].style.left = std.math.clamp(x_val, 0.0, 1.0) * (pr.width - 12.0);
        tree.nodes.items[t_idx].style.top = (1.0 - std.math.clamp(y_val, 0.0, 1.0)) * (pr.height - 12.0);
    }
}

/// Creates the HWB `ColorWheel` widget (hue ring + inner HWB triangle).
pub fn colorWheel(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    parent: ?usize,
    size_px: f32,
    initial_color: graphics.Color,
    tag: []const u8,
) !ui_core.UiNodeId {
    const hwb = color_math.srgbaToHwba(initial_color);
    const idx = try tree.createNode(parent, .{
        .id = "",
        .kind = .custom,
        .focusable = true,
        .cursor = .pointer,
        .style = .{
            .width = size_px,
            .height = size_px,
            .min_height = size_px,
            .padding = 0,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
        .paint_extra = .{
            .color_wheel = .{
                .hue_deg = hwb.h,
                .ring_width = 12.0,
            },
        },
    });
    const nid = tree.idOf(idx).?;
    _ = try mgr.attach(nid, tag, .{
        .color_wheel = .{
            .hue_deg = hwb.h,
            .whiteness = hwb.w,
            .blackness = hwb.b,
            .ring_width = 12.0,
        },
    });
    return nid;
}

/// Handles for a `colorSwatchGrid` (root panel + 24 recent-color cell node IDs).
pub const ColorSwatchGridHandles = struct {
    root: usize,
    cells: [24]ui_core.UiNodeId,
};

/// Creates a 12x2 grid of 24 recent color swatch cells.
pub fn colorSwatchGrid(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *const theme.UiTheme,
    parent: ?usize,
    settings: *const ColorInputSettings,
    tag_prefix: []const u8,
) !ColorSwatchGridHandles {
    const grid = try tree.createNode(parent, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .column,
            .padding = 0,
            .gap = 3,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
    });

    var cells: [24]ui_core.UiNodeId = undefined;
    for (0..2) |row_i| {
        const row = try tree.createNode(grid, .{
            .id = "",
            .kind = .panel,
            .style = .{
                .direction = .row,
                .padding = 0,
                .gap = 3,
                .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            },
        });
        for (0..12) |col_i| {
            const slot = row_i * 12 + col_i;
            const maybe_col = settings.recent_colors[slot];
            const col = maybe_col orelse graphics.Color{ .r = 0.16, .g = 0.17, .b = 0.19, .a = 1.0 };
            const cell = try tree.createNode(row, .{
                .id = "",
                .kind = .button,
                .focusable = true,
                .cursor = if (maybe_col != null) .pointer else .default,
                .style = .{
                    .width = 16,
                    .height = 16,
                    .min_height = 16,
                    .padding = 0,
                    .bg_color = col,
                    .border_color = th.color(.field_border, .floating),
                    .border_widths = .{ 1, 1, 1, 1 },
                    .corner_radii = rounded.RoundedCorners.all.toRadii(2.0),
                },
            });
            const cell_id = tree.idOf(cell).?;
            cells[slot] = cell_id;
            _ = try mgr.attach(cell_id, tag_prefix, .{ .button = .{} });
        }
    }
    return .{ .root = grid, .cells = cells };
}

/// Handles for a compact `ColorInput` swatch trigger + full tabbed `Popover` picker.
pub const ColorInputHandles = struct {
    trigger: ui_core.UiNodeId,
    swatch_fill: ui_core.UiNodeId,
    popup: ui_core.UiNodeId,
    mode_tabs: @import("tooling.zig").TabStripHandles,
    wheel: ui_core.UiNodeId,
    plane: ui_core.UiNodeId,
    sliders: [4]ColorSliderHandles,
    channel_labels: [4]ui_core.UiNodeId,
    channel_nums: [4]ui_core.UiNodeId,
    preview_bar: ui_core.UiNodeId,
    swatch_cells: [24]ui_core.UiNodeId,
    settings: *ColorInputSettings,
    color: graphics.Color,
    mode: ColorInputMode = .wheel,
    was_open: bool = false,
};

/// Creates a compact color swatch button that opens a full tabbed Color Picker popover (`Wheel | RGB | HSL`).
pub fn colorInput(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *const theme.UiTheme,
    parent: ?usize,
    initial_color: graphics.Color,
    settings: *ColorInputSettings,
    tag: []const u8,
    level: theme.SurfaceLevel,
) !ColorInputHandles {
    const tooling = @import("tooling.zig");
    const inputs = @import("inputs.zig");

    const trig_idx = try tree.createNode(parent, .{
        .id = "",
        .kind = .panel,
        .focusable = true,
        .cursor = .pointer,
        .style = .{
            .direction = .row,
            .width = 56,
            .height = theme.Metrics.row_height,
            .min_height = theme.Metrics.row_height,
            .padding = 3,
            .gap = 4,
            .align_items = .center,
            .bg_color = th.color(.button_bg, level),
            .border_color = th.color(.field_border, level),
            .border_widths = .{ 1, 1, 1, 1 },
            .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.corner_radius),
        },
    });
    const sw = try colorSwatch(tree, trig_idx, th, initial_color, 30, 18);
    _ = try tree.createNode(trig_idx, .{
        .id = "",
        .kind = .custom,
        .pickable = false,
        .style = .{ .width = 12, .height = 12, .min_height = 12, .padding = 0, .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
        .paint_extra = .{ .icon = .{ .kind = .chevron_down, .size = 10, .color = th.color(.text_main, level) } },
    });

    const popup_idx = try tree.createNode(null, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .column,
            .position = .absolute,
            .layer = .overlay,
            .visible = false,
            .width = 256,
            .padding = 8,
            .gap = 6,
            .bg_color = th.color(.menu_bg, .floating),
            .border_color = th.color(.menu_border, .floating),
            .border_widths = .{ 1, 1, 1, 1 },
            .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.corner_radius),
        },
    });

    const active_tab: usize = switch (settings.mode) {
        .wheel => 0,
        .rgb => 1,
        .hsl => 2,
    };
    const mode_tabs = try tooling.tabStrip(tree, mgr, th, popup_idx, &.{ "Wheel", "RGB", "HSL" }, active_tab, tag, .floating);

    const wheel_id = try colorWheel(tree, mgr, popup_idx, 180, initial_color, tag);
    if (tree.resolveId(wheel_id)) |wi| {
        tree.nodes.items[wi].style.visible = (settings.mode == .wheel);
    }

    const plane_id = try colorPlane(tree, mgr, popup_idx, 180, initial_color.b, tag);
    if (tree.resolveId(plane_id)) |pi| {
        tree.nodes.items[pi].style.visible = (settings.mode != .wheel);
    }

    const hsla = color_math.srgbaToHsla(initial_color);
    const ch_names = [4][]const u8{ "H", "S", "L", "A" };
    const ch_kinds = [4]ColorChannel{ .hsl_hue, .hsl_saturation, .hsl_lightness, .alpha };
    const ch_vals = [4]f64{ hsla.h, hsla.s, hsla.l, initial_color.a };
    const num_vals = [4]f32{ hsla.h, hsla.s * 100.0, hsla.l * 100.0, initial_color.a * 255.0 };

    var sliders: [4]ColorSliderHandles = undefined;
    var ch_labels: [4]ui_core.UiNodeId = undefined;
    var ch_nums: [4]ui_core.UiNodeId = undefined;

    for (0..4) |ci| {
        const row = try tree.createNode(popup_idx, .{
            .id = "",
            .kind = .panel,
            .style = .{
                .direction = .row,
                .padding = 0,
                .gap = 6,
                .align_items = .center,
                .min_height = 20,
                .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            },
        });
        const lbl_idx = try tree.createNode(row, .{
            .id = "",
            .kind = .label,
            .text = ch_names[ci],
            .style = .{
                .width = 14,
                .padding = 0,
                .min_height = 16,
                .font_scale = theme.Metrics.font_small,
                .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .text_color = th.color(.text_dim, .floating),
            },
        });
        ch_labels[ci] = tree.idOf(lbl_idx).?;
        sliders[ci] = try colorSlider(tree, mgr, row, ch_kinds[ci], initial_color, ch_vals[ci], tag);
        ch_nums[ci] = try inputs.numberInput(tree, mgr, th, row, .{
            .value = .{ .f32 = num_vals[ci] },
            .precision = 1,
            .width_spec = .{ .px = 58 },
            .tag = tag,
            .level = .floating,
        });
    }

    const preview_idx = try tree.createNode(popup_idx, .{
        .id = "",
        .kind = .custom,
        .style = .{
            .height = 18,
            .min_height = 18,
            .padding = 0,
            .bg_color = initial_color,
            .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.corner_radius),
        },
    });

    const swatch_grid = try colorSwatchGrid(tree, mgr, th, popup_idx, settings, tag);

    const trig_id = tree.idOf(trig_idx).?;
    const popup_id = tree.idOf(popup_idx).?;
    _ = try mgr.attach(trig_id, tag, .{ .menu_trigger = .{ .popup_node = popup_id } });
    _ = try mgr.attach(popup_id, "", .{ .popover = .{ .anchor = trig_id } });

    return .{
        .trigger = trig_id,
        .swatch_fill = sw.fill,
        .popup = popup_id,
        .mode_tabs = mode_tabs,
        .wheel = wheel_id,
        .plane = plane_id,
        .sliders = sliders,
        .channel_labels = ch_labels,
        .channel_nums = ch_nums,
        .preview_bar = tree.idOf(preview_idx).?,
        .swatch_cells = swatch_grid.cells,
        .settings = settings,
        .color = initial_color,
        .mode = settings.mode,
        .was_open = false,
    };
}

/// Synchronizes a `ColorInput` popup (tab switching, sliders, numeric boxes, swatch & preview).
pub fn syncColorInput(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *const theme.UiTheme,
    ci: *ColorInputHandles,
) void {
    const tooling = @import("tooling.zig");
    for (mgr.eventsSlice()) |ev| {
        for (ci.mode_tabs.tab_buttons, 0..) |maybe_tb, ti| {
            if (maybe_tb) |tb| {
                if (std.meta.eql(ev.node, tb.node) and ev.payload == .activate) {
                    ci.mode = switch (ti) {
                        0 => .wheel,
                        1 => .rgb,
                        else => .hsl,
                    };
                    ci.settings.mode = ci.mode;
                    tooling.setActiveTab(tree, th, &ci.mode_tabs, ti);
                    if (tree.resolveId(ci.wheel)) |wi| tree.nodes.items[wi].style.visible = (ci.mode == .wheel);
                    if (tree.resolveId(ci.plane)) |pi| tree.nodes.items[pi].style.visible = (ci.mode != .wheel);
                }
            }
        }
        for (ci.swatch_cells, 0..) |cell_id, slot| {
            if (std.meta.eql(ev.node, cell_id) and ev.payload == .activate) {
                if (ci.settings.recent_colors[slot]) |saved| {
                    ci.color = saved;
                }
            }
        }
        if (std.meta.eql(ev.node, ci.wheel) and ev.payload == .value_color) {
            ci.color = color_math.withAlpha(ev.payload.value_color, ci.color.a);
        } else if (std.meta.eql(ev.node, ci.plane) and ev.payload == .value_vec2) {
            const v = ev.payload.value_vec2;
            if (ci.mode == .rgb) {
                ci.color.r = v[0];
                ci.color.g = v[1];
            } else {
                var hsla = color_math.srgbaToHsla(ci.color);
                hsla.h = v[0] * 360.0;
                hsla.s = v[1];
                ci.color = color_math.withAlpha(color_math.hslaToSrgba(hsla), ci.color.a);
            }
        }
        for (ci.channel_nums, 0..) |cn_id, ni_idx| {
            if (std.meta.eql(ev.node, cn_id) and ev.payload == .value_numeric) {
                const fv: f32 = @floatCast(ev.payload.value_numeric.asF64());
                if (ci.mode == .rgb) {
                    const norm = std.math.clamp(fv / 255.0, 0.0, 1.0);
                    switch (ni_idx) {
                        0 => ci.color.r = norm,
                        1 => ci.color.g = norm,
                        2 => ci.color.b = norm,
                        else => ci.color.a = norm,
                    }
                } else {
                    var hsla = color_math.srgbaToHsla(ci.color);
                    switch (ni_idx) {
                        0 => hsla.h = std.math.clamp(fv, 0.0, 360.0),
                        1 => hsla.s = std.math.clamp(fv / 100.0, 0.0, 1.0),
                        2 => hsla.l = std.math.clamp(fv / 100.0, 0.0, 1.0),
                        else => ci.color.a = std.math.clamp(fv / 255.0, 0.0, 1.0),
                    }
                    if (ni_idx < 3) ci.color = color_math.withAlpha(color_math.hslaToSrgba(hsla), ci.color.a);
                }
            }
        }
        for (ci.sliders, 0..) |sl, si| {
            if (std.meta.eql(ev.node, sl.root) and ev.payload == .value_f64) {
                const v: f32 = @floatCast(ev.payload.value_f64);
                if (ci.mode == .rgb) {
                    switch (si) {
                        0 => ci.color.r = v,
                        1 => ci.color.g = v,
                        2 => ci.color.b = v,
                        else => ci.color.a = v,
                    }
                } else {
                    var hsla = color_math.srgbaToHsla(ci.color);
                    switch (si) {
                        0 => hsla.h = v,
                        1 => hsla.s = v,
                        2 => hsla.l = v,
                        else => ci.color.a = v,
                    }
                    if (si < 3) ci.color = color_math.withAlpha(color_math.hslaToSrgba(hsla), ci.color.a);
                }
            }
        }
    }

    const is_open = if (mgr.findByNode(ci.popup)) |pb|
        (pb.behavior == .popover and pb.behavior.popover.open)
    else
        false;
    if (ci.was_open and !is_open) {
        ci.settings.pushRecent(ci.color);
    }
    ci.was_open = is_open;

    for (ci.swatch_cells, 0..) |cell_id, slot| {
        if (tree.resolveId(cell_id)) |cell_idx| {
            const maybe_col = ci.settings.recent_colors[slot];
            tree.nodes.items[cell_idx].style.bg_color = maybe_col orelse graphics.Color{ .r = 0.16, .g = 0.17, .b = 0.19, .a = 1.0 };
            tree.nodes.items[cell_idx].cursor = if (maybe_col != null) .pointer else .default;
            const is_selected = if (maybe_col) |c|
                (@abs(c.r - ci.color.r) < 0.005 and @abs(c.g - ci.color.g) < 0.005 and
                    @abs(c.b - ci.color.b) < 0.005 and @abs(c.a - ci.color.a) < 0.005)
            else
                false;
            tree.nodes.items[cell_idx].style.border_color = if (tree.nodes.items[cell_idx].hovered and maybe_col != null)
                color_math.lighter(th.color(.field_border, .floating), 0.35)
            else if (is_selected)
                graphics.Color{ .r = 1, .g = 1, .b = 1, .a = 1 }
            else
                th.color(.field_border, .floating);
        }
    }

    if (tree.resolveId(ci.trigger)) |ti| {
        const hov = tree.nodes.items[ti].hovered;
        tree.nodes.items[ti].style.bg_color = th.color(if (hov) .button_bg_hover else .button_bg, .base);
        tree.nodes.items[ti].style.border_color = if (hov)
            color_math.lighter(th.color(.field_border, .base), 0.25)
        else
            th.color(.field_border, .base);
    }
    if (tree.resolveId(ci.swatch_fill)) |sfi| tree.nodes.items[sfi].style.bg_color = ci.color;
    if (tree.resolveId(ci.preview_bar)) |pbi| tree.nodes.items[pbi].style.bg_color = ci.color;

    const hsla = color_math.srgbaToHsla(ci.color);
    if (ci.mode == .rgb) {
        syncColorPlane(tree, mgr, ci.plane, ci.color.r, ci.color.g, ci.color.b);
    } else if (ci.mode == .hsl) {
        syncColorPlane(tree, mgr, ci.plane, hsla.h / 360.0, hsla.s, 0.5);
    }
    const lbls = if (ci.mode == .rgb) [4][]const u8{ "R", "G", "B", "A" } else [4][]const u8{ "H", "S", "L", "A" };
    const kinds = if (ci.mode == .rgb)
        [4]ColorChannel{ .red, .green, .blue, .alpha }
    else
        [4]ColorChannel{ .hsl_hue, .hsl_saturation, .hsl_lightness, .alpha };
    const sl_vals = if (ci.mode == .rgb)
        [4]f64{ ci.color.r, ci.color.g, ci.color.b, ci.color.a }
    else
        [4]f64{ hsla.h, hsla.s, hsla.l, ci.color.a };
    const num_vals = if (ci.mode == .rgb)
        [4]f32{ ci.color.r * 255.0, ci.color.g * 255.0, ci.color.b * 255.0, ci.color.a * 255.0 }
    else
        [4]f32{ hsla.h, hsla.s * 100.0, hsla.l * 100.0, ci.color.a * 255.0 };

    for (0..4) |si| {
        if (tree.resolveId(ci.channel_labels[si])) |li| {
            if (!std.mem.eql(u8, tree.nodes.items[li].text, lbls[si])) {
                tree.setNodeText(li, lbls[si]) catch {};
            }
        }
        ci.sliders[si].channel = kinds[si];
        if (mgr.findByNode(ci.sliders[si].root)) |sb| {
            if (sb.behavior == .slider) {
                sb.behavior.slider.range.max = if (kinds[si] == .hsl_hue) 360.0 else 1.0;
                if (!sb.behavior.slider.dragging) sb.behavior.slider.value = sl_vals[si];
            }
        }
        syncColorSlider(tree, mgr, ci.sliders[si], ci.color);
        if (mgr.findByNode(ci.channel_nums[si])) |nb| {
            if (nb.behavior == .number_input and nb.behavior.number_input.mode == .idle) {
                nb.behavior.number_input.value = .{ .f32 = num_vals[si] };
            }
        }
    }
}
