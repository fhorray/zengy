//! UI Core Package Tests (`packages/ui/core/tests/ui_core_tests.zig`).
//!
//! Validates Phase 6 `UiTree`: 1000+ node layout, spatial hit testing,
//! focus assignment, `ui.action` event emission, and `DrawCommand` paint list.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const window = @import("window");
const graphics = @import("graphics");
const ui_core = @import("ui_core");

test "UiTree 1000+ nodes layout, hit testing, focus, click action, and paint list" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(window.module());
    try app.registerModule(graphics.module());
    try app.registerModule(ui_core.module());
    try app.initialize();

    const ActionCatcher = struct {
        fired: bool = false,
        fn onAction(raw: ?*anyopaque, ev: engine.EventEnvelope) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (std.mem.eql(u8, ev.payload, "debug.clear")) {
                self.fired = true;
            }
        }
    };
    var catcher = ActionCatcher{};
    _ = try app.events.subscribe(999, "ui.action", ActionCatcher.onAction, &catcher);

    const tree = app.resources.get(ui_core.UiTree).?;
    const panel = try tree.createNode(null, .{ .id = "root.panel", .kind = .panel });
    _ = try tree.createNode(panel, .{ .id = "lbl", .kind = .label, .text = "Console" });
    const btn = try tree.createNode(panel, .{
        .id = "btn_clear",
        .kind = .button,
        .text = "Clear",
        .action = "debug.clear",
    });

    for (0..1000) |i| {
        var buf: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&buf, "item_{d}", .{i});
        _ = try tree.createNode(panel, .{ .id = id, .kind = .label, .text = "log" });
    }
    try testing.expectEqual(@as(usize, 1003), tree.nodeCount());

    tree.layoutTree(800, 600);
    const btn_rect = tree.nodes.items[btn].layout;
    const hit = tree.handlePointerClick(btn_rect.x + 4, btn_rect.y + 4, &app.events);
    try testing.expectEqual(@as(?usize, btn), hit);
    try testing.expect(tree.nodes.items[btn].focused);

    _ = app.events.drain();
    try testing.expect(catcher.fired);

    var cmds: std.ArrayList(graphics.DrawCommand) = .empty;
    defer cmds.deinit(testing.allocator);
    try tree.paint(testing.allocator, &cmds);
    try testing.expect(cmds.items.len >= 1003);
}

test "UiTree textbox input, backspace, scrollNode, and clip_rect emission" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(window.module());
    try app.registerModule(graphics.module());
    try app.registerModule(ui_core.module());
    try app.initialize();

    const u_entry = try app.services.getService("engine.ui.tree", 1);
    const tree: *ui_core.UiTree = @ptrCast(@alignCast(@constCast(u_entry.api_ptr)));

    const tb = try tree.createNode(null, .{ .id = "tb", .kind = .textbox, .text = "hi" });
    const list = try tree.createNode(null, .{
        .id = "lst",
        .kind = .virtual_list,
        .style = .{ .height = 40.0, .clip_children = true },
    });
    _ = try tree.createNode(list, .{ .id = "c0", .kind = .label, .text = "row0" });

    tree.layoutTree(400.0, 300.0);
    const tb_rect = tree.nodes.items[tb].layout;
    _ = tree.handlePointerClick(tb_rect.x + 2.0, tb_rect.y + 2.0, &app.events);

    try testing.expect(try tree.handleTextInput("!"));
    try testing.expectEqualStrings("hi!", tree.nodes.items[tb].text);
    try testing.expect(try tree.handleBackspace());
    try testing.expectEqualStrings("hi", tree.nodes.items[tb].text);

    tree.scrollNode(list, 10.0);
    try testing.expectEqual(@as(f32, 10.0), tree.nodes.items[list].scroll_y);

    var cmds: std.ArrayList(graphics.DrawCommand) = .empty;
    defer cmds.deinit(testing.allocator);
    try tree.paint(testing.allocator, &cmds);

    var saw_clip_open = false;
    var saw_clip_close = false;
    for (cmds.items) |cmd| {
        if (cmd == .clip_push) saw_clip_open = true;
        if (cmd == .clip_pop) saw_clip_close = true;
    }
    try testing.expect(saw_clip_open and saw_clip_close);
}

