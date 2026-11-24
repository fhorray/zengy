//! Hierarchical Layout Containers for `ui-plume` (`official.ui.plume`).
//!
//! Provides `pane`, `subpane`, `group`, and `flexSpacer` builders propagating
//! `SurfaceLevel` context down to child controls.

const ui_core = @import("ui_core");
const theme = @import("theme.zig");
const rounded = @import("rounded_corners.zig");

/// Container handles returned by `pane` / `subpane` / `group`.
pub const ContainerHandles = struct {
    root: usize,
    header: usize,
    body: usize,
};

/// Creates a standard editor pane (`Base` header + `Higher` body).
pub fn pane(
    tree: *ui_core.UiTree,
    parent: ?usize,
    th: *const theme.UiTheme,
    title: []const u8,
) !ContainerHandles {
    const root = try tree.createNode(parent, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .column,
            .padding = 0,
            .gap = 0,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
    });

    const header = try tree.createNode(root, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .row,
            .min_height = theme.Metrics.header_height,
            .padding_edges = ui_core.Edges.xy(8, 6),
            .gap = 6,
            .align_items = .center,
            .bg_color = th.color(.pane_header_bg, .base),
            .border_color = th.color(.pane_header_border, .base),
            .border_widths = .{ 1, 1, 0, 1 },
            .corner_radii = rounded.RoundedCorners.top.toRadii(theme.Metrics.corner_radius),
        },
    });

    if (title.len > 0) {
        _ = try tree.createNode(header, .{
            .id = "",
            .kind = .label,
            .text = title,
            .style = .{
                .padding = 0,
                .min_height = 16,
                .font_scale = theme.Metrics.font_medium,
                .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .text_color = th.color(.pane_header_text, .base),
            },
        });
    }

    const body = try tree.createNode(root, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .column,
            .padding = 6,
            .gap = 4,
            .bg_color = th.color(.pane_body_bg, .higher),
            .corner_radii = rounded.RoundedCorners.bottom.toRadii(theme.Metrics.corner_radius),
        },
    });

    return .{ .root = root, .header = header, .body = body };
}

/// Creates a vertical 1px divider inside a `pane` header.
pub fn paneHeaderDivider(tree: *ui_core.UiTree, header_idx: usize, th: *const theme.UiTheme) !usize {
    return tree.createNode(header_idx, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .width = 1,
            .min_height = 18,
            .padding = 0,
            .bg_color = th.color(.pane_header_divider, .base),
        },
    });
}

/// Creates a bordered sub-pane (`Highest` header + `Higher` body).
pub fn subpane(
    tree: *ui_core.UiTree,
    parent: ?usize,
    th: *const theme.UiTheme,
    title: []const u8,
) !ContainerHandles {
    const root = try tree.createNode(parent, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .column,
            .padding = 0,
            .gap = 0,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
    });

    const header = try tree.createNode(root, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .row,
            .min_height = theme.Metrics.header_height,
            .padding_edges = ui_core.Edges.xy(10, 4),
            .gap = 4,
            .align_items = .center,
            .bg_color = th.color(.subpane_header_bg, .highest),
            .border_color = th.color(.subpane_header_border, .highest),
            .border_widths = .{ 1, 1, 0, 1 },
            .corner_radii = rounded.RoundedCorners.top.toRadii(theme.Metrics.corner_radius),
        },
    });

    if (title.len > 0) {
        _ = try tree.createNode(header, .{
            .id = "",
            .kind = .label,
            .text = title,
            .style = .{
                .padding = 0,
                .min_height = 16,
                .font_scale = theme.Metrics.font_medium,
                .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .text_color = th.color(.subpane_header_text, .highest),
            },
        });
    }

    const body = try tree.createNode(root, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .column,
            .padding = 6,
            .gap = 4,
            .bg_color = th.color(.subpane_body_bg, .higher),
            .border_color = th.color(.subpane_body_border, .higher),
            .border_widths = .{ 0, 1, 1, 1 },
            .corner_radii = rounded.RoundedCorners.bottom.toRadii(theme.Metrics.corner_radius),
        },
    });

    return .{ .root = root, .header = header, .body = body };
}

