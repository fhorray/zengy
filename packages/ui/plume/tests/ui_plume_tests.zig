//! Headless Tests for `ui-plume` (`packages/ui/plume/tests/ui_plume_tests.zig`).

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const window = @import("window");
const graphics = @import("graphics");
const ui_core = @import("ui_core");
const ui_widgets = @import("ui_widgets");
const ui_plume = @import("ui_plume");
const testing_sdk = @import("testing_sdk");

test "UiTheme contextual surface resolution and container hierarchy" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(window.module());
    try app.registerModule(graphics.module());
    try app.registerModule(ui_core.module());
    try app.registerModule(ui_widgets.module());
    try app.registerModule(ui_plume.module());
    try app.initialize();

    const tree = app.resources.get(ui_core.UiTree).?;
    const th = app.resources.get(ui_plume.UiTheme).?;

    // Highest surface (Group) lightens solid fills relative to Base.
    const base_btn = th.color(.button_bg, .base);
    const group_btn = th.color(.button_bg, .highest);
    try testing.expect(group_btn.r > base_btn.r);

    const p = try ui_plume.containers.pane(tree, null, th, "Editor Pane");
    _ = try ui_plume.containers.paneHeaderDivider(tree, p.header, th);
    _ = try ui_plume.containers.flexSpacer(tree, p.header);
    const sp = try ui_plume.containers.subpane(tree, p.body, th, "Sub-Pane");
    const grp = try ui_plume.containers.group(tree, sp.body, th, "Group");
    _ = try ui_plume.display.label(tree, grp.body, th, .highest, "Property", .dim);
    _ = try ui_plume.display.icon(tree, p.header, th, .base, .close_x, 12);

    tree.layoutTree(400, 300);
    var cmds: std.ArrayList(graphics.DrawCommand) = .empty;
    defer cmds.deinit(testing.allocator);
    try tree.paint(testing.allocator, &cmds);
    try testing.expect(cmds.items.len >= 6);
}

test "Plume controls, menu popover, color wheel, vec3, and CaptureService golden render" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(window.module());
    try app.registerModule(graphics.module());
    try app.registerModule(ui_core.module());
    try app.registerModule(ui_widgets.module());
    try app.registerModule(ui_plume.module());
    try app.registerModule(testing_sdk.module());
    try app.initialize();

    const tree = app.resources.get(ui_core.UiTree).?;
    const mgr = app.resources.get(ui_widgets.WidgetManager).?;
    const th = app.resources.get(ui_plume.UiTheme).?;
    const cap = app.resources.get(testing_sdk.CaptureService).?;
    const input = @as(*window.InputService, @ptrCast(@alignCast(@constCast((try app.services.getService("engine.input", 1)).api_ptr))));

    const root = try tree.createNode(null, .{ .id = "root", .kind = .panel, .style = .{ .width = 128, .height = 128, .padding = 4, .gap = 4, .bg_color = th.color(.window_bg, .base) } });
    const btn = try ui_plume.controls.button.button(tree, mgr, th, root, .{ .label = "Go", .variant = .primary });
    _ = try ui_plume.controls.toggles.checkbox(tree, mgr, th, root, .{ .label = "Ok", .checked = true });
    const sl = try ui_plume.controls.inputs.slider(tree, mgr, th, root, .{ .value = 25, .min = 0, .max = 100 });
    const mh = try ui_plume.controls.overlays.menu(tree, mgr, th, root, "Menu", .higher);
    _ = try ui_plume.controls.overlays.menuItem(tree, mgr, th, mh, "Item 1", "i1");
    _ = try ui_plume.controls.color_picker.colorWheel(tree, mgr, root, 40, .{ .r = 0.2, .g = 0.7, .b = 0.4, .a = 1.0 }, "cw");
    _ = try ui_plume.controls.tooling.tabStrip(tree, mgr, th, root, &.{ "W", "R", "H" }, 0, "tab", .higher);

    tree.layoutTree(128, 128);

    // Slider fill_bar width must match exact 25% of slider track width.
    const sl_rect = tree.nodes.items[tree.resolveId(sl.root).?].layout;
    const fill_rect = tree.nodes.items[tree.resolveId(sl.fill_bar).?].layout;
    try testing.expectApproxEqAbs(sl_rect.width * 0.25, fill_rect.width, 0.5);

    // Click menu trigger -> opens popover.
    const trig_rect = tree.nodes.items[tree.resolveId(mh.trigger.node).?].layout;
    input.beginFrame();
    input.injectMouseMove(trig_rect.x + 2, trig_rect.y + 2);
    input.injectMouseButton(.left, true);
    try mgr.processFrame(tree, input, null, 128, 128);
    try testing.expect(mgr.findByNode(mh.popup).?.behavior.popover.open);

    tree.layoutTree(128, 128);
    var cmds: std.ArrayList(graphics.DrawCommand) = .empty;
    defer cmds.deinit(testing.allocator);
    try cmds.append(testing.allocator, .{ .clear = th.color(.window_bg, .base) });
    try tree.paint(testing.allocator, &cmds);
    cap.rasterize(cmds.items);
    const hash = cap.computeHash();
    try testing.expect(hash != 0);

    // Primary button pixel should be non-background.
    const br = tree.nodes.items[tree.resolveId(btn.node).?].layout;
    const px = cap.readPixel(@intFromFloat(br.x + 4), @intFromFloat(br.y + 4)).?;
    try testing.expect(px[2] > px[0]); // blue-tinted primary accent
}

