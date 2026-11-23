//! UI Frontends IR Equivalence Tests (`packages/ui-markup/tests/ui_frontends_tests.zig`).
//!
//! Validates Phases 9 & 10: two independent declarative UI frontends
//! (`official.ui.markup` HTML-like and `community.ui.novaui` DSL) produce
//! structurally identical `UiTree` IR without any special-casing in `src/core/`.

const std = @import("std");
const testing = std.testing;
const ui_core = @import("ui_core");
const ui_markup = @import("ui_markup");
const ui_novaui = @import("ui_novaui");

test "HTML-like markup and NovaUI community DSL produce equivalent UiTree IR" {
    var tree_html = ui_core.UiTree.init(testing.allocator);
    defer tree_html.deinit();

    var tree_nova = ui_core.UiTree.init(testing.allocator);
    defer tree_nova.deinit();

    const html_src =
        \\<ui-document>
        \\  <panel id="developer.console">
        \\    <label id="caption">Developer Console</label>
        \\    <button id="clear_btn" action="debug.clear">Clear</button>
        \\  </panel>
        \\</ui-document>
    ;

    const nova_src =
        \\Panel id="developer.console" {
        \\  Label id="caption" text="Developer Console"
        \\  Button id="clear_btn" text="Clear" action="debug.clear"
        \\}
    ;

    try ui_markup.parseIntoTree(testing.allocator, html_src, &tree_html);
    try ui_novaui.parseIntoTree(testing.allocator, nova_src, &tree_nova);

    try testing.expectEqual(tree_html.nodeCount(), tree_nova.nodeCount());
    for (tree_html.nodes.items, tree_nova.nodes.items) |a, b| {
        try testing.expectEqual(a.kind, b.kind);
        try testing.expectEqualStrings(a.id, b.id);
        try testing.expectEqualStrings(a.text, b.text);
        try testing.expectEqualStrings(a.action, b.action);
        try testing.expectEqual(a.children.items.len, b.children.items.len);
    }
}
