//! TextInput, Slider, NumberInput & Vec3Input Controls (`official.ui.plume`).

const std = @import("std");
const ui_core = @import("ui_core");
const ui_widgets = @import("ui_widgets");
const theme = @import("../theme.zig");
const tokens = @import("../tokens.zig");
const rounded = @import("../rounded_corners.zig");

/// Configuration properties for `textInput`.
pub const TextInputProps = struct {
    text: []const u8 = "",
    max_len: usize = 256,
    disabled: bool = false,
    width_spec: ?ui_core.SizeSpec = null,
    tag: []const u8 = "",
    level: theme.SurfaceLevel = .higher,
};

/// Creates a themed single-line text input box.
pub fn textInput(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *const theme.UiTheme,
    parent: ?usize,
    props: TextInputProps,
) !ui_core.UiNodeId {
    const idx = try tree.createNode(parent, .{
        .id = "",
        .kind = .textbox,
        .text = props.text,
        .focusable = true,
        .disabled = props.disabled,
        .cursor = .text,
        .style = .{
            .width_spec = props.width_spec,
            .min_height = theme.Metrics.row_height,
            .padding_edges = ui_core.Edges.xy(8, 4),
            .font_scale = theme.Metrics.font_compact,
            .bg_color = th.color(.field_bg, props.level),
            .text_color = th.color(.field_text, props.level),
            .border_color = th.color(.field_border, props.level),
            .border_widths = .{ 1, 1, 1, 1 },
            .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.corner_radius),
        },
    });
    const nid = tree.idOf(idx).?;
    _ = try mgr.attach(nid, props.tag, .{
        .text_input = .{ .max_len = props.max_len },
    });
    return nid;
}

/// Configuration properties for `slider`.
pub const SliderProps = struct {
    value: f64 = 0.0,
    min: f64 = 0.0,
    max: f64 = 100.0,
    step: f64 = 0.0,
    precision: u8 = 2,
    disabled: bool = false,
    auto_update: bool = true,
    tag: []const u8 = "",
    level: theme.SurfaceLevel = .higher,
};

/// Visual handles for a `PlumeSlider`.
pub const SliderVisualMeta = struct {
    root: ui_core.UiNodeId,
    fill_bar: ui_core.UiNodeId,
    label: ui_core.UiNodeId,
    precision: u8,
    level: theme.SurfaceLevel,
};

/// Creates a horizontal slider with filled progress bar and centered mono value label.
pub fn slider(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *const theme.UiTheme,
    parent: ?usize,
    props: SliderProps,
) !SliderVisualMeta {
    const root_idx = try tree.createNode(parent, .{
        .id = "",
        .kind = .custom,
        .focusable = true,
        .disabled = props.disabled,
        .cursor = .ew_resize,
        .style = .{
            .min_height = theme.Metrics.row_height,
            .padding = 0,
            .clip_children = true,
            .bg_color = th.color(.slider_bg, props.level),
            .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.slider_radius),
        },
    });

    const span = @max(@as(f64, 1e-6), props.max - props.min);
    const frac: f32 = @floatCast(std.math.clamp((props.value - props.min) / span, 0.0, 1.0));

    const fill_idx = try tree.createNode(root_idx, .{
        .id = "",
        .kind = .custom,
        .pickable = false,
        .style = .{
            .position = .absolute,
            .left = 0,
            .top = 0,
            .width_spec = .{ .percent = frac * 100.0 },
            .height = theme.Metrics.row_height,
            .min_height = theme.Metrics.row_height,
            .padding = 0,
            .corner_radii = rounded.RoundedCorners.left.toRadii(theme.Metrics.slider_radius),
            .bg_color = th.color(.slider_bar, props.level),
        },
    });

    var buf: [32]u8 = undefined;
    const val_str = std.fmt.bufPrint(&buf, "{d:.2}", .{props.value}) catch "0.00";

    const lbl_idx = try tree.createNode(root_idx, .{
        .id = "",
        .kind = .label,
        .pickable = false,
        .text = val_str,
        .style = .{
            .position = .absolute,
            .left = 0,
            .top = 0,
            .width_spec = .{ .percent = 100.0 },
            .height = theme.Metrics.row_height,
            .min_height = theme.Metrics.row_height,
            .padding = 0,
            .text_align = .center,
            .font_scale = theme.Metrics.font_small,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .text_color = th.color(.slider_text, props.level),
        },
    });

    const root_id = tree.idOf(root_idx).?;
    _ = try mgr.attach(root_id, props.tag, .{
        .slider = .{
            .value = props.value,
            .range = .{ .min = props.min, .max = props.max },
            .step = props.step,
            .auto_update = props.auto_update,
        },
    });

    return .{
        .root = root_id,
        .fill_bar = tree.idOf(fill_idx).?,
        .label = tree.idOf(lbl_idx).?,
        .precision = props.precision,
        .level = props.level,
    };
}

