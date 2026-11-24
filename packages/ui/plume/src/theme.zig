//! Contextual Two-Level Theme System (`official.ui.plume`).
//!
//! Resolves `ThemeToken` -> `SemanticToken` -> `graphics.Color` based on the
//! container's `SurfaceLevel` (`base`, `higher`, `highest`, `floating`).

const std = @import("std");
const graphics = @import("graphics");
const color = @import("ui_widgets").color;
const palette = @import("palette.zig");
const tokens = @import("tokens.zig");

/// Surface elevation context propagated down container hierarchies.
pub const SurfaceLevel = enum(usize) {
    base = 0,
    higher = 1,
    highest = 2,
    floating = 3,
};

/// Standard layout metrics shared across `ui-plume` widgets.
pub const Metrics = struct {
    pub const row_height: f32 = 24.0;
    pub const header_height: f32 = 30.0;
    pub const checkbox_size: f32 = 18.0;
    pub const radio_size: f32 = 18.0;
    pub const toggle_width: f32 = 32.0;
    pub const toggle_height: f32 = 18.0;
    pub const corner_radius: f32 = 0.0;
    pub const slider_radius: f32 = 0.0;
    pub const font_header: f32 = 2.25; // 18px
    pub const font_medium: f32 = 2.0; // 16px
    pub const font_compact: f32 = 1.875; // 15px
    pub const font_small: f32 = 1.75; // 14px
};

const SEMANTIC_COUNT = @typeInfo(tokens.SemanticToken).@"enum".field_names.len;
const TOKEN_COUNT = @typeInfo(tokens.ThemeToken).@"enum".field_names.len;
const LEVEL_COUNT = @typeInfo(SurfaceLevel).@"enum".field_names.len;

/// Complete theme definition with contextual surface overrides.
pub const ThemeProps = struct {
    semantic_base: [SEMANTIC_COUNT]graphics.Color,
    semantic_overrides: [LEVEL_COUNT][SEMANTIC_COUNT]?graphics.Color,
    token_map: [TOKEN_COUNT]tokens.SemanticToken,

    /// Resolves a `ThemeToken` for the given `SurfaceLevel`.
    pub fn resolve(self: *const ThemeProps, token: tokens.ThemeToken, level: SurfaceLevel) graphics.Color {
        const sem = self.token_map[@intFromEnum(token)];
        if (self.semantic_overrides[@intFromEnum(level)][@intFromEnum(sem)]) |ovr| {
            return ovr;
        }
        return self.semantic_base[@intFromEnum(sem)];
    }
};

/// Active `ui-plume` theme resource.
pub const UiTheme = struct {
    props: ThemeProps,

    /// Initializes `UiTheme` with the default dark theme.
    pub fn initDark() UiTheme {
        return .{ .props = createDarkTheme() };
    }

    /// Initializes `UiTheme` with the built-in light theme.
    pub fn initLight() UiTheme {
        return .{ .props = createLightTheme() };
    }

    /// Resolves `token` at `level`.
    pub fn color(self: *const UiTheme, token: tokens.ThemeToken, level: SurfaceLevel) graphics.Color {
        return self.props.resolve(token, level);
    }
};

