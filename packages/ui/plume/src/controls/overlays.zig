//! Menu, Select, Scrollable ListView & Modal Dialog Controls (`official.ui.plume`).

const std = @import("std");
const window = @import("window");
const graphics = @import("graphics");
const ui_core = @import("ui_core");
const ui_widgets = @import("ui_widgets");
const theme = @import("../theme.zig");
const rounded = @import("../rounded_corners.zig");
const button = @import("button.zig");

/// Handles for a dropdown `menu` trigger + floating popup container.
pub const MenuHandles = struct {
    trigger: button.ButtonStyleMeta,
    popup: ui_core.UiNodeId,
    popup_idx: usize,
};

/// Creates a dropdown menu trigger button and its hidden floating `Popover` popup.
pub fn menu(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *const theme.UiTheme,
    parent: ?usize,
    label: []const u8,
    level: theme.SurfaceLevel,
) !MenuHandles {
    const trig = try button.button(tree, mgr, th, parent, .{
        .label = label,
        .variant = .normal,
        .level = level,
    });
    const trig_idx = tree.resolveId(trig.node).?;
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
        .paint_extra = .{
            .icon = .{
                .kind = .chevron_down,
                .size = 10,
                .color = th.color(.button_text, level),
            },
        },
    });

    const popup_idx = try tree.createNode(null, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .column,
            .position = .absolute,
            .layer = .overlay,
            .visible = false,
            .width = 150,
            .min_width = 140,
            .padding = 4,
            .gap = 2,
            .bg_color = th.color(.menu_bg, .floating),
            .border_color = th.color(.menu_border, .floating),
            .border_widths = .{ 1, 1, 1, 1 },
            .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.corner_radius),
        },
    });
    const popup_id = tree.idOf(popup_idx).?;

    _ = try mgr.attach(trig.node, "", .{ .menu_trigger = .{ .popup_node = popup_id } });
    _ = try mgr.attach(popup_id, "", .{ .popover = .{ .anchor = trig.node } });

    return .{ .trigger = trig, .popup = popup_id, .popup_idx = popup_idx };
}

/// Appends a clickable item row to an existing `MenuHandles.popup_idx`.
pub fn menuItem(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *const theme.UiTheme,
    mh: MenuHandles,
    label: []const u8,
    tag: []const u8,
) !ui_core.UiNodeId {
    const idx = try tree.createNode(mh.popup_idx, .{
        .id = "",
        .kind = .button,
        .text = label,
        .focusable = true,
        .cursor = .pointer,
        .style = .{
            .min_height = theme.Metrics.row_height,
            .padding_edges = ui_core.Edges.xy(10, 4),
            .text_align = .left,
            .font_scale = theme.Metrics.font_medium,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .text_color = th.color(.text_main, .floating),
            .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.corner_radius),
        },
    });
    const nid = tree.idOf(idx).?;
    _ = try mgr.attach(nid, tag, .{ .menu_item = .{ .popup_node = mh.popup } });
    return nid;
}

/// Synchronizes menu item hover highlight and border.
pub fn syncMenuItem(tree: *ui_core.UiTree, th: *const theme.UiTheme, node_id: ui_core.UiNodeId) void {
    const idx = tree.resolveId(node_id) orelse return;
    const n = &tree.nodes.items[idx];
    n.style.bg_color = if (n.hovered) th.color(.item_hover, .floating) else .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    n.style.border_color = if (n.hovered) th.color(.menu_border, .floating) else .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    n.style.border_widths = if (n.hovered) .{ 1, 1, 1, 1 } else .{ 0, 0, 0, 0 };
}

/// Handles for a scrollable `listView` and its vertical scrollbar.
pub const ListViewHandles = struct {
    root: ui_core.UiNodeId,
    scroll_area: ui_core.UiNodeId,
    scroll_idx: usize,
    scrollbar: ui_core.UiNodeId,
    thumb: ui_core.UiNodeId,
};

