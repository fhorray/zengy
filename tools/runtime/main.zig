//! Manifesto-Driven Visual Game Runtime (`zengy-runtime`).
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
const plugin_paths = @import("plugin_paths.zig");
const hook_tracker = @import("hook_tracker.zig");
const engine = @import("engine");
const window = @import("window");
const window_sdl3 = @import("window_sdl3");
const graphics = @import("graphics");
const graphics_wgpu = @import("graphics_wgpu");
const draw_2d = @import("draw_2d");
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
    host: ?*scripting_host.ScriptingHost,
    script: ?scripting_host.ScriptModuleHandle,
    rt: graphics.RenderTargetHandle,
    cmds: std.ArrayList(graphics.DrawCommand),
    hooks: hook_tracker.HookTracker = .{},
};

fn readFileCwd(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024));
}

fn onUiAction(user_ctx: ?*anyopaque, ev: engine.EventEnvelope) void {
    const st: *RuntimeState = @ptrCast(@alignCast(user_ctx orelse return));
    if (st.script) |sc| {
        if (st.host) |h| {
            _ = h.invokeScript(sc, "on_ui_action", ev.payload);
        }
    }
}

fn invokeOptionalHook(
    tracker: *hook_tracker.HookTracker,
    hook: hook_tracker.Hook,
    host: *scripting_host.ScriptingHost,
    sc: scripting_host.ScriptModuleHandle,
    fn_name: []const u8,
    arg: []const u8,
) void {
    if (!tracker.shouldCall(hook)) return;
    const res = host.invokeScript(sc, fn_name, arg);
    if (res.ok) {
        tracker.recordSuccess();
        return;
    }
    // A hook the script does not define is optional: remember that and stop looking it up.
    if (std.mem.eql(u8, res.error_message, "python function not found") or
        std.mem.eql(u8, res.error_message, "lua function not found"))
    {
        tracker.markMissing(hook);
        return;
    }
    if (tracker.recordError(res.error_message)) {
        std.debug.print("[zengy-runtime] script error in '{s}': {s}\n", .{ fn_name, res.error_message });
    }
}

fn runtimeFixedUpdateSystem(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(RuntimeState) orelse return;
    if (st.script) |sc| {
        if (st.host) |h| {
            var dt_buf: [32]u8 = undefined;
            const dt_str = std.fmt.bufPrint(&dt_buf, "{d:.5}", .{ctx.fixedDeltaSeconds()}) catch "0.01667";
            invokeOptionalHook(&st.hooks, .fixed_update, h, sc, "fixed_update", dt_str);
        }
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
        if (st.host) |h| {
            var dt_buf: [32]u8 = undefined;
            const dt_str = std.fmt.bufPrint(&dt_buf, "{d:.5}", .{ctx.dt}) catch "0.016";
            invokeOptionalHook(&st.hooks, .update, h, sc, "update", dt_str);
        }
    }
}

fn runtimeDestroySystem(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(RuntimeState) orelse return;
    if (st.script) |sc| {
        if (st.host) |h| {
            invokeOptionalHook(&st.hooks, .destroy, h, sc, "destroy", "");
        }
    }
}

const HeadlessScriptState = struct {
    host: *scripting_host.ScriptingHost,
    script: ?scripting_host.ScriptModuleHandle,
    hooks: hook_tracker.HookTracker = .{},
};

fn headlessFixedUpdateSystem(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(HeadlessScriptState) orelse return;
    if (st.script) |sc| {
        var dt_buf: [32]u8 = undefined;
        const dt_str = std.fmt.bufPrint(&dt_buf, "{d:.5}", .{ctx.fixedDeltaSeconds()}) catch "0.01667";
        invokeOptionalHook(&st.hooks, .fixed_update, st.host, sc, "fixed_update", dt_str);
    }
}

fn headlessUpdateSystem(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(HeadlessScriptState) orelse return;
    if (st.script) |sc| {
        var dt_buf: [32]u8 = undefined;
        const dt_str = std.fmt.bufPrint(&dt_buf, "{d:.5}", .{ctx.dt}) catch "0.016";
        invokeOptionalHook(&st.hooks, .update, st.host, sc, "update", dt_str);
    }
}

