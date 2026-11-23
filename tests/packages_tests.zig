//! Optional Packages Integration Tests (Phases 5, 6, 7, 9, and 10).
//!
//! Validates that optional modules compose cleanly without modifying `src/core/`:
//! - Phase 5: `official.window` + `official.graphics` resize, present, and device-lost errors.
//! - Phase 6: `official.ui.core` 1000-node layout, hit testing, focus, click actions, and paint list.
//! - Phase 9 & 10: `official.ui.markup` and `community.ui.novaui` producing identical `UiTree` IR.
//! - Phase 10: `community.ui.immediate` working without `official.ui.core`.
//! - Phase 7: `official.script.host` running two coexisting runtimes with isolated errors.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const window = @import("window");
const graphics = @import("graphics");
const ui_core = @import("ui_core");
const ui_markup = @import("ui_markup");
const ui_novaui = @import("ui_novaui");
const ui_immediate = @import("ui_immediate");
const scripting_host = @import("scripting_host");
const assets = @import("assets");

test "Phase 5: Window, Input, and Graphics modules with resize, present, and device-lost error" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    // Register in reverse dependency order to verify topological resolution
    try app.registerModule(graphics.module());
    try app.registerModule(window.module());
    try app.initialize();

    try testing.expect(app.scheduler.render_extract_enabled);

    const win_svc = app.resources.get(window.WindowService);
    _ = win_svc;
    const w_entry = try app.services.getService("engine.window", 1);
    const win: *window.WindowService = @ptrCast(@alignCast(@constCast(w_entry.api_ptr)));

    const g_entry = try app.services.getService("engine.graphics.device", 1);
    const gfx: *graphics.GraphicsDeviceService = @ptrCast(@alignCast(@constCast(g_entry.api_ptr)));

    const wh = try win.createWindow(.{ .title = "Test", .width = 800, .height = 600 });
    const rt = try gfx.createSurface(@bitCast(wh), 800, 600);

    try gfx.beginFrame(rt);
    try gfx.submitDrawCommands(rt, &.{
        .{ .clear = .{ .r = 0.1, .g = 0.1, .b = 0.12 } },
        .{ .rect = .{ .x = 10, .y = 10, .width = 100, .height = 40, .color = .{ .r = 0.2, .g = 0.6, .b = 0.9 } } },
    });
    try gfx.present(rt);
    try testing.expectEqual(@as(?u64, 1), gfx.presentedFrames(rt));

    // Resize & close lifecycle
    try testing.expect(win.resize(wh, 1280, 720));
    try testing.expect(gfx.resizeSurface(rt, 1280, 720));
    try testing.expectEqual(@as(u32, 1280), win.getSize(wh).?.width);

    try testing.expect(win.requestClose(wh));
    try testing.expect(win.shouldClose(wh));

    // Device unavailable error reporting
    gfx.setDeviceAvailable(false);
    try testing.expectError(error.DeviceUnavailable, gfx.beginFrame(rt));

    app.shutdown();
    try testing.expect(!app.scheduler.render_extract_enabled);
    try testing.expectError(error.ProviderNotFound, app.services.getService("engine.window", 1));
}

