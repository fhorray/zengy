//! Headless Tests for `ui-widgets` (`packages/ui/widgets/tests/ui_widgets_tests.zig`).

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const window = @import("window");
const graphics = @import("graphics");
const ui_core = @import("ui_core");
const ui_widgets = @import("ui_widgets");

test "color conversions round-trip sRGBA <-> HSLA/HWBA and hex" {
    const col = graphics.Color{ .r = 0.024, .g = 0.373, .b = 0.275, .a = 0.702 };
    var buf: [16]u8 = undefined;
    const hex = try ui_widgets.color.formatHexRgba(col, &buf);
    const parsed = ui_widgets.color.parseHexRgba(hex).?;
    try testing.expectApproxEqAbs(col.r, parsed.r, 0.01);
    try testing.expectApproxEqAbs(col.g, parsed.g, 0.01);
    try testing.expectApproxEqAbs(col.b, parsed.b, 0.01);
    try testing.expectApproxEqAbs(col.a, parsed.a, 0.01);

    const hsla = ui_widgets.color.srgbaToHsla(col);
    const back_hsl = ui_widgets.color.hslaToSrgba(hsla);
    try testing.expectApproxEqAbs(col.r, back_hsl.r, 0.01);
    try testing.expectApproxEqAbs(col.g, back_hsl.g, 0.01);
    try testing.expectApproxEqAbs(col.b, back_hsl.b, 0.01);

    const hwba = ui_widgets.color.srgbaToHwba(col);
    const back_hwb = ui_widgets.color.hwbaToSrgba(hwba);
    try testing.expectApproxEqAbs(col.r, back_hwb.r, 0.01);
    try testing.expectApproxEqAbs(col.g, back_hwb.g, 0.01);
    try testing.expectApproxEqAbs(col.b, back_hwb.b, 0.01);
}

