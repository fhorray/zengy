//! Editor document: the entities an editor session manages, the current selection and a transform
//! undo/redo history. It is plain data over `engine.World`, so it runs and is tested headless
//! (no window, GPU or input), and the editor executable only adds presentation on top of it.

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

/// Returns true when both handles refer to the same live entity slot and generation.
pub fn sameEntity(a: engine.EntityHandle, b: engine.EntityHandle) bool {
    return a.index == b.index and a.generation == b.generation;
}

/// Entities, selection and transform history of one editor session.
pub const EditorDocument = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    selected: ?engine.EntityHandle = null,
    undo_stack: std.ArrayList(TransformEdit) = .empty,
    redo_stack: std.ArrayList(TransformEdit) = .empty,

    /// Creates an empty document.
    pub fn init(allocator: std.mem.Allocator) EditorDocument {
        return .{ .allocator = allocator };
    }

    /// Releases all document storage. Entities themselves stay in the world.
    pub fn deinit(self: *EditorDocument) void {
        self.entries.deinit(self.allocator);
        self.undo_stack.deinit(self.allocator);
        self.redo_stack.deinit(self.allocator);
    }

    /// Lists `entity` in the hierarchy under `name` (truncated to `MAX_NAME_LEN`).
    pub fn register(self: *EditorDocument, entity: engine.EntityHandle, name: []const u8) !void {
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
        purge(&self.undo_stack, entity);
        purge(&self.redo_stack, entity);
        return true;
    }

    /// Sets the entity's transform and records an undo step. Clears the redo history.
    /// Reserves history capacity before mutating so a failed allocation leaves the world untouched.
    /// Rejects entities that are not listed in this document.
    pub fn setTransform(self: *EditorDocument, world: *engine.World, entity: engine.EntityHandle, after: render_3d.Transform3D) !void {
        if (self.indexOf(entity) == null) return error.EntityNotInDocument;
        if (!finiteTransform(after)) return error.InvalidTransform;
        const before = (world.getConst(entity, render_3d.Transform3D) orelse return error.MissingTransform).*;
        if (std.meta.eql(before, after)) return;
        try self.undo_stack.ensureUnusedCapacity(self.allocator, 1);
        if (self.undo_stack.items.len >= MAX_HISTORY) _ = self.undo_stack.orderedRemove(0);
        try world.set(entity, render_3d.Transform3D, after);
        self.undo_stack.appendAssumeCapacity(.{ .entity = entity, .before = before, .after = after });
        self.redo_stack.clearRetainingCapacity();
    }

    /// Reverts the latest transform edit. Returns false when there is nothing to undo or the
    /// target is no longer a listed, live transform entity (stale entries are dropped).
    pub fn undo(self: *EditorDocument, world: *engine.World) !bool {
        while (self.undo_stack.items.len > 0) {
            try self.redo_stack.ensureUnusedCapacity(self.allocator, 1);
            const edit = self.undo_stack.pop().?;
            if (self.indexOf(edit.entity) == null or world.getConst(edit.entity, render_3d.Transform3D) == null) {
                continue; // drop stale history; do not report success
            }
            try world.set(edit.entity, render_3d.Transform3D, edit.before);
            self.redo_stack.appendAssumeCapacity(edit);
            return true;
        }
        return false;
    }

    /// Re-applies the latest undone transform edit. Returns false when there is nothing to redo
    /// or the target is no longer applicable.
    pub fn redo(self: *EditorDocument, world: *engine.World) !bool {
        while (self.redo_stack.items.len > 0) {
            try self.undo_stack.ensureUnusedCapacity(self.allocator, 1);
            const edit = self.redo_stack.pop().?;
            if (self.indexOf(edit.entity) == null or world.getConst(edit.entity, render_3d.Transform3D) == null) {
                continue;
            }
            try world.set(edit.entity, render_3d.Transform3D, edit.after);
            self.undo_stack.appendAssumeCapacity(edit);
            return true;
        }
        return false;
    }

    fn purge(stack: *std.ArrayList(TransformEdit), entity: engine.EntityHandle) void {
        var i: usize = 0;
        while (i < stack.items.len) {
            if (sameEntity(stack.items[i].entity, entity)) {
                _ = stack.orderedRemove(i);
            } else i += 1;
        }
    }
};

fn finiteTransform(t: render_3d.Transform3D) bool {
    inline for (.{ t.position, t.rotation_euler, t.scale }) |vec| {
        inline for (vec) |v| {
            if (!std.math.isFinite(v)) return false;
        }
    }
    return true;
}