test "UiTree v2 generational ids, Tab navigation, pointer capture, and overlay layering" {
    var tree = ui_core.UiTree.init(testing.allocator);
    defer tree.deinit();

    const root = try tree.createNode(null, .{
        .id = "root",
        .kind = .panel,
        .style = .{ .direction = .row, .width = 400, .height = 100 },
    });
    const b1 = try tree.createNode(root, .{ .id = "b1", .kind = .button, .text = "A" });
    const b2 = try tree.createNode(root, .{ .id = "b2", .kind = .button, .text = "B" });
    const ov = try tree.createNode(null, .{
        .id = "overlay",
        .kind = .panel,
        .style = .{ .position = .absolute, .left = 10, .top = 10, .width = 80, .height = 40, .layer = .overlay },
    });

    tree.layoutTree(400, 300);

    // Overlay should win hit testing over base layer at (20, 20).
    try testing.expectEqual(@as(?usize, ov), tree.hitTest(20, 20));

    // Tab navigation cycles focusable nodes.
    try testing.expectEqual(@as(?usize, b1), tree.focusNext(false));
    try testing.expect(tree.nodes.items[b1].focus_visible);
    try testing.expectEqual(@as(?usize, b2), tree.focusNext(false));
    try testing.expectEqual(@as(?usize, b1), tree.focusNext(true));

    // Generational ID invalidates after subtree removal.
    const b2_id = tree.idOf(b2).?;
    try testing.expectEqual(@as(?usize, b2), tree.resolveId(b2_id));
    tree.removeSubtree(b2);
    try testing.expectEqual(@as(?usize, null), tree.resolveId(b2_id));
}

test "UiTree.clear invalidates old handles and destroyed slots are reused" {
    var tree = ui_core.UiTree.init(testing.allocator);
    defer tree.deinit();

    const a = try tree.createNode(null, .{ .id = "a", .kind = .panel });
    const old_a = tree.idOf(a).?;
    tree.clear();
    // Old handles must stay dead even though the slot index is handed out again.
    try testing.expect(tree.resolveId(old_a) == null);
    const b = try tree.createNode(null, .{ .id = "b", .kind = .panel });
    try testing.expect(tree.resolveId(old_a) == null);
    try testing.expect(tree.resolveId(tree.idOf(b).?) != null);

    // Removing and recreating nodes must not grow the slot array.
    for (0..100) |i| {
        const n = try tree.createNode(b, .{ .id = "", .kind = .panel });
        const h = tree.idOf(n).?;
        tree.removeSubtree(n);
        try testing.expect(tree.resolveId(h) == null);
        _ = i;
    }
    try testing.expect(tree.nodes.items.len <= 3);
    try testing.expectEqual(@as(usize, 1), tree.nodeCount());
}

test "UiTree text editing moves, inserts, and deletes whole UTF-8 code points" {
    var tree = ui_core.UiTree.init(testing.allocator);
    defer tree.deinit();
    const tb = try tree.createNode(null, .{ .id = "t", .kind = .textbox });
    tree.focused_node = tb;
    try tree.setNodeText(tb, "añ€😀b");

    tree.text_cursor = tree.nodes.items[tb].text.len;
    try testing.expect(try tree.handleBackspace()); // removes 'b'
    try testing.expect(try tree.handleBackspace()); // removes the 4-byte emoji
    try testing.expectEqualStrings("añ€", tree.nodes.items[tb].text);
    try testing.expect(std.unicode.utf8ValidateSlice(tree.nodes.items[tb].text));

    tree.moveTextCursor(-1); // before '€'
    try testing.expectEqual(@as(usize, 3), tree.text_cursor);
    try testing.expect(try tree.handleDelete()); // removes '€' (3 bytes)
    try testing.expectEqualStrings("añ", tree.nodes.items[tb].text);

    // A cursor stranded inside a code point snaps to a boundary before inserting.
    tree.text_cursor = 2; // middle of 'ñ'
    try testing.expect(try tree.handleTextInput("é"));
    try testing.expectEqualStrings("aéñ", tree.nodes.items[tb].text);

    // Invalid UTF-8 never enters the buffer.
    try testing.expect(!(try tree.handleTextInput("\xff\xfe")));
    try testing.expectEqualStrings("aéñ", tree.nodes.items[tb].text);
}