/// Synchronizes slider fill width and formatted label text with `WidgetManager` state.
pub fn syncSlider(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *const theme.UiTheme,
    meta: SliderVisualMeta,
) void {
    const b = mgr.findByNode(meta.root) orelse return;
    if (b.behavior != .slider) return;
    const sl = b.behavior.slider;
    const r_idx = tree.resolveId(meta.root) orelse return;
    const f_idx = tree.resolveId(meta.fill_bar) orelse return;
    const l_idx = tree.resolveId(meta.label) orelse return;

    const span = @max(@as(f64, 1e-6), sl.range.max - sl.range.min);
    const frac: f32 = @floatCast(std.math.clamp((sl.value - sl.range.min) / span, 0.0, 1.0));
    tree.nodes.items[f_idx].style.width_spec = .{ .percent = frac * 100.0 };

    const active = tree.nodes.items[r_idx].hovered or sl.dragging;
    tree.nodes.items[r_idx].style.bg_color = th.color(if (active) .slider_bg_hover else .slider_bg, meta.level);
    tree.nodes.items[f_idx].style.bg_color = th.color(if (active) .slider_bar_hover else .slider_bar, meta.level);

    var buf: [32]u8 = undefined;
    const txt = std.fmt.bufPrint(&buf, "{d:.2}", .{sl.value}) catch "0.00";
    tree.setNodeText(l_idx, txt) catch {};
}

/// Configuration properties for `numberInput`.
pub const NumberInputProps = struct {
    value: ui_widgets.events.NumericValue = .{ .f32 = 0.0 },
    min: f64 = -std.math.inf(f64),
    max: f64 = std.math.inf(f64),
    step: f64 = 0.05,
    precision: u8 = 3,
    sigil_color: ?tokens.ThemeToken = null,
    axis_label: []const u8 = "",
    width_spec: ?ui_core.SizeSpec = null,
    tag: []const u8 = "",
    level: theme.SurfaceLevel = .highest,
};

