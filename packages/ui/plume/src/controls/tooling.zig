//! Advanced Tooling Controls: Tabs, SplitPane & TreeView (`official.ui.plume`).

const graphics = @import("graphics");
const ui_core = @import("ui_core");
const ui_widgets = @import("ui_widgets");
const theme = @import("../theme.zig");
const rounded = @import("../rounded_corners.zig");
const button = @import("button.zig");

/// Handles for a horizontal `tabStrip` (`Wheel | RGB | HSL`, etc.).
pub const TabStripHandles = struct {
    root: ui_core.UiNodeId,
    tab_buttons: [8]?button.ButtonStyleMeta = @splat(null),
    count: usize = 0,
    active_idx: usize = 0,
};

/// Creates a segmented tab strip where the active tab uses `.primary` styling.
pub fn tabStrip(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *const theme.UiTheme,
    parent: ?usize,
    labels: []const []const u8,
    active_idx: usize,
    tag_prefix: []const u8,
    level: theme.SurfaceLevel,
) !TabStripHandles {
    const root_idx = try tree.createNode(parent, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .row,
            .padding = 0,
            .gap = 0,
            .min_height = theme.Metrics.row_height,
            .bg_color = th.color(.tab_strip_bg, level),
            .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.corner_radius),
        },
    });

    var handles = TabStripHandles{
        .root = tree.idOf(root_idx).?,
        .active_idx = active_idx,
    };

    const n = @min(labels.len, handles.tab_buttons.len);
    for (0..n) |i| {
        const corners: rounded.RoundedCorners = if (n == 1)
            .all
        else if (i == 0)
            .left
        else if (i + 1 == n)
            .right
        else
            .none;
        handles.tab_buttons[i] = try button.button(tree, mgr, th, root_idx, .{
            .label = labels[i],
            .variant = button.ButtonVariant.selected(i == active_idx),
            .corners = corners,
            .width_spec = .{ .grow = 1.0 },
            .tag = tag_prefix,
            .level = level,
        });
        handles.count += 1;
    }

    return handles;
}

/// Updates active tab styling across `TabStripHandles`.
pub fn setActiveTab(
    tree: *ui_core.UiTree,
    th: *const theme.UiTheme,
    handles: *TabStripHandles,
    new_active: usize,
) void {
    handles.active_idx = new_active;
    for (0..handles.count) |i| {
        if (handles.tab_buttons[i]) |*meta| {
            meta.variant = button.ButtonVariant.selected(i == new_active);
            button.syncButtonStyle(tree, th, meta.*);
        }
    }
}

/// Creates a 2-pane horizontal split container with a 4px divider handle.
pub fn splitPaneHorizontal(
    tree: *ui_core.UiTree,
    th: *const theme.UiTheme,
    parent: ?usize,
    left_grow: f32,
    right_grow: f32,
) !struct { root: usize, left: usize, handle: usize, right: usize } {
    const root = try tree.createNode(parent, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .row,
            .padding = 0,
            .gap = 0,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
    });
    const left = try tree.createNode(root, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .column,
            .width_spec = .{ .grow = left_grow },
            .padding = 4,
            .gap = 4,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
    });
    const handle = try tree.createNode(root, .{
        .id = "",
        .kind = .custom,
        .cursor = .ew_resize,
        .style = .{
            .width = 4,
            .min_height = 24,
            .padding = 0,
            .bg_color = th.color(.pane_header_divider, .base),
        },
    });
    const right = try tree.createNode(root, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .column,
            .width_spec = .{ .grow = right_grow },
            .padding = 4,
            .gap = 4,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
    });
    return .{ .root = root, .left = left, .handle = handle, .right = right };
}

/// Handles for a hierarchical `treeItem` row with optional collapsible children container.
pub const TreeItemHandles = struct {
    row: usize,
    chevron: ui_core.UiNodeId,
    children_box: usize,
    eye_btn: ?ui_core.UiNodeId = null,
    has_children: bool = true,
    level: theme.SurfaceLevel = .higher,
};