/// Creates a scrollable list container with an attached vertical scrollbar.
pub fn listView(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *const theme.UiTheme,
    parent: ?usize,
    height_px: f32,
    tag: []const u8,
    level: theme.SurfaceLevel,
) !ListViewHandles {
    const root_idx = try tree.createNode(parent, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .row,
            .height = height_px,
            .min_height = height_px,
            .padding = 0,
            .gap = 2,
            .bg_color = th.color(.pane_body_bg, level),
            .border_color = th.color(.group_border, level),
            .border_widths = .{ 1, 1, 1, 1 },
            .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.corner_radius),
        },
    });

    const scroll_idx = try tree.createNode(root_idx, .{
        .id = "",
        .kind = .virtual_list,
        .scrollable = true,
        .style = .{
            .direction = .column,
            .width_spec = .{ .grow = 1.0 },
            .height = height_px - 2,
            .min_height = height_px - 2,
            .padding = 4,
            .gap = 2,
            .clip_children = true,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
    });

    const sb_idx = try tree.createNode(root_idx, .{
        .id = "",
        .kind = .custom,
        .cursor = .pointer,
        .style = .{
            .width = 8,
            .height = height_px - 2,
            .min_height = height_px - 2,
            .padding = 0,
            .bg_color = th.color(.scrollbar_bg, level),
        },
    });

    const thumb_idx = try tree.createNode(sb_idx, .{
        .id = "",
        .kind = .custom,
        .style = .{
            .position = .absolute,
            .left = 1,
            .top = 0,
            .width = 6,
            .height = 24,
            .min_height = 16,
            .padding = 0,
            .corner_radii = rounded.RoundedCorners.all.toRadii(3.0),
            .bg_color = th.color(.scrollbar_thumb, level),
        },
    });

    const root_id = tree.idOf(root_idx).?;
    const scroll_id = tree.idOf(scroll_idx).?;
    const sb_id = tree.idOf(sb_idx).?;
    const thumb_id = tree.idOf(thumb_idx).?;

    _ = try mgr.attach(scroll_id, tag, .{ .listbox = .{} });
    _ = try mgr.attach(sb_id, "", .{
        .scrollbar = .{
            .target_scroll = scroll_id,
            .thumb_node = thumb_id,
            .orientation = .vertical,
        },
    });

    return .{
        .root = root_id,
        .scroll_area = scroll_id,
        .scroll_idx = scroll_idx,
        .scrollbar = sb_id,
        .thumb = thumb_id,
    };
}

/// Appends a selectable row inside a `ListViewHandles.scroll_idx`.
pub fn listRow(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *const theme.UiTheme,
    lv: ListViewHandles,
    index: usize,
    label: []const u8,
    selected: bool,
) !ui_core.UiNodeId {
    const idx = try tree.createNode(lv.scroll_idx, .{
        .id = "",
        .kind = .button,
        .text = label,
        .focusable = true,
        .cursor = .pointer,
        .style = .{
            .min_height = theme.Metrics.row_height,
            .padding_edges = ui_core.Edges.xy(8, 4),
            .text_align = .left,
            .font_scale = theme.Metrics.font_medium,
            .bg_color = if (selected) th.color(.item_selected, .higher) else .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .text_color = th.color(.text_main, .higher),
            .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.corner_radius),
        },
    });
    tree.nodes.items[idx].selected = selected;
    const nid = tree.idOf(idx).?;
    _ = try mgr.attach(nid, "", .{
        .list_item = .{ .listbox_node = lv.scroll_area, .index = index },
    });
    return nid;
}

/// Synchronizes list row selection, hover highlight, and hover border.
pub fn syncListRow(tree: *ui_core.UiTree, th: *const theme.UiTheme, row_id: ui_core.UiNodeId) void {
    const idx = tree.resolveId(row_id) orelse return;
    const n = &tree.nodes.items[idx];
    n.style.bg_color = if (n.selected)
        th.color(.item_selected, .higher)
    else if (n.hovered)
        th.color(.item_hover, .higher)
    else
        .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    n.style.border_color = if (n.hovered) th.color(.field_border, .higher) else .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    n.style.border_widths = if (n.hovered) .{ 1, 1, 1, 1 } else .{ 0, 0, 0, 0 };
}

/// Handles for a `select` (ComboBox) control.
pub const SelectHandles = struct {
    menu_handles: MenuHandles,
    selected_idx: usize = 0,
};

