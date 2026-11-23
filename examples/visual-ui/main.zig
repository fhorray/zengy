//! Visual UI Hello (D4) — Retained UiTree, Markup Frontend, Text Atlas, Click, Textbox & Clipping (`examples/visual-ui/main.zig`).
//!
//! Builds a UI tree using `ui_markup` (proving markup parity), handles real mouse clicks,
//! keyboard/text input for a textbox, scroll/clipping for a list, and renders with high-DPI
//! scaling through `official.graphics.sdlgpu`.
//!
//! Run with: `zig build run-visual-ui`

const std = @import("std");
const engine = @import("engine");
const window = @import("window");
const window_sdl3 = @import("window_sdl3");
const graphics = @import("graphics");
const graphics_sdlgpu = @import("graphics_sdlgpu");
const ui_core = @import("ui_core");
const ui_markup = @import("ui_markup");

const UiDemoState = struct {
    app: *engine.App,
    gfx: *graphics.GraphicsDeviceService,
    win: *window.WindowService,
    input: *window.InputService,
    tree: *ui_core.UiTree,
    rt: graphics.RenderTargetHandle,
    cmds: std.ArrayList(graphics.DrawCommand),
    click_count: u32 = 0,
    list_idx: ?usize = null,
    status_idx: ?usize = null,
};

fn onUiAction(user_ctx: ?*anyopaque, ev: engine.EventEnvelope) void {
    const st: *UiDemoState = @ptrCast(@alignCast(user_ctx orelse return));
    if (std.mem.eql(u8, ev.payload, "demo.increment")) {
        st.click_count += 1;
        if (st.status_idx) |idx| {
            var buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Clicks: {d}", .{st.click_count}) catch "Clicks: ?";
            st.tree.setNodeText(idx, msg) catch {};
        }
    } else if (std.mem.eql(u8, ev.payload, "demo.scroll_down")) {
        if (st.list_idx) |li| st.tree.scrollNode(li, 16.0);
    } else if (std.mem.eql(u8, ev.payload, "demo.scroll_up")) {
        if (st.list_idx) |li| st.tree.scrollNode(li, -16.0);
    }
}

fn uiUpdateSystem(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(UiDemoState) orelse return;

    // 1. Handle real mouse clicks.
    if (st.input.wasMouseClicked(.left)) {
        _ = st.tree.handlePointerClick(st.input.mouse_x, st.input.mouse_y, ctx.events);
    }

    // 2. Handle real text input & backspace when textbox is focused.
    if (st.input.last_text_len > 0) {
        _ = try st.tree.handleTextInput(st.input.last_text[0..st.input.last_text_len]);
    }
    // SDL_SCANCODE_BACKSPACE = 42
    if (st.input.wasKeyPressed(42)) {
        _ = try st.tree.handleBackspace();
    }

    // 3. Layout in logical window coordinates.
    const px = window_sdl3.pixelSize(st.app);
    const dpi: f32 = if (px) |p| (if (p.dpi_scale > 0.0) p.dpi_scale else 1.0) else 1.0;
    const log_w: f32 = if (px) |p| @as(f32, @floatFromInt(p.width)) / dpi else 1280.0;
    const log_h: f32 = if (px) |p| @as(f32, @floatFromInt(p.height)) / dpi else 720.0;
    st.tree.layoutTree(log_w, log_h);
}

