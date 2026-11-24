//! Display Elements (Labels, Vector Icons, Badges, Chips, Alerts, Separators & Progress/Spinners) for `ui-plume` (`official.ui.plume`).

const std = @import("std");
const graphics = @import("graphics");
const ui_core = @import("ui_core");
const ui_widgets = @import("ui_widgets");
const theme = @import("theme.zig");
const rounded = @import("rounded_corners.zig");

/// Text emphasis variants for `label`.
pub const LabelTone = enum {
    main,
    dim,
    accent,
    small,
};

/// Creates a themed text label node.
pub fn label(
    tree: *ui_core.UiTree,
    parent: ?usize,
    th: *const theme.UiTheme,
    level: theme.SurfaceLevel,
    text: []const u8,
    tone: LabelTone,
) !usize {
    const col = switch (tone) {
        .main, .small => th.color(.text_main, level),
        .dim => th.color(.text_dim, level),
        .accent => th.color(.text_accent, level),
    };
    const scale: f32 = if (tone == .small) theme.Metrics.font_small else theme.Metrics.font_medium;
    return tree.createNode(parent, .{
        .id = "",
        .kind = .label,
        .text = text,
        .style = .{
            .padding = 0,
            .min_height = 16,
            .font_scale = scale,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .text_color = col,
        },
    });
}

/// Creates a themed geometric vector icon node.
pub fn icon(
    tree: *ui_core.UiTree,
    parent: ?usize,
    th: *const theme.UiTheme,
    level: theme.SurfaceLevel,
    kind: graphics.IconKind,
    size_px: f32,
) !usize {
    return tree.createNode(parent, .{
        .id = "",
        .kind = .custom,
        .style = .{
            .width = size_px,
            .height = size_px,
            .min_height = size_px,
            .padding = 0,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
        .paint_extra = .{
            .icon = .{
                .kind = kind,
                .size = size_px,
                .color = th.color(.text_main, level),
            },
        },
    });
}

/// Visual tone for `badge`, `chip`, and `alert`.
pub const StatusTone = enum {
    neutral,
    accent,
    success,
    warning,
    danger,
};

fn toneColors(th: *const theme.UiTheme, level: theme.SurfaceLevel, tone: StatusTone) struct {
    bg: graphics.Color,
    border: graphics.Color,
    fg: graphics.Color,
} {
    return switch (tone) {
        .neutral => .{
            .bg = .{ .r = 0.20, .g = 0.21, .b = 0.24, .a = 0.90 },
            .border = th.color(.field_border, level),
            .fg = th.color(.text_main, level),
        },
        .accent => .{
            .bg = .{ .r = 0.13, .g = 0.31, .b = 0.56, .a = 0.35 },
            .border = .{ .r = 0.25, .g = 0.55, .b = 0.92, .a = 0.85 },
            .fg = .{ .r = 0.78, .g = 0.90, .b = 1.0, .a = 1.0 },
        },
        .success => .{
            .bg = .{ .r = 0.11, .g = 0.36, .b = 0.22, .a = 0.35 },
            .border = .{ .r = 0.22, .g = 0.72, .b = 0.44, .a = 0.85 },
            .fg = .{ .r = 0.74, .g = 0.96, .b = 0.82, .a = 1.0 },
        },
        .warning => .{
            .bg = .{ .r = 0.48, .g = 0.32, .b = 0.08, .a = 0.28 },
            .border = .{ .r = 0.88, .g = 0.62, .b = 0.18, .a = 0.85 },
            .fg = .{ .r = 0.98, .g = 0.88, .b = 0.64, .a = 1.0 },
        },
        .danger => .{
            .bg = .{ .r = 0.48, .g = 0.14, .b = 0.16, .a = 0.35 },
            .border = .{ .r = 0.88, .g = 0.30, .b = 0.32, .a = 0.85 },
            .fg = .{ .r = 1.0, .g = 0.80, .b = 0.80, .a = 1.0 },
        },
    };
}

/// Creates a compact status badge (`v0.2.0`, `Running`, `3 Errors`).
pub fn badge(
    tree: *ui_core.UiTree,
    parent: ?usize,
    th: *const theme.UiTheme,
    level: theme.SurfaceLevel,
    text: []const u8,
    tone: StatusTone,
) !usize {
    const cols = toneColors(th, level, tone);
    const est_w = @as(f32, @floatFromInt(text.len)) * 7.5 + 16.0;
    const pill = try tree.createNode(parent, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .row,
            .width = est_w,
            .padding_edges = ui_core.Edges.xy(8, 2),
            .min_height = 20,
            .align_items = .center,
            .justify_content = .center,
            .bg_color = cols.bg,
            .border_color = cols.border,
            .border_widths = .{ 1, 1, 1, 1 },
            .corner_radii = rounded.RoundedCorners.all.toRadii(4.0),
        },
    });
    _ = try tree.createNode(pill, .{
        .id = "",
        .kind = .label,
        .pickable = false,
        .text = text,
        .style = .{
            .padding = 0,
            .min_height = 14,
            .text_align = .center,
            .font_scale = theme.Metrics.font_small,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .text_color = cols.fg,
        },
    });
    return pill;
}

