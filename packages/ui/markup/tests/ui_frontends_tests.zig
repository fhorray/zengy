//! UI Markup Frontend Tests (`packages/ui/markup/tests/ui_frontends_tests.zig`).
//!
//! Validates HTML-like markup parsing into `ui_core.UiTree` IR.

const std = @import("std");
const testing = std.testing;
const ui_core = @import("ui_core");
const ui_markup = @import("ui_markup");

test "HTML-like markup parses into expected UiTree IR" {
    var tree_html = ui_core.UiTree.init(testing.allocator);
    defer tree_html.deinit();

    const html_src =
        \\<ui-document>
        \\  <panel id="developer.console">
        \\    <label id="caption">Developer Console</label>
        \\    <button id="clear_btn" action="debug.clear">Clear</button>
        \\  </panel>
        \\</ui-document>
    ;

    try ui_markup.parseIntoTree(testing.allocator, html_src, &tree_html);

    try testing.expectEqual(@as(usize, 3), tree_html.nodeCount());
    try testing.expectEqual(ui_core.NodeKind.panel, tree_html.nodes.items[0].kind);
    try testing.expectEqualStrings("developer.console", tree_html.nodes.items[0].id);
    try testing.expectEqual(@as(usize, 2), tree_html.nodes.items[0].children.items.len);
    try testing.expectEqual(ui_core.NodeKind.label, tree_html.nodes.items[1].kind);
    try testing.expectEqualStrings("Developer Console", tree_html.nodes.items[1].text);
    try testing.expectEqual(ui_core.NodeKind.button, tree_html.nodes.items[2].kind);
    try testing.expectEqualStrings("debug.clear", tree_html.nodes.items[2].action);
}
