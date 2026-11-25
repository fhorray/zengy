//! Headless Plume panel rebuild for the editor harness.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const window = @import("window");
const graphics = @import("graphics");
const ui_core = @import("ui_core");
const ui_widgets = @import("ui_widgets");
const ui_plume = @import("ui_plume");
const document = @import("document");
const panels = @import("panels");
const render_3d = @import("render_3d");

test "Plume hierarchy and inspector rebuild from EditorDocument" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();
    try app.registerModule(window.module());
    try app.registerModule(graphics.module());
    try app.registerModule(ui_core.module());
    try app.registerModule(ui_widgets.module());
    try app.registerModule(ui_plume.module());
    try app.initialize();

    var doc = document.EditorDocument.init(testing.allocator);
    defer doc.deinit();
    const e = try app.world.spawn();
    try app.world.set(e, render_3d.Transform3D, .{ .position = .{ 1, 0, 0 } });
    try doc.register(e, "Cube");
    doc.select(e);

    const tree = app.resources.get(ui_core.UiTree).?;
    const mgr = app.resources.get(ui_widgets.WidgetManager).?;
    const th = app.resources.get(ui_plume.UiTheme).?;
    try panels.rebuild(tree, mgr, th, &doc, 1280, 720);
    try testing.expect(tree.nodeCount() >= 1);

    var cmds: std.ArrayList(graphics.DrawCommand) = .empty;
    defer cmds.deinit(testing.allocator);
    try panels.paint(tree, testing.allocator, &cmds);
    try testing.expect(cmds.items.len > 0);
}