fn headlessDestroySystem(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(HeadlessScriptState) orelse return;
    if (st.script) |sc| {
        invokeOptionalHook(&st.hooks, .destroy, st.host, sc, "destroy", "");
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

fn loadDynamicPlugins(allocator: std.mem.Allocator, io: std.Io, app: *engine.App, manifest_plugins: []const []const u8) !usize {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Auto-discovered libraries in .zengy/plugins/ (directory order is filesystem-dependent, so
    // planLoadOrder sorts them and removes duplicates of explicitly listed libraries).
    var discovered: std.ArrayList([]const u8) = .empty;
    if (std.Io.Dir.cwd().openDir(io, ".zengy/plugins", .{ .iterate = true })) |opened| {
        var dir = opened;
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file or !plugin_paths.isSharedLibName(entry.name)) continue;
            try discovered.append(arena, try arena.dupe(u8, entry.name));
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const plan = try plugin_paths.planLoadOrder(arena, manifest_plugins, ".zengy/plugins", discovered.items);
    for (plan) |path| {
        const ph = try app.ensurePluginHost();
        const h = try ph.loadSharedLibrary(path);
        const rc = ph.startPlugin(h);
        if (rc != .ok) return error.PluginStartFailed;
    }
    return plan.len;
}

fn needsPhysicsModule(plugins: []const []const u8) bool {
    for (plugins) |p| {
        if (plugin_paths.requestsPhysics(p)) return true;
    }
    return false;
}

fn scriptLanguageForPath(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".lua")) return "lua";
    return "python";
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var headless = std.mem.eql(u8, "headless", "never");
    var headless_ticks: u64 = 60;
    var parallel = false;
    {
        var args_it = try init.minimal.args.iterateAllocator(allocator);
        defer args_it.deinit();
        _ = args_it.next();
        while (args_it.next()) |arg| {
            if (std.mem.eql(u8, arg, "--headless")) {
                headless = true;
            } else if (std.mem.eql(u8, arg, "--parallel")) {
                parallel = true;
            } else if (std.mem.eql(u8, arg, "--ticks")) {
                if (args_it.next()) |val| {
                    headless_ticks = std.fmt.parseInt(u64, val, 10) catch 60;
                }
            }
        }
    }

    const manifest_bytes = readFileCwd(allocator, io, "game.toml") catch |err| {
        std.debug.print("[zengy-runtime] could not read 'game.toml' in current directory: {}\n", .{err});
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

    var app = engine.App.init(allocator, .{ .fixed_dt = 1.0 / 60.0, .enable_parallel = parallel });
    defer app.deinit();

    if (!headless) {
        try app.registerModule(window_sdl3.module());
        try app.registerModule(graphics_wgpu.module());
        try app.registerModule(draw_2d.module());
        try app.registerModule(ui_core.module());
    }
    if (entry_script) |sp| {
        try app.registerModule(scripting_host.module());
        if (std.mem.eql(u8, scriptLanguageForPath(sp), "lua")) {
            try app.registerModule(scripting_lua.module());
        } else {
            try app.registerModule(scripting_python.module());
        }
    }

    var has_scene = false;
    for (manifest.plugins) |plugin_name| {
        if (std.mem.eql(u8, plugin_name, "scene")) {
            if (!has_scene) {
                try app.registerModule(scene.module());
                has_scene = true;
            }
        }
    }
    if (needsPhysicsModule(manifest.plugins)) {
        try app.registerModule(physics.module());
    }

    if (headless) {
        try app.scheduler.addSystem(.{ .name = "runtime.headless_fixed_update", .stage = .fixed_update, .run = headlessFixedUpdateSystem });
        try app.scheduler.addSystem(.{ .name = "runtime.headless_update", .stage = .update, .run = headlessUpdateSystem });
        try app.scheduler.addSystem(.{ .name = "runtime.headless_destroy", .stage = .shutdown, .run = headlessDestroySystem });
        try app.initialize();
        const dynamic_loaded = try loadDynamicPlugins(allocator, io, &app, manifest.plugins);

        var loaded_script: ?scripting_host.ScriptModuleHandle = null;
        if (entry_script) |sp| {
            const host = app.resources.get(scripting_host.ScriptingHost).?;
            const src = try readFileCwd(allocator, io, sp);
            defer allocator.free(src);
            const rt_idx = host.findRuntimeByLanguage(scriptLanguageForPath(sp)) orelse return error.MissingScriptingRuntime;
            loaded_script = try host.loadScript(rt_idx, sp, src);
            try app.resources.insert(HeadlessScriptState, .{
                .host = host,
                .script = loaded_script,
            });
            invokeOptionalHook(&app.resources.get(HeadlessScriptState).?.hooks, .start, host, loaded_script.?, "start", "");
        }

        var t: u64 = 0;
        while (t < headless_ticks and !app.should_quit) : (t += 1) {
            try app.tick(1.0 / 60.0);
        }

        const phys_steps: u64 = if (app.resources.get(physics.PhysicsService)) |ps| ps.step_count else 0;
        const phys_backend = if (app.resources.get(physics.PhysicsService)) |ps| ps.hasBackend() else false;
        app.shutdown();
        std.debug.print(
            "{{\"mode\":\"headless\",\"ticks\":{d},\"dynamic_plugins\":{d},\"physics_steps\":{d},\"physics_backend\":{},\"status\":\"ok\"}}\n",
            .{ t, dynamic_loaded, phys_steps, phys_backend },
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

    var has_ui = false;
    if (ui_path) |up| {
        const ui_src = try readFileCwd(allocator, io, up);
        defer allocator.free(ui_src);
        try ui_markup.parseIntoTree(allocator, ui_src, tree);
        has_ui = true;
    }

    const host_opt: ?*scripting_host.ScriptingHost = app.resources.get(scripting_host.ScriptingHost);
    var loaded_script: ?scripting_host.ScriptModuleHandle = null;
    if (entry_script) |sp| {
        const host = host_opt.?;
        const src = try readFileCwd(allocator, io, sp);
        defer allocator.free(src);
        const rt_idx = host.findRuntimeByLanguage(scriptLanguageForPath(sp)) orelse return error.MissingScriptingRuntime;
        loaded_script = try host.loadScript(rt_idx, sp, src);
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
        .host = host_opt,
        .script = loaded_script,
        .rt = rt,
        .cmds = .empty,
    });
    const st_ptr = app.resources.get(RuntimeState).?;
    defer st_ptr.cmds.deinit(allocator);

    if (loaded_script) |sc| {
        invokeOptionalHook(&st_ptr.hooks, .start, host_opt.?, sc, "start", "");
    }

    _ = try app.events.subscribe(9010, "ui.action", onUiAction, st_ptr);

    try window_sdl3.runVisualLoop(&app);
}
