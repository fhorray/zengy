//! UI Core Package Tests (`packages/ui-core/tests/ui_core_tests.zig`).
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
        if (cmd == .clip_rect) {
            if (cmd.clip_rect != null) saw_clip_open = true else saw_clip_close = true;
        }
    }
    try testing.expect(saw_clip_open and saw_clip_close);
}
