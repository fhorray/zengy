//! Manifesto-Driven Visual Game Runtime (`zigeng-runtime`).
//!
//! Reads `game.toml` from the current working directory and runs the user's game
//! without requiring any Zig boilerplate:
//!
//! ```toml
//! [game]
//! title = "My Game"
//! width = 1280
//! height = 720
//! mode = "2d"
//! entry_script = "scripts/main.py"
//! ui = "ui/hud.html"
//! plugins = ["scene", "physics", "physics-jolt"]
//! ```

const std = @import("std");
const engine = @import("engine");
const window = @import("window");
const window_sdl3 = @import("window_sdl3");
const graphics = @import("graphics");
const graphics_sdlgpu = @import("graphics_sdlgpu");
const scene = @import("scene");
const physics = @import("physics");
const physics_jolt = @import("physics_jolt");
const ui_core = @import("ui_core");
const ui_markup = @import("ui_markup");
const scripting_host = @import("scripting_host");
const scripting_python = @import("scripting_python");
const scripting_lua = @import("scripting_lua");
const toml_format = @import("toml_format");

const RuntimeState = struct {
    allocator: std.mem.Allocator,
    app: *engine.App,
    input: *window.InputService,
    gfx: *graphics.GraphicsDeviceService,
    tree: *ui_core.UiTree,
    has_ui: bool,
    host: *scripting_host.ScriptingHost,
    script: ?scripting_host.ScriptModuleHandle,
    rt: graphics.RenderTargetHandle,
    cmds: std.ArrayList(graphics.DrawCommand),
};

fn readFileCwd(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024));
}

fn onUiAction(user_ctx: ?*anyopaque, ev: engine.EventEnvelope) void {
    const st: *RuntimeState = @ptrCast(@alignCast(user_ctx orelse return));
    if (st.script) |sc| {
        _ = st.host.invokeScript(sc, "on_ui_action", ev.payload);
    }
}

fn runtimeUpdateSystem(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(RuntimeState) orelse return;

    // Sync Window InputService -> ScriptInputState for Python/Lua scripts.
    if (st.app.resources.get(scripting_host.ScriptInputState)) |sinp| {
        sinp.mouse_x = st.input.mouse_x;
        sinp.mouse_y = st.input.mouse_y;
        sinp.mouse_left_down = st.input.isMouseDown(.left);
        sinp.mouse_left_clicked = st.input.wasMouseClicked(.left);
        sinp.keys_down = st.input.keys_down;
    }

    if (st.has_ui) {
        const px = window_sdl3.pixelSize(st.app);
        const dpi: f32 = if (px) |p| (if (p.dpi_scale > 0.0) p.dpi_scale else 1.0) else 1.0;
        const log_w: f32 = if (px) |p| @as(f32, @floatFromInt(p.width)) / dpi else 1280.0;
        const log_h: f32 = if (px) |p| @as(f32, @floatFromInt(p.height)) / dpi else 720.0;
        st.tree.layoutTree(log_w, log_h);

        if (st.input.wasMouseClicked(.left)) {
            _ = st.tree.handlePointerClick(st.input.mouse_x, st.input.mouse_y, ctx.events);
        }
        if (st.input.last_text_len > 0) {
            _ = try st.tree.handleTextInput(st.input.last_text[0..st.input.last_text_len]);
        }
        if (st.input.wasKeyPressed(42)) {
            _ = try st.tree.handleBackspace();
        }
    }

    if (st.app.resources.get(scripting_host.ScriptDrawQueue)) |q| q.clear();

    if (st.script) |sc| {
        var dt_buf: [32]u8 = undefined;
        const dt_str = std.fmt.bufPrint(&dt_buf, "{d:.5}", .{ctx.dt}) catch "0.016";
        const res = st.host.invokeScript(sc, "on_frame", dt_str);
        if (!res.ok) {
            std.debug.print("[zigeng-runtime] script error: {s}\n", .{res.error_message});
        }
    }
}

