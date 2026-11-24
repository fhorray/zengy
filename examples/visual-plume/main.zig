//! Visual Plume Widget Gallery (`examples/visual-plume/main.zig`).
//!
//! 3-column widget gallery matching Bevy Feathers layout with sharp corners
//! and embedded Fira Sans TTF typography.
//!
//! Run with: `zig build run-visual-plume`

const std = @import("std");
const engine = @import("engine");
const window = @import("window");
const window_sdl3 = @import("window_sdl3");
const graphics = @import("graphics");
const graphics_sdlgpu = @import("graphics_sdlgpu");
const ui_core = @import("ui_core");
const ui_widgets = @import("ui_widgets");
const ui_plume = @import("ui_plume");

const GalleryState = struct {
    app: *engine.App,
    gfx: *graphics.GraphicsDeviceService,
    input: *window.InputService,
    win: *window.WindowService,
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *ui_plume.UiTheme,
    rt: graphics.RenderTargetHandle,
    cmds: std.ArrayList(graphics.DrawCommand),

    buttons: [40]ui_plume.controls.button.ButtonStyleMeta = undefined,
    btn_count: usize = 0,
    toggles: [16]ui_plume.controls.toggles.ToggleVisualMeta = undefined,
    tog_count: usize = 0,
    slider_meta: ui_plume.controls.inputs.SliderVisualMeta = undefined,
    num_ids: [10]ui_core.UiNodeId = undefined,
    num_count: usize = 0,
    list_rows: [6]ui_core.UiNodeId = undefined,
    menu_items: [8]ui_core.UiNodeId = undefined,
    menu_item_count: usize = 0,
    swatch_preview: ui_plume.controls.color_picker.ColorSwatchHandles = undefined,
    plane_id: ui_core.UiNodeId = undefined,
    hex_input_id: ui_core.UiNodeId = undefined,
    color_sliders: [3]ui_plume.controls.color_picker.ColorSliderHandles = undefined,
    color_inputs: [2]ui_plume.controls.color_picker.ColorInputHandles = undefined,
    current_color: graphics.Color = .{ .r = 0.024, .g = 0.373, .b = 0.275, .a = 0.702 },
    ci_settings: ui_plume.controls.color_picker.ColorInputSettings = .{},

    // New widget showcase state
    toggle_group: ui_plume.controls.toggles.ToggleGroupHandles = undefined,
    range_slider: ui_plume.controls.inputs.RangeSliderHandles = undefined,
    combobox: ui_plume.controls.inputs.ComboboxHandles = undefined,
    table_h: ui_plume.controls.data.TableHandles = undefined,
    progress_h: ui_plume.display.ProgressBarHandles = undefined,
    spinner_h: ui_plume.display.SpinnerHandles = undefined,
    toast_host: ui_plume.controls.overlays.ToastHost = undefined,
    alert_dlg: ui_plume.controls.overlays.AlertDialogHandles = undefined,
    sheet_h: ui_plume.controls.overlays.SheetHandles = undefined,
    cmd_palette: ui_plume.controls.navigation.CommandPaletteHandles = undefined,
    toast_btn: ui_core.UiNodeId = undefined,
    alert_btn: ui_core.UiNodeId = undefined,
    sheet_btn: ui_core.UiNodeId = undefined,
    cmd_btn: ui_core.UiNodeId = undefined,
    anim_phase: f32 = 0.0,
};