test "WidgetManager headless button, fast-click checkbox, radio group, and slider drag" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(window.module());
    try app.registerModule(graphics.module());
    try app.registerModule(ui_core.module());
    try app.registerModule(ui_widgets.module());
    try app.initialize();

    const tree = app.resources.get(ui_core.UiTree).?;
    const mgr = app.resources.get(ui_widgets.WidgetManager).?;
    const input = @as(*window.InputService, @ptrCast(@alignCast(@constCast((try app.services.getService("engine.input", 1)).api_ptr))));

    const root = try tree.createNode(null, .{ .id = "root", .kind = .panel, .style = .{ .width = 300, .height = 200 } });
    const cb_idx = try tree.createNode(root, .{ .id = "cb", .kind = .button, .style = .{ .height = 24 } });
    const r1_idx = try tree.createNode(root, .{ .id = "r1", .kind = .button, .style = .{ .height = 24 } });
    const r2_idx = try tree.createNode(root, .{ .id = "r2", .kind = .button, .style = .{ .height = 24 } });
    const sl_idx = try tree.createNode(root, .{ .id = "sl", .kind = .custom, .style = .{ .height = 24 } });

    const cb_id = tree.idOf(cb_idx).?;
    const r1_id = tree.idOf(r1_idx).?;
    const r2_id = tree.idOf(r2_idx).?;
    const sl_id = tree.idOf(sl_idx).?;

    _ = try mgr.attach(cb_id, "fast_cb", .{ .checkbox = .{ .fast_click = true } });
    _ = try mgr.attach(r1_id, "radio1", .{ .radio = .{ .group_id = 1, .checked = true } });
    _ = try mgr.attach(r2_id, "radio2", .{ .radio = .{ .group_id = 1, .checked = false } });
    _ = try mgr.attach(sl_id, "slider", .{ .slider = .{ .value = 0, .range = .{ .min = 0, .max = 100 } } });

    tree.layoutTree(300, 200);

    // 1. Fast-click checkbox toggles immediately on press.
    const cb_rect = tree.nodes.items[cb_idx].layout;
    input.beginFrame();
    input.injectMouseMove(cb_rect.x + 5, cb_rect.y + 5);
    input.injectMouseButton(.left, true);
    try mgr.processFrame(tree, input, null, 300, 200);
    try testing.expect(tree.nodes.items[cb_idx].checked);

    // Release mouse.
    input.beginFrame();
    input.injectMouseButton(.left, false);
    try mgr.processFrame(tree, input, null, 300, 200);

    // 2. Radio2 click deselects Radio1.
    const r2_rect = tree.nodes.items[r2_idx].layout;
    input.beginFrame();
    input.injectMouseMove(r2_rect.x + 5, r2_rect.y + 5);
    input.injectMouseButton(.left, true);
    try mgr.processFrame(tree, input, null, 300, 200);
    input.beginFrame();
    input.injectMouseButton(.left, false);
    try mgr.processFrame(tree, input, null, 300, 200);
    try testing.expect(!tree.nodes.items[r1_idx].checked);
    try testing.expect(tree.nodes.items[r2_idx].checked);

    // 3. Slider drag to midpoint (~50.0) even when mouse moves vertically outside rect (pointer capture).
    const sl_rect = tree.nodes.items[sl_idx].layout;
    input.beginFrame();
    input.injectMouseMove(sl_rect.x + 2, sl_rect.y + 10);
    input.injectMouseButton(.left, true);
    try mgr.processFrame(tree, input, null, 300, 200);

    input.beginFrame();
    input.injectMouseMove(sl_rect.x + sl_rect.width * 0.5, sl_rect.y + 80);
    try mgr.processFrame(tree, input, null, 300, 200);
    try testing.expectApproxEqAbs(@as(f64, 50.0), mgr.findByNode(sl_id).?.behavior.slider.value, 1.0);

    // 4. Integer NumberInput accumulates sub-integer drag deltas across frames without rounding back to 0.
    input.beginFrame();
    input.injectMouseButton(.left, false);
    try mgr.processFrame(tree, input, null, 300, 200);

    const ni_idx = try tree.createNode(root, .{ .id = "ni", .kind = .custom, .style = .{ .height = 24 } });
    const ni_id = tree.idOf(ni_idx).?;
    _ = try mgr.attach(ni_id, "int_input", .{ .number_input = .{ .value = .{ .i32 = 0 }, .step = 0.05 } });
    tree.layoutTree(300, 200);
    const ni_rect = tree.nodes.items[ni_idx].layout;

    input.beginFrame();
    input.injectMouseMove(ni_rect.x + 5, ni_rect.y + 5);
    input.injectMouseButton(.left, true);
    try mgr.processFrame(tree, input, null, 300, 200);

    // 5 small 2px drags = 10px total -> should reach 5 (0.5 per px).
    for (1..6) |step_i| {
        input.beginFrame();
        input.injectMouseMove(ni_rect.x + 5 + @as(f32, @floatFromInt(step_i * 2)), ni_rect.y + 5);
        try mgr.processFrame(tree, input, null, 300, 200);
    }
    try testing.expectEqual(@as(i32, 5), mgr.findByNode(ni_id).?.behavior.number_input.value.i32);
}

test "WidgetManager node index: attach replaces in place, finds in O(1), and survives clear" {
    var mgr = ui_widgets.WidgetManager.init(testing.allocator);
    defer mgr.deinit();

    const n = 2000;
    for (0..n) |i| {
        const id: ui_core.UiNodeId = .{ .index = @intCast(i), .generation = 1 };
        const slot = try mgr.attach(id, "w", .{ .button = .{} });
        try testing.expectEqual(i, slot);
    }
    const mid: ui_core.UiNodeId = .{ .index = 1234, .generation = 1 };
    try testing.expectEqual(@as(usize, 1234), try mgr.attach(mid, "replaced", .{ .button = .{} }));
    try testing.expectEqual(@as(usize, n), mgr.bindings.items.len);
    try testing.expectEqualStrings("replaced", mgr.findByNode(mid).?.tag);
    // Same index, different generation is a different (stale) node.
    try testing.expect(mgr.findByNode(.{ .index = 1234, .generation = 2 }) == null);

    mgr.clear();
    try testing.expect(mgr.findByNode(mid) == null);
    try testing.expectEqual(@as(usize, 0), try mgr.attach(mid, "", .{ .button = .{} }));
}