/// Handles for a removable `chip` (root pill + `close_btn` node ID).
pub const ChipHandles = struct {
    root: usize,
    close_btn: ui_core.UiNodeId,
};

/// Creates a removable chip with a trailing Lucide `x` button emitting `.activate` under `tag`.
pub fn chip(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *const theme.UiTheme,
    parent: ?usize,
    level: theme.SurfaceLevel,
    text: []const u8,
    tone: StatusTone,
    tag: []const u8,
) !ChipHandles {
    const cols = toneColors(th, level, tone);
    const est_w = @as(f32, @floatFromInt(text.len)) * 7.5 + 32.0;
    const root = try tree.createNode(parent, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .row,
            .width = est_w,
            .padding_edges = ui_core.Edges.xy(8, 2),
            .gap = 6,
            .min_height = 20,
            .align_items = .center,
            .bg_color = cols.bg,
            .border_color = cols.border,
            .border_widths = .{ 1, 1, 1, 1 },
            .corner_radii = rounded.RoundedCorners.all.toRadii(4.0),
        },
    });
    _ = try tree.createNode(root, .{
        .id = "",
        .kind = .label,
        .pickable = false,
        .text = text,
        .style = .{
            .padding = 0,
            .min_height = 14,
            .font_scale = theme.Metrics.font_small,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .text_color = cols.fg,
        },
    });
    const x_idx = try tree.createNode(root, .{
        .id = "",
        .kind = .button,
        .focusable = true,
        .cursor = .pointer,
        .style = .{
            .width = 14,
            .height = 14,
            .min_height = 14,
            .padding = 0,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
        .paint_extra = .{ .icon = .{ .kind = .close_x, .size = 11, .color = cols.fg } },
    });
    const x_id = tree.idOf(x_idx).?;
    _ = try mgr.attach(x_id, tag, .{ .button = .{} });
    return .{ .root = root, .close_btn = x_id };
}

/// Creates an inline `Alert` / `Callout` block with icon, title, and description.
pub fn alert(
    tree: *ui_core.UiTree,
    parent: ?usize,
    th: *const theme.UiTheme,
    level: theme.SurfaceLevel,
    tone: StatusTone,
    title: []const u8,
    description: []const u8,
) !usize {
    const cols = toneColors(th, level, tone);
    const box = try tree.createNode(parent, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .row,
            .padding = 8,
            .gap = 8,
            .align_items = .start,
            .bg_color = cols.bg,
            .border_color = cols.border,
            .border_widths = .{ 1, 1, 1, 3 },
            .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.corner_radius),
        },
    });
    const icon_kind: graphics.IconKind = switch (tone) {
        .success => .check_circle,
        .warning, .danger => .alert_triangle,
        .neutral, .accent => .info,
    };
    _ = try tree.createNode(box, .{
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
        .paint_extra = .{ .icon = .{ .kind = icon_kind, .size = 12, .color = cols.fg } },
    });
    const col = try tree.createNode(box, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .column,
            .width_spec = .{ .grow = 1.0 },
            .padding = 0,
            .gap = 2,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
    });
    _ = try tree.createNode(col, .{
        .id = "",
        .kind = .label,
        .text = title,
        .style = .{
            .padding = 0,
            .min_height = 16,
            .font_scale = theme.Metrics.font_medium,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .text_color = cols.fg,
        },
    });
    if (description.len > 0) {
        _ = try tree.createNode(col, .{
            .id = "",
            .kind = .label,
            .text = description,
            .style = .{
                .padding = 0,
                .min_height = 14,
                .font_scale = theme.Metrics.font_small,
                .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .text_color = th.color(.text_dim, level),
            },
        });
    }
    return box;
}

/// Creates a horizontal or vertical `Separator` with an optional centered label.
pub fn separator(
    tree: *ui_core.UiTree,
    parent: ?usize,
    th: *const theme.UiTheme,
    level: theme.SurfaceLevel,
    orientation: ui_widgets.events.ControlOrientation,
    opt_label: ?[]const u8,
) !usize {
    const line_col = th.color(.field_border, level);
    if (orientation == .vertical) {
        return tree.createNode(parent, .{
            .id = "",
            .kind = .panel,
            .style = .{
                .width = 1,
                .min_height = 16,
                .padding = 0,
                .bg_color = line_col,
            },
        });
    }
    if (opt_label == null or opt_label.?.len == 0) {
        return tree.createNode(parent, .{
            .id = "",
            .kind = .panel,
            .style = .{
                .height = 1,
                .min_height = 1,
                .padding = 0,
                .bg_color = line_col,
            },
        });
    }
    const row = try tree.createNode(parent, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .direction = .row,
            .align_items = .center,
            .gap = 8,
            .padding = 0,
            .min_height = 16,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
    });
    _ = try tree.createNode(row, .{
        .id = "",
        .kind = .panel,
        .style = .{ .width_spec = .{ .grow = 1.0 }, .height = 1, .min_height = 1, .padding = 0, .bg_color = line_col },
    });
    _ = try label(tree, row, th, level, opt_label.?, .dim);
    _ = try tree.createNode(row, .{
        .id = "",
        .kind = .panel,
        .style = .{ .width_spec = .{ .grow = 1.0 }, .height = 1, .min_height = 1, .padding = 0, .bg_color = line_col },
    });
    return row;
}

