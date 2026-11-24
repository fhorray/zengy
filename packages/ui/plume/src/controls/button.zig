//! Button & Segmented Button Controls (`official.ui.plume`).

const graphics = @import("graphics");
const ui_core = @import("ui_core");
const ui_widgets = @import("ui_widgets");
const theme = @import("../theme.zig");
const tokens = @import("../tokens.zig");
const rounded = @import("../rounded_corners.zig");

/// Visual variants for `PlumeButton`.
pub const ButtonVariant = enum {
    normal,
    primary,
    plain,
    tool,

    /// Returns `.primary` when `is_selected` is true, otherwise `.normal`.
    pub fn selected(is_selected: bool) ButtonVariant {
        return if (is_selected) .primary else .normal;
    }
};

/// Configuration properties for `button`.
pub const ButtonProps = struct {
    label: []const u8 = "",
    icon: ?graphics.IconKind = null,
    variant: ButtonVariant = .normal,
    corners: rounded.RoundedCorners = .all,
    disabled: bool = false,
    activate_on_press: bool = false,
    width_spec: ?ui_core.SizeSpec = null,
    tag: []const u8 = "",
    level: theme.SurfaceLevel = .higher,
};

/// Metadata stored per button for dynamic theme synchronization.
pub const ButtonStyleMeta = struct {
    node: ui_core.UiNodeId,
    variant: ButtonVariant,
    level: theme.SurfaceLevel,
};

/// Creates a styled button node and attaches `ButtonBehavior`.
pub fn button(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *const theme.UiTheme,
    parent: ?usize,
    props: ButtonProps,
) !ButtonStyleMeta {
    const bg_tok: tokens.ThemeToken = switch (props.variant) {
        .normal, .tool => if (props.disabled) .button_bg_disabled else .button_bg,
        .primary => if (props.disabled) .button_primary_bg_disabled else .button_primary_bg,
        .plain => .button_plain_bg,
    };
    const txt_tok: tokens.ThemeToken = switch (props.variant) {
        .normal, .tool, .plain => if (props.disabled) .button_text_disabled else .button_text,
        .primary => if (props.disabled) .button_primary_text_disabled else .button_primary_text,
    };

    const extra: ui_core.PaintExtra = if (props.icon) |ic| .{
        .icon = .{
            .kind = ic,
            .size = 14.0,
            .color = th.color(txt_tok, props.level),
        },
    } else .none;

    const idx = try tree.createNode(parent, .{
        .id = "",
        .kind = .button,
        .text = props.label,
        .focusable = true,
        .disabled = props.disabled,
        .cursor = if (props.disabled) .default else .pointer,
        .paint_extra = extra,
        .style = .{
            .direction = .row,
            .width_spec = props.width_spec,
            .min_height = theme.Metrics.row_height,
            .min_width = if (props.icon != null and props.label.len == 0) 24.0 else 0.0,
            .padding_edges = if (props.icon != null and props.label.len == 0)
                ui_core.Edges.all(4)
            else if (props.width_spec != null)
                ui_core.Edges.xy(4, 4)
            else
                ui_core.Edges.xy(10, 4),
            .align_items = .center,
            .justify_content = .center,
            .text_align = .center,
            .font_scale = theme.Metrics.font_medium,
            .bg_color = th.color(bg_tok, props.level),
            .text_color = th.color(txt_tok, props.level),
            .corner_radii = props.corners.toRadii(theme.Metrics.corner_radius),
        },
    });
    const nid = tree.idOf(idx).?;
    _ = try mgr.attach(nid, props.tag, .{
        .button = .{ .activate_on_press = props.activate_on_press },
    });
    return .{
        .node = nid,
        .variant = props.variant,
        .level = props.level,
    };
}

/// Synchronizes button colors with hover/pressed/disabled state.
pub fn syncButtonStyle(
    tree: *ui_core.UiTree,
    th: *const theme.UiTheme,
    meta: ButtonStyleMeta,
) void {
    const idx = tree.resolveId(meta.node) orelse return;
    const node = &tree.nodes.items[idx];

    const bg_tok: tokens.ThemeToken = switch (meta.variant) {
        .normal, .tool => if (node.disabled)
            .button_bg_disabled
        else if (node.pressed)
            .button_bg_pressed
        else if (node.hovered)
            .button_bg_hover
        else
            .button_bg,
        .primary => if (node.disabled)
            .button_primary_bg_disabled
        else if (node.pressed)
            .button_primary_bg_pressed
        else if (node.hovered)
            .button_primary_bg_hover
        else
            .button_primary_bg,
        .plain => if (node.pressed)
            .button_plain_bg_pressed
        else if (node.hovered)
            .button_plain_bg_hover
        else
            .button_plain_bg,
    };
    const txt_tok: tokens.ThemeToken = switch (meta.variant) {
        .normal, .tool, .plain => if (node.disabled) .button_text_disabled else .button_text,
        .primary => if (node.disabled) .button_primary_text_disabled else .button_primary_text,
    };

    node.style.bg_color = th.color(bg_tok, meta.level);
    node.style.text_color = th.color(txt_tok, meta.level);
    if (node.paint_extra == .icon) {
        node.paint_extra.icon.color = node.style.text_color;
    }
}
