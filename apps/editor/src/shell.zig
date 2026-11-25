//! Editor shell (`app.editor.shell`), owned by the editor application (`apps/editor`).
//!
//! Owns panel registry metadata. Authoring mutations and undo/redo delegate to an
//! `EditorDocument` (bound by the application, or a shell-owned fallback) so Remote,
//! keyboard and UI share one history.

const std = @import("std");
const engine = @import("engine");
const document = @import("document");

pub const MODULE_OWNER_ID: u64 = 2008;

/// Descriptor for a dockable tool panel registered with the editor shell.
pub const PanelDescriptor = struct {
    id: []const u8,
    title: []const u8,
    open: bool = true,
};

/// Manages registered editor panels and routes authoring edits to a single document history.
pub const EditorShellService = struct {
    allocator: std.mem.Allocator,
    panels: std.ArrayList(PanelDescriptor),
    /// Used when the application has not bound an external document (tests / inspector demos).
    fallback_doc: document.EditorDocument,
    /// Active authoring document; null means `fallback_doc`.
    bound_doc: ?*document.EditorDocument = null,

    pub fn init(allocator: std.mem.Allocator) EditorShellService {
        return .{
            .allocator = allocator,
            .panels = .empty,
            .fallback_doc = document.EditorDocument.init(allocator),
        };
    }

    pub fn deinit(self: *EditorShellService) void {
        for (self.panels.items) |p| {
            self.allocator.free(p.id);
            self.allocator.free(p.title);
        }
        self.panels.deinit(self.allocator);
        self.bound_doc = null;
        self.fallback_doc.deinit();
    }

    /// Routes subsequent field edits / undo / redo through `doc` (typically the editor MVP document).
    pub fn bindDocument(self: *EditorShellService, doc: *document.EditorDocument) void {
        self.bound_doc = doc;
    }

    /// Clears an external binding and returns to the shell-owned fallback document.
    pub fn unbindDocument(self: *EditorShellService) void {
        self.bound_doc = null;
    }

    /// Returns the active authoring document (bound or fallback).
    pub fn authoring(self: *EditorShellService) *document.EditorDocument {
        return self.bound_doc orelse &self.fallback_doc;
    }

    pub fn authoringConst(self: *const EditorShellService) *const document.EditorDocument {
        return self.bound_doc orelse &self.fallback_doc;
    }

    pub fn registerPanel(self: *EditorShellService, desc: PanelDescriptor) !void {
        const id_copy = try self.allocator.dupe(u8, desc.id);
        errdefer self.allocator.free(id_copy);
        const title_copy = try self.allocator.dupe(u8, desc.title);
        errdefer self.allocator.free(title_copy);

        try self.panels.append(self.allocator, .{
            .id = id_copy,
            .title = title_copy,
            .open = desc.open,
        });
    }

    pub fn panelCount(self: *const EditorShellService) usize {
        return self.panels.items.len;
    }

    /// Edits a reflected field through the active document history.
    pub fn setInspectedField(
        self: *EditorShellService,
        world: *engine.World,
        types: *const engine.TypeRegistry,
        entity: engine.EntityHandle,
        schema_id: engine.reflection.SchemaId,
        field_name: []const u8,
        new_value: engine.reflection.FieldValue,
    ) !void {
        try self.authoring().setField(world, types, entity, schema_id, field_name, new_value);
    }

    pub fn undo(self: *EditorShellService, world: *engine.World, types: *const engine.TypeRegistry) !bool {
        return self.authoring().undo(world, types);
    }

    pub fn redo(self: *EditorShellService, world: *engine.World, types: *const engine.TypeRegistry) !bool {
        return self.authoring().redo(world, types);
    }
};

fn buildModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    try app.resources.insert(EditorShellService, EditorShellService.init(app.allocator));
    const svc = app.resources.get(EditorShellService).?;

    try svc.registerPanel(.{ .id = "editor.hierarchy", .title = "Hierarchy" });
    try svc.registerPanel(.{ .id = "editor.inspector", .title = "Inspector" });
    try svc.registerPanel(.{ .id = "editor.console", .title = "Console" });
    try svc.registerPanel(.{ .id = "editor.profiler", .title = "Profiler" });
    try svc.registerPanel(.{ .id = "editor.remote", .title = "Remote Inspector" });

    try app.services.register(.{
        .capability = "editor.shell",
        .major_version = 1,
        .provider_id = "app.editor.shell",
        .owner_id = MODULE_OWNER_ID,
        .exclusive = true,
        .api_ptr = svc,
        .api_size = @sizeOf(EditorShellService),
    });
}

fn stopModule(raw_app: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    _ = app.services.unregisterByOwner(MODULE_OWNER_ID);
    _ = app.resources.remove(EditorShellService);
}

pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = "app.editor.shell",
            .version = "0.1.0",
            .provides_capabilities = &.{"editor.shell/1"},
            .required_capabilities = &.{"engine.ui.tree/1"},
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
