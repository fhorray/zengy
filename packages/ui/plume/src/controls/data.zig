//! Customizable Sortable Data Table / DataGrid (`official.ui.plume`).

const std = @import("std");
const graphics = @import("graphics");
const ui_core = @import("ui_core");
const ui_widgets = @import("ui_widgets");
const theme = @import("../theme.zig");
const rounded = @import("../rounded_corners.zig");

/// Column definition for `table`.
pub const TableColumn = struct {
    header: []const u8,
    width: ?f32 = null,
    flex: f32 = 1.0,
    text_align: ui_core.TextAlign = .left,
};

/// Customization options for `table`.
pub const TableOptions = struct {
    striped: bool = true,
    row_dividers: bool = true,
    hover_highlight: bool = true,
    selectable: bool = true,
    show_scrollbar: bool = true,
    row_height: f32 = 24.0,
    body_height: f32 = 100.0,
    level: theme.SurfaceLevel = .base,
};

/// Handles for a sortable, scrollable, customizable `Table` / `DataGrid` (up to 8 columns, 32 rows).
pub const TableHandles = struct {
    root: usize,
    scroll_idx: usize,
    header_btns: [8]?ui_core.UiNodeId = @splat(null),
    row_nodes: [32]?ui_core.UiNodeId = @splat(null),
    cell_nodes: [32][8]?ui_core.UiNodeId = @splat(@as([8]?ui_core.UiNodeId, @splat(null))),
    col_count: usize = 0,
    row_count: usize = 0,
    sort_col: ?usize = null,
    sort_asc: bool = true,
    selected_row: ?usize = null,
    opts: TableOptions = .{},
};

