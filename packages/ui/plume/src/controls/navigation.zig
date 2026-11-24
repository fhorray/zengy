//! Navigation & Productivity Controls: Menubar, Breadcrumb & CommandPalette (`official.ui.plume`).

const std = @import("std");
const window = @import("window");
const ui_core = @import("ui_core");
const ui_widgets = @import("ui_widgets");
const theme = @import("../theme.zig");
const rounded = @import("../rounded_corners.zig");
const overlays = @import("overlays.zig");
const inputs = @import("inputs.zig");
const button = @import("button.zig");

/// Creates a top-level `Menubar` container (`row` with tight spacing).
pub fn menubar(
    tree: *ui_core.UiTree,
    th: *const theme.UiTheme,
    parent: ?usize,
    level: theme.SurfaceLevel,
) !usize {
    return tree.createNode(parent, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .row,
            .min_height = theme.Metrics.header_height,
            .padding_edges = ui_core.Edges.xy(6, 2),
            .gap = 4,
            .align_items = .center,
            .bg_color = th.color(.pane_header_bg, level),
            .border_color = th.color(.group_border, level),
            .border_widths = .{ 0, 0, 1, 0 },
        },
    });
}

/// Appends a hover-switchable `Menubar` menu trigger (`File`, `Edit`, `View`, `Help`) sharing `menubar_group`.
pub fn menubarMenu(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *const theme.UiTheme,
    bar_idx: usize,
    label: []const u8,
    menubar_group: u32,
    level: theme.SurfaceLevel,
) !overlays.MenuHandles {
    const mh = try overlays.menu(tree, mgr, th, bar_idx, label, level);
    if (mgr.findByNode(mh.trigger.node)) |tb| {
        if (tb.behavior == .menu_trigger) tb.behavior.menu_trigger.menubar_group = menubar_group;
    }
    return mh;
}

/// Handles for a clickable `Breadcrumb` trail (`Assets > Characters > Hero.gltf`).
pub const BreadcrumbHandles = struct {
    root: usize,
    items: [12]?ui_core.UiNodeId = @splat(null),
    count: usize = 0,
};

/// Creates a clickable `Breadcrumb` path trail (up to 12 segments).
pub fn breadcrumb(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *const theme.UiTheme,
    parent: ?usize,
    segments: []const []const u8,
    tag: []const u8,
    level: theme.SurfaceLevel,
) !BreadcrumbHandles {
    const root = try tree.createNode(parent, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .row,
            .padding = 0,
            .gap = 4,
            .align_items = .center,
            .min_height = 20,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
    });
    var handles = BreadcrumbHandles{ .root = root };
    const n = @min(segments.len, 12);
    handles.count = n;
    for (0..n) |i| {
        if (i > 0) {
            _ = try tree.createNode(root, .{
                .id = "",
                .kind = .custom,
                .pickable = false,
                .style = .{ .width = 10, .height = 10, .min_height = 10, .padding = 0, .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
                .paint_extra = .{ .icon = .{ .kind = .chevron_right, .size = 9, .color = th.color(.text_dim, level) } },
            });
        }
        const is_last = (i + 1 == n);
        const btn = try tree.createNode(root, .{
            .id = "",
            .kind = .button,
            .text = segments[i],
            .focusable = true,
            .cursor = .pointer,
            .style = .{
                .min_height = 18,
                .padding_edges = ui_core.Edges.xy(4, 2),
                .font_scale = theme.Metrics.font_small,
                .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .text_color = th.color(if (is_last) .text_main else .text_dim, level),
            },
        });
        const bid = tree.idOf(btn).?;
        handles.items[i] = bid;
        _ = try mgr.attach(bid, tag, .{ .button = .{} });
    }
    return handles;
}

/// Entry definition for `CommandPalette`.
pub const CommandEntry = struct {
    label: []const u8,
    shortcut: []const u8 = "",
    tag: []const u8 = "",
};

/// Handles for a `Ctrl+K` `CommandPalette` modal with fuzzy search and right-aligned shortcuts.
pub const CommandPaletteHandles = struct {
    backdrop: ui_core.UiNodeId,
    search_input: ui_core.UiNodeId,
    row_nodes: [24]?ui_core.UiNodeId = @splat(null),
    btn_nodes: [24]?ui_core.UiNodeId = @splat(null),
    count: usize = 0,
    dismiss_on_outside: bool = true,
    open: bool = false,
};

