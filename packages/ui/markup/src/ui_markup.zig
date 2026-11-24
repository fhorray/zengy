//! Official HTML-like UI Markup Frontend (`official.ui.markup`).
//!
//! Translates declarative `<ui-document>` / `<panel>` / `<label>` / `<button>` /
//! `<text-input>` / `<virtual-list>` markup into `ui_core.UiTree` nodes.
//!
//! This frontend is completely optional and replaceable; `ui-core` and `src/core/`
//! have zero knowledge of HTML or markup syntax.

const std = @import("std");
const ui_core = @import("ui_core");

pub const MarkupError = error{
    MalformedTag,
    UnclosedTag,
    OutOfMemory,
};

fn extractAttr(attrs: []const u8, key: []const u8) []const u8 {
    var i: usize = 0;
    while (i < attrs.len) {
        while (i < attrs.len and std.ascii.isWhitespace(attrs[i])) : (i += 1) {}
        if (i >= attrs.len) break;

        const key_start = i;
        while (i < attrs.len and attrs[i] != '=' and !std.ascii.isWhitespace(attrs[i])) : (i += 1) {}
        const attr_key = attrs[key_start..i];
        while (i < attrs.len and (attrs[i] == '=' or std.ascii.isWhitespace(attrs[i]))) : (i += 1) {}
        if (i >= attrs.len) break;

        var val: []const u8 = "";
        if (attrs[i] == '"') {
            i += 1;
            const val_start = i;
            while (i < attrs.len and attrs[i] != '"') : (i += 1) {}
            val = attrs[val_start..i];
            if (i < attrs.len and attrs[i] == '"') i += 1;
        } else {
            const val_start = i;
            while (i < attrs.len and !std.ascii.isWhitespace(attrs[i])) : (i += 1) {}
            val = attrs[val_start..i];
        }

        if (std.mem.eql(u8, attr_key, key)) {
            return val;
        }
    }
    return "";
}

/// Parses a minimal HTML-like markup document into a UiTree IR.
pub fn parseIntoTree(allocator: std.mem.Allocator, source: []const u8, tree: *ui_core.UiTree) !void {
    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(allocator);

    var i: usize = 0;
    while (i < source.len) {
        const lt = std.mem.indexOfScalarPos(u8, source, i, '<') orelse break;
        const gt = std.mem.indexOfScalarPos(u8, source, lt + 1, '>') orelse return error.MalformedTag;
        const tag_body = std.mem.trim(u8, source[lt + 1 .. gt], " \t\r\n");
        i = gt + 1;

        if (tag_body.len == 0) continue;

        if (tag_body[0] == '/') {
            if (stack.items.len > 0) {
                _ = stack.pop();
            }
            continue;
        }

        const self_closing = tag_body[tag_body.len - 1] == '/';
        const clean_body = if (self_closing) std.mem.trimEnd(u8, tag_body[0 .. tag_body.len - 1], " \t") else tag_body;

        var space_idx: usize = 0;
        while (space_idx < clean_body.len and !std.ascii.isWhitespace(clean_body[space_idx])) : (space_idx += 1) {}
        const tag_name = clean_body[0..space_idx];
        const attrs = if (space_idx < clean_body.len) clean_body[space_idx + 1 ..] else "";

        if (std.mem.eql(u8, tag_name, "ui-document")) {
            continue;
        }

        const id = extractAttr(attrs, "id");
        const action = extractAttr(attrs, "action");
        var text = extractAttr(attrs, "text");

        // Capture inner text for <label>...</label> or <button>...</button>
        if (!self_closing and text.len == 0) {
            if (std.mem.indexOfScalarPos(u8, source, i, '<')) |next_lt| {
                const candidate = std.mem.trim(u8, source[i..next_lt], " \t\r\n");
                if (candidate.len > 0) {
                    text = candidate;
                }
            }
        }

        const kind: ?ui_core.NodeKind = if (std.mem.eql(u8, tag_name, "panel"))
            .panel
        else if (std.mem.eql(u8, tag_name, "label"))
            .label
        else if (std.mem.eql(u8, tag_name, "button"))
            .button
        else if (std.mem.eql(u8, tag_name, "text-input"))
            .textbox
        else if (std.mem.eql(u8, tag_name, "virtual-list"))
            .virtual_list
        else
            null;

        if (kind) |k| {
            const parent = if (stack.items.len > 0) stack.items[stack.items.len - 1] else null;
            const node_idx = try tree.createNode(parent, .{
                .id = id,
                .kind = k,
                .text = text,
                .action = action,
            });
            if (!self_closing) {
                try stack.append(allocator, node_idx);
            }
        }
    }
}