/// Creates a customizable `Table` / `DataGrid` with sortable headers, row hover/selection, and optional scrollbar.
pub fn table(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *const theme.UiTheme,
    parent: ?usize,
    columns: []const TableColumn,
    rows: []const []const []const u8,
    opts: TableOptions,
    tag: []const u8,
) !TableHandles {
    const level = opts.level;
    const hdr_lvl: theme.SurfaceLevel = if (level == .base) .higher else .highest;
    const root = try tree.createNode(parent, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .column,
            .padding = 0,
            .gap = 0,
            .bg_color = th.color(.pane_body_bg, level),
            .border_color = th.color(.group_border, level),
            .border_widths = .{ 1, 1, 1, 1 },
            .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.corner_radius),
        },
    });
    const hdr_row = try tree.createNode(root, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .row,
            .min_height = theme.Metrics.row_height + 2,
            .padding_edges = ui_core.Edges.xy(6, 2),
            .gap = 6,
            .align_items = .center,
            .bg_color = th.color(.subpane_header_bg, hdr_lvl),
            .border_color = th.color(.group_border, level),
            .border_widths = .{ 0, 0, 1, 0 },
        },
    });

    var handles = TableHandles{
        .root = root,
        .scroll_idx = 0,
        .col_count = @min(columns.len, 8),
        .row_count = @min(rows.len, 32),
        .opts = opts,
    };
    for (0..handles.col_count) |ci| {
        const col = columns[ci];
        const hb = try tree.createNode(hdr_row, .{
            .id = "",
            .kind = .button,
            .text = col.header,
            .focusable = true,
            .cursor = .pointer,
            .style = .{
                .width = col.width,
                .width_spec = if (col.width == null) .{ .grow = col.flex } else .{ .auto = {} },
                .min_height = 20,
                .padding_edges = ui_core.Edges.xy(4, 2),
                .text_align = col.text_align,
                .font_scale = theme.Metrics.font_small,
                .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .text_color = th.color(.text_main, hdr_lvl),
            },
        });
        const hid = tree.idOf(hb).?;
        handles.header_btns[ci] = hid;
        _ = try mgr.attach(hid, tag, .{ .button = .{} });
    }

    const body_wrap = try tree.createNode(root, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .row,
            .height = opts.body_height,
            .min_height = opts.body_height,
            .padding = 0,
            .gap = 2,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
    });

    const scroll_idx = try tree.createNode(body_wrap, .{
        .id = "",
        .kind = .panel,
        .scrollable = true,
        .style = .{
            .direction = .column,
            .width_spec = .{ .grow = 1.0 },
            .height = opts.body_height,
            .min_height = opts.body_height,
            .padding = 2,
            .gap = 0,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
    });
    handles.scroll_idx = scroll_idx;

    if (opts.show_scrollbar) {
        const sb_idx = try tree.createNode(body_wrap, .{
            .id = "",
            .kind = .custom,
            .cursor = .pointer,
            .style = .{
                .width = 8,
                .height = opts.body_height,
                .min_height = opts.body_height,
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
        _ = try mgr.attach(tree.idOf(sb_idx).?, "", .{
            .scrollbar = .{
                .target_scroll = tree.idOf(scroll_idx).?,
                .thumb_node = tree.idOf(thumb_idx).?,
                .orientation = .vertical,
            },
        });
    }

    for (0..handles.row_count) |ri| {
        const r_idx = try tree.createNode(scroll_idx, .{
            .id = "",
            .kind = if (opts.selectable) .button else .panel,
            .focusable = opts.selectable,
            .cursor = if (opts.selectable) .pointer else .default,
            .style = .{
                .direction = .row,
                .min_height = opts.row_height,
                .padding_edges = ui_core.Edges.xy(6, 2),
                .gap = 6,
                .align_items = .center,
                .bg_color = if (opts.striped and ri % 2 == 1) th.color(.subpane_body_bg, level) else .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .border_color = if (opts.row_dividers) th.color(.group_border, level) else .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .border_widths = if (opts.row_dividers) .{ 0, 0, 1, 0 } else .{ 0, 0, 0, 0 },
            },
        });
        const rid = tree.idOf(r_idx).?;
        handles.row_nodes[ri] = rid;
        if (opts.selectable) {
            _ = try mgr.attach(rid, tag, .{ .button = .{} });
        }
        for (0..handles.col_count) |ci| {
            const col = columns[ci];
            const txt = if (ci < rows[ri].len) rows[ri][ci] else "";
            const c_idx = try tree.createNode(r_idx, .{
                .id = "",
                .kind = .label,
                .pickable = false,
                .text = txt,
                .style = .{
                    .width = col.width,
                    .width_spec = if (col.width == null) .{ .grow = col.flex } else .{ .auto = {} },
                    .min_height = opts.row_height - 4,
                    .padding_edges = ui_core.Edges.xy(4, 1),
                    .text_align = col.text_align,
                    .font_scale = theme.Metrics.font_small,
                    .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                    .text_color = th.color(.text_main, level),
                },
            });
            handles.cell_nodes[ri][ci] = tree.idOf(c_idx).?;
        }
    }
    return handles;
}

/// Handles header sorting, row hover highlights, and row selection on `TableHandles`.
pub fn syncTable(tree: *ui_core.UiTree, mgr: *const ui_widgets.WidgetManager, th: *const theme.UiTheme, tbl: *TableHandles) void {
    var clicked_col: ?usize = null;
    for (mgr.eventsSlice()) |ev| {
        if (ev.payload != .activate) continue;
        for (0..tbl.col_count) |ci| {
            if (tbl.header_btns[ci]) |hid| {
                if (std.meta.eql(ev.node, hid)) clicked_col = ci;
            }
        }
        if (tbl.opts.selectable) {
            for (0..tbl.row_count) |ri| {
                if (tbl.row_nodes[ri]) |rid| {
                    if (std.meta.eql(ev.node, rid)) tbl.selected_row = ri;
                }
            }
        }
    }
    if (clicked_col) |sort_c| {
        if (tbl.sort_col == sort_c) {
            tbl.sort_asc = !tbl.sort_asc;
        } else {
            tbl.sort_col = sort_c;
            tbl.sort_asc = true;
        }
        const children = &tree.nodes.items[tbl.scroll_idx].children;
        if (children.items.len >= 2) {
            var i: usize = 0;
            while (i < tbl.row_count) : (i += 1) {
                var j: usize = 0;
                while (j + 1 < tbl.row_count - i) : (j += 1) {
                    const a_txt = cellText(tree, tbl.cell_nodes[j][sort_c]);
                    const b_txt = cellText(tree, tbl.cell_nodes[j + 1][sort_c]);
                    const ord = std.mem.order(u8, a_txt, b_txt);
                    const swap = if (tbl.sort_asc) ord == .gt else ord == .lt;
                    if (swap) {
                        std.mem.swap(?ui_core.UiNodeId, &tbl.row_nodes[j], &tbl.row_nodes[j + 1]);
                        std.mem.swap([8]?ui_core.UiNodeId, &tbl.cell_nodes[j], &tbl.cell_nodes[j + 1]);
                        std.mem.swap(usize, &children.items[j], &children.items[j + 1]);
                    }
                }
            }
        }
        for (0..tbl.col_count) |ci| {
            if (tbl.header_btns[ci]) |hid| {
                if (tree.resolveId(hid)) |hi| {
                    tree.nodes.items[hi].style.text_color = if (ci == sort_c)
                        th.color(.text_accent, .higher)
                    else
                        th.color(.text_main, .higher);
                }
            }
        }
    }

    // Update row selection & hover backgrounds.
    for (0..tbl.row_count) |ri| {
        if (tbl.row_nodes[ri]) |rid| {
            if (tree.resolveId(rid)) |r_idx| {
                const is_sel = (tbl.selected_row == ri);
                const is_hov = tbl.opts.hover_highlight and tree.nodes.items[r_idx].hovered;
                tree.nodes.items[r_idx].selected = is_sel;
                tree.nodes.items[r_idx].style.bg_color = if (is_sel)
                    th.color(.item_selected, tbl.opts.level)
                else if (is_hov)
                    th.color(.item_hover, tbl.opts.level)
                else if (tbl.opts.striped and ri % 2 == 1)
                    th.color(.subpane_body_bg, tbl.opts.level)
                else
                    graphics.Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
            }
        }
    }
}

fn cellText(tree: *const ui_core.UiTree, maybe_id: ?ui_core.UiNodeId) []const u8 {
    const id = maybe_id orelse return "";
    const idx = tree.resolveId(id) orelse return "";
    return tree.nodes.items[idx].text;
}