/// Creates a centered `CommandPalette` modal (`Ctrl+K` to toggle, real-time fuzzy filter, `Esc` to close).
pub fn commandPalette(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *const theme.UiTheme,
    entries: []const CommandEntry,
    visible: bool,
) !CommandPaletteHandles {
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
            .padding_edges = .{ .top = 60, .bottom = 0, .left = 0, .right = 0 },
            .align_items = .center,
            .justify_content = .start,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0.45 },
        },
    });
    const panel_idx = try tree.createNode(backdrop_idx, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .column,
            .width = 380,
            .padding = 8,
            .gap = 6,
            .bg_color = th.color(.menu_bg, .floating),
            .border_color = th.color(.menu_border, .floating),
            .border_widths = .{ 1, 1, 1, 1 },
            .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.corner_radius),
        },
    });
    const search_id = try inputs.textInput(tree, mgr, th, panel_idx, .{
        .text = "",
        .tag = "cmd_search",
        .level = .floating,
    });
    const list_idx = try tree.createNode(panel_idx, .{
        .id = "",
        .kind = .panel,
        .scrollable = true,
        .style = .{
            .direction = .column,
            .height = 200,
            .padding = 0,
            .gap = 2,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
    });

    var handles = CommandPaletteHandles{
        .backdrop = tree.idOf(backdrop_idx).?,
        .search_input = search_id,
        .open = visible,
    };
    const n = @min(entries.len, 24);
    handles.count = n;
    for (0..n) |i| {
        const e = entries[i];
        const row_idx = try tree.createNode(list_idx, .{
            .id = "",
            .kind = .panel,
            .style = .{
                .direction = .row,
                .align_items = .center,
                .justify_content = .space_between,
                .padding_edges = ui_core.Edges.xy(8, 3),
                .min_height = theme.Metrics.row_height,
                .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            },
        });
        const btn_meta = try button.button(tree, mgr, th, row_idx, .{
            .label = e.label,
            .variant = .normal,
            .tag = e.tag,
            .level = .floating,
        });
        if (tree.resolveId(btn_meta.node)) |bi| {
            tree.nodes.items[bi].style.width_spec = .{ .grow = 1.0 };
            tree.nodes.items[bi].style.text_align = .left;
            tree.nodes.items[bi].style.bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
            tree.nodes.items[bi].style.border_widths = .{ 0, 0, 0, 0 };
        }
        if (e.shortcut.len > 0) {
            _ = try tree.createNode(row_idx, .{
                .id = "",
                .kind = .label,
                .pickable = false,
                .text = e.shortcut,
                .style = .{
                    .padding = 0,
                    .min_height = 14,
                    .font_scale = theme.Metrics.font_small,
                    .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                    .text_color = th.color(.text_dim, .floating),
                },
            });
        }
        handles.row_nodes[i] = tree.idOf(row_idx).?;
        handles.btn_nodes[i] = btn_meta.node;
    }
    return handles;
}

/// Handles `Ctrl+K` toggle, `Esc` dismiss, and real-time fuzzy filtering on `CommandPalette`.
pub fn syncCommandPalette(
    tree: *ui_core.UiTree,
    mgr: *const ui_widgets.WidgetManager,
    input: *const window.InputService,
    th: *const theme.UiTheme,
    cp: *CommandPaletteHandles,
) void {
    if (input.modifiers.ctrl and input.wasKeyPressed(window.KeyCode.a + 10)) { // 'K' = 4 + 10 = 14
        cp.open = !cp.open;
        if (cp.open) {
            if (tree.resolveId(cp.search_input)) |si| tree.setFocus(si, false);
        }
    }
    if (cp.open and input.wasKeyPressed(window.KeyCode.escape)) cp.open = false;
    if (cp.open and cp.dismiss_on_outside and input.wasMouseClicked(.left)) {
        if (tree.hitTest(input.mouse_x, input.mouse_y)) |hit_idx| {
            if (tree.resolveId(cp.backdrop)) |bi| {
                if (hit_idx == bi) cp.open = false;
            }
        }
    }

    if (cp.open) {
        const query = if (tree.resolveId(cp.search_input)) |si| tree.nodes.items[si].text else "";
        for (0..cp.count) |i| {
            if (cp.row_nodes[i]) |rid| {
                if (tree.resolveId(rid)) |ri| {
                    const label = if (cp.btn_nodes[i]) |bid|
                        (if (tree.resolveId(bid)) |bi| tree.nodes.items[bi].text else "")
                    else
                        "";
                    const vis = fuzzyMatch(label, query);
                    tree.nodes.items[ri].style.visible = vis;
                    if (cp.btn_nodes[i]) |bid| {
                        if (tree.resolveId(bid)) |bi| {
                            tree.nodes.items[ri].style.bg_color = if (tree.nodes.items[bi].hovered)
                                th.color(.item_hover, .floating)
                            else
                                .{ .r = 0, .g = 0, .b = 0, .a = 0 };
                        }
                    }
                }
            }
        }
        for (mgr.eventsSlice()) |ev| {
            if (ev.payload != .activate) continue;
            for (0..cp.count) |i| {
                if (cp.btn_nodes[i]) |bid| {
                    if (std.meta.eql(ev.node, bid)) cp.open = false;
                }
            }
        }
    }

    if (tree.resolveId(cp.backdrop)) |bi| tree.nodes.items[bi].style.visible = cp.open;
}

fn fuzzyMatch(haystack: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    var qi: usize = 0;
    for (haystack) |hc| {
        if (std.ascii.toLower(hc) == std.ascii.toLower(query[qi])) {
            qi += 1;
            if (qi == query.len) return true;
        }
    }
    return false;
}