test "TextEditState never truncates undo snapshots and clips paste on UTF-8 boundaries" {
    var st: ui_widgets.text_edit.TextEditState = .{};
    st.pushUndo("short");
    try testing.expectEqual(@as(u8, 1), st.undo_count);
    // Oversized text clears history rather than recording a truncated copy.
    const long: [200]u8 = @splat('x');
    st.pushUndo(&long);
    try testing.expectEqual(@as(u8, 0), st.undo_count);

    const clip = ui_widgets.text_edit.TextEditState.clipPaste;
    try testing.expectEqualStrings("ab", clip("abcdef", 2, true));
    // 'é' is 2 bytes: room for 2 bytes after 'a' must not split it.
    try testing.expectEqualStrings("a", clip("aé", 2, true));
    try testing.expectEqualStrings("aé", clip("aé", 3, true));
    try testing.expectEqualStrings("one", clip("one\ntwo", 100, false));
    try testing.expectEqualStrings("one\ntwo", clip("one\ntwo", 100, true));
}

test "NumberInput confirms by Tab with a final event, rejects non-finite text, and caret blinks by elapsed time" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();
    try app.registerModule(window.module());
    try app.registerModule(graphics.module());
    try app.registerModule(ui_core.module());
    try app.registerModule(ui_widgets.module());
    try app.initialize();
    const tree = app.resources.get(ui_core.UiTree).?;
    const mgr = app.resources.get(ui_widgets.WidgetManager).?;
    const input = @as(*window.InputService, @ptrCast(@alignCast(@constCast((try app.services.getService("engine.input", 1)).api_ptr))));

    const root = try tree.createNode(null, .{ .id = "root", .kind = .panel, .style = .{ .width = 300, .height = 200 } });
    const ni_idx = try tree.createNode(root, .{ .id = "ni", .kind = .textbox, .focusable = true, .style = .{ .height = 24 } });
    const other_idx = try tree.createNode(root, .{ .id = "other", .kind = .button, .style = .{ .height = 24 } });
    const ni_id = tree.idOf(ni_idx).?;
    _ = try mgr.attach(ni_id, "num", .{ .number_input = .{ .value = .{ .f64 = 1.0 }, .range = .{ .min = 0, .max = 100 }, .mode = .editing } });
    _ = other_idx;
    tree.layoutTree(300, 200);
    tree.focused_node = ni_idx;
    try tree.setNodeText(ni_idx, "42");

    input.beginFrame();
    input.injectKey(window.KeyCode.tab, true);
    try mgr.processFrame(tree, input, null, 300, 200);

    const ni = mgr.findByNode(ni_id).?.behavior.number_input;
    try testing.expectEqual(@as(f64, 42.0), ni.value.f64);
    try testing.expect(ni.mode == .idle);
    var finals: usize = 0;
    for (mgr.eventsSlice()) |ev| {
        if (std.meta.eql(ev.node, ni_id) and ev.is_final) finals += 1;
    }
    try testing.expectEqual(@as(usize, 1), finals);

    // "nan"/"inf" parse as floats but must never become the value.
    mgr.findByNode(ni_id).?.behavior.number_input.mode = .editing;
    tree.focused_node = ni_idx;
    try tree.setNodeText(ni_idx, "nan");
    input.beginFrame();
    input.injectKey(window.KeyCode.tab, true);
    try mgr.processFrame(tree, input, null, 300, 200);
    try testing.expectEqual(@as(f64, 42.0), mgr.findByNode(ni_id).?.behavior.number_input.value.f64);

    // Caret phase advances by elapsed time: 2 frames of 100 ms -> 0.2, regardless of frame count.
    tree.focused_node = ni_idx;
    tree.caret_phase = 0.0;
    input.beginFrame();
    try mgr.processFrameWithDt(tree, input, null, 300, 200, 100.0);
    input.beginFrame();
    try mgr.processFrameWithDt(tree, input, null, 300, 200, 100.0);
    try testing.expectApproxEqAbs(@as(f32, 0.2), tree.caret_phase, 0.001);
}