/// Visual handles for `progressBar`.
pub const ProgressBarHandles = struct {
    track: ui_core.UiNodeId,
    fill: ui_core.UiNodeId,
};

/// Creates a determinate/indeterminate progress bar.
pub fn progressBar(
    tree: *ui_core.UiTree,
    parent: ?usize,
    th: *const theme.UiTheme,
    level: theme.SurfaceLevel,
    progress_0_1: f32,
) !ProgressBarHandles {
    const track = try tree.createNode(parent, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .height = 8,
            .min_height = 8,
            .padding = 0,
            .bg_color = th.color(.slider_bg, level),
            .border_color = th.color(.field_border, level),
            .border_widths = .{ 1, 1, 1, 1 },
            .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.corner_radius),
        },
    });
    const fill = try tree.createNode(track, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .position = .absolute,
            .left = 0,
            .top = 0,
            .width = 0,
            .height = 8,
            .min_height = 8,
            .padding = 0,
            .bg_color = th.color(.slider_bar, level),
            .corner_radii = rounded.RoundedCorners.all.toRadii(theme.Metrics.corner_radius),
        },
    });
    const pb = ProgressBarHandles{
        .track = tree.idOf(track).?,
        .fill = tree.idOf(fill).?,
    };
    setProgress(tree, pb, progress_0_1);
    return pb;
}

/// Updates `progressBar` fill width for determinate progress in `[0, 1]`.
pub fn setProgress(tree: *ui_core.UiTree, pb: ProgressBarHandles, progress_0_1: f32) void {
    const t_idx = tree.resolveId(pb.track) orelse return;
    const f_idx = tree.resolveId(pb.fill) orelse return;
    const p = std.math.clamp(progress_0_1, 0.0, 1.0);
    const track_w = @max(@as(f32, 120.0), tree.nodes.items[t_idx].layout.width);
    tree.nodes.items[f_idx].style.left = 0;
    tree.nodes.items[f_idx].style.width = track_w * p;
}

/// Updates `progressBar` in indeterminate marquee mode using `phase_0_1` in `[0, 1)`.
pub fn setIndeterminateProgress(tree: *ui_core.UiTree, pb: ProgressBarHandles, phase_0_1: f32) void {
    const t_idx = tree.resolveId(pb.track) orelse return;
    const f_idx = tree.resolveId(pb.fill) orelse return;
    const track_w = @max(@as(f32, 120.0), tree.nodes.items[t_idx].layout.width);
    const bar_w = track_w * 0.28;
    const travel = @max(@as(f32, 0.0), track_w - bar_w);
    tree.nodes.items[f_idx].style.left = @mod(phase_0_1, 1.0) * travel;
    tree.nodes.items[f_idx].style.width = bar_w;
}

/// Visual handles for a compact activity `spinner`.
pub const SpinnerHandles = struct {
    track: ui_core.UiNodeId,
    dot: ui_core.UiNodeId,
    size_px: f32,
};

/// Creates a compact square activity spinner whose indicator orbits via `tickSpinner`.
pub fn spinner(
    tree: *ui_core.UiTree,
    parent: ?usize,
    th: *const theme.UiTheme,
    level: theme.SurfaceLevel,
    size_px: f32,
) !SpinnerHandles {
    const track = try tree.createNode(parent, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .width = size_px,
            .height = size_px,
            .min_height = size_px,
            .padding = 0,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .border_color = th.color(.field_border, level),
            .border_widths = .{ 2, 2, 2, 2 },
            .corner_radii = rounded.RoundedCorners.all.toRadii(size_px * 0.5),
        },
    });
    const dot_sz = @max(@as(f32, 4.0), size_px * 0.28);
    const dot = try tree.createNode(track, .{
        .id = "",
        .kind = .panel,
        .style = .{
            .position = .absolute,
            .left = (size_px - dot_sz) * 0.5,
            .top = 0,
            .width = dot_sz,
            .height = dot_sz,
            .min_height = dot_sz,
            .padding = 0,
            .bg_color = th.color(.focus_ring, level),
            .corner_radii = rounded.RoundedCorners.all.toRadii(dot_sz * 0.5),
        },
    });
    return .{ .track = tree.idOf(track).?, .dot = tree.idOf(dot).?, .size_px = size_px };
}

/// Advances `spinner` indicator position for `phase_0_1` in `[0, 1)`.
pub fn tickSpinner(tree: *ui_core.UiTree, sp: SpinnerHandles, phase_0_1: f32) void {
    const d_idx = tree.resolveId(sp.dot) orelse return;
    const dot_sz = @max(@as(f32, 4.0), sp.size_px * 0.28);
    const r = (sp.size_px - dot_sz) * 0.5;
    const angle = @mod(phase_0_1, 1.0) * std.math.tau;
    tree.nodes.items[d_idx].style.left = r + @cos(angle) * r;
    tree.nodes.items[d_idx].style.top = r + @sin(angle) * r;
}
