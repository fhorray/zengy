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

fn invokeOptionalHook(
    host: *scripting_host.ScriptingHost,
    sc: scripting_host.ScriptModuleHandle,
    fn_name: []const u8,
    arg: []const u8,
) void {
    const res = host.invokeScript(sc, fn_name, arg);
    if (!res.ok) {
        if (std.mem.eql(u8, res.error_message, "python function not found") or
            std.mem.eql(u8, res.error_message, "lua function not found"))
        {
            return;
        }
        std.debug.print("[zigeng-runtime] script error in '{s}': {s}\n", .{ fn_name, res.error_message });
    }
}

fn runtimeFixedUpdateSystem(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(RuntimeState) orelse return;
    if (st.script) |sc| {
        var dt_buf: [32]u8 = undefined;
        const dt_str = std.fmt.bufPrint(&dt_buf, "{d:.5}", .{ctx.fixedDeltaSeconds()}) catch "0.01667";
        invokeOptionalHook(st.host, sc, "fixed_update", dt_str);
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
        invokeOptionalHook(st.host, sc, "update", dt_str);
    }
}

fn runtimeDestroySystem(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(RuntimeState) orelse return;
    if (st.script) |sc| {
        invokeOptionalHook(st.host, sc, "destroy", "");
    }
}

const HeadlessScriptState = struct {
    host: *scripting_host.ScriptingHost,
    script: ?scripting_host.ScriptModuleHandle,
};

fn headlessFixedUpdateSystem(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(HeadlessScriptState) orelse return;
    if (st.script) |sc| {
        var dt_buf: [32]u8 = undefined;
        const dt_str = std.fmt.bufPrint(&dt_buf, "{d:.5}", .{ctx.fixedDeltaSeconds()}) catch "0.01667";
        invokeOptionalHook(st.host, sc, "fixed_update", dt_str);
    }
}

fn headlessUpdateSystem(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(HeadlessScriptState) orelse return;
    if (st.script) |sc| {
        var dt_buf: [32]u8 = undefined;
        const dt_str = std.fmt.bufPrint(&dt_buf, "{d:.5}", .{ctx.dt}) catch "0.016";
        invokeOptionalHook(st.host, sc, "update", dt_str);
    }
}