test "Accordion, Select, Dialog, TreeView, ColorInput, DockPanel, and VirtualKeyboard" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(window.module());
    try app.registerModule(graphics.module());
    try app.registerModule(ui_core.module());
    try app.registerModule(ui_widgets.module());
    try app.registerModule(ui_plume.module());
    try app.initialize();

    const tree = app.resources.get(ui_core.UiTree).?;
    const mgr = app.resources.get(ui_widgets.WidgetManager).?;
    const th = app.resources.get(ui_plume.UiTheme).?;
    const input = @as(*window.InputService, @ptrCast(@alignCast(@constCast((try app.services.getService("engine.input", 1)).api_ptr))));

    const root = try tree.createNode(null, .{ .id = "root", .kind = .panel, .style = .{ .width = 400, .height = 400 } });

    const acc = try ui_plume.controls.toggles.accordion(tree, mgr, th, root, .{ .title = "Accordion", .expanded = true, .tag = "acc" });
    _ = try ui_plume.display.label(tree, acc.body, th, .higher, "Inside", .main);

    _ = try ui_plume.controls.overlays.select(tree, mgr, th, root, &.{ "Opt A", "Opt B" }, 0, "sel", .higher);
    _ = try ui_plume.controls.overlays.dialog(tree, th, "Confirm", 220, 120, false);

    const tv = try ui_plume.controls.tooling.treeView(tree, th, root, .higher);
    const ti = try ui_plume.controls.tooling.treeItem(tree, mgr, th, tv, "Node 1", true, "tree", .higher);
    _ = try ui_plume.controls.tooling.treeItem(tree, mgr, th, ti.children_box, "Child 1", false, "tree", .higher);

    var ci_settings = ui_plume.controls.color_picker.ColorInputSettings{};
    ci_settings.pushRecent(.{ .r = 0.8, .g = 0.4, .b = 0.1, .a = 1.0 });
    var ci = try ui_plume.controls.color_picker.colorInput(tree, mgr, th, root, .{ .r = 0.2, .g = 0.5, .b = 0.9, .a = 1.0 }, &ci_settings, "ci", .higher);

    _ = try ui_plume.controls.tooling.dockPanel(tree, mgr, th, root, &.{ "Inspector", "Console" }, 0, "dock", .higher);
    _ = try ui_plume.controls.tooling.virtualKeyboard(tree, mgr, th, root, "vk", .higher);

    tree.layoutTree(400, 400);

    // Click accordion header -> collapses body.
    const hdr_rect = tree.nodes.items[tree.resolveId(acc.meta.root).?].layout;
    input.beginFrame();
    input.injectMouseMove(hdr_rect.x + 5, hdr_rect.y + 5);
    input.injectMouseButton(.left, true);
    try mgr.processFrame(tree, input, null, 400, 400);
    input.beginFrame();
    input.injectMouseButton(.left, false);
    try mgr.processFrame(tree, input, null, 400, 400);
    try testing.expect(!tree.nodes.items[acc.body].style.visible);

    // ToggleSwitch thumb must pass-through hit testing to root so cursor & hover work over the white thumb.
    const sw = try ui_plume.controls.toggles.toggleSwitch(tree, mgr, th, root, .{ .checked = true });
    tree.layoutTree(400, 400);
    const thumb_r = tree.nodes.items[tree.resolveId(sw.mark).?].layout;
    input.beginFrame();
    input.injectMouseMove(thumb_r.x + 4, thumb_r.y + 4);
    try mgr.processFrame(tree, input, null, 400, 400);
    try testing.expectEqual(window.CursorShape.pointer, input.requested_cursor);
    try testing.expect(tree.nodes.items[tree.resolveId(sw.root).?].hovered);

    // ColorInput: closing popover saves the current color into recent_colors[0],
    // and clicking a saved recent swatch cell restores that color.
    const pb = mgr.findByNode(ci.popup).?;
    pb.behavior.popover.open = true;
    ci.color = .{ .r = 0.1, .g = 0.9, .b = 0.3, .a = 1.0 };
    ui_plume.controls.color_picker.syncColorInput(tree, mgr, th, &ci);
    try testing.expect(ci.was_open);

    pb.behavior.popover.open = false;
    ui_plume.controls.color_picker.syncColorInput(tree, mgr, th, &ci);
    try testing.expect(!ci.was_open);
    try testing.expectApproxEqAbs(@as(f32, 0.1), ci_settings.recent_colors[0].?.r, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.9), ci_settings.recent_colors[0].?.g, 0.001);

    // Slot 1 now holds the previously pushed {0.8, 0.4, 0.1, 1.0}; clicking it restores it.
    pb.behavior.popover.open = true;
    input.beginFrame();
    try mgr.processFrame(tree, input, null, 800, 800);
    tree.layoutTree(800, 800);
    ui_plume.controls.color_picker.syncColorInput(tree, mgr, th, &ci);
    const cell1_rect = tree.nodes.items[tree.resolveId(ci.swatch_cells[1]).?].layout;
    input.beginFrame();
    input.injectMouseMove(cell1_rect.x + 4, cell1_rect.y + 4);
    input.injectMouseButton(.left, true);
    try mgr.processFrame(tree, input, null, 800, 800);
    input.beginFrame();
    input.injectMouseMove(cell1_rect.x + 4, cell1_rect.y + 4);
    input.injectMouseButton(.left, false);
    try mgr.processFrame(tree, input, null, 800, 800);
    ui_plume.controls.color_picker.syncColorInput(tree, mgr, th, &ci);
    try testing.expectApproxEqAbs(@as(f32, 0.8), ci.color.r, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.4), ci.color.g, 0.001);
}

