//! PocketPy + Lua Coexistence Tests (`packages/scripting/python/tests/scripting_python_tests.zig`).
//!
//! Validates `official.script.python` (PocketPy v2.2.0, vendored) and proves
//! Section 7.8: Lua and PocketPy coexist in the same `App`, spawning ECS
//! entities and exchanging events through `ScriptingHost` with zero Core branches.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const scripting_host = @import("scripting_host");
const scripting_lua = @import("scripting_lua");
const scripting_python = @import("scripting_python");

test "PocketPy and Lua coexist in one App, spawn entities, and exchange events" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    const Catcher = struct {
        lua_seen: bool = false,
        py_seen: bool = false,
        fn onEv(raw: ?*anyopaque, ev: engine.EventEnvelope) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (std.mem.eql(u8, ev.name, "lua.event")) self.lua_seen = true;
            if (std.mem.eql(u8, ev.name, "py.event")) self.py_seen = true;
        }
    };
    var catcher = Catcher{};
    _ = try app.events.subscribe(1, "*", Catcher.onEv, &catcher);

    try app.registerModule(scripting_host.module());
    try app.registerModule(scripting_lua.module());
    try app.registerModule(scripting_python.module());
    try app.initialize();

    const host = app.resources.get(scripting_host.ScriptingHost).?;

    // Runtime 0 = Lua, Runtime 1 = PocketPy
    const lua_mod = try host.loadScript(0, "a.lua",
        \\local M = {}
        \\function M.run(arg)
        \\    engine.spawn_entity()
        \\    engine.post_event("lua.event", arg)
        \\end
        \\return M
    );

    const py_mod = try host.loadScript(1, "b.py",
        \\import zengy
        \\def run(arg):
        \\    zengy.log("python: " + arg)
        \\    zengy.spawn_entity()
        \\    zengy.post_event("py.event", arg)
        \\def fail(arg):
        \\    raise ValueError("intentional python error")
    );

    try testing.expect(host.invokeScript(lua_mod, "run", "from_lua").ok);
    try testing.expect(host.invokeScript(py_mod, "run", "from_python").ok);

    // Python exception is isolated and does not crash host
    const py_err = host.invokeScript(py_mod, "fail", "");
    try testing.expect(!py_err.ok);

    try app.commands.apply(&app.world, &app.events);
    _ = app.events.drain();

    try testing.expectEqual(@as(usize, 2), app.world.entity_count);
    try testing.expect(catcher.lua_seen);
    try testing.expect(catcher.py_seen);
}

test "PocketPy engine.draw_rect populates ScriptDrawQueue" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(scripting_host.module());
    try app.registerModule(scripting_python.module());
    try app.initialize();

    const h_entry = try app.services.getService("engine.script.host", 1);
    const host: *scripting_host.ScriptingHost = @ptrCast(@alignCast(@constCast(h_entry.api_ptr)));

    const rt: u16 = 0;
    const mod = try host.loadScript(rt, "draw_test.py",
        \\import zengy
        \\def draw(arg):
        \\    zengy.draw_rect(10, 20, 100, 50, 0.2, 0.4, 0.8, 1.0)
    );
    try testing.expect(host.invokeScript(mod, "draw", "").ok);

    const q = app.resources.get(scripting_host.ScriptDrawQueue).?;
    try testing.expectEqual(@as(usize, 1), q.rects.items.len);
    try testing.expectEqual(@as(f32, 10.0), q.rects.items[0].x);
    try testing.expectEqual(@as(f32, 100.0), q.rects.items[0].width);
}

test "import zengy, submodules (input, Key), is_alive, and 0-arg hooks work" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(scripting_host.module());
    try app.registerModule(scripting_python.module());
    try app.initialize();

    const h_entry = try app.services.getService("engine.script.host", 1);
    const host: *scripting_host.ScriptingHost = @ptrCast(@alignCast(@constCast(h_entry.api_ptr)));

    const mod = try host.loadScript(0, "zengy_api_test.py",
        \\import zengy
        \\from zengy import Key, input
        \\
        \\started = False
        \\
        \\def start():
        \\    global started
        \\    started = True
        \\    zengy.log("started via zengy", "warn")
        \\    ent = zengy.spawn_entity()
        \\    if not zengy.is_alive(ent):
        \\        raise RuntimeError("entity should be alive")
        \\    if Key.W != 26 or Key.A != 4 or Key.SPACE != 44:
        \\        raise RuntimeError("unexpected scancodes")
        \\    if input.is_key_down(Key.W):
        \\        raise RuntimeError("key should not be down")
        \\    zengy.draw_rect(1, 2, 3, 4)
        \\
        \\def check(arg):
        \\    if not started:
        \\        raise RuntimeError("start() did not run")
    );
    try testing.expect(host.invokeScript(mod, "start", "").ok);
    try testing.expect(host.invokeScript(mod, "check", "").ok);

    const q = app.resources.get(scripting_host.ScriptDrawQueue).?;
    try testing.expectEqual(@as(usize, 1), q.rects.items.len);
    try testing.expect(app.diagnostics.count() >= 1);
}
