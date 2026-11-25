//! Editor document: entities, selection and a single authoring history for transform and
//! reflected-field edits. Headless-friendly (no window/GPU); presentation stays in `main.zig`.

const std = @import("std");
const engine = @import("engine");
const render_3d = @import("render_3d");

/// Maximum stored entity name length in bytes; longer names are truncated.
pub const MAX_NAME_LEN = 32;

/// Maximum retained undo steps; the oldest step is dropped beyond this.
pub const MAX_HISTORY = 256;

/// One entity listed in the hierarchy.
pub const Entry = struct {
    entity: engine.EntityHandle,
    name_buf: [MAX_NAME_LEN]u8 = @splat(0),
    name_len: u8 = 0,

    /// Returns the display name.
    pub fn name(self: *const Entry) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

/// A reversible change of one entity's `Transform3D`.
pub const TransformEdit = struct {
    entity: engine.EntityHandle,
    before: render_3d.Transform3D,
    after: render_3d.Transform3D,
};

/// A reversible reflected field edit (same shape as the former shell-local transaction).
pub const FieldEdit = struct {
    entity: engine.EntityHandle,
    type_id: engine.ComponentTypeId,
    schema_id: engine.reflection.SchemaId,
    field_name: []const u8,
    old_value: engine.reflection.FieldValue,
    new_value: engine.reflection.FieldValue,
};

/// One chronological authoring step. Transform and field edits share a single undo/redo stack.
pub const HistoryEntry = union(enum) {
    transform: TransformEdit,
    field: FieldEdit,
};

/// Returns true when both handles refer to the same live entity slot and generation.
pub fn sameEntity(a: engine.EntityHandle, b: engine.EntityHandle) bool {
    return a.index == b.index and a.generation == b.generation;
}

/// Entities, selection and unified authoring history of one editor session.
pub const EditorDocument = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    selected: ?engine.EntityHandle = null,
    undo_stack: std.ArrayList(HistoryEntry) = .empty,
    redo_stack: std.ArrayList(HistoryEntry) = .empty,
    /// When true, the document differs from the last successful save checkpoint.
    dirty: bool = false,
    saved_revision: u64 = 0,
    revision: u64 = 0,

    /// Creates an empty document.
    pub fn init(allocator: std.mem.Allocator) EditorDocument {
        return .{ .allocator = allocator };
    }

    /// Releases all document storage. Entities themselves stay in the world.
    pub fn deinit(self: *EditorDocument) void {
        self.clearHistoryStacks();
        self.entries.deinit(self.allocator);
        self.undo_stack.deinit(self.allocator);
        self.redo_stack.deinit(self.allocator);
    }

    fn clearHistoryStacks(self: *EditorDocument) void {
        for (self.undo_stack.items) |e| freeEntry(self.allocator, e);
        for (self.redo_stack.items) |e| freeEntry(self.allocator, e);
        self.undo_stack.clearRetainingCapacity();
        self.redo_stack.clearRetainingCapacity();
    }

    /// Lists `entity` in the hierarchy under `name` (truncated to `MAX_NAME_LEN`).
    pub fn register(self: *EditorDocument, entity: engine.EntityHandle, name: []const u8) !void {
        if (self.indexOf(entity) != null) return error.DuplicateEntity;
        var entry: Entry = .{ .entity = entity };
        const n = @min(name.len, MAX_NAME_LEN);
        @memcpy(entry.name_buf[0..n], name[0..n]);
        entry.name_len = @intCast(n);
        try self.entries.append(self.allocator, entry);
    }

    /// Returns the hierarchy index of `entity`, or null when it is not listed.
    pub fn indexOf(self: *const EditorDocument, entity: engine.EntityHandle) ?usize {
        for (self.entries.items, 0..) |e, i| {
            if (sameEntity(e.entity, entity)) return i;
        }
        return null;
    }

    /// Returns the hierarchy entry of the selected entity, if any.
    pub fn selectedEntry(self: *const EditorDocument) ?*const Entry {
        const sel = self.selected orelse return null;
        const i = self.indexOf(sel) orelse return null;
        return &self.entries.items[i];
    }

    /// Selects `entity`. Entities that are not listed cannot be selected, which clears the selection.
    pub fn select(self: *EditorDocument, entity: ?engine.EntityHandle) void {
        const e = entity orelse {
            self.selected = null;
            return;
        };
        self.selected = if (self.indexOf(e) != null) e else null;
    }

    /// Moves the selection `step` rows through the hierarchy (wrapping); selects the first row when nothing is selected.
    pub fn selectRelative(self: *EditorDocument, step: isize) void {
        const len: isize = @intCast(self.entries.items.len);
        if (len == 0) return;
        const cur: isize = if (self.selected) |s| @intCast(self.indexOf(s) orelse 0) else -step;
        const next: usize = @intCast(@mod(cur + step, len));
        self.selected = self.entries.items[next].entity;
    }

    /// Removes `entity` from the hierarchy and from the history, and clears the selection if it was selected.
    /// Returns false when the entity was not listed. The entity is not despawned.
    pub fn unregister(self: *EditorDocument, entity: engine.EntityHandle) bool {
        const i = self.indexOf(entity) orelse return false;
        _ = self.entries.orderedRemove(i);
        if (self.selected) |s| {
            if (sameEntity(s, entity)) self.selected = null;
        }
        purge(self.allocator, &self.undo_stack, entity);
        purge(self.allocator, &self.redo_stack, entity);
        return true;
    }

    /// Sets the entity's transform and records an undo step. Clears the redo history.
    pub fn setTransform(self: *EditorDocument, world: *engine.World, entity: engine.EntityHandle, after: render_3d.Transform3D) !void {
        if (self.indexOf(entity) == null) return error.EntityNotInDocument;
        if (!finiteTransform(after)) return error.InvalidTransform;
        const before = (world.getConst(entity, render_3d.Transform3D) orelse return error.MissingTransform).*;
        if (std.meta.eql(before, after)) return;
        try self.preparePush();
        try world.set(entity, render_3d.Transform3D, after);
        self.undo_stack.appendAssumeCapacity(.{ .transform = .{ .entity = entity, .before = before, .after = after } });
        self.markEdited();
    }

    /// Edits a reflected field through the ECS mutation contract and records one history entry.
    pub fn setField(
        self: *EditorDocument,
        world: *engine.World,
        types: *const engine.TypeRegistry,
        entity: engine.EntityHandle,
        schema_id: engine.reflection.SchemaId,
        field_name: []const u8,
        new_value: engine.reflection.FieldValue,
    ) !void {
        const schema = types.getById(schema_id) orelse return error.SchemaNotFound;
        const bytes = world.getRawConst(entity, schema.component_type_id) orelse return error.ComponentNotPresent;
        const old_value = try engine.TypeRegistry.getField(schema, bytes, field_name);
        if (fieldValuesEqual(old_value, new_value)) return;

        const fname_copy = try self.allocator.dupe(u8, field_name);
        errdefer self.allocator.free(fname_copy);
        try self.preparePush();
        try types.setReflectedField(world, entity, schema_id, field_name, new_value);
        self.undo_stack.appendAssumeCapacity(.{ .field = .{
            .entity = entity,
            .type_id = schema.component_type_id,
            .schema_id = schema_id,
            .field_name = fname_copy,
            .old_value = old_value,
            .new_value = new_value,
        } });
        self.markEdited();
    }

    /// Reverts the latest authoring edit. Returns false when nothing applicable remains.
    pub fn undo(self: *EditorDocument, world: *engine.World, types: ?*const engine.TypeRegistry) !bool {
        while (self.undo_stack.items.len > 0) {
            try self.redo_stack.ensureUnusedCapacity(self.allocator, 1);
            const edit = self.undo_stack.pop().?;
            switch (edit) {
                .transform => |t| {
                    if (self.indexOf(t.entity) == null or world.getConst(t.entity, render_3d.Transform3D) == null) {
                        freeEntry(self.allocator, edit);
                        continue;
                    }
                    try world.set(t.entity, render_3d.Transform3D, t.before);
                    self.redo_stack.appendAssumeCapacity(edit);
                    self.syncDirtyFromRevision();
                    return true;
                },
                .field => |f| {
                    const reg = types orelse {
                        freeEntry(self.allocator, edit);
                        continue;
                    };
                    if (world.getRawConst(f.entity, f.type_id) == null) {
                        freeEntry(self.allocator, edit);
                        continue;
                    }
                    try reg.setReflectedField(world, f.entity, f.schema_id, f.field_name, f.old_value);
                    self.redo_stack.appendAssumeCapacity(edit);
                    self.syncDirtyFromRevision();
                    return true;
                },
            }
        }
        return false;
    }

    /// Re-applies the latest undone edit.
    pub fn redo(self: *EditorDocument, world: *engine.World, types: ?*const engine.TypeRegistry) !bool {
        while (self.redo_stack.items.len > 0) {
            try self.undo_stack.ensureUnusedCapacity(self.allocator, 1);
            const edit = self.redo_stack.pop().?;
            switch (edit) {
                .transform => |t| {
                    if (self.indexOf(t.entity) == null or world.getConst(t.entity, render_3d.Transform3D) == null) {
                        freeEntry(self.allocator, edit);
                        continue;
                    }
                    try world.set(t.entity, render_3d.Transform3D, t.after);
                    self.undo_stack.appendAssumeCapacity(edit);
                    self.markEdited();
                    return true;
                },
                .field => |f| {
                    const reg = types orelse {
                        freeEntry(self.allocator, edit);
                        continue;
                    };
                    if (world.getRawConst(f.entity, f.type_id) == null) {
                        freeEntry(self.allocator, edit);
                        continue;
                    }
                    try reg.setReflectedField(world, f.entity, f.schema_id, f.field_name, f.new_value);
                    self.undo_stack.appendAssumeCapacity(edit);
                    self.markEdited();
                    return true;
                },
            }
        }
        return false;
    }

    /// Compatibility wrapper used by the MVP keyboard path (transform-only undo).
    pub fn undoTransform(self: *EditorDocument, world: *engine.World) !bool {
        return self.undo(world, null);
    }

    /// Compatibility wrapper used by the MVP keyboard path (transform-only redo).
    pub fn redoTransform(self: *EditorDocument, world: *engine.World) !bool {
        return self.redo(world, null);
    }

    /// Marks the current revision as saved (clears dirty).
    pub fn markSaved(self: *EditorDocument) void {
        self.saved_revision = self.revision;
        self.dirty = false;
    }

    fn preparePush(self: *EditorDocument) !void {
        try self.undo_stack.ensureUnusedCapacity(self.allocator, 1);
        if (self.undo_stack.items.len >= MAX_HISTORY) {
            const dropped = self.undo_stack.orderedRemove(0);
            freeEntry(self.allocator, dropped);
        }
        for (self.redo_stack.items) |e| freeEntry(self.allocator, e);
        self.redo_stack.clearRetainingCapacity();
    }

    fn markEdited(self: *EditorDocument) void {
        self.revision += 1;
        self.dirty = self.revision != self.saved_revision;
    }

    fn syncDirtyFromRevision(self: *EditorDocument) void {
        if (self.revision > 0) self.revision -= 1;
        self.dirty = self.revision != self.saved_revision;
    }
};

fn freeEntry(allocator: std.mem.Allocator, entry: HistoryEntry) void {
    switch (entry) {
        .transform => {},
        .field => |f| allocator.free(f.field_name),
    }
}

fn purge(allocator: std.mem.Allocator, stack: *std.ArrayList(HistoryEntry), entity: engine.EntityHandle) void {
    var i: usize = 0;
    while (i < stack.items.len) {
        const matches = switch (stack.items[i]) {
            .transform => |t| sameEntity(t.entity, entity),
            .field => |f| sameEntity(f.entity, entity),
        };
        if (matches) {
            freeEntry(allocator, stack.orderedRemove(i));
        } else i += 1;
    }
}

fn finiteTransform(t: render_3d.Transform3D) bool {
    inline for (.{ t.position, t.rotation_euler, t.scale }) |vec| {
        inline for (vec) |v| {
            if (!std.math.isFinite(v)) return false;
        }
    }
    return true;
}

fn fieldValuesEqual(a: engine.reflection.FieldValue, b: engine.reflection.FieldValue) bool {
    return std.meta.eql(a, b);
}