/// Creates a numeric input field supporting drag-scrubbing and click-to-edit.
pub fn numberInput(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *const theme.UiTheme,
    parent: ?usize,
    props: NumberInputProps,
) !ui_core.UiNodeId {
    const row_idx = try tree.createNode(parent, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .row,
            .width_spec = props.width_spec,
            .min_height = theme.Metrics.row_height,
            .padding = 1,
            .gap = 0,
            .clip_children = true,
            .bg_color = th.color(.field_bg, props.level),
            .border_color = th.color(.field_border, props.level),
            .border_widths = .{ 1, 1, 1, 1 },
            .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.corner_radius),
        },
    });

    if (props.sigil_color) |sig_tok| {
        _ = try tree.createNode(row_idx, .{
            .id = "",
            .kind = .panel,
            .style = .{
                .width = 4,
                .height = theme.Metrics.row_height - 2,
                .min_height = theme.Metrics.row_height - 2,
                .padding = 0,
                .bg_color = th.color(sig_tok, props.level),
            },
        });
    }

    if (props.axis_label.len > 0) {
        _ = try tree.createNode(row_idx, .{
            .id = "",
            .kind = .label,
            .text = props.axis_label,
            .style = .{
                .width = 20,
                .height = theme.Metrics.row_height - 2,
                .min_height = theme.Metrics.row_height - 2,
                .padding_edges = ui_core.Edges.xy(4, 3),
                .text_align = .center,
                .font_scale = theme.Metrics.font_small,
                .bg_color = th.color(.button_bg, props.level),
                .text_color = th.color(.text_main, props.level),
            },
        });
    }

    var buf: [32]u8 = undefined;
    const val_str = formatNumeric(props.value, props.precision, &buf);

    const val_idx = try tree.createNode(row_idx, .{
        .id = "",
        .kind = .custom,
        .text = val_str,
        .focusable = true,
        .cursor = .ew_resize,
        .style = .{
            .width_spec = .{ .grow = 1.0 },
            .min_height = theme.Metrics.row_height - 2,
            .padding_edges = ui_core.Edges.xy(14, 3),
            .text_align = .center,
            .font_scale = theme.Metrics.font_compact,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .text_color = th.color(.field_text, props.level),
        },
    });

    const val_id = tree.idOf(val_idx).?;

    // Hover stepper buttons ('<' and '>') with pointer cursor.
    const dec_idx = try tree.createNode(val_idx, .{
        .id = "",
        .kind = .custom,
        .cursor = .pointer,
        .style = .{
            .position = .absolute,
            .left = 2,
            .top = 5,
            .width = 14,
            .height = 14,
            .min_height = 14,
            .padding = 0,
            .visible = false,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
        .paint_extra = .{
            .icon = .{
                .kind = .chevron_left,
                .size = 10,
                .color = th.color(.text_dim, props.level),
            },
        },
    });
    const inc_idx = try tree.createNode(val_idx, .{
        .id = "",
        .kind = .custom,
        .cursor = .pointer,
        .style = .{
            .position = .absolute,
            .right = 2,
            .top = 5,
            .width = 14,
            .height = 14,
            .min_height = 14,
            .padding = 0,
            .visible = false,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
        .paint_extra = .{
            .icon = .{
                .kind = .chevron_right,
                .size = 10,
                .color = th.color(.text_dim, props.level),
            },
        },
    });

    _ = try mgr.attach(val_id, props.tag, .{
        .number_input = .{
            .value = props.value,
            .range = .{ .min = props.min, .max = props.max },
            .step = props.step,
            .precision = props.precision,
        },
    });
    _ = try mgr.attach(tree.idOf(dec_idx).?, "", .{ .number_stepper = .{ .target_input = val_id, .dir = -1 } });
    _ = try mgr.attach(tree.idOf(inc_idx).?, "", .{ .number_stepper = .{ .target_input = val_id, .dir = 1 } });
    return val_id;
}

/// Synchronizes a `TextInput` hover and focus border highlight.
pub fn syncTextInput(tree: *ui_core.UiTree, th: *const theme.UiTheme, node_id: ui_core.UiNodeId) void {
    const idx = tree.resolveId(node_id) orelse return;
    const n = &tree.nodes.items[idx];
    n.style.bg_color = th.color(if (n.hovered) .field_bg_hover else .field_bg, .higher);
    n.style.border_color = if (n.focused)
        th.color(.focus_ring, .higher)
    else if (n.hovered)
        ui_widgets.color.lighter(th.color(.field_border, .higher), 0.25)
    else
        th.color(.field_border, .higher);
}

/// Synchronizes a `NumberInput` display string and editing/hover highlight.
pub fn syncNumberInput(tree: *ui_core.UiTree, mgr: *ui_widgets.WidgetManager, node_id: ui_core.UiNodeId) void {
    const b = mgr.findByNode(node_id) orelse return;
    if (b.behavior != .number_input) return;
    const ni = b.behavior.number_input;
    const idx = tree.resolveId(node_id) orelse return;
    var any_child_hover = false;
    for (tree.nodes.items[idx].children.items) |c_idx| {
        if (c_idx < tree.nodes.items.len and tree.nodes.items[c_idx].hovered) {
            any_child_hover = true;
            break;
        }
    }
    const is_hovered = tree.nodes.items[idx].hovered or any_child_hover;
    const show_arrows = is_hovered and ni.mode == .idle;
    for (tree.nodes.items[idx].children.items) |c_idx| {
        if (c_idx < tree.nodes.items.len) {
            tree.nodes.items[c_idx].style.visible = show_arrows;
            if (tree.nodes.items[c_idx].paint_extra == .icon) {
                tree.nodes.items[c_idx].paint_extra.icon.color = if (tree.nodes.items[c_idx].hovered)
                    .{ .r = 0.95, .g = 0.95, .b = 0.97, .a = 1.0 }
                else
                    .{ .r = 0.55, .g = 0.56, .b = 0.58, .a = 1.0 };
            }
        }
    }
    if (tree.nodes.items[idx].parent) |p_idx| {
        if (p_idx < tree.nodes.items.len) {
            tree.nodes.items[p_idx].style.border_color = if (ni.mode == .editing)
                .{ .r = 0.13, .g = 0.43, .b = 0.79, .a = 1.0 }
            else if (is_hovered)
                .{ .r = 0.55, .g = 0.56, .b = 0.58, .a = 1.0 }
            else
                .{ .r = 0.37, .g = 0.37, .b = 0.38, .a = 1.0 };
            tree.nodes.items[p_idx].style.bg_color = if (is_hovered and ni.mode != .editing)
                .{ .r = 0.25, .g = 0.26, .b = 0.29, .a = 1.0 }
            else
                .{ .r = 0.21, .g = 0.22, .b = 0.24, .a = 1.0 };
        }
    }
    if (ni.mode == .editing) return;
    var buf: [32]u8 = undefined;
    const txt = formatNumeric(ni.value, ni.precision, &buf);
    if (!std.mem.eql(u8, tree.nodes.items[idx].text, txt)) {
        tree.setNodeText(idx, txt) catch {};
    }
}

fn formatNumeric(val: ui_widgets.events.NumericValue, precision: u8, buf: []u8) []const u8 {
    return switch (val) {
        .i32 => |v| std.fmt.bufPrint(buf, "{d}", .{v}) catch "0",
        .i64 => |v| std.fmt.bufPrint(buf, "{d}", .{v}) catch "0",
        .f32, .f64 => blk: {
            const f = val.asF64();
            if (@abs(f - @round(f)) < 1e-5) {
                break :blk std.fmt.bufPrint(buf, "{d}", .{@as(i64, @intFromFloat(@round(f)))}) catch "0";
            }
            if (precision <= 1) {
                break :blk std.fmt.bufPrint(buf, "{d:.1}", .{f}) catch "0";
            } else if (precision == 2) {
                break :blk std.fmt.bufPrint(buf, "{d:.2}", .{f}) catch "0";
            }
            break :blk std.fmt.bufPrint(buf, "{d:.3}", .{f}) catch "0";
        },
    };
}

/// Creates a 3-component `X / Y / Z` property row with color-coded axis sigils.
pub fn vec3Input(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *const theme.UiTheme,
    parent: ?usize,
    value: [3]f32,
    tag_x: []const u8,
    tag_y: []const u8,
    tag_z: []const u8,
    level: theme.SurfaceLevel,
) ![3]ui_core.UiNodeId {
    const row = try tree.createNode(parent, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .row,
            .padding = 0,
            .gap = 6,
            .min_height = theme.Metrics.row_height,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
    });
    const x_id = try numberInput(tree, mgr, th, row, .{
        .value = .{ .f32 = value[0] },
        .sigil_color = .axis_x,
        .axis_label = "X",
        .width_spec = .{ .grow = 1.0 },
        .tag = tag_x,
        .level = level,
    });
    const y_id = try numberInput(tree, mgr, th, row, .{
        .value = .{ .f32 = value[1] },
        .sigil_color = .axis_y,
        .axis_label = "Y",
        .width_spec = .{ .grow = 1.0 },
        .tag = tag_y,
        .level = level,
    });
    const z_id = try numberInput(tree, mgr, th, row, .{
        .value = .{ .f32 = value[2] },
        .sigil_color = .axis_z,
        .axis_label = "Z",
        .width_spec = .{ .grow = 1.0 },
        .tag = tag_z,
        .level = level,
    });
    return .{ x_id, y_id, z_id };
}

