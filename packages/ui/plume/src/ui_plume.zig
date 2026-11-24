//! Styled Editor & Tooling Widget Kit (`official.ui.plume`).
//!
//! Built cleanly on top of `ui_core.UiTree` and `ui_widgets.WidgetManager`.
//! Provides contextual two-level theming (`SurfaceLevel`), `RoundedCorners`,
//! hierarchical containers (`Pane`, `SubPane`, `Group`), display helpers, and
//! cohesive controls.

const engine = @import("engine");
const ui_core = @import("ui_core");
const ui_widgets = @import("ui_widgets");

pub const palette = @import("palette.zig");
pub const tokens = @import("tokens.zig");
pub const theme = @import("theme.zig");
pub const rounded_corners = @import("rounded_corners.zig");
pub const containers = @import("containers.zig");
pub const display = @import("display.zig");
pub const controls = struct {
    pub const button = @import("controls/button.zig");
    pub const toggles = @import("controls/toggles.zig");
    pub const inputs = @import("controls/inputs.zig");
    pub const overlays = @import("controls/overlays.zig");
    pub const color_picker = @import("controls/color_picker.zig");
    pub const tooling = @import("controls/tooling.zig");
    pub const navigation = @import("controls/navigation.zig");
    pub const data = @import("controls/data.zig");
};

pub const UiTheme = theme.UiTheme;
pub const SurfaceLevel = theme.SurfaceLevel;
pub const RoundedCorners = rounded_corners.RoundedCorners;

pub const MODULE_OWNER_ID: u64 = 2015;

fn buildModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    try app.resources.insert(UiTheme, UiTheme.initDark());
    const th = app.resources.get(UiTheme).?;

    try app.services.register(.{
        .capability = "engine.ui.theme",
        .major_version = 1,
        .provider_id = "official.ui.plume",
        .owner_id = MODULE_OWNER_ID,
        .exclusive = true,
        .api_ptr = th,
        .api_size = @sizeOf(UiTheme),
    });
}

fn stopModule(raw_app: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    _ = app.services.unregisterByOwner(MODULE_OWNER_ID);
    _ = app.resources.remove(UiTheme);
}

/// Synchronizes hover/selection/editing styles across all bound `ui-plume` widgets.
pub fn syncAll(tree: *ui_core.UiTree, mgr: *ui_widgets.WidgetManager, th: *const UiTheme) void {
    for (mgr.bindings.items) |b| {
        switch (b.behavior) {
            .menu_item => controls.overlays.syncMenuItem(tree, th, b.node),
            .list_item => controls.overlays.syncListRow(tree, th, b.node),
            .number_input => controls.inputs.syncNumberInput(tree, mgr, b.node),
            .text_input => controls.inputs.syncTextInput(tree, th, b.node),
            .disclosure => controls.tooling.syncTreeRow(tree, mgr, th, b.node),
            else => {},
        }
    }
}

/// Returns the `official.ui.plume` module descriptor.
pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = "official.ui.plume",
            .version = "0.3.0",
            .provides_capabilities = &.{"engine.ui.theme/1"},
            .required_capabilities = &.{ "engine.ui.tree/1", "engine.ui.widgets/1" },
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
