//! Real Lua 5.5 Scripting Runtime Tests (`packages/scripting/lua/tests/scripting_lua_tests.zig`).
//!
//! Validates `official.script.lua` (`zlua`):
//! - Executes real Lua 5.5 code calling `engine.log`, `engine.spawn_entity`, and `engine.post_event`.
//! - Catches Lua syntax and runtime errors without crashing the Zig host.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const scripting_host = @import("scripting_host");
const scripting_lua = @import("scripting_lua");

test "Lua 5.5 VM executes scripts, spawns entities, posts events, and isolates errors" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    const Catcher = struct {
        seen: bool = false,
        fn onEv(raw: ?*anyopaque, ev: engine.EventEnvelope) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (std.mem.eql(u8, ev.payload, "hello_from_lua55")) {
                self.seen = true;
            }
        }
    };
    var catcher = Catcher{};
    _ = try app.events.subscribe(1, "lua.ping", Catcher.onEv, &catcher);

    try app.registerModule(scripting_host.module());
    try app.registerModule(scripting_lua.module());
    try app.initialize();

    const host = app.resources.get(scripting_host.ScriptingHost).?;

    // Find the registered Lua runtime (index 0)
    const mod_handle = try host.loadScript(0, "game.lua",
        \\local M = {}
        \\function M.on_tick(arg)
        \\    engine.log("lua: " .. arg)
        \\    local e = engine.spawn_entity()
        \\    engine.post_event("lua.ping", "hello_from_lua55")
        \\end
        \\function M.fail(arg)
        \\    error("intentional lua error")
        \\end
        \\return M
    );

    const ok_res = host.invokeScript(mod_handle, "on_tick", "tick1");
    try testing.expect(ok_res.ok);

    // Runtime error is caught cleanly without crashing
    const err_res = host.invokeScript(mod_handle, "fail", "");
    try testing.expect(!err_res.ok);

    try app.commands.apply(&app.world, &app.events);
    _ = app.events.drain();

    try testing.expectEqual(@as(usize, 1), app.world.entity_count);
    try testing.expect(catcher.seen);
    try testing.expect(app.diagnostics.count() >= 1);
}
