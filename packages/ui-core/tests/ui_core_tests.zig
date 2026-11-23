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
