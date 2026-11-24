//! Checkbox, Radio, ToggleSwitch & DisclosureToggle Controls (`official.ui.plume`).

const std = @import("std");
const graphics = @import("graphics");
const ui_core = @import("ui_core");
const ui_widgets = @import("ui_widgets");
const theme = @import("../theme.zig");
const rounded = @import("../rounded_corners.zig");

const color_math = ui_widgets.color;

/// Handles for synchronizing a Checkbox or Radio visual state.
pub const ToggleVisualMeta = struct {
    root: ui_core.UiNodeId,
    box: ui_core.UiNodeId,
    mark: ui_core.UiNodeId,
    level: theme.SurfaceLevel,
    kind: enum { checkbox, radio, toggle_switch, disclosure },
};

/// Configuration properties for `checkbox`.
pub const CheckboxProps = struct {
    label: []const u8 = "",
    checked: bool = false,
    fast_click: bool = false,
    disabled: bool = false,
    auto_update: bool = true,
    tag: []const u8 = "",
    level: theme.SurfaceLevel = .higher,
};

/// Creates a styled checkbox with optional caption label.
pub fn checkbox(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *const theme.UiTheme,
    parent: ?usize,
    props: CheckboxProps,
) !ToggleVisualMeta {
    const root_idx = try tree.createNode(parent, .{
        .id = "",
        .kind = .panel,
        .focusable = true,
        .disabled = props.disabled,
        .cursor = if (props.disabled) .default else .pointer,
        .style = .{
            .direction = .row,
            .min_height = theme.Metrics.row_height,
            .padding = 0,
            .gap = 6,
            .align_items = .center,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
    });
    tree.nodes.items[root_idx].checked = props.checked;

    const sz = theme.Metrics.checkbox_size;
    const box_idx = try tree.createNode(root_idx, .{
        .id = "",
        .kind = .custom,
        .pickable = false,
        .style = .{
            .width = sz,
            .height = sz,
            .min_height = sz,
            .padding = 0,
            .align_items = .center,
            .justify_content = .center,
            .border_widths = .{ 1, 1, 1, 1 },
            .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.corner_radius),
            .bg_color = th.color(if (props.checked) .checkbox_bg_checked else .checkbox_bg, props.level),
            .border_color = th.color(.checkbox_border, props.level),
        },
    });

    const mark_idx = try tree.createNode(box_idx, .{
        .id = "",
        .kind = .custom,
        .pickable = false,
        .style = .{
            .position = .absolute,
            .left = 3,
            .top = 3,
            .width = 12,
            .height = 12,
            .min_height = 12,
            .padding = 0,
            .visible = props.checked,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
        .paint_extra = .{
            .icon = .{
                .kind = .check,
                .size = 12,
                .color = th.color(.checkbox_mark, props.level),
            },
        },
    });

    if (props.label.len > 0) {
        _ = try tree.createNode(root_idx, .{
            .id = "",
            .kind = .label,
            .pickable = false,
            .text = props.label,
            .style = .{
                .padding = 0,
                .min_height = 16,
                .font_scale = theme.Metrics.font_medium,
                .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .text_color = th.color(if (props.disabled) .button_text_disabled else .checkbox_text, props.level),
            },
        });
    }

    const root_id = tree.idOf(root_idx).?;
    _ = try mgr.attach(root_id, props.tag, .{
        .checkbox = .{
            .checked = props.checked,
            .fast_click = props.fast_click,
            .auto_update = props.auto_update,
        },
    });

    return .{
        .root = root_id,
        .box = tree.idOf(box_idx).?,
        .mark = tree.idOf(mark_idx).?,
        .level = props.level,
        .kind = .checkbox,
    };
}

/// Configuration properties for `radio`.
pub const RadioProps = struct {
    label: []const u8 = "",
    group_id: u32 = 1,
    checked: bool = false,
    fast_click: bool = false,
    disabled: bool = false,
    auto_update: bool = true,
    tag: []const u8 = "",
    level: theme.SurfaceLevel = .higher,
};

/// Creates a styled radio button belonging to `group_id`.
pub fn radio(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *const theme.UiTheme,
    parent: ?usize,
    props: RadioProps,
) !ToggleVisualMeta {
    const root_idx = try tree.createNode(parent, .{
        .id = "",
        .kind = .panel,
        .focusable = true,
        .disabled = props.disabled,
        .cursor = if (props.disabled) .default else .pointer,
        .style = .{
            .direction = .row,
            .min_height = theme.Metrics.row_height,
            .padding = 0,
            .gap = 6,
            .align_items = .center,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
    });
    tree.nodes.items[root_idx].checked = props.checked;

    const sz = theme.Metrics.radio_size;
    const box_idx = try tree.createNode(root_idx, .{
        .id = "",
        .kind = .custom,
        .pickable = false,
        .style = .{
            .width = sz,
            .height = sz,
            .min_height = sz,
            .padding = 4,
            .border_widths = .{ 2, 2, 2, 2 },
            .corner_radii = rounded.RoundedCorners.all.toRadii(sz * 0.5),
            .bg_color = th.color(.radio_bg, props.level),
            .border_color = th.color(if (props.checked) .radio_mark else .radio_border, props.level),
        },
    });

    const mark_idx = try tree.createNode(box_idx, .{
        .id = "",
        .kind = .custom,
        .pickable = false,
        .style = .{
            .width = 10,
            .height = 10,
            .min_height = 10,
            .padding = 0,
            .visible = props.checked,
            .corner_radii = rounded.RoundedCorners.all.toRadii(5.0),
            .bg_color = th.color(.radio_mark, props.level),
        },
    });

    if (props.label.len > 0) {
        _ = try tree.createNode(root_idx, .{
            .id = "",
            .kind = .label,
            .pickable = false,
            .text = props.label,
            .style = .{
                .padding = 0,
                .min_height = 16,
                .font_scale = theme.Metrics.font_medium,
                .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .text_color = th.color(if (props.disabled) .button_text_disabled else .checkbox_text, props.level),
            },
        });
    }

    const root_id = tree.idOf(root_idx).?;
    _ = try mgr.attach(root_id, props.tag, .{
        .radio = .{
            .group_id = props.group_id,
            .checked = props.checked,
            .fast_click = props.fast_click,
            .auto_update = props.auto_update,
        },
    });

    return .{
        .root = root_id,
        .box = tree.idOf(box_idx).?,
        .mark = tree.idOf(mark_idx).?,
        .level = props.level,
        .kind = .radio,
    };
}

/// Configuration properties for `toggleSwitch`.
pub const ToggleSwitchProps = struct {
    checked: bool = false,
    fast_click: bool = true,
    disabled: bool = false,
    auto_update: bool = true,
    tag: []const u8 = "",
    level: theme.SurfaceLevel = .higher,
};

/// Creates a pill-shaped sliding toggle switch (32x18px).
pub fn toggleSwitch(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *const theme.UiTheme,
    parent: ?usize,
    props: ToggleSwitchProps,
) !ToggleVisualMeta {
    const w = theme.Metrics.toggle_width;
    const h = theme.Metrics.toggle_height;
    const root_idx = try tree.createNode(parent, .{
        .id = "",
        .kind = .custom,
        .focusable = true,
        .disabled = props.disabled,
        .cursor = if (props.disabled) .default else .pointer,
        .style = .{
            .width = w,
            .height = h,
            .min_height = h,
            .padding = 0,
            .border_widths = .{ 1, 1, 1, 1 },
            .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.corner_radius),
            .bg_color = th.color(if (props.checked) .switch_bg_checked else .switch_bg, props.level),
            .border_color = th.color(.switch_border, props.level),
        },
    });
    tree.nodes.items[root_idx].checked = props.checked;

    const slide_w = w * 0.5 - 2.0;
    const slide_idx = try tree.createNode(root_idx, .{
        .id = "",
        .kind = .custom,
        .pickable = false,
        .style = .{
            .position = .absolute,
            .left = if (props.checked) w * 0.5 else 2.0,
            .top = 2.0,
            .width = slide_w,
            .height = h - 4.0,
            .min_height = h - 4.0,
            .padding = 0,
            .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.corner_radius),
            .bg_color = th.color(.switch_slide, props.level),
        },
    });

    const root_id = tree.idOf(root_idx).?;
    _ = try mgr.attach(root_id, props.tag, .{
        .checkbox = .{
            .checked = props.checked,
            .fast_click = props.fast_click,
            .auto_update = props.auto_update,
        },
    });

    return .{
        .root = root_id,
        .box = root_id,
        .mark = tree.idOf(slide_idx).?,
        .level = props.level,
        .kind = .toggle_switch,
    };
}