fn defaultTokenMap() [TOKEN_COUNT]tokens.SemanticToken {
    var m: [TOKEN_COUNT]tokens.SemanticToken = undefined;
    m[@intFromEnum(tokens.ThemeToken.window_bg)] = .surface_window;
    m[@intFromEnum(tokens.ThemeToken.focus_ring)] = .focus_ring;
    m[@intFromEnum(tokens.ThemeToken.text_main)] = .text_default;
    m[@intFromEnum(tokens.ThemeToken.text_dim)] = .text_dim;
    m[@intFromEnum(tokens.ThemeToken.text_accent)] = .text_accent;
    m[@intFromEnum(tokens.ThemeToken.button_bg)] = .fill_solid_default;
    m[@intFromEnum(tokens.ThemeToken.button_bg_hover)] = .fill_solid_hover;
    m[@intFromEnum(tokens.ThemeToken.button_bg_pressed)] = .fill_solid_pressed;
    m[@intFromEnum(tokens.ThemeToken.button_bg_disabled)] = .fill_solid_disabled;
    m[@intFromEnum(tokens.ThemeToken.button_text)] = .text_default;
    m[@intFromEnum(tokens.ThemeToken.button_text_disabled)] = .text_disabled;
    m[@intFromEnum(tokens.ThemeToken.button_primary_bg)] = .fill_accent_default;
    m[@intFromEnum(tokens.ThemeToken.button_primary_bg_hover)] = .fill_accent_hover;
    m[@intFromEnum(tokens.ThemeToken.button_primary_bg_pressed)] = .fill_accent_pressed;
    m[@intFromEnum(tokens.ThemeToken.button_primary_bg_disabled)] = .fill_accent_disabled;
    m[@intFromEnum(tokens.ThemeToken.button_primary_text)] = .text_on_accent;
    m[@intFromEnum(tokens.ThemeToken.button_primary_text_disabled)] = .text_disabled;
    m[@intFromEnum(tokens.ThemeToken.button_plain_bg)] = .fill_none;
    m[@intFromEnum(tokens.ThemeToken.button_plain_bg_hover)] = .fill_item_hover;
    m[@intFromEnum(tokens.ThemeToken.button_plain_bg_pressed)] = .fill_item_pressed;
    m[@intFromEnum(tokens.ThemeToken.slider_bg)] = .fill_solid_default;
    m[@intFromEnum(tokens.ThemeToken.slider_bg_hover)] = .fill_solid_hover;
    m[@intFromEnum(tokens.ThemeToken.slider_bg_pressed)] = .fill_solid_pressed;
    m[@intFromEnum(tokens.ThemeToken.slider_bg_disabled)] = .fill_solid_disabled;
    m[@intFromEnum(tokens.ThemeToken.slider_bar)] = .fill_accent_default;
    m[@intFromEnum(tokens.ThemeToken.slider_bar_hover)] = .fill_accent_hover;
    m[@intFromEnum(tokens.ThemeToken.slider_bar_pressed)] = .fill_accent_pressed;
    m[@intFromEnum(tokens.ThemeToken.slider_bar_disabled)] = .fill_accent_disabled;
    m[@intFromEnum(tokens.ThemeToken.slider_text)] = .text_on_accent;
    m[@intFromEnum(tokens.ThemeToken.slider_text_disabled)] = .text_disabled;
    m[@intFromEnum(tokens.ThemeToken.checkbox_bg)] = .fill_field_default;
    m[@intFromEnum(tokens.ThemeToken.checkbox_bg_checked)] = .fill_accent_default;
    m[@intFromEnum(tokens.ThemeToken.checkbox_bg_disabled)] = .fill_solid_disabled;
    m[@intFromEnum(tokens.ThemeToken.checkbox_border)] = .border_default;
    m[@intFromEnum(tokens.ThemeToken.checkbox_mark)] = .text_on_accent;
    m[@intFromEnum(tokens.ThemeToken.checkbox_text)] = .text_default;
    m[@intFromEnum(tokens.ThemeToken.radio_bg)] = .fill_field_default;
    m[@intFromEnum(tokens.ThemeToken.radio_border)] = .border_default;
    m[@intFromEnum(tokens.ThemeToken.radio_mark)] = .fill_accent_default;
    m[@intFromEnum(tokens.ThemeToken.switch_bg)] = .fill_field_default;
    m[@intFromEnum(tokens.ThemeToken.switch_bg_checked)] = .fill_accent_default;
    m[@intFromEnum(tokens.ThemeToken.switch_border)] = .border_default;
    m[@intFromEnum(tokens.ThemeToken.switch_slide)] = .text_on_accent;
    m[@intFromEnum(tokens.ThemeToken.field_bg)] = .fill_field_default;
    m[@intFromEnum(tokens.ThemeToken.field_bg_hover)] = .fill_field_hover;
    m[@intFromEnum(tokens.ThemeToken.field_border)] = .border_default;
    m[@intFromEnum(tokens.ThemeToken.field_text)] = .text_default;
    m[@intFromEnum(tokens.ThemeToken.pane_header_bg)] = .surface_pane_header;
    m[@intFromEnum(tokens.ThemeToken.pane_header_border)] = .border_default;
    m[@intFromEnum(tokens.ThemeToken.pane_header_divider)] = .border_default;
    m[@intFromEnum(tokens.ThemeToken.pane_header_text)] = .text_default;
    m[@intFromEnum(tokens.ThemeToken.pane_body_bg)] = .surface_pane_body;
    m[@intFromEnum(tokens.ThemeToken.subpane_header_bg)] = .surface_subpane_header;
    m[@intFromEnum(tokens.ThemeToken.subpane_header_border)] = .border_default;
    m[@intFromEnum(tokens.ThemeToken.subpane_header_text)] = .text_default;
    m[@intFromEnum(tokens.ThemeToken.subpane_body_bg)] = .surface_subpane_body;
    m[@intFromEnum(tokens.ThemeToken.subpane_body_border)] = .border_default;
    m[@intFromEnum(tokens.ThemeToken.group_bg)] = .surface_group;
    m[@intFromEnum(tokens.ThemeToken.group_border)] = .border_default;
    m[@intFromEnum(tokens.ThemeToken.group_header_text)] = .text_default;
    m[@intFromEnum(tokens.ThemeToken.menu_bg)] = .surface_menu;
    m[@intFromEnum(tokens.ThemeToken.menu_border)] = .border_default;
    m[@intFromEnum(tokens.ThemeToken.item_hover)] = .fill_item_hover;
    m[@intFromEnum(tokens.ThemeToken.item_selected)] = .fill_item_selected;
    m[@intFromEnum(tokens.ThemeToken.scrollbar_bg)] = .fill_none;
    m[@intFromEnum(tokens.ThemeToken.scrollbar_thumb)] = .fill_solid_default;
    m[@intFromEnum(tokens.ThemeToken.scrollbar_thumb_hover)] = .fill_solid_hover;
    m[@intFromEnum(tokens.ThemeToken.tab_strip_bg)] = .surface_pane_header;
    m[@intFromEnum(tokens.ThemeToken.tab_active_bg)] = .surface_pane_body;
    m[@intFromEnum(tokens.ThemeToken.axis_x)] = .axis_x;
    m[@intFromEnum(tokens.ThemeToken.axis_y)] = .axis_y;
    m[@intFromEnum(tokens.ThemeToken.axis_z)] = .axis_z;
    m[@intFromEnum(tokens.ThemeToken.axis_w)] = .axis_w;
    return m;
}