/// Creates a `select` dropdown displaying `options[selected_idx]` with a popup option list.
pub fn select(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *const theme.UiTheme,
    parent: ?usize,
    options: []const []const u8,
    selected_idx: usize,
    tag_prefix: []const u8,
    level: theme.SurfaceLevel,
) !SelectHandles {
    const initial = if (selected_idx < options.len) options[selected_idx] else "";
    const mh = try menu(tree, mgr, th, parent, initial, level);
    if (tree.resolveId(mh.trigger.node)) |ti| {
        tree.nodes.items[ti].style.text_align = .left;
    }
    var item_parent_idx = mh.popup_idx;
    if (options.len > 6) {
        tree.nodes.items[mh.popup_idx].style.direction = .row;
        tree.nodes.items[mh.popup_idx].style.height = 160;
        tree.nodes.items[mh.popup_idx].style.padding = 2;
        tree.nodes.items[mh.popup_idx].style.gap = 2;

        item_parent_idx = try tree.createNode(mh.popup_idx, .{
            .id = "",
            .kind = .panel,
            .scrollable = true,
            .style = .{
                .direction = .column,
                .width_spec = .{ .grow = 1.0 },
                .height = 154,
                .min_height = 154,
                .padding = 2,
                .gap = 2,
                .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            },
        });
        const sb_idx = try tree.createNode(mh.popup_idx, .{
            .id = "",
            .kind = .panel,
            .cursor = .pointer,
            .style = .{
                .width = 8,
                .height = 154,
                .min_height = 154,
                .padding = 0,
                .bg_color = th.color(.scrollbar_bg, .floating),
                .corner_radii = rounded.RoundedCorners.all.toRadii(4.0),
            },
        });
        const thumb_idx = try tree.createNode(sb_idx, .{
            .id = "",
            .kind = .custom,
            .style = .{
                .position = .absolute,
                .left = 1,
                .top = 0,
                .width = 6,
                .height = 24,
                .min_height = 16,
                .padding = 0,
                .corner_radii = rounded.RoundedCorners.all.toRadii(3.0),
                .bg_color = th.color(.scrollbar_thumb, .floating),
            },
        });
        _ = try mgr.attach(tree.idOf(sb_idx).?, "", .{
            .scrollbar = .{
                .target_scroll = tree.idOf(item_parent_idx).?,
                .thumb_node = tree.idOf(thumb_idx).?,
                .orientation = .vertical,
            },
        });
    }
    if (mgr.findByNode(mh.popup)) |pb| {
        if (pb.behavior == .popover) {
            pb.behavior.popover.match_anchor_width = true;
        }
    }
    const item_mh = MenuHandles{
        .trigger = mh.trigger,
        .popup = mh.popup,
        .popup_idx = item_parent_idx,
    };
    for (options) |opt| {
        const item_id = try menuItem(tree, mgr, th, item_mh, opt, tag_prefix);
        if (mgr.findByNode(item_id)) |ib| {
            if (ib.behavior == .menu_item) {
                ib.behavior.menu_item.select_trigger = mh.trigger.node;
            }
        }
    }
    return .{ .menu_handles = mh, .selected_idx = selected_idx };
}

/// Handles for a modal `dialog` overlay.
pub const DialogHandles = struct {
    backdrop: ui_core.UiNodeId,
    panel: ui_core.UiNodeId,
    body: usize,
    footer: usize,
};

/// Creates a centered modal `dialog` in `UiLayer.modal`.
pub fn dialog(
    tree: *ui_core.UiTree,
    th: *const theme.UiTheme,
    title: []const u8,
    width_px: f32,
    height_px: f32,
    visible: bool,
) !DialogHandles {
    const backdrop_idx = try tree.createNode(null, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .position = .absolute,
            .layer = .modal,
            .visible = visible,
            .left = 0,
            .top = 0,
            .width_spec = .{ .percent = 100 },
            .height_spec = .{ .percent = 100 },
            .align_items = .center,
            .justify_content = .center,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0.55 },
        },
    });

    const panel_idx = try tree.createNode(backdrop_idx, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .column,
            .width = width_px,
            .height = height_px,
            .padding = 0,
            .gap = 0,
            .bg_color = th.color(.pane_body_bg, .floating),
            .border_color = th.color(.menu_border, .floating),
            .border_widths = .{ 1, 1, 1, 1 },
            .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.corner_radius),
        },
    });

    const hdr = try tree.createNode(panel_idx, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .row,
            .min_height = theme.Metrics.header_height,
            .padding_edges = ui_core.Edges.xy(10, 6),
            .bg_color = th.color(.pane_header_bg, .floating),
            .corner_radii = rounded.RoundedCorners.top.toRadii(theme.Metrics.corner_radius),
        },
    });
    if (title.len > 0) {
        _ = try tree.createNode(hdr, .{
            .id = "",
            .kind = .label,
            .text = title,
            .style = .{
                .padding = 0,
                .min_height = 16,
                .font_scale = theme.Metrics.font_header,
                .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .text_color = th.color(.text_main, .floating),
            },
        });
    }

    const body_idx = try tree.createNode(panel_idx, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .column,
            .width_spec = .{ .grow = 1.0 },
            .padding = 10,
            .gap = 6,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
    });

    const footer_idx = try tree.createNode(panel_idx, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .row,
            .position = .absolute,
            .left = 0,
            .bottom = 0,
            .width_spec = .{ .percent = 100 },
            .height = 38,
            .min_height = 38,
            .padding_edges = ui_core.Edges.xy(10, 6),
            .gap = 8,
            .align_items = .center,
            .justify_content = .end,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
    });

    return .{
        .backdrop = tree.idOf(backdrop_idx).?,
        .panel = tree.idOf(panel_idx).?,
        .body = body_idx,
        .footer = footer_idx,
    };
}