/// Creates a multiline `Textarea` with vertical scroll and `Enter` newline support.
pub fn textarea(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *const theme.UiTheme,
    parent: ?usize,
    initial_text: []const u8,
    height_px: f32,
    max_len: usize,
    tag: []const u8,
    level: theme.SurfaceLevel,
) !ui_core.UiNodeId {
    const idx = try tree.createNode(parent, .{
        .id = "",
        .kind = .textbox,
        .text = initial_text,
        .focusable = true,
        .scrollable = true,
        .cursor = .text,
        .style = .{
            .height = height_px,
            .min_height = height_px,
            .padding = 6,
            .text_align = .left,
            .font_scale = theme.Metrics.font_medium,
            .bg_color = th.color(.field_bg, level),
            .text_color = th.color(.field_text, level),
            .border_color = th.color(.field_border, level),
            .border_widths = .{ 1, 1, 1, 1 },
            .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.corner_radius),
        },
    });
    const nid = tree.idOf(idx).?;
    _ = try mgr.attach(nid, tag, .{
        .text_input = .{
            .max_len = max_len,
            .multiline = true,
        },
    });
    return nid;
}

/// Handles for a searchable `Combobox` (trigger button + search box + filtered option buttons).
pub const ComboboxHandles = struct {
    trigger: ui_core.UiNodeId,
    popup: ui_core.UiNodeId,
    search_input: ui_core.UiNodeId,
    option_nodes: [32]?ui_core.UiNodeId = @splat(null),
    option_count: usize = 0,
    selected_idx: usize = 0,
};