test "UiTree focus: skips hidden subtrees, traps Tab inside a modal, sanitizes stale focus, and handles many nodes" {
    var tree = ui_core.UiTree.init(testing.allocator);
    defer tree.deinit();

    const page = try tree.createNode(null, .{ .id = "page", .kind = .panel });
    const b1 = try tree.createNode(page, .{ .id = "b1", .kind = .button });
    const hidden_panel = try tree.createNode(page, .{ .id = "hp", .kind = .panel });
    const hidden_btn = try tree.createNode(hidden_panel, .{ .id = "hb", .kind = .button });
    const b2 = try tree.createNode(page, .{ .id = "b2", .kind = .button });
    tree.nodes.items[hidden_panel].style.visible = false;

    // Child of a hidden ancestor is not reachable by Tab even though its own flag is visible.
    try testing.expect(!tree.isEffectivelyVisible(hidden_btn));
    try testing.expectEqual(@as(?usize, b1), tree.focusNext(false));
    try testing.expectEqual(@as(?usize, b2), tree.focusNext(false));
    try testing.expectEqual(@as(?usize, b1), tree.focusNext(false));

    // Focus on a node whose ancestor gets hidden is dropped by sanitizeFocus.
    tree.nodes.items[hidden_panel].style.visible = true;
    tree.setFocus(hidden_btn, true);
    tree.nodes.items[hidden_panel].style.visible = false;
    tree.sanitizeFocus();
    try testing.expect(tree.focused_node == null);
    try testing.expect(!tree.nodes.items[hidden_btn].focused);

    // Modal traps Tab: only its descendants are candidates, and outside focus is cleared.
    const modal = try tree.createNode(null, .{ .id = "m", .kind = .panel, .style = .{ .layer = .modal } });
    const m1 = try tree.createNode(modal, .{ .id = "m1", .kind = .button });
    const m2 = try tree.createNode(modal, .{ .id = "m2", .kind = .button });
    tree.setFocus(b1, true);
    tree.sanitizeFocus();
    try testing.expect(tree.focused_node == null);
    try testing.expectEqual(@as(?usize, m1), tree.focusNext(false));
    try testing.expectEqual(@as(?usize, m2), tree.focusNext(false));
    try testing.expectEqual(@as(?usize, m1), tree.focusNext(false));
    try testing.expectEqual(@as(?usize, m2), tree.focusNext(true)); // reverse wraps within the modal
    tree.nodes.items[modal].style.visible = false;
    try testing.expectEqual(@as(?usize, b1), tree.focusNext(false)); // modal closed: back to page

    // More than 256 focusable nodes: every one is reachable.
    var tree2 = ui_core.UiTree.init(testing.allocator);
    defer tree2.deinit();
    const root = try tree2.createNode(null, .{ .id = "r", .kind = .panel });
    for (0..400) |_| _ = try tree2.createNode(root, .{ .id = "", .kind = .button });
    var visited: usize = 0;
    var last: ?usize = null;
    while (visited < 400) : (visited += 1) last = tree2.focusNext(false);
    try testing.expectEqual(@as(?usize, 400), last); // 400th button is node index 400 (root is 0)
    try testing.expectEqual(@as(?usize, 1), tree2.focusNext(false)); // wraps
}