/// Customization options for `treeItemEx`.
pub const TreeItemOptions = struct {
    expanded: bool = true,
    has_children: bool = true,
    icon: ?graphics.IconKind = null,
    icon_color: ?graphics.Color = null,
    show_visibility_toggle: bool = false,
    visible_state: bool = true,
    indent_px: f32 = 16.0,
    level: theme.SurfaceLevel = .higher,
};

/// Creates a `treeView` container.
pub fn treeView(tree: *ui_core.UiTree, th: *const theme.UiTheme, parent: ?usize, level: theme.SurfaceLevel) !usize {
    return tree.createNode(parent, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .column,
            .padding = 4,
            .gap = 2,
            .bg_color = th.color(.pane_body_bg, level),
            .border_color = th.color(.group_border, level),
            .border_widths = .{ 1, 1, 1, 1 },
            .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.corner_radius),
        },
    });
}

/// Creates a hierarchical `treeItem` with disclosure toggle and indented `children_box`.
pub fn treeItem(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *const theme.UiTheme,
    parent: usize,
    label_text: []const u8,
    expanded: bool,
    tag: []const u8,
    level: theme.SurfaceLevel,
) !TreeItemHandles {
    return treeItemEx(tree, mgr, th, parent, label_text, .{
        .expanded = expanded,
        .has_children = true,
        .level = level,
    }, tag);
}

