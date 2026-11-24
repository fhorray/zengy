//! Optional Modular Editor Shell Package (`official.tools.editor_shell`).
//!
//! Demonstrates Phase 12: editor tooling (panel registry, undo/redo command
//! history, and schema-driven component inspector) built strictly as an optional
//! package on top of `TypeRegistry` and `CommandBuffer` — never imported by Core
//! or exported standalone games.

const std = @import("std");
const engine = @import("engine");

pub const MODULE_OWNER_ID: u64 = 2008;

/// Descriptor for a dockable tool panel registered with the editor shell.
pub const PanelDescriptor = struct {
    id: []const u8,
    title: []const u8,
    open: bool = true,
};

/// Undoable transaction representing a component field modification.
pub const FieldEditTransaction = struct {
    entity: engine.EntityHandle,
    type_id: engine.ComponentTypeId,
    schema_id: engine.reflection.SchemaId,
    field_name: []const u8,
    old_value: engine.reflection.FieldValue,
    new_value: engine.reflection.FieldValue,
};

/// Manages registered editor panels, undo/redo history, and reflection-based inspection.
pub const EditorShellService = struct {
    allocator: std.mem.Allocator,
    panels: std.ArrayList(PanelDescriptor),
    undo_stack: std.ArrayList(FieldEditTransaction),
    redo_stack: std.ArrayList(FieldEditTransaction),

    pub fn init(allocator: std.mem.Allocator) EditorShellService {
        return .{
            .allocator = allocator,
            .panels = .empty,
            .undo_stack = .empty,
            .redo_stack = .empty,
        };
    }

    pub fn deinit(self: *EditorShellService) void {
        for (self.panels.items) |p| {
            self.allocator.free(p.id);
            self.allocator.free(p.title);
        }
        self.panels.deinit(self.allocator);

        for (self.undo_stack.items) |tx| self.allocator.free(tx.field_name);
        self.undo_stack.deinit(self.allocator);

        for (self.redo_stack.items) |tx| self.allocator.free(tx.field_name);
        self.redo_stack.deinit(self.allocator);
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

    /// Inspects and edits a dynamic component field via `TypeRegistry`, recording an undo entry.
    /// Transactional: allocates and reserves undo_stack capacity before mutating the world.
    pub fn setInspectedField(
        self: *EditorShellService,
        world: *engine.World,
        types: *const engine.TypeRegistry,
        entity: engine.EntityHandle,
        schema_id: engine.reflection.SchemaId,
        field_name: []const u8,
        new_value: engine.reflection.FieldValue,
    ) !void {
        const schema = types.getById(schema_id) orelse return error.SchemaNotFound;
        const bytes = world.getRaw(entity, schema.component_type_id) orelse return error.ComponentNotPresent;
        const old_value = try engine.TypeRegistry.getField(schema, bytes, field_name);

        const fname_copy = try self.allocator.dupe(u8, field_name);
        errdefer self.allocator.free(fname_copy);
        try self.undo_stack.ensureUnusedCapacity(self.allocator, 1);

        try engine.TypeRegistry.setField(schema, bytes, field_name, new_value);

        self.undo_stack.appendAssumeCapacity(.{
            .entity = entity,
            .type_id = schema.component_type_id,
            .schema_id = schema_id,
            .field_name = fname_copy,
            .old_value = old_value,
            .new_value = new_value,
        });

        for (self.redo_stack.items) |tx| self.allocator.free(tx.field_name);
        self.redo_stack.clearRetainingCapacity();
    }

    pub fn undo(self: *EditorShellService, world: *engine.World, types: *const engine.TypeRegistry) !bool {
        if (self.undo_stack.items.len == 0) return false;
        const tx = self.undo_stack.items[self.undo_stack.items.len - 1];
        const schema = types.getById(tx.schema_id) orelse return error.SchemaNotFound;
        const bytes = world.getRaw(tx.entity, tx.type_id) orelse return error.ComponentNotPresent;
        try self.redo_stack.ensureUnusedCapacity(self.allocator, 1);

        try engine.TypeRegistry.setField(schema, bytes, tx.field_name, tx.old_value);
        _ = self.undo_stack.pop();
        self.redo_stack.appendAssumeCapacity(tx);
        return true;
    }

    pub fn redo(self: *EditorShellService, world: *engine.World, types: *const engine.TypeRegistry) !bool {
        if (self.redo_stack.items.len == 0) return false;
        const tx = self.redo_stack.items[self.redo_stack.items.len - 1];
        const schema = types.getById(tx.schema_id) orelse return error.SchemaNotFound;
        const bytes = world.getRaw(tx.entity, tx.type_id) orelse return error.ComponentNotPresent;
        try self.undo_stack.ensureUnusedCapacity(self.allocator, 1);

        try engine.TypeRegistry.setField(schema, bytes, tx.field_name, tx.new_value);
        _ = self.redo_stack.pop();
        self.undo_stack.appendAssumeCapacity(tx);
        return true;
    }
};

fn buildModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    try app.resources.insert(EditorShellService, EditorShellService.init(app.allocator));
    const svc = app.resources.get(EditorShellService).?;

    // Register default built-in editor panels.
    try svc.registerPanel(.{ .id = "editor.hierarchy", .title = "Hierarchy" });
    try svc.registerPanel(.{ .id = "editor.inspector", .title = "Inspector" });
    try svc.registerPanel(.{ .id = "editor.console", .title = "Console" });

    try app.services.register(.{
        .capability = "engine.tools.editor_shell",
        .major_version = 1,
        .provider_id = "official.tools.editor_shell",
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
            .id = "official.tools.editor_shell",
            .version = "0.1.0",
            .provides_capabilities = &.{"engine.tools.editor_shell/1"},
            .required_capabilities = &.{"engine.ui.tree/1"},
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
