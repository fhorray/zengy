//! Bridge from the optional `remote` integration contract to the editor shell.
//!
//! Attaching routes `zengy/set_component_field` through the shell's undo history and
//! lets `zengy/list_panels` enumerate shell panels. State is resolved through
//! `app.resources` on every call, so no pointer to the shell is ever cached.

const std = @import("std");
const engine = @import("engine");
const remote = @import("remote");
const editor_shell = @import("editor_shell");

/// Errors returned when the adapter outlives the resource it bridges to.
pub const AdapterError = error{EditorShellUnavailable};

// The adapter is stateless; its context only needs a stable non-null address.
var context_marker: u8 = 0;

fn editField(_: *anyopaque, app: *engine.App, request: remote.FieldEditRequest) anyerror!void {
    const shell = app.resources.get(editor_shell.EditorShellService) orelse return error.EditorShellUnavailable;
    try shell.setInspectedField(&app.world, &app.types, request.entity, request.schema_id, request.field_name, request.value);
}

fn visitPanels(_: *anyopaque, app: *engine.App, visitor: remote.PanelVisitor) anyerror!void {
    const shell = app.resources.get(editor_shell.EditorShellService) orelse return error.EditorShellUnavailable;
    for (shell.panels.items) |p| {
        try visitor.visit(visitor.context, .{ .id = p.id, .title = p.title, .open = p.open });
    }
}

/// Returns the integration descriptor backed by the editor shell.
pub fn integration() remote.RemoteIntegration {
    return .{
        .context = &context_marker,
        .edit_field = editField,
        .visit_panels = visitPanels,
    };
}

/// Attaches the shell integration to the app's `RemoteInspectorService`.
/// Call after `app.initialize()`; requires the remote module to be registered.
pub fn attach(app: *engine.App) !void {
    const svc = app.resources.get(remote.RemoteInspectorService) orelse return error.RemoteUnavailable;
    svc.setIntegration(integration());
}

/// Detaches the integration if the remote service is still present.
pub fn detach(app: *engine.App) void {
    if (app.resources.get(remote.RemoteInspectorService)) |svc| svc.clearIntegration();
}