/// Attaches a lightweight hover `Tooltip` (~350ms delay, auto-flip, never steals focus) to `target_node`.
pub fn tooltip(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *const theme.UiTheme,
    target_node: ui_core.UiNodeId,
    text: []const u8,
    delay_ms: f32,
) !ui_core.UiNodeId {
    const popup_idx = try tree.createNode(null, .{
        .id = "",
        .kind = .panel,
        .pickable = false,
        .style = .{
            .position = .absolute,
            .layer = .overlay,
            .visible = false,
            .padding_edges = ui_core.Edges.xy(8, 4),
            .bg_color = th.color(.menu_bg, .floating),
            .border_color = th.color(.menu_border, .floating),
            .border_widths = .{ 1, 1, 1, 1 },
            .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.corner_radius),
        },
    });
    _ = try tree.createNode(popup_idx, .{
        .id = "",
        .kind = .label,
        .pickable = false,
        .text = text,
        .style = .{
            .padding = 0,
            .min_height = 14,
            .font_scale = theme.Metrics.font_small,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .text_color = th.color(.text_main, .floating),
        },
    });
    const popup_id = tree.idOf(popup_idx).?;
    _ = try mgr.attach(popup_id, "", .{
        .tooltip = .{
            .target_node = target_node,
            .delay_ms = delay_ms,
        },
    });
    return popup_id;
}

/// Creates a right-click `ContextMenu` anchored at the pointer position over `target_node`.
pub fn contextMenu(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *const theme.UiTheme,
    target_node: ui_core.UiNodeId,
) !MenuHandles {
    const popup_idx = try tree.createNode(null, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .column,
            .position = .absolute,
            .layer = .overlay,
            .visible = false,
            .width = 160,
            .min_width = 140,
            .padding = 4,
            .gap = 2,
            .bg_color = th.color(.menu_bg, .floating),
            .border_color = th.color(.menu_border, .floating),
            .border_widths = .{ 1, 1, 1, 1 },
            .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.corner_radius),
        },
    });
    const popup_id = tree.idOf(popup_idx).?;
    _ = try mgr.attach(popup_id, "", .{ .popover = .{ .anchor = target_node, .context_target = target_node } });
    return .{
        .trigger = .{ .node = target_node, .variant = .normal, .level = .floating },
        .popup = popup_id,
        .popup_idx = popup_idx,
    };
}

/// Handles for a confirmation `AlertDialog` with Enter/Esc shortcuts and confirm/cancel buttons.
pub const AlertDialogHandles = struct {
    dialog: DialogHandles,
    confirm_btn: ui_core.UiNodeId,
    cancel_btn: ui_core.UiNodeId,
    dismiss_on_outside: bool = true,
    open: bool = false,
};

