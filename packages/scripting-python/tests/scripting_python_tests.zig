//! Real CPython 3 + Lua 5.5 Coexistence Tests (`packages/scripting-python/tests/scripting_python_tests.zig`).
//!
//! Validates `official.script.python` (real CPython via `NativeLib`) and proves
//! Section 7.8: Lua 5.5 and CPython 3 coexist in the same `App`, spawning ECS
//! entities and exchanging events through `ScriptingHost` with zero Core branches.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const scripting_host = @import("scripting_host");
const scripting_lua = @import("scripting_lua");
const scripting_python = @import("scripting_python");

test "CPython 3 and Lua 5.5 coexist in one App, spawn entities, and exchange events" {
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

    // Runtime 0 = Lua 5.5, Runtime 1 = CPython 3
    const lua_mod = try host.loadScript(0, "a.lua",
        \\local M = {}
        \\function M.run(arg)
        \\    engine.spawn_entity()
        \\    engine.post_event("lua.event", arg)
        \\end
        \\return M
    );

    const py_mod = try host.loadScript(1, "b.py",
        \\import engine
        \\def run(arg):
        \\    engine.log("python: " + arg)
        \\    engine.spawn_entity()
        \\    engine.post_event("py.event", arg)
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