/// Synchronizes visual appearance of checkbox/radio/switch with `checked` and `disabled` state.
pub fn syncToggleStyle(
    tree: *ui_core.UiTree,
    th: *const theme.UiTheme,
    meta: ToggleVisualMeta,
) void {
    const r_idx = tree.resolveId(meta.root) orelse return;
    const b_idx = tree.resolveId(meta.box) orelse return;
    const m_idx = tree.resolveId(meta.mark) orelse return;
    const root = tree.nodes.items[r_idx];

    const base_border = th.color(.checkbox_border, meta.level);
    const hover_border = color_math.lighter(base_border, 0.28);

    switch (meta.kind) {
        .checkbox => {
            tree.nodes.items[m_idx].style.visible = root.checked;
            const bg = th.color(
                if (root.disabled) .checkbox_bg_disabled else if (root.checked) .checkbox_bg_checked else .checkbox_bg,
                meta.level,
            );
            tree.nodes.items[b_idx].style.bg_color = if (!root.disabled and root.hovered) color_math.lighter(bg, 0.08) else bg;
            tree.nodes.items[b_idx].style.border_color = if (!root.disabled and root.hovered) hover_border else base_border;
            tree.nodes.items[b_idx].style.border_widths = if (!root.disabled and root.hovered) .{ 2, 2, 2, 2 } else .{ 1, 1, 1, 1 };
        },
        .radio => {
            tree.nodes.items[m_idx].style.visible = root.checked;
            const rb = th.color(if (root.checked) .radio_mark else .radio_border, meta.level);
            tree.nodes.items[b_idx].style.border_color = if (!root.disabled and root.hovered) color_math.lighter(rb, 0.25) else rb;
            tree.nodes.items[b_idx].style.border_widths = if (!root.disabled and root.hovered) .{ 2, 2, 2, 2 } else .{ 1, 1, 1, 1 };
        },
        .toggle_switch => {
            const w = theme.Metrics.toggle_width;
            const bg = th.color(
                if (root.disabled) .checkbox_bg_disabled else if (root.checked) .switch_bg_checked else .switch_bg,
                meta.level,
            );
            tree.nodes.items[b_idx].style.bg_color = if (!root.disabled and root.hovered) color_math.lighter(bg, 0.08) else bg;
            tree.nodes.items[b_idx].style.border_color = if (!root.disabled and root.hovered) hover_border else base_border;
            tree.nodes.items[b_idx].style.border_widths = if (!root.disabled and root.hovered) .{ 2, 2, 2, 2 } else .{ 1, 1, 1, 1 };
            tree.nodes.items[m_idx].style.left = if (root.checked) w * 0.5 else 2.0;
            tree.nodes.items[m_idx].style.bg_color = if (root.disabled)
                .{ .r = 0.50, .g = 0.51, .b = 0.53, .a = 0.7 }
            else if (root.hovered or root.checked)
                .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 }
            else
                .{ .r = 0.76, .g = 0.76, .b = 0.78, .a = 1.0 };
        },
        .disclosure => {
            if (tree.nodes.items[m_idx].paint_extra == .icon) {
                tree.nodes.items[m_idx].paint_extra.icon.kind = if (root.expanded) .chevron_down else .chevron_right;
            }
        },
    }
}