fn headlessDestroySystem(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(HeadlessScriptState) orelse return;
    if (st.script) |sc| {
        invokeOptionalHook(st.host, sc, "destroy", "");
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

fn isSharedLibName(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".so") or
        std.mem.endsWith(u8, name, ".dll") or
        std.mem.endsWith(u8, name, ".dylib");
}

fn loadDynamicPlugins(allocator: std.mem.Allocator, io: std.Io, app: *engine.App, manifest_plugins: []const []const u8) !usize {
    var loaded_count: usize = 0;

    // 1. Load explicit shared library paths listed in game.toml
    for (manifest_plugins) |spec| {
        if (isSharedLibName(spec)) {
            const ph = try app.ensurePluginHost();
            const h = try ph.loadSharedLibrary(spec);
            const rc = ph.startPlugin(h);
            if (rc != .ok) return error.PluginStartFailed;
            loaded_count += 1;
        }
    }

    // 2. Auto-load compiled plugins in .zigeng/plugins/
    var dir = std.Io.Dir.cwd().openDir(io, ".zigeng/plugins", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return loaded_count,
        else => return err,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!isSharedLibName(entry.name)) continue;

        const full_path = try std.fmt.allocPrint(allocator, ".zigeng/plugins/{s}", .{entry.name});
        defer allocator.free(full_path);

        const ph = try app.ensurePluginHost();
        const h = try ph.loadSharedLibrary(full_path);
        const rc = ph.startPlugin(h);
        if (rc != .ok) return error.PluginStartFailed;
        loaded_count += 1;
    }

    return loaded_count;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var headless = std.mem.eql(u8, "headless", "never");
    var headless_ticks: u64 = 60;
    {
        var args_it = try init.minimal.args.iterateAllocator(allocator);
        defer args_it.deinit();
        _ = args_it.next();
        while (args_it.next()) |arg| {
            if (std.mem.eql(u8, arg, "--headless")) {
                headless = true;
            } else if (std.mem.eql(u8, arg, "--ticks")) {
                if (args_it.next()) |val| {
                    headless_ticks = std.fmt.parseInt(u64, val, 10) catch 60;
                }
            }
        }
    }

    const manifest_bytes = readFileCwd(allocator, io, "game.toml") catch |err| {
        std.debug.print("[zigeng-runtime] could not read 'game.toml' in current directory: {}\n", .{err});
        return err;
    };
    defer allocator.free(manifest_bytes);

    var manifest = try toml_format.TomlService.parseGameManifest(allocator, manifest_bytes);
    defer manifest.deinit(allocator);

    if (std.mem.eql(u8, manifest.mode, "headless")) {
        headless = true;
    }

    const title = manifest.title;
    const width: u32 = manifest.width;
    const height: u32 = manifest.height;
    const entry_script: ?[]const u8 = if (manifest.entry_script.len > 0) manifest.entry_script else null;
    const ui_path: ?[]const u8 = if (manifest.ui.len > 0) manifest.ui else null;

    var app = engine.App.init(allocator, .{ .fixed_dt = 1.0 / 60.0 });
    defer app.deinit();

    if (!headless) {
        try app.registerModule(window_sdl3.module());
        try app.registerModule(graphics_sdlgpu.module());
        try app.registerModule(ui_core.module());
    }
    try app.registerModule(scripting_host.module());
    try app.registerModule(scripting_lua.module());
    try app.registerModule(scripting_python.module());

    var has_scene = false;
    var has_physics = false;
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
        } else {
            // Dynamic plugins (e.g. physics backends, owner/repo, URLs, ./local-path, or shared libs)
            // are loaded via PluginHost; ensure the physics contract is available if they attach to it.
            if (!has_physics) {
                try app.registerModule(physics.module());
                has_physics = true;
            }
        }
    }

    if (headless) {
        try app.scheduler.addSystem(.{ .name = "runtime.headless_fixed_update", .stage = .fixed_update, .run = headlessFixedUpdateSystem });
        try app.scheduler.addSystem(.{ .name = "runtime.headless_update", .stage = .update, .run = headlessUpdateSystem });
        try app.scheduler.addSystem(.{ .name = "runtime.headless_destroy", .stage = .shutdown, .run = headlessDestroySystem });
        try app.initialize();
        const dynamic_loaded = try loadDynamicPlugins(allocator, io, &app, manifest.plugins);

        const host = app.resources.get(scripting_host.ScriptingHost).?;
        var loaded_script: ?scripting_host.ScriptModuleHandle = null;
        if (entry_script) |sp| {
            if (sp.len > 0) {
                const src = try readFileCwd(allocator, io, sp);
                defer allocator.free(src);
                const rt_idx: u16 = if (std.mem.endsWith(u8, sp, ".lua")) 0 else 1;
                loaded_script = try host.loadScript(rt_idx, sp, src);
            }
        }
        try app.resources.insert(HeadlessScriptState, .{
            .host = host,
            .script = loaded_script,
        });
        if (loaded_script) |sc| {
            invokeOptionalHook(host, sc, "start", "");
        }

        var t: u64 = 0;
        while (t < headless_ticks) : (t += 1) {
            try app.tick(1.0 / 60.0);
        }

        const phys_steps: u64 = if (app.resources.get(physics.PhysicsService)) |ps| ps.step_count else 0;
        const phys_backend = if (app.resources.get(physics.PhysicsService)) |ps| ps.hasBackend() else false;
        app.shutdown();
        std.debug.print(
            "{{\"mode\":\"headless\",\"ticks\":{d},\"dynamic_plugins\":{d},\"physics_steps\":{d},\"physics_backend\":{},\"status\":\"ok\"}}\n",
            .{ headless_ticks, dynamic_loaded, phys_steps, phys_backend },
        );
        return;
    }

    try app.resources.insert(window_sdl3.WindowConfig, .{
        .title = title,
        .width = width,
        .height = height,
        .resizable = true,
    });

    try app.scheduler.addSystem(.{ .name = "runtime.fixed_update", .stage = .fixed_update, .run = runtimeFixedUpdateSystem });
    try app.scheduler.addSystem(.{ .name = "runtime.update", .stage = .update, .run = runtimeUpdateSystem });
    try app.scheduler.addSystem(.{ .name = "runtime.render", .stage = .render_extract, .run = runtimeRenderSystem });
    try app.scheduler.addSystem(.{ .name = "runtime.destroy", .stage = .shutdown, .run = runtimeDestroySystem });

    try app.initialize();
    _ = try loadDynamicPlugins(allocator, io, &app, manifest.plugins);

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
    if (loaded_script) |sc| {
        invokeOptionalHook(host, sc, "start", "");
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