/// Builds the default `ui-plume` dark theme.
pub fn createDarkTheme() ThemeProps {
    var base: [SEMANTIC_COUNT]graphics.Color = undefined;
    base[@intFromEnum(tokens.SemanticToken.surface_window)] = palette.GRAY_0;
    base[@intFromEnum(tokens.SemanticToken.surface_pane_header)] = palette.GRAY_0;
    base[@intFromEnum(tokens.SemanticToken.surface_pane_body)] = palette.GRAY_1;
    base[@intFromEnum(tokens.SemanticToken.surface_subpane_header)] = palette.GRAY_2;
    base[@intFromEnum(tokens.SemanticToken.surface_subpane_body)] = palette.GRAY_1;
    base[@intFromEnum(tokens.SemanticToken.surface_group)] = palette.GRAY_2;
    base[@intFromEnum(tokens.SemanticToken.surface_dialog)] = palette.GRAY_1;
    base[@intFromEnum(tokens.SemanticToken.surface_menu)] = palette.GRAY_1;
    base[@intFromEnum(tokens.SemanticToken.border_default)] = palette.WARM_GRAY_1;
    base[@intFromEnum(tokens.SemanticToken.text_default)] = palette.LIGHT_GRAY_1;
    base[@intFromEnum(tokens.SemanticToken.text_dim)] = palette.LIGHT_GRAY_2;
    base[@intFromEnum(tokens.SemanticToken.text_accent)] = color.lighter(palette.ACCENT, 0.20);
    base[@intFromEnum(tokens.SemanticToken.text_disabled)] = color.withAlpha(palette.LIGHT_GRAY_1, 0.40);
    base[@intFromEnum(tokens.SemanticToken.text_on_accent)] = palette.WHITE;
    base[@intFromEnum(tokens.SemanticToken.fill_accent_default)] = palette.ACCENT;
    base[@intFromEnum(tokens.SemanticToken.fill_accent_hover)] = color.lighter(palette.ACCENT, 0.08);
    base[@intFromEnum(tokens.SemanticToken.fill_accent_pressed)] = color.lighter(palette.ACCENT, 0.16);
    base[@intFromEnum(tokens.SemanticToken.fill_accent_disabled)] = color.withAlpha(palette.GRAY_3, 0.70);
    base[@intFromEnum(tokens.SemanticToken.fill_solid_default)] = palette.GRAY_3;
    base[@intFromEnum(tokens.SemanticToken.fill_solid_hover)] = color.lighter(palette.GRAY_3, 0.08);
    base[@intFromEnum(tokens.SemanticToken.fill_solid_pressed)] = color.lighter(palette.GRAY_3, 0.16);
    base[@intFromEnum(tokens.SemanticToken.fill_solid_disabled)] = color.withAlpha(palette.GRAY_2, 0.70);
    base[@intFromEnum(tokens.SemanticToken.fill_item_default)] = palette.TRANSPARENT;
    base[@intFromEnum(tokens.SemanticToken.fill_item_hover)] = color.lighter(palette.GRAY_1, 0.06);
    base[@intFromEnum(tokens.SemanticToken.fill_item_pressed)] = color.lighter(palette.GRAY_1, 0.12);
    base[@intFromEnum(tokens.SemanticToken.fill_item_selected)] = color.withAlpha(palette.ACCENT, 0.30);
    base[@intFromEnum(tokens.SemanticToken.fill_field_default)] = palette.GRAY_2;
    base[@intFromEnum(tokens.SemanticToken.fill_field_hover)] = color.lighter(palette.GRAY_2, 0.06);
    base[@intFromEnum(tokens.SemanticToken.fill_field_pressed)] = color.lighter(palette.GRAY_2, 0.12);
    base[@intFromEnum(tokens.SemanticToken.fill_none)] = palette.TRANSPARENT;
    base[@intFromEnum(tokens.SemanticToken.axis_x)] = palette.X_AXIS;
    base[@intFromEnum(tokens.SemanticToken.axis_y)] = palette.Y_AXIS;
    base[@intFromEnum(tokens.SemanticToken.axis_z)] = palette.Z_AXIS;
    base[@intFromEnum(tokens.SemanticToken.axis_w)] = palette.W_AXIS;
    base[@intFromEnum(tokens.SemanticToken.focus_ring)] = color.withAlpha(palette.ACCENT, 0.65);

    var overrides: [LEVEL_COUNT][SEMANTIC_COUNT]?graphics.Color = @splat(@splat(null));
    // Group / subpane header context (`highest`) lightens controls and fields for contrast.
    overrides[@intFromEnum(SurfaceLevel.highest)][@intFromEnum(tokens.SemanticToken.fill_solid_default)] = color.lighter(palette.GRAY_3, 0.06);
    overrides[@intFromEnum(SurfaceLevel.highest)][@intFromEnum(tokens.SemanticToken.fill_solid_hover)] = color.lighter(palette.GRAY_3, 0.12);
    overrides[@intFromEnum(SurfaceLevel.highest)][@intFromEnum(tokens.SemanticToken.fill_field_default)] = palette.GRAY_1;
    overrides[@intFromEnum(SurfaceLevel.highest)][@intFromEnum(tokens.SemanticToken.fill_field_hover)] = color.lighter(palette.GRAY_1, 0.05);
    // Floating context (`floating`) gives crisp contrast for menus/popovers.
    overrides[@intFromEnum(SurfaceLevel.floating)][@intFromEnum(tokens.SemanticToken.fill_solid_default)] = palette.GRAY_3;
    overrides[@intFromEnum(SurfaceLevel.floating)][@intFromEnum(tokens.SemanticToken.fill_field_default)] = palette.GRAY_2;
    overrides[@intFromEnum(SurfaceLevel.floating)][@intFromEnum(tokens.SemanticToken.fill_item_hover)] = color.lighter(palette.GRAY_2, 0.06);

    return .{
        .semantic_base = base,
        .semantic_overrides = overrides,
        .token_map = defaultTokenMap(),
    };
}