fn galleryUpdate(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(GalleryState) orelse return;
    const px = window_sdl3.pixelSize(st.app);
    const dpi: f32 = if (px) |p| (if (p.dpi_scale > 0.0) p.dpi_scale else 1.0) else 1.0;
    const log_w: f32 = if (px) |p| @as(f32, @floatFromInt(p.width)) / dpi else 1120.0;
    const log_h: f32 = if (px) |p| @as(f32, @floatFromInt(p.height)) / dpi else 760.0;

    st.tree.layoutTree(log_w, log_h);
    try st.mgr.processFrameWithDt(st.tree, st.input, st.win, log_w, log_h, ctx.dt * 1000.0);

    for (st.buttons[0..st.btn_count]) |b| {
        ui_plume.controls.button.syncButtonStyle(st.tree, st.th, b);
    }
    for (st.toggles[0..st.tog_count]) |t| {
        ui_plume.controls.toggles.syncToggleStyle(st.tree, st.th, t);
    }
    ui_plume.syncAll(st.tree, st.mgr, st.th);
    ui_plume.controls.inputs.syncSlider(st.tree, st.mgr, st.th, st.slider_meta);
    ui_plume.controls.toggles.syncToggleGroup(st.tree, st.mgr, st.th, &st.toggle_group);
    ui_plume.controls.inputs.syncRangeSlider(st.tree, st.mgr, st.range_slider);
    ui_plume.controls.inputs.syncCombobox(st.tree, st.mgr, st.th, &st.combobox);
    ui_plume.controls.data.syncTable(st.tree, st.mgr, st.th, &st.table_h);
    _ = ui_plume.controls.overlays.syncAlertDialog(st.tree, st.mgr, st.input, &st.alert_dlg);
    ui_plume.controls.overlays.syncSheetWithDt(st.tree, st.mgr, st.input, &st.sheet_h, ctx.dt);
    ui_plume.controls.navigation.syncCommandPalette(st.tree, st.mgr, st.input, st.th, &st.cmd_palette);
    st.toast_host.update(st.tree, st.mgr, ctx.dt * 1000.0);
    st.anim_phase = @mod(st.anim_phase + ctx.dt * 0.65, 1.0);
    ui_plume.display.setIndeterminateProgress(st.tree, st.progress_h, st.anim_phase);
    ui_plume.display.tickSpinner(st.tree, st.spinner_h, st.anim_phase);

    for (st.mgr.eventsSlice()) |ev| {
        if (ev.payload == .activate) {
            if (std.meta.eql(ev.node, st.toast_btn)) {
                st.toast_host.push(st.tree, st.mgr, st.th, .success, "Shader compiled", "Undo", "toast_undo", 3500.0) catch {};
            } else if (std.meta.eql(ev.node, st.alert_btn)) {
                st.alert_dlg.open = true;
            } else if (std.meta.eql(ev.node, st.sheet_btn)) {
                st.sheet_h.open = !st.sheet_h.open;
            } else if (std.meta.eql(ev.node, st.cmd_btn)) {
                st.cmd_palette.open = true;
            } else if (std.mem.eql(u8, ev.tag, "insp_res")) {
                for (25..28) |bi| st.buttons[bi].variant = if (std.meta.eql(st.buttons[bi].node, ev.node)) .primary else .normal;
            } else if (std.mem.eql(u8, ev.tag, "insp_ah")) {
                for (29..32) |bi| st.buttons[bi].variant = if (std.meta.eql(st.buttons[bi].node, ev.node)) .primary else .normal;
            } else if (std.mem.eql(u8, ev.tag, "insp_av")) {
                for (32..35) |bi| st.buttons[bi].variant = if (std.meta.eql(st.buttons[bi].node, ev.node)) .primary else .normal;
            }
        }
        if (std.mem.eql(u8, ev.tag, "plane") and ev.payload == .value_vec2) {
            st.current_color.r = ev.payload.value_vec2[0];
            st.current_color.g = ev.payload.value_vec2[1];
        } else if (std.mem.eql(u8, ev.tag, "cr") and ev.payload == .value_f64) {
            st.current_color.r = @floatCast(ev.payload.value_f64);
        } else if (std.mem.eql(u8, ev.tag, "cg") and ev.payload == .value_f64) {
            st.current_color.g = @floatCast(ev.payload.value_f64);
        } else if (std.mem.eql(u8, ev.tag, "cb") and ev.payload == .value_f64) {
            st.current_color.b = @floatCast(ev.payload.value_f64);
        }
    }
    if (st.tree.resolveId(st.swatch_preview.fill)) |sfi| {
        st.tree.nodes.items[sfi].style.bg_color = st.current_color;
    }
    if (st.tree.resolveId(st.hex_input_id)) |hi| {
        if (!st.tree.nodes.items[hi].focused) {
            var hbuf: [16]u8 = undefined;
            if (ui_widgets.color.formatHexRgba(st.current_color, &hbuf)) |hex| {
                st.tree.setNodeText(hi, hex) catch {};
            } else |_| {}
        }
    }
    ui_plume.controls.color_picker.syncColorPlane(st.tree, st.mgr, st.plane_id, st.current_color.r, st.current_color.g, st.current_color.b);
    for (st.color_sliders, 0..) |cs, si| {
        if (st.mgr.findByNode(cs.root)) |sb| {
            if (sb.behavior == .slider and !sb.behavior.slider.dragging) {
                sb.behavior.slider.value = switch (si) {
                    0 => st.current_color.r,
                    1 => st.current_color.g,
                    else => st.current_color.b,
                };
            }
        }
        ui_plume.controls.color_picker.syncColorSlider(st.tree, st.mgr, cs, st.current_color);
    }
    for (&st.color_inputs) |*ci| ui_plume.controls.color_picker.syncColorInput(st.tree, st.mgr, st.th, ci);

    st.tree.layoutTree(log_w, log_h);
}