/// Creates a confirmation `AlertDialog` (`Delete entity?`, etc.) with destructive confirm styling.
pub fn alertDialog(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *const theme.UiTheme,
    title: []const u8,
    message: []const u8,
    confirm_label: []const u8,
    cancel_label: []const u8,
    destructive: bool,
    visible: bool,
    tag_prefix: []const u8,
) !AlertDialogHandles {
    const dlg = try dialog(tree, th, title, 300, 145, visible);
    _ = try tree.createNode(dlg.body, .{
        .id = "",
        .kind = .label,
        .text = message,
        .style = .{
            .padding = 0,
            .min_height = 16,
            .font_scale = theme.Metrics.font_medium,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .text_color = th.color(.text_dim, .floating),
        },
    });
    const cancel_meta = try button.button(tree, mgr, th, dlg.footer, .{
        .label = cancel_label,
        .variant = .normal,
        .tag = tag_prefix,
        .level = .floating,
    });
    const confirm_meta = try button.button(tree, mgr, th, dlg.footer, .{
        .label = confirm_label,
        .variant = .primary,
        .tag = tag_prefix,
        .level = .floating,
    });
    if (destructive) {
        if (tree.resolveId(confirm_meta.node)) |ci| {
            tree.nodes.items[ci].style.bg_color = .{ .r = 0.72, .g = 0.18, .b = 0.20, .a = 1.0 };
        }
    }
    return .{
        .dialog = dlg,
        .confirm_btn = confirm_meta.node,
        .cancel_btn = cancel_meta.node,
        .open = visible,
    };
}

/// Synchronizes `AlertDialog` visibility and Enter/Esc/button dismissal; returns `true` if confirmed this frame.
pub fn syncAlertDialog(
    tree: *ui_core.UiTree,
    mgr: *const ui_widgets.WidgetManager,
    input: *const window.InputService,
    ad: *AlertDialogHandles,
) bool {
    var confirmed = false;
    if (ad.open) {
        if (input.wasKeyPressed(window.KeyCode.escape)) ad.open = false;
        if (ad.dismiss_on_outside and input.wasMouseClicked(.left)) {
            if (tree.hitTest(input.mouse_x, input.mouse_y)) |hit_idx| {
                if (tree.resolveId(ad.dialog.backdrop)) |bi| {
                    if (hit_idx == bi) ad.open = false;
                }
            }
        }
        if (input.wasKeyPressed(window.KeyCode.enter)) {
            ad.open = false;
            confirmed = true;
        }
        for (mgr.eventsSlice()) |ev| {
            if (ev.payload != .activate) continue;
            if (std.meta.eql(ev.node, ad.confirm_btn)) {
                ad.open = false;
                confirmed = true;
            } else if (std.meta.eql(ev.node, ad.cancel_btn)) {
                ad.open = false;
            }
        }
    }
    if (tree.resolveId(ad.dialog.backdrop)) |bi| {
        tree.nodes.items[bi].style.visible = ad.open;
    }
    return confirmed;
}

/// Screen edge for `Sheet` / `Drawer`.
pub const SheetSide = enum {
    left,
    right,
    bottom,
};

/// Handles for an edge-anchored `Sheet` / `Drawer`.
pub const SheetHandles = struct {
    backdrop: ui_core.UiNodeId,
    panel: ui_core.UiNodeId,
    close_btn: ui_core.UiNodeId,
    body: usize,
    side: SheetSide = .right,
    size_px: f32 = 260.0,
    anim_t: f32 = 0.0,
    dismiss_on_outside: bool = true,
    open: bool = false,
};

/// Creates an edge-anchored `Sheet` / `Drawer` (`left`, `right`, or `bottom`).
pub fn sheet(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *const theme.UiTheme,
    side: SheetSide,
    size_px: f32,
    title: []const u8,
    visible: bool,
    tag: []const u8,
) !SheetHandles {
    const backdrop_idx = try tree.createNode(null, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .position = .absolute,
            .layer = .modal,
            .visible = visible,
            .left = 0,
            .top = 0,
            .width_spec = .{ .percent = 100 },
            .height_spec = .{ .percent = 100 },
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = if (visible) 0.45 else 0.0 },
        },
    });
    const init_t: f32 = if (visible) 1.0 else 0.0;
    const offset = -size_px * (1.0 - init_t);
    const panel_idx = try tree.createNode(backdrop_idx, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .column,
            .position = .absolute,
            .left = if (side == .left) offset else if (side == .bottom) 0 else null,
            .right = if (side == .right) offset else null,
            .top = if (side != .bottom) 0 else null,
            .bottom = if (side == .bottom) offset else null,
            .width = if (side == .bottom) null else size_px,
            .width_spec = if (side == .bottom) .{ .percent = 100 } else .{ .auto = {} },
            .height = if (side == .bottom) size_px else null,
            .height_spec = if (side == .bottom) .{ .auto = {} } else .{ .percent = 100 },
            .padding = 0,
            .gap = 0,
            .bg_color = th.color(.pane_body_bg, .floating),
            .border_color = th.color(.menu_border, .floating),
            .border_widths = .{ 1, 1, 1, 1 },
        },
    });
    const hdr = try tree.createNode(panel_idx, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .row,
            .min_height = theme.Metrics.header_height,
            .padding_edges = ui_core.Edges.xy(10, 6),
            .justify_content = .space_between,
            .align_items = .center,
            .bg_color = th.color(.pane_header_bg, .floating),
        },
    });
    _ = try tree.createNode(hdr, .{
        .id = "",
        .kind = .label,
        .text = title,
        .style = .{
            .padding = 0,
            .min_height = 16,
            .font_scale = theme.Metrics.font_header,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .text_color = th.color(.text_main, .floating),
        },
    });
    const close_meta = try button.button(tree, mgr, th, hdr, .{
        .label = "X",
        .variant = .normal,
        .tag = tag,
        .level = .floating,
    });
    const body = try tree.createNode(panel_idx, .{
        .id = "",
        .kind = .panel,
        .scrollable = true,
        .style = .{
            .direction = .column,
            .width_spec = .{ .grow = 1.0 },
            .height_spec = .{ .grow = 1.0 },
            .padding = 10,
            .gap = 6,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
    });
    return .{
        .backdrop = tree.idOf(backdrop_idx).?,
        .panel = tree.idOf(panel_idx).?,
        .close_btn = close_meta.node,
        .body = body,
        .side = side,
        .size_px = size_px,
        .anim_t = init_t,
        .open = visible,
    };
}