/// Builds a clean light theme variant for `ui-plume`.
pub fn createLightTheme() ThemeProps {
    var base: [SEMANTIC_COUNT]graphics.Color = undefined;
    base[@intFromEnum(tokens.SemanticToken.surface_window)] = .{ .r = 0.91, .g = 0.92, .b = 0.94, .a = 1 };
    base[@intFromEnum(tokens.SemanticToken.surface_pane_header)] = .{ .r = 0.87, .g = 0.88, .b = 0.91, .a = 1 };
    base[@intFromEnum(tokens.SemanticToken.surface_pane_body)] = .{ .r = 0.94, .g = 0.95, .b = 0.96, .a = 1 };
    base[@intFromEnum(tokens.SemanticToken.surface_subpane_header)] = .{ .r = 0.85, .g = 0.86, .b = 0.89, .a = 1 };
    base[@intFromEnum(tokens.SemanticToken.surface_subpane_body)] = .{ .r = 0.92, .g = 0.93, .b = 0.95, .a = 1 };
    base[@intFromEnum(tokens.SemanticToken.surface_group)] = .{ .r = 0.89, .g = 0.90, .b = 0.93, .a = 1 };
    base[@intFromEnum(tokens.SemanticToken.surface_dialog)] = .{ .r = 0.96, .g = 0.96, .b = 0.98, .a = 1 };
    base[@intFromEnum(tokens.SemanticToken.surface_menu)] = .{ .r = 0.97, .g = 0.97, .b = 0.98, .a = 1 };
    base[@intFromEnum(tokens.SemanticToken.border_default)] = .{ .r = 0.72, .g = 0.74, .b = 0.78, .a = 1 };
    base[@intFromEnum(tokens.SemanticToken.text_default)] = .{ .r = 0.12, .g = 0.13, .b = 0.16, .a = 1 };
    base[@intFromEnum(tokens.SemanticToken.text_dim)] = .{ .r = 0.42, .g = 0.44, .b = 0.48, .a = 1 };
    base[@intFromEnum(tokens.SemanticToken.text_accent)] = palette.ACCENT;
    base[@intFromEnum(tokens.SemanticToken.text_disabled)] = .{ .r = 0.55, .g = 0.57, .b = 0.60, .a = 0.7 };
    base[@intFromEnum(tokens.SemanticToken.text_on_accent)] = palette.WHITE;
    base[@intFromEnum(tokens.SemanticToken.fill_accent_default)] = palette.ACCENT;
    base[@intFromEnum(tokens.SemanticToken.fill_accent_hover)] = color.lighter(palette.ACCENT, 0.08);
    base[@intFromEnum(tokens.SemanticToken.fill_accent_pressed)] = color.darker(palette.ACCENT, 0.10);
    base[@intFromEnum(tokens.SemanticToken.fill_accent_disabled)] = .{ .r = 0.75, .g = 0.77, .b = 0.80, .a = 0.7 };
    base[@intFromEnum(tokens.SemanticToken.fill_solid_default)] = .{ .r = 0.82, .g = 0.84, .b = 0.87, .a = 1 };
    base[@intFromEnum(tokens.SemanticToken.fill_solid_hover)] = .{ .r = 0.77, .g = 0.79, .b = 0.83, .a = 1 };
    base[@intFromEnum(tokens.SemanticToken.fill_solid_pressed)] = .{ .r = 0.72, .g = 0.74, .b = 0.78, .a = 1 };
    base[@intFromEnum(tokens.SemanticToken.fill_solid_disabled)] = .{ .r = 0.86, .g = 0.87, .b = 0.89, .a = 0.7 };
    base[@intFromEnum(tokens.SemanticToken.fill_item_default)] = palette.TRANSPARENT;
    base[@intFromEnum(tokens.SemanticToken.fill_item_hover)] = .{ .r = 0.84, .g = 0.86, .b = 0.90, .a = 1 };
    base[@intFromEnum(tokens.SemanticToken.fill_item_pressed)] = .{ .r = 0.78, .g = 0.81, .b = 0.86, .a = 1 };
    base[@intFromEnum(tokens.SemanticToken.fill_item_selected)] = color.withAlpha(palette.ACCENT, 0.22);
    base[@intFromEnum(tokens.SemanticToken.fill_field_default)] = .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1 };
    base[@intFromEnum(tokens.SemanticToken.fill_field_hover)] = .{ .r = 0.98, .g = 0.98, .b = 0.99, .a = 1 };
    base[@intFromEnum(tokens.SemanticToken.fill_field_pressed)] = .{ .r = 0.95, .g = 0.96, .b = 0.98, .a = 1 };
    base[@intFromEnum(tokens.SemanticToken.fill_none)] = palette.TRANSPARENT;
    base[@intFromEnum(tokens.SemanticToken.axis_x)] = palette.X_AXIS;
    base[@intFromEnum(tokens.SemanticToken.axis_y)] = palette.Y_AXIS;
    base[@intFromEnum(tokens.SemanticToken.axis_z)] = palette.Z_AXIS;
    base[@intFromEnum(tokens.SemanticToken.axis_w)] = palette.W_AXIS;
    base[@intFromEnum(tokens.SemanticToken.focus_ring)] = color.withAlpha(palette.ACCENT, 0.65);

    const overrides: [LEVEL_COUNT][SEMANTIC_COUNT]?graphics.Color = @splat(@splat(null));
    return .{
        .semantic_base = base,
        .semantic_overrides = overrides,
        .token_map = defaultTokenMap(),
    };
}
