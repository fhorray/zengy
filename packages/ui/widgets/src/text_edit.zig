//! Shared Text Editing Context (`TextEditState`) & Extensible Editor `UndoHistory` (`official.ui.widgets`).
//!
//! Centralizes keyboard shortcuts (`Ctrl+A/C/X/V/Z/Y`, `Ctrl+Shift+Z`, arrows, `Home/End`,
//! `Backspace/Delete`) for every text-editable widget and provides an open, community-extensible
//! command history (`UndoHistory`) that connects UI widgets with future editor actions.

const std = @import("std");
const window = @import("window");
const ui_core = @import("ui_core");
const events = @import("events.zig");

/// Outcome returned by `TextEditState.processInput`.
pub const EditOutcome = struct {
    changed: bool = false,
    submitted: bool = false,
    cancelled: bool = false,
    consumed_undo_redo: bool = false,
};

/// Reusable text editing state (selection + 16-entry undo/redo stack) shared across all editable inputs.
pub const TextEditState = struct {
    all_selected: bool = false,
    undo_buf: [16][128]u8 = @splat(@splat(0)),
    undo_lens: [16]u8 = @splat(0),
    undo_count: u8 = 0,
    redo_buf: [16][128]u8 = @splat(@splat(0)),
    redo_lens: [16]u8 = @splat(0),
    redo_count: u8 = 0,

    /// Clears `all_selected` on pointer click or external reset.
    pub fn clearSelection(self: *TextEditState, tree: *ui_core.UiTree, idx: usize) void {
        self.all_selected = false;
        if (idx < tree.nodes.items.len) tree.nodes.items[idx].selected = false;
    }

    fn pushSnap(bufs: *[16][128]u8, lens: *[16]u8, count: *u8, txt: []const u8) void {
        const n = @min(txt.len, 128);
        if (count.* > 0) {
            const top = count.* - 1;
            if (lens[top] == n and std.mem.eql(u8, bufs[top][0..n], txt[0..n])) return;
        }
        if (count.* >= 16) {
            for (0..15) |i| {
                bufs[i] = bufs[i + 1];
                lens[i] = lens[i + 1];
            }
            count.* = 15;
        }
        @memcpy(bufs[count.*][0..n], txt[0..n]);
        lens[count.*] = @intCast(n);
        count.* += 1;
    }

    /// Pushes current text to the undo stack and invalidates the redo stack.
    pub fn pushUndo(self: *TextEditState, txt: []const u8) void {
        pushSnap(&self.undo_buf, &self.undo_lens, &self.undo_count, txt);
        self.redo_count = 0;
    }

    /// Processes all standard editing, clipboard, undo/redo, and cursor-navigation shortcuts.
    pub fn processInput(
        self: *TextEditState,
        tree: *ui_core.UiTree,
        idx: usize,
        input: *const window.InputService,
        win_svc: ?*window.WindowService,
        allocator: std.mem.Allocator,
        max_len: usize,
        multiline: bool,
    ) !EditOutcome {
        var out = EditOutcome{};
        const mod = input.modifiers;

        if (mod.ctrl and input.wasKeyPressed(window.KeyCode.a)) {
            self.all_selected = tree.nodes.items[idx].text.len > 0;
            tree.nodes.items[idx].selected = self.all_selected;
            return out;
        }

        if (mod.ctrl and !mod.shift and input.wasKeyPressed(window.KeyCode.z)) {
            if (self.undo_count > 0) {
                pushSnap(&self.redo_buf, &self.redo_lens, &self.redo_count, tree.nodes.items[idx].text);
                self.undo_count -= 1;
                const ulen = self.undo_lens[self.undo_count];
                try tree.setNodeText(idx, self.undo_buf[self.undo_count][0..ulen]);
                tree.text_cursor = ulen;
                self.clearSelection(tree, idx);
                out.changed = true;
                out.consumed_undo_redo = true;
            }
            return out;
        }

        if (mod.ctrl and (input.wasKeyPressed(window.KeyCode.y) or (mod.shift and input.wasKeyPressed(window.KeyCode.z)))) {
            if (self.redo_count > 0) {
                pushSnap(&self.undo_buf, &self.undo_lens, &self.undo_count, tree.nodes.items[idx].text);
                self.redo_count -= 1;
                const rlen = self.redo_lens[self.redo_count];
                try tree.setNodeText(idx, self.redo_buf[self.redo_count][0..rlen]);
                tree.text_cursor = rlen;
                self.clearSelection(tree, idx);
                out.changed = true;
                out.consumed_undo_redo = true;
            }
            return out;
        }

        if (mod.ctrl and input.wasKeyPressed(window.KeyCode.c)) {
            if (win_svc) |ws| ws.setClipboardText(tree.nodes.items[idx].text) catch {};
            return out;
        }

        if (mod.ctrl and input.wasKeyPressed(window.KeyCode.x)) {
            self.pushUndo(tree.nodes.items[idx].text);
            if (win_svc) |ws| ws.setClipboardText(tree.nodes.items[idx].text) catch {};
            if (tree.nodes.items[idx].text.len > 0) {
                try tree.setNodeText(idx, "");
                out.changed = true;
            }
            self.clearSelection(tree, idx);
            return out;
        }

        if (mod.ctrl and input.wasKeyPressed(window.KeyCode.v)) {
            if (win_svc) |ws| {
                if (ws.getClipboardText(allocator) catch null) |ct| {
                    defer allocator.free(ct);
                    self.pushUndo(tree.nodes.items[idx].text);
                    if (self.all_selected) {
                        try tree.setNodeText(idx, "");
                        self.clearSelection(tree, idx);
                    }
                    if (try tree.handleTextInput(ct)) out.changed = true;
                }
            }
            return out;
        }

        if (!mod.ctrl and input.last_text_len > 0) {
            const txt = input.last_text[0..input.last_text_len];
            self.pushUndo(tree.nodes.items[idx].text);
            if (self.all_selected) {
                try tree.setNodeText(idx, "");
                self.clearSelection(tree, idx);
            }
            if (tree.nodes.items[idx].text.len + txt.len <= max_len) {
                if (try tree.handleTextInput(txt)) out.changed = true;
            }
        }

        if (input.wasKeyPressed(window.KeyCode.left)) {
            self.clearSelection(tree, idx);
            tree.moveTextCursor(-1);
        } else if (input.wasKeyPressed(window.KeyCode.right)) {
            self.clearSelection(tree, idx);
            tree.moveTextCursor(1);
        } else if (input.wasKeyPressed(window.KeyCode.home)) {
            self.clearSelection(tree, idx);
            tree.moveTextCursorLineEdge(false);
        } else if (input.wasKeyPressed(window.KeyCode.end)) {
            self.clearSelection(tree, idx);
            tree.moveTextCursorLineEdge(true);
        } else if (multiline and input.wasKeyPressed(window.KeyCode.up)) {
            self.clearSelection(tree, idx);
            tree.moveTextCursorVertical(-1);
        } else if (multiline and input.wasKeyPressed(window.KeyCode.down)) {
            self.clearSelection(tree, idx);
            tree.moveTextCursorVertical(1);
        }

        if (input.wasKeyPressed(window.KeyCode.backspace) or input.wasKeyPressed(window.KeyCode.delete)) {
            self.pushUndo(tree.nodes.items[idx].text);
            if (self.all_selected) {
                try tree.setNodeText(idx, "");
                self.clearSelection(tree, idx);
                out.changed = true;
            } else if (input.wasKeyPressed(window.KeyCode.backspace)) {
                if (try tree.handleBackspace()) out.changed = true;
            } else if (try tree.handleDelete()) {
                out.changed = true;
            }
        }

        if (input.wasKeyPressed(window.KeyCode.enter)) {
            self.clearSelection(tree, idx);
            if (multiline) {
                if (tree.nodes.items[idx].text.len + 1 <= max_len) {
                    self.pushUndo(tree.nodes.items[idx].text);
                    if (try tree.handleTextInput("\n")) out.changed = true;
                }
            } else {
                out.submitted = true;
            }
        } else if (input.wasKeyPressed(window.KeyCode.escape)) {
            self.clearSelection(tree, idx);
            out.cancelled = true;
        }

        return out;
    }
};