/// Synchronizes `Sheet` close button and visibility immediately (headless/instant).
pub fn syncSheet(tree: *ui_core.UiTree, mgr: *const ui_widgets.WidgetManager, sh: *SheetHandles) void {
    syncSheetWithDt(tree, mgr, null, sh, 1.0);
}

/// Synchronizes `Sheet` close button, outside click, backdrop alpha, and smooth slide-in/slide-out animation.
pub fn syncSheetWithDt(tree: *ui_core.UiTree, mgr: *const ui_widgets.WidgetManager, input: ?*const window.InputService, sh: *SheetHandles, dt_s: f32) void {
    if (sh.open and sh.dismiss_on_outside) {
        if (input) |inp| {
            if (inp.wasKeyPressed(window.KeyCode.escape)) sh.open = false;
            if (inp.wasMouseClicked(.left)) {
                if (tree.hitTest(inp.mouse_x, inp.mouse_y)) |hit_idx| {
                    if (tree.resolveId(sh.backdrop)) |bi| {
                        if (hit_idx == bi) sh.open = false;
                    }
                }
            }
        }
    }
    for (mgr.eventsSlice()) |ev| {
        if (ev.payload == .activate and std.meta.eql(ev.node, sh.close_btn)) {
            sh.open = false;
        }
    }
    const speed: f32 = 6.5;
    if (sh.open) {
        sh.anim_t = @min(1.0, sh.anim_t + dt_s * speed);
    } else {
        sh.anim_t = @max(0.0, sh.anim_t - dt_s * speed);
    }
    const inv = 1.0 - sh.anim_t;
    const eased = 1.0 - inv * inv * inv;
    const vis = sh.open or sh.anim_t > 0.001;

    if (tree.resolveId(sh.backdrop)) |bi| {
        tree.nodes.items[bi].style.visible = vis;
        tree.nodes.items[bi].style.bg_color.a = 0.45 * eased;
    }
    if (tree.resolveId(sh.panel)) |pi| {
        const offset = -sh.size_px * (1.0 - eased);
        switch (sh.side) {
            .left => tree.nodes.items[pi].style.left = offset,
            .right => tree.nodes.items[pi].style.right = offset,
            .bottom => tree.nodes.items[pi].style.bottom = offset,
        }
    }
}

/// Visual severity for `Toast` notifications.
pub const ToastVariant = enum {
    info,
    success,
    warning,
    @"error",
};

/// Single active toast entry inside `ToastHost`.
pub const ToastEntry = struct {
    root: ui_core.UiNodeId = .{ .index = 0, .generation = 0 },
    close_btn: ui_core.UiNodeId = .{ .index = 0, .generation = 0 },
    action_btn: ?ui_core.UiNodeId = null,
    remaining_ms: f32 = 3500.0,
    alive: bool = false,
};

