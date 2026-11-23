//! Optional Lua 5.4 Scripting Runtime Package (`official.script.lua`).
//!
//! Integrates the official Lua 5.4.7 C VM (`github.com/lua/lua`) as an optional
//! `engine.Module` registered with `official.script.host` (`engine.script.host/1`).
//!
//! Cross-platform & Architectural Guarantees:
//! - Compiles pure C99/C11 Lua sources natively for Linux, Windows, and macOS.
//! - `src/core/` has zero references to Lua.
//! - Lua scripts interact with the engine exclusively through `ScriptEngineBridge`.
//! - Syntax and runtime errors are caught via `lua_pcall` and returned as `ScriptResult`.

const std = @import("std");
const engine = @import("engine");
const scripting_host = @import("scripting_host");
const c = @import("lua_c");

pub const MODULE_OWNER_ID: u64 = 2020;
const BRIDGE_REG_KEY = "_zigeng_bridge";

const LuaRuntimeState = struct {
    allocator: std.mem.Allocator,
    L: *c.lua_State,
    bridge: *scripting_host.ScriptEngineBridge,
    next_mod_id: u64,
};

fn getBridge(L: ?*c.lua_State) ?*scripting_host.ScriptEngineBridge {
    const state = L orelse return null;
    _ = c.lua_getfield(state, c.LUA_REGISTRYINDEX, BRIDGE_REG_KEY);
    defer c.lua_pop(state, 1);
    const ptr = c.lua_touserdata(state, -1) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn luaToSlice(L: *c.lua_State, idx: c_int) ?[]const u8 {
    var len: usize = 0;
    const ptr = c.lua_tolstring(L, idx, &len) orelse return null;
    return ptr[0..len];
}

fn luaEngineLog(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L orelse return 0;
    const bridge = getBridge(state) orelse return 0;
    const msg = luaToSlice(state, 1) orelse return 0;
    bridge.log(.info, msg) catch {};
    return 0;
}

fn luaEngineSpawnEntity(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L orelse return 0;
    const bridge = getBridge(state) orelse {
        c.lua_pushinteger(state, 0);
        return 1;
    };
    const handle = bridge.spawnEntity() catch {
        c.lua_pushinteger(state, 0);
        return 1;
    };
    c.lua_pushinteger(state, @intCast(handle));
    return 1;
}

fn luaEnginePostEvent(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L orelse return 0;
    const bridge = getBridge(state) orelse return 0;
    const name = luaToSlice(state, 1) orelse return 0;
    const payload = luaToSlice(state, 2) orelse "";
    bridge.postEvent(name, payload, 0) catch {};
    return 0;
}

fn createLuaRuntime(allocator: std.mem.Allocator, bridge: *scripting_host.ScriptEngineBridge) !*anyopaque {
    const L = c.luaL_newstate() orelse return error.OutOfMemory;
    errdefer c.lua_close(L);

    c.luaL_openlibs(L);

    // Store ScriptEngineBridge pointer in Lua registry.
    c.lua_pushlightuserdata(L, bridge);
    c.lua_setfield(L, c.LUA_REGISTRYINDEX, BRIDGE_REG_KEY);

    // Expose global `engine` table to Lua scripts.
    c.lua_createtable(L, 0, 3);
    c.lua_pushcclosure(L, luaEngineLog, 0);
    c.lua_setfield(L, -2, "log");
    c.lua_pushcclosure(L, luaEngineSpawnEntity, 0);
    c.lua_setfield(L, -2, "spawn_entity");
    c.lua_pushcclosure(L, luaEnginePostEvent, 0);
    c.lua_setfield(L, -2, "post_event");
    c.lua_setglobal(L, "engine");

    const st = try allocator.create(LuaRuntimeState);
    st.* = .{
        .allocator = allocator,
        .L = L,
        .bridge = bridge,
        .next_mod_id = 1,
    };
    return st;
}

fn loadLuaScript(raw: *anyopaque, _: []const u8, source: []const u8) !u64 {
    const st: *LuaRuntimeState = @ptrCast(@alignCast(raw));
    if (c.luaL_loadbufferx(st.L, source.ptr, source.len, "script", null) != c.LUA_OK) {
        c.lua_pop(st.L, 1);
        return error.LuaSyntaxError;
    }
    if (c.lua_pcallk(st.L, 0, 1, 0, 0, null) != c.LUA_OK) {
        c.lua_pop(st.L, 1);
        return error.LuaRuntimeError;
    }

    const id = st.next_mod_id;
    st.next_mod_id += 1;

    var key_buf: [32]u8 = undefined;
    const key = try std.fmt.bufPrintSentinel(&key_buf, "_zigeng_mod_{d}", .{id}, 0);
    c.lua_setfield(st.L, c.LUA_REGISTRYINDEX, key.ptr);
    return id;
}

fn invokeLuaScript(raw: *anyopaque, script_id: u64, fn_name: []const u8, arg: []const u8) scripting_host.ScriptResult {
    const st: *LuaRuntimeState = @ptrCast(@alignCast(raw));

    var key_buf: [32]u8 = undefined;
    const key = std.fmt.bufPrintSentinel(&key_buf, "_zigeng_mod_{d}", .{script_id}, 0) catch {
        return .{ .ok = false, .error_message = "invalid script id" };
    };
    _ = c.lua_getfield(st.L, c.LUA_REGISTRYINDEX, key.ptr);
    if (c.lua_type(st.L, -1) != c.LUA_TTABLE) {
        c.lua_pop(st.L, 1);
        return .{ .ok = false, .error_message = "lua module did not return a table" };
    }

    const z_fn = std.fmt.allocPrintSentinel(st.allocator, "{s}", .{fn_name}, 0) catch {
        c.lua_pop(st.L, 1);
        return .{ .ok = false, .error_message = "out of memory" };
    };
    defer st.allocator.free(z_fn);

    _ = c.lua_getfield(st.L, -1, z_fn.ptr);
    if (c.lua_type(st.L, -1) != c.LUA_TFUNCTION) {
        c.lua_pop(st.L, 2);
        return .{ .ok = false, .error_message = "lua function not found" };
    }

    _ = c.lua_pushlstring(st.L, arg.ptr, arg.len);
    if (c.lua_pcallk(st.L, 1, 0, 0, 0, null) != c.LUA_OK) {
        c.lua_pop(st.L, 2);
        return .{ .ok = false, .error_message = "lua runtime exception" };
    }
    c.lua_pop(st.L, 1);
    return .{ .ok = true };
}

fn unloadLuaScript(raw: *anyopaque, script_id: u64) void {
    const st: *LuaRuntimeState = @ptrCast(@alignCast(raw));
    var key_buf: [32]u8 = undefined;
    const key = std.fmt.bufPrintSentinel(&key_buf, "_zigeng_mod_{d}", .{script_id}, 0) catch return;
    c.lua_pushnil(st.L);
    c.lua_setfield(st.L, c.LUA_REGISTRYINDEX, key.ptr);
}

fn destroyLuaRuntime(raw: *anyopaque, allocator: std.mem.Allocator) void {
    const st: *LuaRuntimeState = @ptrCast(@alignCast(raw));
    c.lua_close(st.L);
    allocator.destroy(st);
}

pub const vtable = scripting_host.RuntimeProviderVTable{
    .create = createLuaRuntime,
    .load = loadLuaScript,
    .invoke = invokeLuaScript,
    .unload = unloadLuaScript,
    .destroy = destroyLuaRuntime,
};

const LuaModuleHandle = struct {
    runtime_idx: u16,
};

fn buildModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    const host = app.resources.get(scripting_host.ScriptingHost) orelse return error.MissingScriptingHost;
    const rt_idx = try host.registerRuntime(.{
        .language_id = "lua",
        .language_version = "5.4",
        .api_version = 1,
    }, vtable);

    try app.resources.insert(LuaModuleHandle, .{ .runtime_idx = rt_idx });
}

fn stopModule(raw_app: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    if (app.resources.get(LuaModuleHandle)) |h| {
        if (app.resources.get(scripting_host.ScriptingHost)) |host| {
            host.destroyRuntime(h.runtime_idx);
        }
        _ = app.resources.remove(LuaModuleHandle);
    }
}

pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = "official.script.lua",
            .version = "0.1.0",
            .provides_capabilities = &.{"engine.script.runtime.lua/1"},
            .required_capabilities = &.{"engine.script.host/1"},
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