fn runtimeRenderSystem(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(RuntimeState) orelse return;
    st.cmds.clearRetainingCapacity();

    try st.cmds.append(st.allocator, .{ .clear = .{ .r = 0.06, .g = 0.08, .b = 0.12, .a = 1.0 } });

    if (st.app.resources.get(scripting_host.ScriptDrawQueue)) |q| {
        for (q.rects.items) |r| {
            try st.cmds.append(st.allocator, .{
                .rect = .{
                    .x = r.x,
                    .y = r.y,
                    .width = r.width,
                    .height = r.height,
                    .color = .{ .r = r.r, .g = r.g, .b = r.b, .a = r.a },
                },
            });
        }
    }

    if (st.has_ui) {
        try st.tree.paint(st.allocator, &st.cmds);
    }

    try st.gfx.beginFrame(st.rt);
    try st.gfx.submitDrawCommands(st.rt, st.cmds.items);
    try st.gfx.present(st.rt);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const manifest_bytes = readFileCwd(allocator, io, "game.toml") catch |err| {
        std.debug.print("[zigeng-runtime] could not read 'game.toml' in current directory: {}\n", .{err});
        return err;
    };
    defer allocator.free(manifest_bytes);

    var manifest = try toml_format.TomlService.parseGameManifest(allocator, manifest_bytes);
    defer manifest.deinit(allocator);

    const title = manifest.title;
    const width: u32 = manifest.width;
    const height: u32 = manifest.height;
    const entry_script: ?[]const u8 = if (manifest.entry_script.len > 0) manifest.entry_script else null;
    const ui_path: ?[]const u8 = if (manifest.ui.len > 0) manifest.ui else null;

    var app = engine.App.init(allocator, .{});
    defer app.deinit();

    try app.registerModule(window_sdl3.module());
    try app.registerModule(graphics_sdlgpu.module());
    try app.registerModule(ui_core.module());
    try app.registerModule(scripting_host.module());
    try app.registerModule(scripting_lua.module());
    try app.registerModule(scripting_python.module());

    var has_scene = false;
    var has_physics = false;
    var has_physics_jolt = false;
    for (manifest.plugins) |plugin_name| {
        if (std.mem.eql(u8, plugin_name, "scene")) {
            if (!has_scene) {
                try app.registerModule(scene.module());
                has_scene = true;
            }
        } else if (std.mem.eql(u8, plugin_name, "physics")) {
            if (!has_physics) {
                try app.registerModule(physics.module());
                has_physics = true;
            }
        } else if (std.mem.eql(u8, plugin_name, "physics-jolt")) {
            if (!has_physics) {
                try app.registerModule(physics.module());
                has_physics = true;
            }
            if (!has_physics_jolt) {
                try app.registerModule(physics_jolt.module());
                has_physics_jolt = true;
            }
        } else {
            std.debug.print("[zigeng-runtime] unknown plugin in game.toml: '{s}'\n", .{plugin_name});
        }
    }

    try app.resources.insert(window_sdl3.WindowConfig, .{
        .title = title,
        .width = width,
        .height = height,
        .resizable = true,
    });

    try app.scheduler.addSystem(.{ .name = "runtime.update", .stage = .update, .run = runtimeUpdateSystem });
    try app.scheduler.addSystem(.{ .name = "runtime.render", .stage = .render_extract, .run = runtimeRenderSystem });

    try app.initialize();

    const i_entry = try app.services.getService("engine.input", 1);
    const input: *window.InputService = @ptrCast(@alignCast(@constCast(i_entry.api_ptr)));
    const g_entry = try app.services.getService("engine.graphics.device", 1);
    const gfx: *graphics.GraphicsDeviceService = @ptrCast(@alignCast(@constCast(g_entry.api_ptr)));
    const u_entry = try app.services.getService("engine.ui.tree", 1);
    const tree: *ui_core.UiTree = @ptrCast(@alignCast(@constCast(u_entry.api_ptr)));
    const host = app.resources.get(scripting_host.ScriptingHost).?;

    var has_ui = false;
    if (ui_path) |up| {
        if (up.len > 0) {
            const ui_src = try readFileCwd(allocator, io, up);
            defer allocator.free(ui_src);
            try ui_markup.parseIntoTree(allocator, ui_src, tree);
            has_ui = true;
        }
    }

    var loaded_script: ?scripting_host.ScriptModuleHandle = null;
    if (entry_script) |sp| {
        if (sp.len > 0) {
            const src = try readFileCwd(allocator, io, sp);
            defer allocator.free(src);
            // Runtime 0 = Lua, Runtime 1 = Python (PocketPy)
            const rt_idx: u16 = if (std.mem.endsWith(u8, sp, ".lua")) 0 else 1;
            loaded_script = try host.loadScript(rt_idx, sp, src);
        }
    }

    const px = window_sdl3.pixelSize(&app);
    const rt = try gfx.createSurface(1, if (px) |p| p.width else width, if (px) |p| p.height else height);

    try app.resources.insert(RuntimeState, .{
        .allocator = allocator,
        .app = &app,
        .input = input,
        .gfx = gfx,
        .tree = tree,
        .has_ui = has_ui,
        .host = host,
        .script = loaded_script,
        .rt = rt,
        .cmds = .empty,
    });
    const st_ptr = app.resources.get(RuntimeState).?;
    defer st_ptr.cmds.deinit(allocator);

    _ = try app.events.subscribe(9010, "ui.action", onUiAction, st_ptr);

    try window_sdl3.runVisualLoop(&app);
}