test "Phase 6: UiTree layout, 1000 nodes, hit testing, focus, click action, and paint list" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(window.module());
    try app.registerModule(graphics.module());
    try app.registerModule(ui_core.module());
    try app.initialize();

    const ActionCatcher = struct {
        fired: bool = false,
        fn onAction(raw: ?*anyopaque, ev: engine.EventEnvelope) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (std.mem.eql(u8, ev.payload, "debug.clear")) {
                self.fired = true;
            }
        }
    };
    var catcher = ActionCatcher{};
    _ = try app.events.subscribe(999, "ui.action", ActionCatcher.onAction, &catcher);

    const tree = app.resources.get(ui_core.UiTree).?;
    const panel = try tree.createNode(null, .{ .id = "root.panel", .kind = .panel });
    _ = try tree.createNode(panel, .{ .id = "lbl", .kind = .label, .text = "Console" });
    const btn = try tree.createNode(panel, .{
        .id = "btn_clear",
        .kind = .button,
        .text = "Clear",
        .action = "debug.clear",
    });

    // Add 1000 nodes to verify scale & layout
    for (0..1000) |i| {
        var buf: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&buf, "item_{d}", .{i});
        _ = try tree.createNode(panel, .{ .id = id, .kind = .label, .text = "log" });
    }
    try testing.expectEqual(@as(usize, 1003), tree.nodeCount());

    tree.layoutTree(800, 600);
    const btn_rect = tree.nodes.items[btn].layout;
    const hit = tree.handlePointerClick(btn_rect.x + 4, btn_rect.y + 4, &app.events);
    try testing.expectEqual(@as(?usize, btn), hit);
    try testing.expect(tree.nodes.items[btn].focused);

    _ = app.events.drain();
    try testing.expect(catcher.fired);

    var cmds: std.ArrayList(graphics.DrawCommand) = .empty;
    defer cmds.deinit(testing.allocator);
    try tree.paint(testing.allocator, &cmds);
    try testing.expect(cmds.items.len >= 1003);
}

test "Phase 9 & 10: HTML-like markup and NovaUI community DSL produce equivalent UiTree IR" {
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

test "Phase 10: Alternative immediate UI backend works without ui-core" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(window.module());
    try app.registerModule(graphics.module());
    try app.registerModule(ui_immediate.module());
    try app.initialize();

    try testing.expectError(error.ProviderNotFound, app.services.getService("engine.ui.tree", 1));
    try testing.expect(app.services.hasService("engine.ui.backend.immediate", 1));

    const imm_entry = try app.services.getService("engine.ui.backend.immediate", 1);
    const imm: *ui_immediate.ImmediateUiService = @ptrCast(@alignCast(@constCast(imm_entry.api_ptr)));

    const w_entry = try app.services.getService("engine.window", 1);
    const win: *window.WindowService = @ptrCast(@alignCast(@constCast(w_entry.api_ptr)));
    const i_entry = try app.services.getService("engine.input", 1);
    const input: *window.InputService = @ptrCast(@alignCast(@constCast(i_entry.api_ptr)));
    const g_entry = try app.services.getService("engine.graphics.device", 1);
    const gfx: *graphics.GraphicsDeviceService = @ptrCast(@alignCast(@constCast(g_entry.api_ptr)));

    const wh = try win.createWindow(.{});
    const rt = try gfx.createSurface(@bitCast(wh), 800, 600);

    input.beginFrame();
    input.injectMouseMove(25, 16);
    input.injectMouseButton(.left, true);

    try gfx.beginFrame(rt);
    imm.beginFrame();
    const clicked = try imm.button(input, 10, 120, 30, "Run");
    try testing.expect(clicked);
    try imm.flush(gfx, rt);
    try gfx.present(rt);
}