fn galleryRender(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(GalleryState) orelse return;
    st.cmds.clearRetainingCapacity();
    try st.cmds.append(st.app.allocator, .{ .clear = st.th.color(.window_bg, .base) });
    try st.tree.paint(st.app.allocator, &st.cmds);
    try st.gfx.beginFrame(st.rt);
    try st.gfx.submitDrawCommands(st.rt, st.cmds.items);
    try st.gfx.present(st.rt);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        if (gpa.deinit() == .leak) std.debug.print("[visual-plume] WARNING: memory leak detected\n", .{});
    }
    const allocator = gpa.allocator();

    var app = engine.App.init(allocator, .{});
    defer app.deinit();

    try app.registerModule(window_sdl3.module());
    try app.registerModule(graphics_sdlgpu.module());
    try app.registerModule(ui_core.module());
    try app.registerModule(ui_widgets.module());
    try app.registerModule(ui_plume.module());

    try app.resources.insert(window_sdl3.WindowConfig, .{
        .title = "Zengy — Plume Widget Gallery",
        .width = 1560,
        .height = 840,
        .resizable = true,
    });

    try app.scheduler.addSystem(.{ .name = "plume.update", .stage = .update, .run = galleryUpdate });
    try app.scheduler.addSystem(.{ .name = "plume.render", .stage = .render_extract, .run = galleryRender });
    try app.initialize();

    const w_entry = try app.services.getService("engine.window", 1);
    const win: *window.WindowService = @ptrCast(@alignCast(@constCast(w_entry.api_ptr)));
    const i_entry = try app.services.getService("engine.input", 1);
    const input: *window.InputService = @ptrCast(@alignCast(@constCast(i_entry.api_ptr)));
    const g_entry = try app.services.getService("engine.graphics.device", 1);
    const gfx: *graphics.GraphicsDeviceService = @ptrCast(@alignCast(@constCast(g_entry.api_ptr)));
    const tree = app.resources.get(ui_core.UiTree).?;
    const mgr = app.resources.get(ui_widgets.WidgetManager).?;
    const th = app.resources.get(ui_plume.UiTheme).?;
    tree.measure_text_fn = graphics_sdlgpu.measureTextWidth;
    tree.measure_text_ctx = gfx.backend_ctx;

    var st = GalleryState{
        .app = &app,
        .gfx = gfx,
        .input = input,
        .win = win,
        .tree = tree,
        .mgr = mgr,
        .th = th,
        .rt = try gfx.createSurface(1, 1560, 840),
        .cmds = .empty,
    };
    defer st.cmds.deinit(allocator);

    const root = try tree.createNode(null, .{
        .id = "root",
        .kind = .panel,
        .style = .{ .direction = .row, .padding = 12, .gap = 12, .bg_color = th.color(.window_bg, .base) },
    });

    // === Column 1: Controls & Color Picker ===
    const col1 = try tree.createNode(root, .{
        .id = "col1",
        .kind = .panel,
        .style = .{ .direction = .column, .width = 390, .padding = 0, .gap = 6, .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
    });

    const btn_row = try tree.createNode(col1, .{ .id = "", .kind = .panel, .style = .{ .direction = .row, .padding = 0, .gap = 6, .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } } });
    st.buttons[0] = try ui_plume.controls.button.button(tree, mgr, th, btn_row, .{ .label = "Normal", .width_spec = .{ .grow = 1 }, .level = .base });
    st.buttons[1] = try ui_plume.controls.button.button(tree, mgr, th, btn_row, .{ .label = "Disabled", .disabled = true, .width_spec = .{ .grow = 1 }, .level = .base });
    st.buttons[2] = try ui_plume.controls.button.button(tree, mgr, th, btn_row, .{ .label = "Primary", .variant = .primary, .width_spec = .{ .grow = 1 }, .level = .base });
    const mh = try ui_plume.controls.overlays.menu(tree, mgr, th, btn_row, "Menu", .base);
    st.buttons[3] = mh.trigger;
    st.menu_items[0] = try ui_plume.controls.overlays.menuItem(tree, mgr, th, mh, "MenuItem 1", "m1");
    st.menu_items[1] = try ui_plume.controls.overlays.menuItem(tree, mgr, th, mh, "MenuItem 2", "m2");
    st.menu_items[2] = try ui_plume.controls.overlays.menuItem(tree, mgr, th, mh, "MenuItem 3", "m3");
    st.menu_item_count = 3;
    st.buttons[4] = try ui_plume.controls.button.button(tree, mgr, th, btn_row, .{ .icon = .color_wheel, .width_spec = .{ .px = 28 }, .level = .base });

    const sel1 = try ui_plume.controls.overlays.select(tree, mgr, th, col1, &.{ "One", "Two", "Three" }, 0, "sel1", .base);
    st.buttons[5] = sel1.menu_handles.trigger;
    const sel2 = try ui_plume.controls.overlays.select(
        tree,
        mgr,
        th,
        col1,
        &.{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" },
        0,
        "sel2",
        .base,
    );
    st.buttons[6] = sel2.menu_handles.trigger;

    const seg_row = try tree.createNode(col1, .{ .id = "", .kind = .panel, .style = .{ .direction = .row, .padding = 0, .gap = 1, .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } } });
    st.buttons[7] = try ui_plume.controls.button.button(tree, mgr, th, seg_row, .{ .label = "Left", .width_spec = .{ .grow = 1 }, .level = .base });
    st.buttons[8] = try ui_plume.controls.button.button(tree, mgr, th, seg_row, .{ .label = "Center", .width_spec = .{ .grow = 1 }, .level = .base });
    st.buttons[9] = try ui_plume.controls.button.button(tree, mgr, th, seg_row, .{ .label = "Right", .variant = .primary, .width_spec = .{ .grow = 1 }, .level = .base });

    const act_row = try tree.createNode(col1, .{ .id = "", .kind = .panel, .style = .{ .direction = .row, .padding = 0, .gap = 6, .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } } });
    st.buttons[10] = try ui_plume.controls.button.button(tree, mgr, th, act_row, .{ .label = "Toggle override", .width_spec = .{ .grow = 1 }, .level = .base });
    st.buttons[11] = try ui_plume.controls.button.button(tree, mgr, th, act_row, .{ .label = "Quit...", .width_spec = .{ .grow = 1 }, .level = .base });

    const dlg_row = try tree.createNode(col1, .{ .id = "", .kind = .panel, .style = .{ .direction = .row, .padding = 0, .gap = 8, .align_items = .center, .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } } });
    _ = try ui_plume.display.label(tree, dlg_row, th, .base, "Dialog:", .main);
    st.toggles[0] = try ui_plume.controls.toggles.toggleSwitch(tree, mgr, th, dlg_row, .{ .checked = false, .level = .base });

    st.toggles[1] = try ui_plume.controls.toggles.checkbox(tree, mgr, th, col1, .{ .label = "Checkbox", .checked = true, .level = .base });
    st.toggles[2] = try ui_plume.controls.toggles.checkbox(tree, mgr, th, col1, .{ .label = "Fast Click Checkbox", .fast_click = true, .level = .base });
    st.toggles[3] = try ui_plume.controls.toggles.checkbox(tree, mgr, th, col1, .{ .label = "Disabled", .disabled = true, .level = .base });
    st.toggles[4] = try ui_plume.controls.toggles.checkbox(tree, mgr, th, col1, .{ .label = "Checked+Disabled", .checked = true, .disabled = true, .level = .base });
    st.toggles[5] = try ui_plume.controls.toggles.radio(tree, mgr, th, col1, .{ .label = "One", .group_id = 1, .checked = true, .level = .base });
    st.toggles[6] = try ui_plume.controls.toggles.radio(tree, mgr, th, col1, .{ .label = "Two", .group_id = 1, .level = .base });
    st.toggles[7] = try ui_plume.controls.toggles.radio(tree, mgr, th, col1, .{ .label = "Fast Click", .group_id = 1, .fast_click = true, .level = .base });
    st.toggles[8] = try ui_plume.controls.toggles.radio(tree, mgr, th, col1, .{ .label = "Disabled", .group_id = 1, .disabled = true, .level = .base });

    const sw_row = try tree.createNode(col1, .{ .id = "", .kind = .panel, .style = .{ .direction = .row, .padding = 0, .gap = 8, .align_items = .center, .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } } });
    st.toggles[9] = try ui_plume.controls.toggles.toggleSwitch(tree, mgr, th, sw_row, .{ .checked = true, .level = .base });
    st.toggles[10] = try ui_plume.controls.toggles.toggleSwitch(tree, mgr, th, sw_row, .{ .checked = false, .level = .base });
    st.toggles[11] = try ui_plume.controls.toggles.toggleSwitch(tree, mgr, th, sw_row, .{ .checked = false, .disabled = true, .level = .base });
    st.toggles[12] = try ui_plume.controls.toggles.toggleSwitch(tree, mgr, th, sw_row, .{ .checked = false, .disabled = true, .level = .base });
    _ = try ui_plume.display.icon(tree, sw_row, th, .base, .chevron_right, 12);
    st.tog_count = 13;

    st.slider_meta = try ui_plume.controls.inputs.slider(tree, mgr, th, col1, .{ .value = 20.0, .min = 0.0, .max = 100.0, .level = .base });

    const srgba_hdr = try tree.createNode(col1, .{ .id = "", .kind = .panel, .style = .{ .direction = .row, .padding = 0, .gap = 6, .align_items = .center, .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } } });
    _ = try ui_plume.display.label(tree, srgba_hdr, th, .base, "Srgba", .main);
    _ = try ui_plume.containers.flexSpacer(tree, srgba_hdr);
    st.hex_input_id = try ui_plume.controls.inputs.textInput(tree, mgr, th, srgba_hdr, .{ .text = "#065F46B3", .width_spec = .{ .px = 100 }, .level = .base });
    st.swatch_preview = try ui_plume.controls.color_picker.colorSwatch(tree, srgba_hdr, th, st.current_color, 24, 24);

    st.plane_id = try ui_plume.controls.color_picker.colorPlane(tree, mgr, col1, 100.0, st.current_color.b, "plane");
    st.color_sliders[0] = try ui_plume.controls.color_picker.colorSlider(tree, mgr, col1, .red, st.current_color, st.current_color.r, "cr");
    st.color_sliders[1] = try ui_plume.controls.color_picker.colorSlider(tree, mgr, col1, .green, st.current_color, st.current_color.g, "cg");
    st.color_sliders[2] = try ui_plume.controls.color_picker.colorSlider(tree, mgr, col1, .blue, st.current_color, st.current_color.b, "cb");

    // === Column 2: Pane / SubPane / Group / Properties & List ===
    const col2 = try tree.createNode(root, .{
        .id = "col2",
        .kind = .panel,
        .style = .{ .direction = .column, .width = 410, .padding = 0, .gap = 10, .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
    });
    const pane_h = try ui_plume.containers.pane(tree, col2, th, "");
    st.buttons[12] = try ui_plume.controls.button.button(tree, mgr, th, pane_h.header, .{ .icon = .color_wheel, .variant = .primary, .width_spec = .{ .px = 26 }, .level = .base });
    _ = try ui_plume.containers.paneHeaderDivider(tree, pane_h.header, th);
    st.buttons[13] = try ui_plume.controls.button.button(tree, mgr, th, pane_h.header, .{ .label = "1/4", .variant = .plain, .width_spec = .{ .px = 34 }, .level = .base });
    st.buttons[14] = try ui_plume.controls.button.button(tree, mgr, th, pane_h.header, .{ .label = "1/2", .variant = .plain, .width_spec = .{ .px = 34 }, .level = .base });
    st.buttons[15] = try ui_plume.controls.button.button(tree, mgr, th, pane_h.header, .{ .label = "3/4", .variant = .plain, .width_spec = .{ .px = 34 }, .level = .base });
    _ = try ui_plume.containers.paneHeaderDivider(tree, pane_h.header, th);
    st.buttons[16] = try ui_plume.controls.button.button(tree, mgr, th, pane_h.header, .{ .icon = .chevron_down, .variant = .plain, .width_spec = .{ .px = 24 }, .level = .base });
    _ = try ui_plume.containers.flexSpacer(tree, pane_h.header);
    st.buttons[17] = try ui_plume.controls.button.button(tree, mgr, th, pane_h.header, .{ .icon = .close_x, .variant = .plain, .width_spec = .{ .px = 24 }, .level = .base });
    st.btn_count = 18;

    _ = try ui_plume.display.label(tree, pane_h.body, th, .higher, "A standard editor pane", .dim);
    const sub_h = try ui_plume.containers.subpane(tree, pane_h.body, th, "");
    _ = try ui_plume.display.label(tree, sub_h.header, th, .highest, "Left", .dim);
    _ = try ui_plume.containers.flexSpacer(tree, sub_h.header);
    _ = try ui_plume.display.label(tree, sub_h.header, th, .highest, "Center", .dim);
    _ = try ui_plume.containers.flexSpacer(tree, sub_h.header);
    _ = try ui_plume.display.label(tree, sub_h.header, th, .highest, "Right", .dim);
    _ = try ui_plume.display.label(tree, sub_h.body, th, .higher, "A standard sub-pane", .dim);

    const grp_h = try ui_plume.containers.group(tree, sub_h.body, th, "Group");
    _ = try ui_plume.display.label(tree, grp_h.body, th, .highest, "A standard group", .main);
    _ = try ui_plume.display.label(tree, grp_h.body, th, .highest, "Scalar property", .dim);
    st.num_ids[0] = try ui_plume.controls.inputs.numberInput(tree, mgr, th, grp_h.body, .{ .value = .{ .f32 = 7.12 }, .precision = 2, .width_spec = .{ .px = 130 }, .tag = "scalar" });
    _ = try ui_plume.display.label(tree, grp_h.body, th, .highest, "Scalar property (copy)", .dim);
    st.num_ids[1] = try ui_plume.controls.inputs.numberInput(tree, mgr, th, grp_h.body, .{ .value = .{ .f32 = 7.12 }, .precision = 2, .width_spec = .{ .px = 130 }, .tag = "scalar_copy" });
    _ = try ui_plume.display.label(tree, grp_h.body, th, .highest, "Vec3 property", .dim);
    const v3 = try ui_plume.controls.inputs.vec3Input(tree, mgr, th, grp_h.body, .{ 10.1, 7.124, 100.0 }, "vx", "vy", "vz", .highest);
    st.num_ids[2] = v3[0];
    st.num_ids[3] = v3[1];
    st.num_ids[4] = v3[2];

    _ = try ui_plume.display.label(tree, grp_h.body, th, .highest, "Color property", .dim);
    const rgba_row = try tree.createNode(grp_h.body, .{ .id = "", .kind = .panel, .style = .{ .direction = .row, .padding = 0, .gap = 4, .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } } });
    st.num_ids[5] = try ui_plume.controls.inputs.numberInput(tree, mgr, th, rgba_row, .{ .value = .{ .i32 = 0 }, .sigil_color = .axis_x, .axis_label = "R", .width_spec = .{ .grow = 1 }, .tag = "cr_i" });
    st.num_ids[6] = try ui_plume.controls.inputs.numberInput(tree, mgr, th, rgba_row, .{ .value = .{ .i32 = 0 }, .sigil_color = .axis_y, .axis_label = "G", .width_spec = .{ .grow = 1 }, .tag = "cg_i" });
    st.num_ids[7] = try ui_plume.controls.inputs.numberInput(tree, mgr, th, rgba_row, .{ .value = .{ .i32 = 0 }, .sigil_color = .axis_z, .axis_label = "B", .width_spec = .{ .grow = 1 }, .tag = "cb_i" });
    st.num_ids[8] = try ui_plume.controls.inputs.numberInput(tree, mgr, th, rgba_row, .{ .value = .{ .i32 = 0 }, .sigil_color = .axis_w, .axis_label = "A", .width_spec = .{ .grow = 1 }, .tag = "ca_i" });
    st.num_count = 9;

    const list_pane = try ui_plume.containers.pane(tree, col2, th, "List");
    const lv = try ui_plume.controls.overlays.listView(tree, mgr, th, list_pane.body, 145, "list", .higher);
    const names = [_][]const u8{ "First World", "Second Nature", "Third Degree", "Fourth Wall", "Fifth Column", "Sixth Sense" };
    for (names, 0..) |nm, idx| {
        st.list_rows[idx] = try ui_plume.controls.overlays.listRow(tree, mgr, th, lv, idx, nm, idx == 1);
    }

    const acc_h = try ui_plume.controls.toggles.accordion(tree, mgr, th, col2, .{
        .title = "Accordion Section",
        .expanded = true,
        .tag = "acc_demo",
        .level = .higher,
    });
    _ = try ui_plume.display.label(tree, acc_h.body, th, .higher, "Collapsible content inside Accordion", .dim);
    st.toggles[13] = acc_h.meta;
    st.tog_count = 14;

    // === Column 3: Compact Color Inputs + New Widgets Showcase ===
    const col3 = try tree.createNode(root, .{
        .id = "col3",
        .kind = .panel,
        .style = .{ .direction = .column, .width_spec = .{ .grow = 1 }, .padding = 0, .gap = 6, .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
    });
    const mbar = try ui_plume.controls.navigation.menubar(tree, th, col3, .base);
    const mb_file = try ui_plume.controls.navigation.menubarMenu(tree, mgr, th, mbar, "File", 1, .base);
    _ = try ui_plume.controls.overlays.menuItem(tree, mgr, th, mb_file, "New Scene", "mb_new");
    _ = try ui_plume.controls.overlays.menuItem(tree, mgr, th, mb_file, "Save", "mb_save");
    const mb_edit = try ui_plume.controls.navigation.menubarMenu(tree, mgr, th, mbar, "Edit", 1, .base);
    _ = try ui_plume.controls.overlays.menuItem(tree, mgr, th, mb_edit, "Undo", "mb_undo");
    _ = try ui_plume.controls.overlays.menuItem(tree, mgr, th, mb_edit, "Redo", "mb_redo");
    const mb_view = try ui_plume.controls.navigation.menubarMenu(tree, mgr, th, mbar, "View", 1, .base);
    _ = try ui_plume.controls.overlays.menuItem(tree, mgr, th, mb_view, "Profiler", "mb_prof");
    st.buttons[18] = mb_file.trigger;
    st.buttons[19] = mb_edit.trigger;
    st.buttons[20] = mb_view.trigger;

    _ = try ui_plume.controls.navigation.breadcrumb(tree, mgr, th, col3, &.{ "Assets", "Characters", "Hero.gltf" }, "bc", .base);

    const ci1_row = try tree.createNode(col3, .{ .id = "", .kind = .panel, .style = .{ .direction = .row, .padding = 0, .gap = 8, .align_items = .center, .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } } });
    _ = try ui_plume.display.label(tree, ci1_row, th, .base, "Armor Tint", .main);
    _ = try ui_plume.containers.flexSpacer(tree, ci1_row);
    st.color_inputs[0] = try ui_plume.controls.color_picker.colorInput(tree, mgr, th, ci1_row, .{ .r = 0.85, .g = 0.45, .b = 0.05, .a = 1.0 }, &st.ci_settings, "ci_armor", .base);

    const ci2_row = try tree.createNode(col3, .{ .id = "", .kind = .panel, .style = .{ .direction = .row, .padding = 0, .gap = 8, .align_items = .center, .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } } });
    _ = try ui_plume.display.label(tree, ci2_row, th, .base, "Skin Color", .main);
    _ = try ui_plume.containers.flexSpacer(tree, ci2_row);
    st.color_inputs[1] = try ui_plume.controls.color_picker.colorInput(tree, mgr, th, ci2_row, .{ .r = 0.12, .g = 0.25, .b = 0.72, .a = 1.0 }, &st.ci_settings, "ci_skin", .base);

    _ = try ui_plume.display.separator(tree, col3, th, .base, .horizontal, "Status & Feedback");
    const badge_row = try tree.createNode(col3, .{ .id = "", .kind = .panel, .style = .{ .direction = .row, .padding = 0, .gap = 6, .align_items = .center, .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } } });
    _ = try ui_plume.display.badge(tree, badge_row, th, .base, "v0.2.0", .accent);
    _ = try ui_plume.display.badge(tree, badge_row, th, .base, "Running", .success);
    _ = try ui_plume.display.chip(tree, mgr, th, badge_row, .base, "3 Errors", .danger, "chip_err");
    st.spinner_h = try ui_plume.display.spinner(tree, badge_row, th, .base, 18);
    st.progress_h = try ui_plume.display.progressBar(tree, col3, th, .base, 0.4);
    _ = try ui_plume.display.alert(tree, col3, th, .base, .warning, "Pipeline Notice", "Right-click Card below for ContextMenu");

    const crd = try ui_plume.containers.card(tree, col3, th, .base, "Scene Filters & Inputs", "Hover buttons for Tooltip, press Ctrl+K");
    const crd_cm = try ui_plume.controls.overlays.contextMenu(tree, mgr, th, tree.idOf(crd.root).?);
    _ = try ui_plume.controls.overlays.menuItem(tree, mgr, th, crd_cm, "Duplicate Card", "ctx_dup");
    _ = try ui_plume.controls.overlays.menuItem(tree, mgr, th, crd_cm, "Reset Filters", "ctx_reset");

    st.toggle_group = try ui_plume.controls.toggles.toggleGroup(tree, mgr, th, crd.content, &.{ "Mesh", "Light", "Collider" }, &.{ true, false, true }, "tg", .higher);
    st.range_slider = try ui_plume.controls.inputs.rangeSlider(tree, mgr, th, crd.content, 0.25, 0.75, 0.0, 1.0, "lod_range", .higher);
    const kb_row = try tree.createNode(crd.content, .{ .id = "", .kind = .panel, .style = .{ .direction = .row, .padding = 0, .gap = 6, .align_items = .center, .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } } });
    _ = try ui_plume.display.label(tree, kb_row, th, .higher, "Shortcut", .dim);
    _ = try ui_plume.containers.flexSpacer(tree, kb_row);
    const kb_id = try ui_plume.controls.inputs.keybindInput(tree, mgr, th, kb_row, "Ctrl+Shift+P", "kb_bind", .higher);
    _ = kb_id;
    st.combobox = try ui_plume.controls.inputs.combobox(tree, mgr, th, crd.content, &.{ "Transform3D", "Camera3D", "PointLight", "MeshRenderer", "RigidBody", "AudioSource" }, 0, "cb_comp", .higher);
    _ = try ui_plume.controls.inputs.textarea(tree, mgr, th, crd.content, "Notes...\nEnter for new line", 48, 256, "notes_ta", .higher);

    const toast_b = try ui_plume.controls.button.button(tree, mgr, th, crd.footer, .{ .label = "Toast", .variant = .primary, .tag = "open_toast", .level = .higher });
    const alert_b = try ui_plume.controls.button.button(tree, mgr, th, crd.footer, .{ .label = "Alert", .variant = .normal, .tag = "open_alert", .level = .higher });
    const sheet_b = try ui_plume.controls.button.button(tree, mgr, th, crd.footer, .{ .label = "Sheet", .variant = .normal, .tag = "open_sheet", .level = .higher });
    const cmd_b = try ui_plume.controls.button.button(tree, mgr, th, crd.footer, .{ .label = "Ctrl+K", .variant = .normal, .tag = "open_cmd", .level = .higher });
    st.toast_btn = toast_b.node;
    st.alert_btn = alert_b.node;
    st.sheet_btn = sheet_b.node;
    st.cmd_btn = cmd_b.node;
    st.buttons[21] = toast_b;
    st.buttons[22] = alert_b;
    st.buttons[23] = sheet_b;
    st.buttons[24] = cmd_b;
    st.btn_count = 25;
    _ = try ui_plume.controls.overlays.tooltip(tree, mgr, th, toast_b.node, "Spawn stackable Toast notification", 350.0);

    st.table_h = try ui_plume.controls.data.table(tree, mgr, th, col3, &.{
        .{ .header = "Entity", .flex = 1 },
        .{ .header = "System", .flex = 1 },
        .{ .header = "ms", .width = 52, .text_align = .right },
    }, &.{
        &.{ "Player", "Physics", "0.42" },
        &.{ "Camera", "Render3D", "1.15" },
        &.{ "Audio", "Mixer", "0.18" },
        &.{ "Particles", "Sim", "0.64" },
        &.{ "Shadows", "Render3D", "0.91" },
    }, .{ .body_height = 96, .striped = true, .hover_highlight = true, .selectable = true, .level = .base }, "ecs_tbl");

    st.toast_host = try ui_plume.controls.overlays.ToastHost.init(tree);
    st.alert_dlg = try ui_plume.controls.overlays.alertDialog(tree, mgr, th, "Delete Entity?", "This action cannot be undone.", "Delete", "Cancel", true, false, "ad");
    st.sheet_h = try ui_plume.controls.overlays.sheet(tree, mgr, th, .right, 260, "Side Drawer", false, "sheet");
    _ = try ui_plume.display.label(tree, st.sheet_h.body, th, .floating, "Edge-anchored Sheet / Drawer", .main);
    st.cmd_palette = try ui_plume.controls.navigation.commandPalette(tree, mgr, th, &.{
        .{ .label = "Build Project", .shortcut = "Ctrl+B", .tag = "cmd_build" },
        .{ .label = "Open Scene", .shortcut = "Ctrl+O", .tag = "cmd_open" },
        .{ .label = "Toggle Profiler", .shortcut = "F9", .tag = "cmd_prof" },
        .{ .label = "Recompile Shaders", .shortcut = "Ctrl+R", .tag = "cmd_shader" },
    }, false);

    // === Column 4: Figma-style Layout / Appearance / Typography Inspector ===
    const col4 = try tree.createNode(root, .{
        .id = "col4",
        .kind = .panel,
        .style = .{
            .direction = .column,
            .width = 270,
            .padding = 8,
            .gap = 8,
            .bg_color = th.color(.pane_body_bg, .base),
            .border_color = th.color(.group_border, .base),
            .border_widths = .{ 1, 1, 1, 1 },
        },
    });
    _ = try ui_plume.display.label(tree, col4, th, .base, "Layout", .main);
    _ = try ui_plume.display.label(tree, col4, th, .base, "Resizing", .dim);
    const res_row = try tree.createNode(col4, .{ .id = "", .kind = .panel, .style = .{ .direction = .row, .padding = 0, .gap = 4, .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } } });
    st.buttons[25] = try ui_plume.controls.button.button(tree, mgr, th, res_row, .{ .icon = .align_left, .width_spec = .{ .grow = 1 }, .tag = "insp_res", .level = .higher });
    st.buttons[26] = try ui_plume.controls.button.button(tree, mgr, th, res_row, .{ .icon = .align_middle, .width_spec = .{ .grow = 1 }, .tag = "insp_res", .level = .higher });
    st.buttons[27] = try ui_plume.controls.button.button(tree, mgr, th, res_row, .{ .icon = .grid_2x2, .variant = .primary, .width_spec = .{ .grow = 1 }, .tag = "insp_res", .level = .higher });

    const wh_row = try tree.createNode(col4, .{ .id = "", .kind = .panel, .style = .{ .direction = .row, .padding = 0, .gap = 6, .align_items = .center, .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } } });
    _ = try ui_plume.controls.inputs.numberInput(tree, mgr, th, wh_row, .{ .value = .{ .i32 = 190 }, .axis_label = "W", .width_spec = .{ .grow = 1 }, .tag = "insp_w" });
    _ = try ui_plume.controls.inputs.numberInput(tree, mgr, th, wh_row, .{ .value = .{ .i32 = 16 }, .axis_label = "H", .width_spec = .{ .grow = 1 }, .tag = "insp_h" });
    st.buttons[28] = try ui_plume.controls.button.button(tree, mgr, th, wh_row, .{ .icon = .maximize_2, .variant = .plain, .width_spec = .{ .px = 24 }, .level = .higher });

    _ = try ui_plume.display.separator(tree, col4, th, .base, .horizontal, null);
    const app_hdr = try tree.createNode(col4, .{ .id = "", .kind = .panel, .style = .{ .direction = .row, .padding = 0, .gap = 6, .align_items = .center, .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } } });
    _ = try ui_plume.display.label(tree, app_hdr, th, .base, "Appearance", .main);
    _ = try ui_plume.containers.flexSpacer(tree, app_hdr);
    _ = try ui_plume.display.icon(tree, app_hdr, th, .base, .eye, 14);
    _ = try ui_plume.display.icon(tree, app_hdr, th, .base, .droplet, 14);

    const app_row = try tree.createNode(col4, .{ .id = "", .kind = .panel, .style = .{ .direction = .row, .padding = 0, .gap = 6, .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } } });
    const op_col = try tree.createNode(app_row, .{ .id = "", .kind = .panel, .style = .{ .direction = .column, .width_spec = .{ .grow = 1 }, .padding = 0, .gap = 3, .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } } });
    _ = try ui_plume.display.label(tree, op_col, th, .base, "Opacity", .dim);
    _ = try ui_plume.controls.inputs.numberInput(tree, mgr, th, op_col, .{ .value = .{ .i32 = 100 }, .min = 0, .max = 100, .axis_label = "%", .width_spec = .{ .grow = 1 }, .tag = "insp_op", .level = .higher });
    const cr_col = try tree.createNode(app_row, .{ .id = "", .kind = .panel, .style = .{ .direction = .column, .width_spec = .{ .grow = 1 }, .padding = 0, .gap = 3, .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } } });
    _ = try ui_plume.display.label(tree, cr_col, th, .base, "Corner radius", .dim);
    _ = try ui_plume.controls.inputs.numberInput(tree, mgr, th, cr_col, .{ .value = .{ .i32 = 0 }, .min = 0, .max = 64, .axis_label = "R", .width_spec = .{ .grow = 1 }, .tag = "insp_cr", .level = .higher });

    _ = try ui_plume.display.separator(tree, col4, th, .base, .horizontal, null);
    const typ_hdr = try tree.createNode(col4, .{ .id = "", .kind = .panel, .style = .{ .direction = .row, .padding = 0, .gap = 6, .align_items = .center, .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } } });
    _ = try ui_plume.display.label(tree, typ_hdr, th, .base, "Typography", .main);
    _ = try ui_plume.containers.flexSpacer(tree, typ_hdr);
    _ = try ui_plume.display.icon(tree, typ_hdr, th, .base, .grid_2x2, 14);

    _ = try ui_plume.controls.overlays.select(tree, mgr, th, col4, &.{ "Fira Sans", "Inter", "JetBrains Mono" }, 0, "font_fam", .higher);
    const wt_row = try tree.createNode(col4, .{ .id = "", .kind = .panel, .style = .{ .direction = .row, .padding = 0, .gap = 6, .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } } });
    _ = try ui_plume.controls.overlays.select(tree, mgr, th, wt_row, &.{ "Regular", "Medium", "Bold" }, 0, "font_wt", .higher);
    _ = try ui_plume.controls.overlays.select(tree, mgr, th, wt_row, &.{ "12", "13", "14", "16", "20" }, 1, "font_sz", .higher);

    const lh_row = try tree.createNode(col4, .{ .id = "", .kind = .panel, .style = .{ .direction = .row, .padding = 0, .gap = 6, .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } } });
    _ = try ui_plume.controls.inputs.textInput(tree, mgr, th, lh_row, .{ .text = "Auto", .width_spec = .{ .grow = 1 }, .level = .higher });
    _ = try ui_plume.controls.inputs.textInput(tree, mgr, th, lh_row, .{ .text = "0%", .width_spec = .{ .grow = 1 }, .level = .higher });

    _ = try ui_plume.display.label(tree, col4, th, .base, "Alignment", .dim);
    const al_row = try tree.createNode(col4, .{ .id = "", .kind = .panel, .style = .{ .direction = .row, .padding = 0, .gap = 4, .align_items = .center, .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } } });
    st.buttons[29] = try ui_plume.controls.button.button(tree, mgr, th, al_row, .{ .icon = .align_left, .width_spec = .{ .px = 26 }, .tag = "insp_ah", .level = .higher });
    st.buttons[30] = try ui_plume.controls.button.button(tree, mgr, th, al_row, .{ .icon = .align_center, .variant = .primary, .width_spec = .{ .px = 26 }, .tag = "insp_ah", .level = .higher });
    st.buttons[31] = try ui_plume.controls.button.button(tree, mgr, th, al_row, .{ .icon = .align_right, .width_spec = .{ .px = 26 }, .tag = "insp_ah", .level = .higher });
    _ = try ui_plume.containers.flexSpacer(tree, al_row);
    st.buttons[32] = try ui_plume.controls.button.button(tree, mgr, th, al_row, .{ .icon = .align_top, .width_spec = .{ .px = 26 }, .tag = "insp_av", .level = .higher });
    st.buttons[33] = try ui_plume.controls.button.button(tree, mgr, th, al_row, .{ .icon = .align_middle, .variant = .primary, .width_spec = .{ .px = 26 }, .tag = "insp_av", .level = .higher });
    st.buttons[34] = try ui_plume.controls.button.button(tree, mgr, th, al_row, .{ .icon = .align_bottom, .width_spec = .{ .px = 26 }, .tag = "insp_av", .level = .higher });
    st.buttons[35] = try ui_plume.controls.button.button(tree, mgr, th, al_row, .{ .icon = .sliders_horizontal, .variant = .primary, .width_spec = .{ .px = 26 }, .level = .higher });
    st.btn_count = 36;

    _ = try ui_plume.display.separator(tree, col4, th, .base, .horizontal, "Scene Tree");
    const tv = try ui_plume.controls.tooling.treeView(tree, th, col4, .base);
    const tv_root = try ui_plume.controls.tooling.treeItemEx(tree, mgr, th, tv, "WorldRoot", .{ .expanded = true, .has_children = true, .icon = .folder, .show_visibility_toggle = true, .level = .higher }, "tv");
    _ = try ui_plume.controls.tooling.treeItemEx(tree, mgr, th, tv_root.children_box, "MainCamera", .{ .has_children = false, .icon = .file, .show_visibility_toggle = true, .level = .higher }, "tv");
    const tv_hero = try ui_plume.controls.tooling.treeItemEx(tree, mgr, th, tv_root.children_box, "Player", .{ .expanded = true, .has_children = true, .icon = .play, .show_visibility_toggle = true, .level = .higher }, "tv");
    _ = try ui_plume.controls.tooling.treeItemEx(tree, mgr, th, tv_hero.children_box, "MeshRenderer", .{ .has_children = false, .icon = .grid_2x2, .show_visibility_toggle = true, .level = .higher }, "tv");
    _ = try ui_plume.controls.tooling.treeItemEx(tree, mgr, th, tv_hero.children_box, "Collider", .{ .has_children = false, .icon = .corner_radius, .show_visibility_toggle = true, .visible_state = false, .level = .higher }, "tv");

    try app.resources.insert(GalleryState, st);
    try window_sdl3.runVisualLoop(&app);
}