/// Creates a raised property group (`Highest` surface with full border).
pub fn group(
    tree: *ui_core.UiTree,
    parent: ?usize,
    th: *const theme.UiTheme,
    title: []const u8,
) !ContainerHandles {
    const root = try tree.createNode(parent, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .column,
            .padding = 0,
            .gap = 0,
            .bg_color = th.color(.group_bg, .highest),
            .border_color = th.color(.group_border, .highest),
            .border_widths = .{ 1, 1, 1, 1 },
            .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.corner_radius),
        },
    });

    const header = try tree.createNode(root, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .row,
            .min_height = theme.Metrics.header_height,
            .padding_edges = ui_core.Edges.xy(10, 4),
            .gap = 4,
            .align_items = .center,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
    });

    if (title.len > 0) {
        _ = try tree.createNode(header, .{
            .id = "",
            .kind = .label,
            .text = title,
            .style = .{
                .padding = 0,
                .min_height = 16,
                .font_scale = theme.Metrics.font_medium,
                .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .text_color = th.color(.group_header_text, .highest),
            },
        });
    }

    const body = try tree.createNode(root, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .column,
            .padding = 6,
            .gap = 4,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
    });

    return .{ .root = root, .header = header, .body = body };
}

/// Creates a growing spacer inside a `row` or `column` container.
pub fn flexSpacer(tree: *ui_core.UiTree, parent: usize) !usize {
    return tree.createNode(parent, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .width_spec = .{ .grow = 1.0 },
            .min_height = 1,
            .padding = 0,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
    });
}

/// Handles for a structured `Card` (`header`, `content`, `footer`).
pub const CardHandles = struct {
    root: usize,
    header: usize,
    content: usize,
    footer: usize,
};

/// Creates a structured `Card` with `header`, `content`, and `footer` sections.
pub fn card(
    tree: *ui_core.UiTree,
    parent: ?usize,
    th: *const theme.UiTheme,
    level: theme.SurfaceLevel,
    title: []const u8,
    subtitle: []const u8,
) !CardHandles {
    const inner_lvl: theme.SurfaceLevel = if (level == .base) .higher else .highest;
    const root = try tree.createNode(parent, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .column,
            .padding = 0,
            .gap = 0,
            .bg_color = th.color(.subpane_body_bg, level),
            .border_color = th.color(.subpane_body_border, level),
            .border_widths = .{ 1, 1, 1, 1 },
            .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.corner_radius),
        },
    });
    const header = try tree.createNode(root, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .column,
            .padding_edges = ui_core.Edges.xy(10, 8),
            .gap = 2,
            .bg_color = th.color(.subpane_header_bg, inner_lvl),
            .border_color = th.color(.subpane_header_border, inner_lvl),
            .border_widths = .{ 0, 0, 1, 0 },
        },
    });
    if (title.len > 0) {
        _ = try tree.createNode(header, .{
            .id = "",
            .kind = .label,
            .text = title,
            .style = .{
                .padding = 0,
                .min_height = 16,
                .font_scale = theme.Metrics.font_medium,
                .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .text_color = th.color(.text_main, inner_lvl),
            },
        });
    }
    if (subtitle.len > 0) {
        _ = try tree.createNode(header, .{
            .id = "",
            .kind = .label,
            .text = subtitle,
            .style = .{
                .padding = 0,
                .min_height = 14,
                .font_scale = theme.Metrics.font_small,
                .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .text_color = th.color(.text_dim, inner_lvl),
            },
        });
    }
    const content = try tree.createNode(root, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .column,
            .padding = 10,
            .gap = 6,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
    });
    const footer = try tree.createNode(root, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .row,
            .padding_edges = ui_core.Edges.xy(10, 6),
            .gap = 6,
            .align_items = .center,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .border_color = th.color(.subpane_body_border, level),
            .border_widths = .{ 1, 0, 0, 0 },
        },
    });
    return .{ .root = root, .header = header, .content = content, .footer = footer };
}