fn uiRenderSystem(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(UiDemoState) orelse return;
    st.cmds.clearRetainingCapacity();

    try st.cmds.append(st.app.allocator, .{ .clear = .{ .r = 0.05, .g = 0.07, .b = 0.10, .a = 1.0 } });
    try st.tree.paint(st.app.allocator, &st.cmds);

    try st.gfx.beginFrame(st.rt);
    try st.gfx.submitDrawCommands(st.rt, st.cmds.items);
    try st.gfx.present(st.rt);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        if (gpa.deinit() == .leak) std.debug.print("[visual-ui] WARNING: memory leak detected\n", .{});
    }
    const allocator = gpa.allocator();

    var app = engine.App.init(allocator, .{});
    defer app.deinit();

    try app.registerModule(window_sdl3.module());
    try app.registerModule(graphics_sdlgpu.module());
    try app.registerModule(ui_core.module());

    try app.resources.insert(window_sdl3.WindowConfig, .{
        .title = "ZigEng — Visual UI Hello (D4)",
        .width = 1280,
        .height = 720,
        .resizable = true,
    });

    try app.scheduler.addSystem(.{ .name = "visual_ui.update", .stage = .update, .run = uiUpdateSystem });
    try app.scheduler.addSystem(.{ .name = "visual_ui.render", .stage = .render_extract, .run = uiRenderSystem });

    try app.initialize();

    const w_entry = try app.services.getService("engine.window", 1);
    const win: *window.WindowService = @ptrCast(@alignCast(@constCast(w_entry.api_ptr)));
    const i_entry = try app.services.getService("engine.input", 1);
    const input: *window.InputService = @ptrCast(@alignCast(@constCast(i_entry.api_ptr)));
    const g_entry = try app.services.getService("engine.graphics.device", 1);
    const gfx: *graphics.GraphicsDeviceService = @ptrCast(@alignCast(@constCast(g_entry.api_ptr)));
    const u_entry = try app.services.getService("engine.ui.tree", 1);
    const tree: *ui_core.UiTree = @ptrCast(@alignCast(@constCast(u_entry.api_ptr)));

    // Build UI using the official HTML-like markup frontend.
    try ui_markup.parseIntoTree(allocator,
        \\<panel id="root">
        \\  <label id="title">ZigEng D4 — UI & Text (High-DPI)</label>
        \\  <label id="status">Clicks: 0</label>
        \\  <button id="inc_btn" action="demo.increment">Click Me (+1)</button>
        \\  <textbox id="input_box">Type here...</textbox>
        \\  <button id="scroll_dn" action="demo.scroll_down">Scroll List Down</button>
        \\  <button id="scroll_up" action="demo.scroll_up">Scroll List Up</button>
        \\  <list id="clip_list">
        \\    <label id="item_0">Clipped Item 0</label>
        \\    <label id="item_1">Clipped Item 1</label>
        \\    <label id="item_2">Clipped Item 2</label>
        \\    <label id="item_3">Clipped Item 3</label>
        \\    <label id="item_4">Clipped Item 4</label>
        \\  </list>
        \\</panel>
    , tree);

    // Apply visual styling & fixed height for the clipped scrollable list.
    if (tree.findById("inc_btn")) |bi| {
        tree.nodes.items[bi].style.bg_color = .{ .r = 0.16, .g = 0.42, .b = 0.72, .a = 1.0 };
    }
    if (tree.findById("input_box")) |ti| {
        tree.nodes.items[ti].style.bg_color = .{ .r = 0.14, .g = 0.17, .b = 0.22, .a = 1.0 };
    }
    const list_idx = tree.findById("clip_list");
    if (list_idx) |li| {
        tree.nodes.items[li].style.height = 90.0;
        tree.nodes.items[li].style.clip_children = true;
        tree.nodes.items[li].style.bg_color = .{ .r = 0.11, .g = 0.13, .b = 0.17, .a = 1.0 };
    }

    const px = window_sdl3.pixelSize(&app);
    const px_w: u32 = if (px) |p| p.width else 1280;
    const px_h: u32 = if (px) |p| p.height else 720;
    const rt = try gfx.createSurface(1, px_w, px_h);

    try app.resources.insert(UiDemoState, .{
        .app = &app,
        .gfx = gfx,
        .win = win,
        .input = input,
        .tree = tree,
        .rt = rt,
        .cmds = .empty,
        .list_idx = list_idx,
        .status_idx = tree.findById("status"),
    });
    const st_ptr = app.resources.get(UiDemoState).?;
    _ = try app.events.subscribe(9001, "ui.action", onUiAction, st_ptr);

    try window_sdl3.runVisualLoop(&app);
    if (app.resources.get(UiDemoState)) |st| {
        st.cmds.deinit(allocator);
    }
    std.debug.print("[visual-ui] closed after {d} frames\n", .{app.diagnostics.frame_count});
}