/// Creates a searchable `Combobox` (up to 32 options) with real-time case-insensitive filtering.
pub fn combobox(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *const theme.UiTheme,
    parent: ?usize,
    options: []const []const u8,
    selected_idx: usize,
    tag: []const u8,
    level: theme.SurfaceLevel,
) !ComboboxHandles {
    const initial = if (selected_idx < options.len) options[selected_idx] else "Select...";
    const trig_idx = try tree.createNode(parent, .{
        .id = "",
        .kind = .button,
        .text = initial,
        .focusable = true,
        .cursor = .pointer,
        .style = .{
            .min_height = theme.Metrics.row_height,
            .padding_edges = ui_core.Edges.xy(8, 4),
            .text_align = .left,
            .font_scale = theme.Metrics.font_medium,
            .bg_color = th.color(.button_bg, level),
            .text_color = th.color(.button_text, level),
            .border_color = th.color(.field_border, level),
            .border_widths = .{ 1, 1, 1, 1 },
            .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.corner_radius),
        },
    });
    const trig_id = tree.idOf(trig_idx).?;
    _ = try tree.createNode(trig_idx, .{
        .id = "",
        .kind = .custom,
        .pickable = false,
        .style = .{
            .position = .absolute,
            .right = 8,
            .top = 6,
            .width = 12,
            .height = 12,
            .min_height = 12,
            .padding = 0,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
        .paint_extra = .{ .icon = .{ .kind = .chevron_down, .size = 10, .color = th.color(.button_text, level) } },
    });

    const popup_idx = try tree.createNode(null, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .column,
            .position = .absolute,
            .layer = .overlay,
            .visible = false,
            .width = 180,
            .padding = 4,
            .gap = 4,
            .bg_color = th.color(.menu_bg, .floating),
            .border_color = th.color(.menu_border, .floating),
            .border_widths = .{ 1, 1, 1, 1 },
            .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.corner_radius),
        },
    });
    const popup_id = tree.idOf(popup_idx).?;
    const search_id = try textInput(tree, mgr, th, popup_idx, .{
        .text = "",
        .tag = tag,
        .level = .floating,
    });
    const list_idx = try tree.createNode(popup_idx, .{
        .id = "",
        .kind = .panel,
        .scrollable = true,
        .style = .{
            .direction = .column,
            .height = if (options.len > 5) 140 else @as(f32, @floatFromInt(@max(@as(usize, 1), options.len) * 26)),
            .padding = 0,
            .gap = 2,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
    });

    var handles = ComboboxHandles{
        .trigger = trig_id,
        .popup = popup_id,
        .search_input = search_id,
        .selected_idx = selected_idx,
    };
    const count = @min(options.len, 32);
    handles.option_count = count;
    for (0..count) |i| {
        const opt_idx = try tree.createNode(list_idx, .{
            .id = "",
            .kind = .button,
            .text = options[i],
            .focusable = true,
            .cursor = .pointer,
            .style = .{
                .min_height = theme.Metrics.row_height,
                .padding_edges = ui_core.Edges.xy(8, 4),
                .text_align = .left,
                .font_scale = theme.Metrics.font_medium,
                .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .text_color = th.color(.text_main, .floating),
            },
        });
        const oid = tree.idOf(opt_idx).?;
        handles.option_nodes[i] = oid;
        _ = try mgr.attach(oid, tag, .{ .menu_item = .{ .popup_node = popup_id, .select_trigger = trig_id } });
    }

    _ = try mgr.attach(trig_id, tag, .{ .menu_trigger = .{ .popup_node = popup_id } });
    _ = try mgr.attach(popup_id, "", .{ .popover = .{ .anchor = trig_id, .match_anchor_width = true } });
    return handles;
}