/// Configuration properties for `disclosureToggle` and `accordion`.
pub const AccordionProps = struct {
    title: []const u8 = "",
    expanded: bool = true,
    tag: []const u8 = "",
    level: theme.SurfaceLevel = .higher,
};

/// Handles for a collapsible `accordion` section.
pub const AccordionHandles = struct {
    meta: ToggleVisualMeta,
    body: usize,
};

/// Creates a disclosure toggle button (`>` / `v`) linked to `target_body`.
pub fn disclosureToggle(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *const theme.UiTheme,
    parent: ?usize,
    label_text: []const u8,
    expanded: bool,
    target_body: ?ui_core.UiNodeId,
    tag: []const u8,
    level: theme.SurfaceLevel,
) !ToggleVisualMeta {
    const root_idx = try tree.createNode(parent, .{
        .id = "",
        .kind = .panel,
        .focusable = true,
        .cursor = .pointer,
        .style = .{
            .direction = .row,
            .min_height = theme.Metrics.row_height,
            .padding_edges = ui_core.Edges.xy(6, 4),
            .gap = 6,
            .align_items = .center,
            .bg_color = th.color(.subpane_header_bg, level),
            .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.corner_radius),
        },
    });
    tree.nodes.items[root_idx].expanded = expanded;

    const icon_idx = try tree.createNode(root_idx, .{
        .id = "",
        .kind = .custom,
        .style = .{
            .width = 14,
            .height = 14,
            .min_height = 14,
            .padding = 0,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
        .paint_extra = .{
            .icon = .{
                .kind = if (expanded) .chevron_down else .chevron_right,
                .size = 12,
                .color = th.color(.text_main, level),
            },
        },
    });

    if (label_text.len > 0) {
        _ = try tree.createNode(root_idx, .{
            .id = "",
            .kind = .label,
            .text = label_text,
            .style = .{
                .padding = 0,
                .min_height = 16,
                .font_scale = theme.Metrics.font_medium,
                .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .text_color = th.color(.text_main, level),
            },
        });
    }

    const root_id = tree.idOf(root_idx).?;
    _ = try mgr.attach(root_id, tag, .{
        .disclosure = .{
            .expanded = expanded,
            .target_body = target_body,
        },
    });

    return .{
        .root = root_id,
        .box = root_id,
        .mark = tree.idOf(icon_idx).?,
        .level = level,
        .kind = .disclosure,
    };
}