/// Creates a customizable hierarchical `treeItemEx` with Lucide chevron + icon and indented `children_box`.
pub fn treeItemEx(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *const theme.UiTheme,
    parent: usize,
    label_text: []const u8,
    opts: TreeItemOptions,
    tag: []const u8,
) !TreeItemHandles {
    const outer = try tree.createNode(parent, .{
        .id = "",
        .kind = .panel,
        .style = .{ .direction = .column, .padding = 0, .gap = 1, .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
    });
    const children_box = try tree.createNode(outer, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .column,
            .padding_edges = .{ .left = opts.indent_px, .top = 0, .right = 0, .bottom = 0 },
            .gap = 1,
            .visible = opts.expanded and opts.has_children,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
    });
    const row = try tree.createNode(outer, .{
        .id = "",
        .kind = .panel,
        .focusable = true,
        .cursor = .pointer,
        .style = .{
            .direction = .row,
            .align_items = .center,
            .min_height = 22,
            .padding_edges = ui_core.Edges.xy(6, 2),
            .gap = 5,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .corner_radii = rounded.RoundedCorners.all.toRadii(3.0),
        },
    });
    const chev = try tree.createNode(row, .{
        .id = "",
        .kind = .custom,
        .pickable = false,
        .style = .{
            .width = 12,
            .height = 12,
            .min_height = 12,
            .padding = 0,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
        .paint_extra = if (opts.has_children) .{
            .icon = .{
                .kind = if (opts.expanded) .chevron_down else .chevron_right,
                .size = 11,
                .color = th.color(.text_dim, opts.level),
            },
        } else .none,
    });
    const item_icon = opts.icon orelse (if (opts.has_children) graphics.IconKind.folder else graphics.IconKind.file);
    _ = try tree.createNode(row, .{
        .id = "",
        .kind = .custom,
        .pickable = false,
        .style = .{
            .width = 14,
            .height = 14,
            .min_height = 14,
            .padding = 0,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
        .paint_extra = .{
            .icon = .{
                .kind = item_icon,
                .size = 13,
                .color = opts.icon_color orelse th.color(if (opts.has_children) .text_accent else .text_dim, opts.level),
            },
        },
    });
    _ = try tree.createNode(row, .{
        .id = "",
        .kind = .label,
        .pickable = false,
        .text = label_text,
        .style = .{
            .padding = 0,
            .min_height = 16,
            .font_scale = theme.Metrics.font_small,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .text_color = th.color(if (opts.visible_state) .text_main else .text_dim, opts.level),
        },
    });
    var eye_id: ?ui_core.UiNodeId = null;
    if (opts.show_visibility_toggle) {
        _ = try tree.createNode(row, .{
            .id = "",
            .kind = .panel,
            .pickable = false,
            .style = .{ .width_spec = .{ .grow = 1.0 }, .min_height = 1, .padding = 0, .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
        });
        const eb = try tree.createNode(row, .{
            .id = "",
            .kind = .button,
            .focusable = true,
            .cursor = .pointer,
            .style = .{
                .width = 18,
                .height = 18,
                .min_height = 18,
                .padding = 0,
                .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            },
            .paint_extra = .{
                .icon = .{
                    .kind = if (opts.visible_state) .eye else .eye_off,
                    .size = 13,
                    .color = th.color(if (opts.visible_state) .text_main else .text_dim, opts.level),
                },
            },
        });
        eye_id = tree.idOf(eb).?;
        _ = try mgr.attach(eye_id.?, tag, .{
            .checkbox = .{
                .checked = opts.visible_state,
                .fast_click = true,
            },
        });
    }
    _ = try mgr.attach(tree.idOf(row).?, tag, .{
        .disclosure = .{
            .expanded = opts.expanded,
            .target_body = tree.idOf(children_box).?,
        },
    });
    // Swap so row precedes children_box.
    const ch = &tree.nodes.items[outer].children;
    if (ch.items.len == 2) {
        const tmp = ch.items[0];
        ch.items[0] = ch.items[1];
        ch.items[1] = tmp;
    }
    return .{
        .row = row,
        .chevron = tree.idOf(chev).?,
        .children_box = children_box,
        .eye_btn = eye_id,
        .has_children = opts.has_children,
        .level = opts.level,
    };
}

/// Synchronizes hover highlight, disclosure chevron icon, and optional visibility eye toggle on a `treeItem` row.
pub fn syncTreeRow(tree: *ui_core.UiTree, mgr: *ui_widgets.WidgetManager, th: *const theme.UiTheme, node_id: ui_core.UiNodeId) void {
    const idx = tree.resolveId(node_id) orelse return;
    const n = &tree.nodes.items[idx];
    if (n.kind != .panel or n.children.items.len == 0) return;
    n.style.bg_color = if (n.hovered) th.color(.item_hover, .higher) else .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    const chev_idx = n.children.items[0];
    if (chev_idx < tree.nodes.items.len and tree.nodes.items[chev_idx].paint_extra == .icon) {
        if (mgr.findByNode(node_id)) |b| {
            if (b.behavior == .disclosure) {
                tree.nodes.items[chev_idx].paint_extra.icon.kind = if (b.behavior.disclosure.expanded) .chevron_down else .chevron_right;
            }
        }
    }
    if (n.children.items.len >= 5) {
        const eye_idx = n.children.items[4];
        if (tree.idOf(eye_idx)) |eye_nid| {
            if (mgr.findByNode(eye_nid)) |eb| {
                if (eb.behavior == .checkbox) {
                    const self_vis = eb.behavior.checkbox.checked;
                    const parent_hidden = hasHiddenAncestorTreeItem(tree, mgr, idx);
                    const eff_vis = self_vis and !parent_hidden;
                    if (tree.nodes.items[eye_idx].paint_extra == .icon) {
                        tree.nodes.items[eye_idx].paint_extra.icon.kind = if (self_vis) .eye else .eye_off;
                        tree.nodes.items[eye_idx].paint_extra.icon.color = if (eff_vis)
                            th.color(.text_main, .higher)
                        else
                            .{ .r = 0.42, .g = 0.44, .b = 0.48, .a = if (parent_hidden) 0.45 else 0.7 };
                    }
                    const icon_idx = n.children.items[1];
                    const lbl_idx = n.children.items[2];
                    if (icon_idx < tree.nodes.items.len and tree.nodes.items[icon_idx].paint_extra == .icon) {
                        tree.nodes.items[icon_idx].paint_extra.icon.color.a = if (eff_vis) 1.0 else 0.35;
                    }
                    if (lbl_idx < tree.nodes.items.len) {
                        tree.nodes.items[lbl_idx].style.text_color = if (eff_vis)
                            th.color(.text_main, .higher)
                        else
                            .{ .r = 0.45, .g = 0.46, .b = 0.50, .a = 0.65 };
                    }
                }
            }
        }
    }
}

fn hasHiddenAncestorTreeItem(tree: *const ui_core.UiTree, mgr: *ui_widgets.WidgetManager, row_idx: usize) bool {
    var cur = tree.nodes.items[row_idx].parent; // outer
    while (cur) |outer_idx| {
        const cbox_idx = tree.nodes.items[outer_idx].parent orelse break;
        const p_outer_idx = tree.nodes.items[cbox_idx].parent orelse break;
        const p_outer = &tree.nodes.items[p_outer_idx];
        if (p_outer.children.items.len >= 1) {
            const p_row_idx = p_outer.children.items[0];
            if (p_row_idx < tree.nodes.items.len) {
                const p_row = &tree.nodes.items[p_row_idx];
                if (p_row.children.items.len >= 5) {
                    if (tree.idOf(p_row.children.items[4])) |eye_nid| {
                        if (mgr.findByNode(eye_nid)) |eb| {
                            if (eb.behavior == .checkbox and !eb.behavior.checkbox.checked) return true;
                        }
                    }
                }
            }
        }
        cur = p_outer.parent;
    }
    return false;
}

/// Creates a docked tabbed panel container (`tabStrip` + body).
pub fn dockPanel(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *const theme.UiTheme,
    parent: ?usize,
    tab_titles: []const []const u8,
    active_tab: usize,
    tag_prefix: []const u8,
    level: theme.SurfaceLevel,
) !struct { root: usize, tabs: TabStripHandles, body: usize } {
    const root = try tree.createNode(parent, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .column,
            .padding = 0,
            .gap = 0,
            .border_color = th.color(.group_border, level),
            .border_widths = .{ 1, 1, 1, 1 },
            .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.corner_radius),
            .bg_color = th.color(.pane_body_bg, level),
        },
    });
    const tabs = try tabStrip(tree, mgr, th, root, tab_titles, active_tab, tag_prefix, level);
    const body = try tree.createNode(root, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .column,
            .width_spec = .{ .grow = 1.0 },
            .padding = 8,
            .gap = 6,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
    });
    return .{ .root = root, .tabs = tabs, .body = body };
}

/// Creates a compact on-screen `virtualKeyboard` widget (QWERTY rows).
pub fn virtualKeyboard(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *const theme.UiTheme,
    parent: ?usize,
    tag_prefix: []const u8,
    level: theme.SurfaceLevel,
) !usize {
    const root = try tree.createNode(parent, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .column,
            .padding = 6,
            .gap = 4,
            .bg_color = th.color(.pane_header_bg, level),
            .border_color = th.color(.group_border, level),
            .border_widths = .{ 1, 1, 1, 1 },
            .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.corner_radius),
        },
    });
    const rows = [3][]const []const u8{
        &.{ "Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P" },
        &.{ "A", "S", "D", "F", "G", "H", "J", "K", "L" },
        &.{ "Z", "X", "C", "V", "B", "N", "M", "<-" },
    };
    for (rows) |keys| {
        const r = try tree.createNode(root, .{
            .id = "",
            .kind = .panel,
            .style = .{ .direction = .row, .padding = 0, .gap = 3, .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
        });
        for (keys) |k| {
            _ = try button.button(tree, mgr, th, r, .{
                .label = k,
                .width_spec = .{ .grow = 1.0 },
                .tag = tag_prefix,
                .level = level,
            });
        }
    }
    return root;
}