test "Phase 7: ScriptingHost coexistence of two independent runtimes without Core branches" {
    const DummyVm = struct {
        const State = struct {
            bridge: *scripting_host.ScriptEngineBridge,
            loaded_count: usize = 0,
            last_arg: [64]u8 = undefined,
            last_arg_len: usize = 0,
        };

        fn create(allocator: std.mem.Allocator, bridge: *scripting_host.ScriptEngineBridge) !*anyopaque {
            const st = try allocator.create(State);
            st.* = .{ .bridge = bridge };
            return st;
        }
        fn load(raw: *anyopaque, _: []const u8, source: []const u8) !u64 {
            const st: *State = @ptrCast(@alignCast(raw));
            if (std.mem.eql(u8, source, "SYNTAX_ERROR")) return error.ScriptSyntaxError;
            st.loaded_count += 1;
            return st.loaded_count;
        }
        fn invoke(raw: *anyopaque, _: u64, fn_name: []const u8, arg: []const u8) scripting_host.ScriptResult {
            const st: *State = @ptrCast(@alignCast(raw));
            if (std.mem.eql(u8, fn_name, "throw")) {
                return .{ .ok = false, .error_message = "isolated script exception" };
            }
            const len = @min(arg.len, st.last_arg.len);
            @memcpy(st.last_arg[0..len], arg[0..len]);
            st.last_arg_len = len;
            st.bridge.postEvent("script.invoked", arg, 0) catch {
                return .{ .ok = false, .error_message = "event post failed" };
            };
            return .{ .ok = true };
        }
        fn unload(_: *anyopaque, _: u64) void {}
        fn destroy(raw: *anyopaque, allocator: std.mem.Allocator) void {
            const st: *State = @ptrCast(@alignCast(raw));
            allocator.destroy(st);
        }

        const vtable = scripting_host.RuntimeProviderVTable{
            .create = create,
            .load = load,
            .invoke = invoke,
            .unload = unload,
            .destroy = destroy,
        };
    };

    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(scripting_host.module());
    try app.initialize();

    const host = app.resources.get(scripting_host.ScriptingHost).?;

    const rt_lua = try host.registerRuntime(.{ .language_id = "lua-mock", .language_version = "5.5" }, DummyVm.vtable);
    const rt_py = try host.registerRuntime(.{ .language_id = "python-mock", .language_version = "3.12" }, DummyVm.vtable);

    const mod_lua = try host.loadScript(rt_lua, "console.lua", "return {}");
    const mod_py = try host.loadScript(rt_py, "console.py", "def configure(app): pass");

    // Isolated script error does not crash host
    const err_res = host.invokeScript(mod_py, "throw", "");
    try testing.expect(!err_res.ok);

    // Both runtimes invoke and post events through the same bridge
    try testing.expect(host.invokeScript(mod_lua, "on_tick", "from_lua").ok);
    try testing.expect(host.invokeScript(mod_py, "on_tick", "from_py").ok);

    try app.commands.apply(&app.world, &app.events);
    try testing.expectEqual(@as(usize, 2), app.events.pendingCount());

    // Destroy runtime -> stale handle rejected
    host.destroyRuntime(rt_lua);
    const stale_res = host.invokeScript(mod_lua, "on_tick", "");
    try testing.expect(!stale_res.ok);
}

test "Phase 11: AssetService importer priority, caching, reload, and stale handle rejection" {
    const TextImporter = struct {
        fn importLow(allocator: std.mem.Allocator, _: []const u8, raw: []const u8) !assets.AssetArtifact {
            return .{
                .kind = try allocator.dupe(u8, "text/low"),
                .bytes = try allocator.dupe(u8, raw),
            };
        }
        fn importHigh(allocator: std.mem.Allocator, _: []const u8, raw: []const u8) !assets.AssetArtifact {
            const upper = try allocator.dupe(u8, raw);
            for (upper) |*c| c.* = std.ascii.toUpper(c.*);
            return .{
                .kind = try allocator.dupe(u8, "text/high"),
                .bytes = upper,
            };
        }
    };

    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(assets.module());
    try app.initialize();

    const svc = app.resources.get(assets.AssetService).?;
    try svc.registerImporter(.{ .id = "low", .extension = ".txt", .priority = 10, .import_fn = TextImporter.importLow });
    try svc.registerImporter(.{ .id = "high", .extension = ".txt", .priority = 200, .import_fn = TextImporter.importHigh });

    const h1 = try svc.loadFromBytes("project://hello.txt", "hello");
    const h2 = try svc.loadFromBytes("project://hello.txt", "ignored");
    try testing.expectEqual(h1, h2);
    try testing.expectEqualStrings("HELLO", svc.getBytes(h1).?);
    try testing.expectEqual(@as(?u32, 1), svc.getVersion(h1));

    try svc.reload(h1, "world");
    try testing.expectEqualStrings("WORLD", svc.getBytes(h1).?);
    try testing.expectEqual(@as(?u32, 2), svc.getVersion(h1));

    try testing.expect(svc.unload(h1));
    try testing.expect(svc.getBytes(h1) == null);
}
