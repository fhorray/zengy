//! Scripting Host Protocol Tests (`packages/scripting-host/tests/scripting_host_tests.zig`).
//!
//! Validates Phase 7: multiple independent scripting runtimes coexisting under
//! `ScriptingHost` (`engine.script.host/1`), isolated script error handling,
//! event bridge posting, and generational handle invalidation on runtime teardown.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const scripting_host = @import("scripting_host");

test "ScriptingHost coexistence of two independent runtimes without Core branches" {
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

    const err_res = host.invokeScript(mod_py, "throw", "");
    try testing.expect(!err_res.ok);

    try testing.expect(host.invokeScript(mod_lua, "on_tick", "from_lua").ok);
    try testing.expect(host.invokeScript(mod_py, "on_tick", "from_py").ok);

    try app.commands.apply(&app.world, &app.events);
    try testing.expectEqual(@as(usize, 2), app.events.pendingCount());

    host.destroyRuntime(rt_lua);
    const stale_res = host.invokeScript(mod_lua, "on_tick", "");
    try testing.expect(!stale_res.ok);
}