/// Filters `Combobox` options by `search_input` text and tracks selection index.
pub fn syncCombobox(tree: *ui_core.UiTree, mgr: *const ui_widgets.WidgetManager, th: *const theme.UiTheme, cb: *ComboboxHandles) void {
    const query = if (tree.resolveId(cb.search_input)) |si| tree.nodes.items[si].text else "";
    for (0..cb.option_count) |i| {
        if (cb.option_nodes[i]) |oid| {
            if (tree.resolveId(oid)) |oi| {
                const txt = tree.nodes.items[oi].text;
                tree.nodes.items[oi].style.visible = containsInsensitive(txt, query);
                const hov = tree.nodes.items[oi].hovered;
                tree.nodes.items[oi].style.bg_color = if (hov) th.color(.item_hover, .floating) else .{ .r = 0, .g = 0, .b = 0, .a = 0 };
            }
        }
    }
    for (mgr.eventsSlice()) |ev| {
        if (ev.payload != .activate) continue;
        for (0..cb.option_count) |i| {
            if (cb.option_nodes[i]) |oid| {
                if (std.meta.eql(ev.node, oid)) cb.selected_idx = i;
            }
        }
    }
}

fn containsInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |start| {
        var match = true;
        for (0..needle.len) |j| {
            if (std.ascii.toLower(haystack[start + j]) != std.ascii.toLower(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

/// Visual handles for a dual-thumb `RangeSlider`.
pub const RangeSliderHandles = struct {
    root: ui_core.UiNodeId,
    fill: ui_core.UiNodeId,
    min_thumb: ui_core.UiNodeId,
    max_thumb: ui_core.UiNodeId,
};

/// Creates a 2-thumb `[min, max]` `RangeSlider`.
pub fn rangeSlider(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *const theme.UiTheme,
    parent: ?usize,
    min_val: f64,
    max_val: f64,
    range_min: f64,
    range_max: f64,
    tag: []const u8,
    level: theme.SurfaceLevel,
) !RangeSliderHandles {
    const h: f32 = 16.0;
    const root_idx = try tree.createNode(parent, .{
        .id = "",
        .kind = .custom,
        .focusable = true,
        .cursor = .ew_resize,
        .style = .{
            .height = h,
            .min_height = h,
            .padding = 0,
            .bg_color = th.color(.slider_bg, level),
            .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.corner_radius),
        },
    });
    const fill_idx = try tree.createNode(root_idx, .{
        .id = "",
        .kind = .custom,
        .pickable = false,
        .style = .{
            .position = .absolute,
            .left = 0,
            .top = 0,
            .width = 40,
            .height = h,
            .min_height = h,
            .padding = 0,
            .bg_color = th.color(.slider_bar, level),
        },
    });
    const min_t = try tree.createNode(root_idx, .{
        .id = "",
        .kind = .custom,
        .pickable = false,
        .style = .{
            .position = .absolute,
            .left = 0,
            .top = 1,
            .width = 10,
            .height = h - 2,
            .min_height = h - 2,
            .padding = 0,
            .bg_color = .{ .r = 0.92, .g = 0.93, .b = 0.95, .a = 1.0 },
            .border_color = th.color(.focus_ring, level),
            .border_widths = .{ 1, 1, 1, 1 },
            .corner_radii = rounded.RoundedCorners.all.toRadii(2.0),
        },
    });
    const max_t = try tree.createNode(root_idx, .{
        .id = "",
        .kind = .custom,
        .pickable = false,
        .style = .{
            .position = .absolute,
            .left = 0,
            .top = 1,
            .width = 10,
            .height = h - 2,
            .min_height = h - 2,
            .padding = 0,
            .bg_color = .{ .r = 0.92, .g = 0.93, .b = 0.95, .a = 1.0 },
            .border_color = th.color(.focus_ring, level),
            .border_widths = .{ 1, 1, 1, 1 },
            .corner_radii = rounded.RoundedCorners.all.toRadii(2.0),
        },
    });
    const root_id = tree.idOf(root_idx).?;
    const fill_id = tree.idOf(fill_idx).?;
    const min_id = tree.idOf(min_t).?;
    const max_id = tree.idOf(max_t).?;
    _ = try mgr.attach(root_id, tag, .{
        .range_slider = .{
            .min_val = min_val,
            .max_val = max_val,
            .range = .{ .min = range_min, .max = range_max },
            .min_thumb = min_id,
            .max_thumb = max_id,
            .fill_node = fill_id,
        },
    });
    return .{ .root = root_id, .fill = fill_id, .min_thumb = min_id, .max_thumb = max_id };
}

/// Synchronizes `RangeSlider` fill bar and thumb positions.
pub fn syncRangeSlider(tree: *ui_core.UiTree, mgr: *ui_widgets.WidgetManager, rs: RangeSliderHandles) void {
    const b = mgr.findByNode(rs.root) orelse return;
    if (b.behavior != .range_slider) return;
    const st = b.behavior.range_slider;
    const r_idx = tree.resolveId(rs.root) orelse return;
    const f_idx = tree.resolveId(rs.fill) orelse return;
    const min_idx = tree.resolveId(rs.min_thumb) orelse return;
    const max_idx = tree.resolveId(rs.max_thumb) orelse return;

    const span = @max(@as(f64, 1e-6), st.range.max - st.range.min);
    const t0: f32 = @floatCast(std.math.clamp((st.min_val - st.range.min) / span, 0.0, 1.0));
    const t1: f32 = @floatCast(std.math.clamp((st.max_val - st.range.min) / span, 0.0, 1.0));
    const w = tree.nodes.items[r_idx].layout.width;
    const travel = @max(@as(f32, 0.0), w - 10.0);
    const x0 = t0 * travel;
    const x1 = t1 * travel;
    tree.nodes.items[min_idx].style.left = x0;
    tree.nodes.items[max_idx].style.left = x1;
    tree.nodes.items[f_idx].style.left = x0 + 5.0;
    tree.nodes.items[f_idx].style.width = @max(@as(f32, 0.0), x1 - x0);
}

/// Creates a `KeybindInput` button that captures a shortcut (`Press a key...` -> `Ctrl+Shift+P`).
pub fn keybindInput(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *const theme.UiTheme,
    parent: ?usize,
    initial_label: []const u8,
    tag: []const u8,
    level: theme.SurfaceLevel,
) !ui_core.UiNodeId {
    const idx = try tree.createNode(parent, .{
        .id = "",
        .kind = .button,
        .text = initial_label,
        .focusable = true,
        .cursor = .pointer,
        .style = .{
            .min_height = theme.Metrics.row_height,
            .padding_edges = ui_core.Edges.xy(10, 4),
            .text_align = .center,
            .font_scale = theme.Metrics.font_small,
            .bg_color = th.color(.field_bg, level),
            .text_color = th.color(.text_accent, level),
            .border_color = th.color(.field_border, level),
            .border_widths = .{ 1, 1, 1, 1 },
            .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.corner_radius),
        },
    });
    const nid = tree.idOf(idx).?;
    _ = try mgr.attach(nid, tag, .{ .keybind_input = .{} });
    return nid;
}
