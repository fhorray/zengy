const std = @import("std");
const ui_core = @import("ui_core");

/// Community DSL ("NovaUI") frontend that compiles into the exact same UiTree IR
/// without any special-casing in src/core or ui-core.
///
/// Syntax example:
/// Panel id="developer.console" {
///   Label id="caption" text="Developer Console"
///   Button id="clear_btn" text="Clear" action="debug.clear"
/// }
pub fn parseIntoTree(allocator: std.mem.Allocator, source: []const u8, tree: *ui_core.UiTree) !void {
    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(allocator);

    var line_it = std.mem.splitScalar(u8, source, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "//")) continue;

        if (std.mem.eql(u8, line, "}")) {
            if (stack.items.len > 0) _ = stack.pop();
            continue;
        }

        const opens_block = std.mem.endsWith(u8, line, "{");
        const content = if (opens_block) std.mem.trimEnd(u8, line[0 .. line.len - 1], " \t") else line;

        var first_space: usize = 0;
        while (first_space < content.len and !std.ascii.isWhitespace(content[first_space])) : (first_space += 1) {}
        const keyword = content[0..first_space];
        const rest = if (first_space < content.len) content[first_space + 1 ..] else "";

        const kind: ?ui_core.NodeKind = if (std.mem.eql(u8, keyword, "Panel"))
            .panel
        else if (std.mem.eql(u8, keyword, "Label"))
            .label
        else if (std.mem.eql(u8, keyword, "Button"))
            .button
        else if (std.mem.eql(u8, keyword, "TextInput"))
            .textbox
        else if (std.mem.eql(u8, keyword, "VirtualList"))
            .virtual_list
        else
            null;

        if (kind) |k| {
            const id = extractProp(rest, "id");
            const text = extractProp(rest, "text");
            const action = extractProp(rest, "action");
            const parent = if (stack.items.len > 0) stack.items[stack.items.len - 1] else null;
            const idx = try tree.createNode(parent, .{
                .id = id,
                .kind = k,
                .text = text,
                .action = action,
            });
            if (opens_block) {
                try stack.append(allocator, idx);
            }
        }
    }
}

fn extractProp(line: []const u8, key: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len) {
        while (i < line.len and std.ascii.isWhitespace(line[i])) : (i += 1) {}
        if (i >= line.len) break;

        const k_start = i;
        while (i < line.len and line[i] != '=' and !std.ascii.isWhitespace(line[i])) : (i += 1) {}
        const k = line[k_start..i];
        while (i < line.len and (line[i] == '=' or std.ascii.isWhitespace(line[i]))) : (i += 1) {}
        if (i >= line.len) break;

        var val: []const u8 = "";
        if (line[i] == '"') {
            i += 1;
            const v_start = i;
            while (i < line.len and line[i] != '"') : (i += 1) {}
            val = line[v_start..i];
            if (i < line.len and line[i] == '"') i += 1;
        } else {
            const v_start = i;
            while (i < line.len and !std.ascii.isWhitespace(line[i])) : (i += 1) {}
            val = line[v_start..i];
        }

        if (std.mem.eql(u8, k, key)) return val;
    }
    return "";
}