/// Callback signature for custom editor/community undo and redo commands.
pub const UndoCallback = *const fn (ctx: ?*anyopaque) void;

/// Polymorphic command entry stored in `UndoHistory` (widget value snapshot or custom editor hook).
pub const UndoCommand = union(enum) {
    widget_bool: struct { node: ui_core.UiNodeId, prev: bool, next: bool },
    widget_f64: struct { node: ui_core.UiNodeId, prev: f64, next: f64 },
    widget_vec2: struct { node: ui_core.UiNodeId, prev: [2]f64, next: [2]f64 },
    widget_numeric: struct { node: ui_core.UiNodeId, prev: events.NumericValue, next: events.NumericValue },
    custom: struct {
        label: []const u8 = "",
        undo_fn: UndoCallback,
        redo_fn: UndoCallback,
        ctx: ?*anyopaque = null,
    },
};

/// Fixed-capacity (64-entry) unified Undo/Redo history shared across widgets and custom editor tools.
pub const UndoHistory = struct {
    entries: [64]UndoCommand = undefined,
    len: usize = 0,
    cursor: usize = 0,

    /// Appends `cmd` at `cursor`, discarding any invalidated redo tail.
    pub fn push(self: *UndoHistory, cmd: UndoCommand) void {
        if (self.cursor < self.entries.len) {
            self.entries[self.cursor] = cmd;
            self.cursor += 1;
            self.len = self.cursor;
        } else {
            for (0..self.entries.len - 1) |i| {
                self.entries[i] = self.entries[i + 1];
            }
            self.entries[self.entries.len - 1] = cmd;
            self.len = self.entries.len;
            self.cursor = self.entries.len;
        }
    }

    /// Convenience helper for custom editor/community commands (`MoveEntity`, `DeleteNode`, etc.).
    pub fn pushCustom(self: *UndoHistory, label: []const u8, undo_fn: UndoCallback, redo_fn: UndoCallback, ctx: ?*anyopaque) void {
        self.push(.{ .custom = .{ .label = label, .undo_fn = undo_fn, .redo_fn = redo_fn, .ctx = ctx } });
    }

    /// Returns the command to undo and moves `cursor` back, or `null` if at the beginning.
    pub fn stepUndo(self: *UndoHistory) ?UndoCommand {
        if (self.cursor == 0) return null;
        self.cursor -= 1;
        return self.entries[self.cursor];
    }

    /// Returns the command to redo and advances `cursor`, or `null` if at the tip.
    pub fn stepRedo(self: *UndoHistory) ?UndoCommand {
        if (self.cursor >= self.len) return null;
        const cmd = self.entries[self.cursor];
        self.cursor += 1;
        return cmd;
    }
};