/// Stackable `Toast` / `Sonner` notification host anchored in `UiLayer.overlay`.
pub const ToastHost = struct {
    container: ui_core.UiNodeId,
    entries: [6]ToastEntry = @splat(.{}),

    /// Creates a bottom-right overlay `ToastHost`.
    pub fn init(tree: *ui_core.UiTree) !ToastHost {
        const idx = try tree.createNode(null, .{
            .id = "",
            .kind = .panel,
            .pickable = false,
            .style = .{
                .direction = .column,
                .position = .absolute,
                .layer = .overlay,
                .right = 14,
                .bottom = 14,
                .width = 320,
                .padding = 0,
                .gap = 6,
                .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            },
        });
        return .{ .container = tree.idOf(idx).? };
    }

    /// Pushes a new toast notification with optional quick-action button (`action_label`) and auto-dismiss timer (`duration_ms`).
    pub fn push(
        self: *ToastHost,
        tree: *ui_core.UiTree,
        mgr: *ui_widgets.WidgetManager,
        th: *const theme.UiTheme,
        variant: ToastVariant,
        message: []const u8,
        action_label: ?[]const u8,
        action_tag: []const u8,
        duration_ms: f32,
    ) !void {
        const cont_idx = tree.resolveId(self.container) orelse return;
        const border_col: graphics.Color = switch (variant) {
            .info => th.color(.focus_ring, .floating),
            .success => .{ .r = 0.24, .g = 0.72, .b = 0.44, .a = 1.0 },
            .warning => .{ .r = 0.88, .g = 0.62, .b = 0.16, .a = 1.0 },
            .@"error" => .{ .r = 0.88, .g = 0.26, .b = 0.28, .a = 1.0 },
        };
        const card_idx = try tree.createNode(cont_idx, .{
            .id = "",
            .kind = .panel,
            .style = .{
                .direction = .row,
                .width_spec = .{ .percent = 100 },
                .align_items = .center,
                .padding_edges = ui_core.Edges.xy(10, 8),
                .gap = 8,
                .bg_color = th.color(.menu_bg, .floating),
                .border_color = border_col,
                .border_widths = .{ 1, 1, 1, 3 },
                .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.corner_radius),
            },
        });
        _ = try tree.createNode(card_idx, .{
            .id = "",
            .kind = .label,
            .text = message,
            .style = .{
                .width_spec = .{ .grow = 1.0 },
                .padding = 0,
                .min_height = 16,
                .font_scale = theme.Metrics.font_medium,
                .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .text_color = th.color(.text_main, .floating),
            },
        });
        var act_id: ?ui_core.UiNodeId = null;
        if (action_label) |al| {
            const act = try button.button(tree, mgr, th, card_idx, .{
                .label = al,
                .variant = .primary,
                .tag = action_tag,
                .level = .floating,
            });
            act_id = act.node;
        }
        const cls = try button.button(tree, mgr, th, card_idx, .{
            .icon = .close_x,
            .variant = .plain,
            .tag = "",
            .level = .floating,
        });

        for (&self.entries) |*slot| {
            if (!slot.alive) {
                slot.* = .{
                    .root = tree.idOf(card_idx).?,
                    .close_btn = cls.node,
                    .action_btn = act_id,
                    .remaining_ms = duration_ms,
                    .alive = true,
                };
                return;
            }
        }
        // Evict slot 0 if full.
        if (tree.resolveId(self.entries[0].root)) |old_idx| tree.nodes.items[old_idx].style.visible = false;
        self.entries[0] = .{
            .root = tree.idOf(card_idx).?,
            .close_btn = cls.node,
            .action_btn = act_id,
            .remaining_ms = duration_ms,
            .alive = true,
        };
    }

    /// Advances auto-dismiss timers (`dt_ms`) and hides dismissed toasts.
    pub fn update(self: *ToastHost, tree: *ui_core.UiTree, mgr: *const ui_widgets.WidgetManager, dt_ms: f32) void {
        for (&self.entries) |*slot| {
            if (!slot.alive) continue;
            var dismiss = false;
            slot.remaining_ms -= dt_ms;
            if (slot.remaining_ms <= 0.0) dismiss = true;
            for (mgr.eventsSlice()) |ev| {
                if (ev.payload == .activate and std.meta.eql(ev.node, slot.close_btn)) dismiss = true;
            }
            if (dismiss) {
                if (tree.resolveId(slot.root)) |ri| tree.nodes.items[ri].style.visible = false;
                slot.alive = false;
            }
        }
    }
};