/// Creates an expandable/collapsible `accordion` section (header + collapsible body).
pub fn accordion(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *const theme.UiTheme,
    parent: ?usize,
    props: AccordionProps,
) !AccordionHandles {
    const outer = try tree.createNode(parent, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .column,
            .padding = 0,
            .gap = 0,
            .border_color = th.color(.group_border, props.level),
            .border_widths = .{ 1, 1, 1, 1 },
            .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.corner_radius),
            .bg_color = th.color(.group_bg, props.level),
        },
    });

    const body = try tree.createNode(outer, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .column,
            .padding = 6,
            .gap = 4,
            .visible = props.expanded,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
    });

    // Insert disclosure header before body by creating it and swapping child order.
    const meta = try disclosureToggle(
        tree,
        mgr,
        th,
        outer,
        props.title,
        props.expanded,
        tree.idOf(body).?,
        props.tag,
        props.level,
    );
    const children = &tree.nodes.items[outer].children;
    if (children.items.len == 2) {
        const tmp = children.items[0];
        children.items[0] = children.items[1];
        children.items[1] = tmp;
    }

    return .{ .meta = meta, .body = body };
}

/// Handles for a multi-select `ToggleGroup` segmented bar (up to 8 segments).
pub const ToggleGroupHandles = struct {
    root: usize,
    items: [8]?ui_core.UiNodeId = @splat(null),
    active: [8]bool = @splat(false),
    count: usize = 0,
    level: theme.SurfaceLevel = .higher,
};

/// Creates a multi-select segmented `ToggleGroup` (e.g. `[Mesh] [Light] [Collider]`).
pub fn toggleGroup(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *const theme.UiTheme,
    parent: ?usize,
    labels: []const []const u8,
    initial_active: []const bool,
    tag: []const u8,
    level: theme.SurfaceLevel,
) !ToggleGroupHandles {
    const root = try tree.createNode(parent, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .row,
            .padding = 2,
            .gap = 2,
            .bg_color = th.color(.group_bg, level),
            .border_color = th.color(.field_border, level),
            .border_widths = .{ 1, 1, 1, 1 },
            .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.corner_radius),
        },
    });
    var handles = ToggleGroupHandles{ .root = root, .level = level };
    const n = @min(labels.len, 8);
    handles.count = n;
    for (0..n) |i| {
        const on = if (i < initial_active.len) initial_active[i] else false;
        handles.active[i] = on;
        const seg = try tree.createNode(root, .{
            .id = "",
            .kind = .button,
            .text = labels[i],
            .focusable = true,
            .cursor = .pointer,
            .style = .{
                .min_height = theme.Metrics.row_height - 2,
                .padding_edges = ui_core.Edges.xy(8, 3),
                .text_align = .center,
                .font_scale = theme.Metrics.font_small,
                .bg_color = th.color(if (on) .button_primary_bg else .button_bg, level),
                .text_color = th.color(if (on) .button_primary_text else .button_text, level),
                .border_color = th.color(if (on) .focus_ring else .field_border, level),
                .border_widths = .{ 1, 1, 1, 1 },
                .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.corner_radius),
            },
        });
        tree.nodes.items[seg].selected = on;
        const sid = tree.idOf(seg).?;
        handles.items[i] = sid;
        _ = try mgr.attach(sid, tag, .{ .button = .{} });
    }
    return handles;
}

/// Processes clicks and updates segment colors on a `ToggleGroup`.
pub fn syncToggleGroup(
    tree: *ui_core.UiTree,
    mgr: *const ui_widgets.WidgetManager,
    th: *const theme.UiTheme,
    tg: *ToggleGroupHandles,
) void {
    for (mgr.eventsSlice()) |ev| {
        if (ev.payload != .activate) continue;
        for (0..tg.count) |i| {
            if (tg.items[i]) |sid| {
                if (std.meta.eql(ev.node, sid)) {
                    tg.active[i] = !tg.active[i];
                }
            }
        }
    }
    for (0..tg.count) |i| {
        if (tg.items[i]) |sid| {
            if (tree.resolveId(sid)) |idx| {
                const on = tg.active[i];
                const hov = tree.nodes.items[idx].hovered;
                tree.nodes.items[idx].selected = on;
                tree.nodes.items[idx].style.bg_color = if (on)
                    th.color(if (hov) .button_primary_bg_hover else .button_primary_bg, tg.level)
                else
                    th.color(if (hov) .button_bg_hover else .button_bg, tg.level);
                tree.nodes.items[idx].style.text_color = th.color(if (on) .button_primary_text else .button_text, tg.level);
                tree.nodes.items[idx].style.border_color = if (on)
                    th.color(.focus_ring, tg.level)
                else if (hov)
                    color_math.lighter(th.color(.field_border, tg.level), 0.25)
                else
                    th.color(.field_border, tg.level);
            }
        }
    }
}