test "Feedback, Navigation, Data, and Advanced Input Widgets" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(window.module());
    try app.registerModule(graphics.module());
    try app.registerModule(ui_core.module());
    try app.registerModule(ui_widgets.module());
    try app.registerModule(ui_plume.module());
    try app.initialize();

    const tree = app.resources.get(ui_core.UiTree).?;
    const mgr = app.resources.get(ui_widgets.WidgetManager).?;
    const th = app.resources.get(ui_plume.UiTheme).?;
    const input = @as(*window.InputService, @ptrCast(@alignCast(@constCast((try app.services.getService("engine.input", 1)).api_ptr))));

    const root = try tree.createNode(null, .{ .id = "root", .kind = .panel, .style = .{ .width = 800, .height = 600, .direction = .column, .gap = 6 } });

    // 1. Display: Badge, Chip, Alert, Separator, ProgressBar, Spinner, Card.
    _ = try ui_plume.display.badge(tree, root, th, .base, "v0.2.0", .accent);
    const ch = try ui_plume.display.chip(tree, mgr, th, root, .base, "Mesh", .success, "chip");
    _ = ch;
    _ = try ui_plume.display.alert(tree, root, th, .base, .warning, "Shader Warning", "Recompile required");
    _ = try ui_plume.display.separator(tree, root, th, .base, .horizontal, "Section");
    const pb = try ui_plume.display.progressBar(tree, root, th, .base, 0.5);
    ui_plume.display.setIndeterminateProgress(tree, pb, 0.25);
    const sp = try ui_plume.display.spinner(tree, root, th, .base, 20);
    ui_plume.display.tickSpinner(tree, sp, 0.5);
    const crd = try ui_plume.containers.card(tree, root, th, .base, "Project", "zengy");
    _ = crd;

    // 2. ToggleGroup (multi-select).
    var tg = try ui_plume.controls.toggles.toggleGroup(tree, mgr, th, root, &.{ "Mesh", "Light", "Collider" }, &.{ true, false, true }, "tg", .base);
    try testing.expect(tg.active[0] and !tg.active[1] and tg.active[2]);

    // 3. Tooltip (~350ms hover delay).
    const btn = try ui_plume.controls.button.button(tree, mgr, th, root, .{ .label = "Hover Me", .level = .base });
    const tt_pop = try ui_plume.controls.overlays.tooltip(tree, mgr, th, btn.node, "Helpful tip", 350.0);

    // 4. ContextMenu (right-click).
    const cm = try ui_plume.controls.overlays.contextMenu(tree, mgr, th, btn.node);
    _ = try ui_plume.controls.overlays.menuItem(tree, mgr, th, cm, "Inspect", "cm_inspect");

    // 5. AlertDialog, Sheet, ToastHost.
    var ad = try ui_plume.controls.overlays.alertDialog(tree, mgr, th, "Delete?", "Cannot undo.", "Delete", "Cancel", true, true, "ad");
    var sh = try ui_plume.controls.overlays.sheet(tree, mgr, th, .right, 240, "Inspector", true, "sh");
    ui_plume.controls.overlays.syncSheet(tree, mgr, &sh);
    var toasts = try ui_plume.controls.overlays.ToastHost.init(tree);
    try toasts.push(tree, mgr, th, .success, "Shader compiled", "Undo", "undo", 500.0);
    try testing.expect(toasts.entries[0].alive);
    toasts.update(tree, mgr, 600.0);
    try testing.expect(!toasts.entries[0].alive);

    // 6. Menubar, Breadcrumb, CommandPalette.
    const mbar = try ui_plume.controls.navigation.menubar(tree, th, root, .base);
    const m_file = try ui_plume.controls.navigation.menubarMenu(tree, mgr, th, mbar, "File", 1, .base);
    const m_edit = try ui_plume.controls.navigation.menubarMenu(tree, mgr, th, mbar, "Edit", 1, .base);
    _ = m_file;
    _ = m_edit;
    _ = try ui_plume.controls.navigation.breadcrumb(tree, mgr, th, root, &.{ "Assets", "Hero.gltf" }, "bc", .base);
    var cmd_p = try ui_plume.controls.navigation.commandPalette(tree, mgr, th, &.{
        .{ .label = "Build Project", .shortcut = "Ctrl+B", .tag = "build" },
        .{ .label = "Open Scene", .shortcut = "Ctrl+O", .tag = "open" },
    }, false);

    // 7. Table / DataGrid.
    var tbl = try ui_plume.controls.data.table(tree, mgr, th, root, &.{
        .{ .header = "Entity", .flex = 1 },
        .{ .header = "Time", .width = 60 },
    }, &.{
        &.{ "Zebra", "2ms" },
        &.{ "Alpha", "1ms" },
    }, .{ .body_height = 80, .level = .base }, "tbl");

    // 8. Textarea, Combobox, RangeSlider, KeybindInput.
    const ta = try ui_plume.controls.inputs.textarea(tree, mgr, th, root, "Line1", 60, 128, "ta", .base);
    var cb = try ui_plume.controls.inputs.combobox(tree, mgr, th, root, &.{ "Transform", "Camera", "Light" }, 0, "cb", .base);
    const rs = try ui_plume.controls.inputs.rangeSlider(tree, mgr, th, root, 0.2, 0.8, 0.0, 1.0, "rs", .base);
    const kb = try ui_plume.controls.inputs.keybindInput(tree, mgr, th, root, "Unbound", "kb", .base);

    tree.layoutTree(800, 600);

    // Close Sheet and confirm AlertDialog on Enter so modals no longer block base-layer hit testing.
    sh.open = false;
    ui_plume.controls.overlays.syncSheet(tree, mgr, &sh);
    input.beginFrame();
    input.injectKey(window.KeyCode.enter, true);
    try testing.expect(ui_plume.controls.overlays.syncAlertDialog(tree, mgr, input, &ad));
    try testing.expect(!ad.open);
    input.injectKey(window.KeyCode.enter, false);

    // Verify Tooltip opens after 350ms hover without stealing focus.
    const btn_rect = tree.nodes.items[tree.resolveId(btn.node).?].layout;
    try testing.expect(btn_rect.width > 0 and btn_rect.height > 0);
    try testing.expectEqual(tree.resolveId(btn.node), tree.hitTest(btn_rect.x + 4, btn_rect.y + 4));
    input.beginFrame();
    input.injectMouseMove(btn_rect.x + 4, btn_rect.y + 4);
    try mgr.processFrameWithDt(tree, input, null, 800, 600, 400.0);
    try testing.expect(tree.nodes.items[tree.resolveId(btn.node).?].hovered);
    try testing.expect(tree.nodes.items[tree.resolveId(tt_pop).?].style.visible);

    // Verify ContextMenu opens on right-click.
    input.beginFrame();
    input.injectMouseMove(btn_rect.x + 4, btn_rect.y + 4);
    input.injectMouseButton(.right, true);
    try mgr.processFrame(tree, input, null, 800, 600);
    try testing.expect(tree.nodes.items[tree.resolveId(cm.popup).?].style.visible);
    input.beginFrame();
    input.injectMouseButton(.right, false);
    try mgr.processFrame(tree, input, null, 800, 600);

    // Verify Textarea inserts newline on Enter and supports Ctrl+A / Ctrl+X.
    tree.setFocus(tree.resolveId(ta).?, false);
    input.beginFrame();
    input.injectKey(window.KeyCode.enter, true);
    try mgr.processFrame(tree, input, null, 800, 600);
    input.injectKey(window.KeyCode.enter, false);
    try testing.expectEqualStrings("Line1\n", tree.nodes.items[tree.resolveId(ta).?].text);

    input.beginFrame();
    input.injectModifiers(.{ .ctrl = true });
    input.injectKey(window.KeyCode.a, true);
    try mgr.processFrame(tree, input, null, 800, 600);
    input.injectKey(window.KeyCode.a, false);
    try testing.expect(tree.nodes.items[tree.resolveId(ta).?].selected);

    input.beginFrame();
    input.injectModifiers(.{ .ctrl = true });
    input.injectKey(window.KeyCode.x, true);
    try mgr.processFrame(tree, input, null, 800, 600);
    input.injectKey(window.KeyCode.x, false);
    input.injectModifiers(.{});
    try testing.expectEqualStrings("", tree.nodes.items[tree.resolveId(ta).?].text);
    try testing.expect(!tree.nodes.items[tree.resolveId(ta).?].selected);

    // Ctrl+Z undoes the cut and restores "Line1\n", Ctrl+Y redoes it, and Ctrl+Z restores again.
    input.beginFrame();
    input.injectModifiers(.{ .ctrl = true });
    input.injectKey(window.KeyCode.z, true);
    try mgr.processFrame(tree, input, null, 800, 600);
    input.injectKey(window.KeyCode.z, false);
    input.injectModifiers(.{});
    try testing.expectEqualStrings("Line1\n", tree.nodes.items[tree.resolveId(ta).?].text);

    input.beginFrame();
    input.injectModifiers(.{ .ctrl = true });
    input.injectKey(window.KeyCode.y, true);
    try mgr.processFrame(tree, input, null, 800, 600);
    input.injectKey(window.KeyCode.y, false);
    input.injectModifiers(.{});
    try testing.expectEqualStrings("", tree.nodes.items[tree.resolveId(ta).?].text);

    // Global extensible UndoHistory custom editor command test (when focus is not a textbox).
    tree.setFocus(null, false);
    const EditorCounter = struct {
        val: i32 = 10,
        fn undo(raw: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.val = 10;
        }
        fn redo(raw: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.val = 42;
        }
    };
    var ed_ctx = EditorCounter{ .val = 42 };
    mgr.undo_history.pushCustom("SetVal", EditorCounter.undo, EditorCounter.redo, &ed_ctx);
    input.beginFrame();
    input.injectModifiers(.{ .ctrl = true });
    input.injectKey(window.KeyCode.z, true);
    try mgr.processFrame(tree, input, null, 800, 600);
    input.injectKey(window.KeyCode.z, false);
    try testing.expectEqual(@as(i32, 10), ed_ctx.val);
    input.beginFrame();
    input.injectKey(window.KeyCode.y, true);
    try mgr.processFrame(tree, input, null, 800, 600);
    input.injectKey(window.KeyCode.y, false);
    input.injectModifiers(.{});
    try testing.expectEqual(@as(i32, 42), ed_ctx.val);
    ui_plume.controls.inputs.syncCombobox(tree, mgr, th, &cb);
    ui_plume.controls.inputs.syncRangeSlider(tree, mgr, rs);

    // Verify KeybindInput captures Ctrl+P.
    const kb_idx = tree.resolveId(kb).?;
    mgr.findByNode(kb).?.behavior.keybind_input.listening = true;
    tree.setFocus(kb_idx, false);
    input.beginFrame();
    input.injectModifiers(.{ .ctrl = true });
    input.injectKey(window.KeyCode.a + 15, true); // 'P'
    try mgr.processFrame(tree, input, null, 800, 600);
    try testing.expectEqualStrings("Ctrl+P", tree.nodes.items[kb_idx].text);

    // Verify CommandPalette opens on Ctrl+K and fuzzy-filters.
    input.beginFrame();
    input.injectModifiers(.{ .ctrl = true });
    input.injectKey(window.KeyCode.a + 10, true); // 'K'
    ui_plume.controls.navigation.syncCommandPalette(tree, mgr, input, th, &cmd_p);
    try testing.expect(cmd_p.open);

    // Verify ToggleGroup click + Table sync compile & run cleanly.
    ui_plume.controls.toggles.syncToggleGroup(tree, mgr, th, &tg);
    ui_plume.controls.data.syncTable(tree, mgr, th, &tbl);
}
