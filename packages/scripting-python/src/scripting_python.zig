//! Optional CPython 3 Runtime Package (`official.script.python`).
//!
//! Integrates a real embedded CPython 3 interpreter as an optional `engine.Module`
//! registered with `official.script.host` (`engine.script.host/1`).
//!
//! Cross-platform design:
//! - Loads `libpython3` dynamically at runtime via `engine.abi.NativeLib`, so
//!   cross-compilation for Linux, Windows, and macOS requires zero target `Python.h`
//!   headers or import libraries on the build machine.
//! - Binds `engine.log`, `engine.spawn_entity`, and `engine.post_event` into Python's
//!   `sys.modules['engine']` via `ctypes` pointing directly to Zig `callconv(.c)` callbacks.
//! - Catches Python syntax/runtime exceptions inside Python without crashing the host.

const std = @import("std");
const builtin = @import("builtin");
const engine = @import("engine");
const scripting_host = @import("scripting_host");

pub const MODULE_OWNER_ID: u64 = 2021;

const PyInitializeExFn = *const fn (initsigs: c_int) callconv(.c) void;
const PyIsInitializedFn = *const fn () callconv(.c) c_int;
const PyRunSimpleStringFn = *const fn (command: [*:0]const u8) callconv(.c) c_int;
const PyErrOccurredFn = *const fn () callconv(.c) ?*anyopaque;
const PyErrClearFn = *const fn () callconv(.c) void;

var g_active_bridge: ?*scripting_host.ScriptEngineBridge = null;

fn pyBridgeLog(msg_z: [*:0]const u8) callconv(.c) void {
    const bridge = g_active_bridge orelse return;
    bridge.log(.info, std.mem.span(msg_z)) catch {};
}

fn pyBridgeSpawn() callconv(.c) u64 {
    const bridge = g_active_bridge orelse return 0;
    return bridge.spawnEntity() catch 0;
}

fn pyBridgePostEvent(name_z: [*:0]const u8, payload_z: [*:0]const u8) callconv(.c) void {
    const bridge = g_active_bridge orelse return;
    bridge.postEvent(std.mem.span(name_z), std.mem.span(payload_z), 0) catch {};
}

const PythonLib = if (builtin.os.tag != .windows and builtin.link_libc) struct {
    handle: *anyopaque,

    fn open(path: []const u8) !PythonLib {
        var buf: [4096]u8 = undefined;
        if (path.len >= buf.len) return error.NameTooLong;
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;
        const h = std.c.dlopen(@ptrCast(buf[0..path.len :0]), .{ .LAZY = true, .GLOBAL = true }) orelse return error.FileNotFound;
        return .{ .handle = h };
    }

    fn lookup(self: *PythonLib, comptime T: type, name: [:0]const u8) ?T {
        const sym = std.c.dlsym(self.handle, name.ptr) orelse return null;
        return @ptrCast(@alignCast(sym));
    }

    fn close(self: *PythonLib) void {
        _ = std.c.dlclose(self.handle);
    }
} else engine.abi.NativeLib;

const PythonRuntimeState = struct {
    allocator: std.mem.Allocator,
    lib: PythonLib,
    py_run_simple: PyRunSimpleStringFn,
    py_err_occurred: PyErrOccurredFn,
    py_err_clear: PyErrClearFn,
    bridge: *scripting_host.ScriptEngineBridge,
    next_mod_id: u64,
};

fn openPythonLib() !PythonLib {
    const candidates: []const []const u8 = switch (builtin.os.tag) {
        .windows => &.{ "python312.dll", "python311.dll", "python3.dll" },
        .macos => &.{ "libpython3.12.dylib", "libpython3.11.dylib", "/opt/homebrew/Frameworks/Python.framework/Versions/3.12/Python" },
        else => &.{
            "/opt/pyenv/versions/3.12.16/lib/libpython3.12.so",
            "libpython3.12.so",
            "libpython3.12.so.1.0",
            "libpython3.11.so",
            "libpython3.so",
        },
    };

    for (candidates) |path| {
        if (PythonLib.open(path)) |lib| {
            return lib;
        } else |_| {}
    }
    return error.PythonLibraryNotFound;
}

fn createPythonRuntime(allocator: std.mem.Allocator, bridge: *scripting_host.ScriptEngineBridge) !*anyopaque {
    var lib = try openPythonLib();
    errdefer lib.close();

    const py_init = lib.lookup(PyInitializeExFn, "Py_InitializeEx") orelse return error.MissingPythonSymbol;
    const py_is_init = lib.lookup(PyIsInitializedFn, "Py_IsInitialized") orelse return error.MissingPythonSymbol;
    const py_run = lib.lookup(PyRunSimpleStringFn, "PyRun_SimpleString") orelse return error.MissingPythonSymbol;
    const py_err_occ = lib.lookup(PyErrOccurredFn, "PyErr_Occurred") orelse return error.MissingPythonSymbol;
    const py_err_clr = lib.lookup(PyErrClearFn, "PyErr_Clear") orelse return error.MissingPythonSymbol;

    if (py_is_init() == 0) {
        py_init(0);
    }

    g_active_bridge = bridge;

    // Bootstrap the `engine` Python module using ctypes over Zig bridge function pointers.
    const bootstrap = try std.fmt.allocPrintSentinel(
        allocator,
        \\import sys, types, ctypes
        \\_log_cb = ctypes.CFUNCTYPE(None, ctypes.c_char_p)({d})
        \\_spawn_cb = ctypes.CFUNCTYPE(ctypes.c_uint64)({d})
        \\_post_cb = ctypes.CFUNCTYPE(None, ctypes.c_char_p, ctypes.c_char_p)({d})
        \\engine_mod = types.ModuleType("engine")
        \\engine_mod.log = lambda msg: _log_cb(str(msg).encode("utf-8"))
        \\engine_mod.spawn_entity = lambda: int(_spawn_cb())
        \\engine_mod.post_event = lambda name, payload="": _post_cb(str(name).encode("utf-8"), str(payload).encode("utf-8"))
        \\sys.modules["engine"] = engine_mod
        \\_zigeng_modules = {{}}
        \\_zigeng_last_err = ""
    ,
        .{
            @intFromPtr(&pyBridgeLog),
            @intFromPtr(&pyBridgeSpawn),
            @intFromPtr(&pyBridgePostEvent),
        },
        0,
    );
    defer allocator.free(bootstrap);

    if (py_run(bootstrap) != 0) {
        if (py_err_occ() != null) py_err_clr();
        return error.PythonBootstrapFailed;
    }

    const st = try allocator.create(PythonRuntimeState);
    st.* = .{
        .allocator = allocator,
        .lib = lib,
        .py_run_simple = py_run,
        .py_err_occurred = py_err_occ,
        .py_err_clear = py_err_clr,
        .bridge = bridge,
        .next_mod_id = 1,
    };
    return st;
}

fn loadPythonScript(raw: *anyopaque, _: []const u8, source: []const u8) !u64 {
    const st: *PythonRuntimeState = @ptrCast(@alignCast(raw));
    const id = st.next_mod_id;
    st.next_mod_id += 1;

    // Escape source safely by passing base64 or raw repr? Using hex encoding avoids all escaping issues!
    var hex_buf = try st.allocator.alloc(u8, source.len * 2);
    defer st.allocator.free(hex_buf);
    const hex_chars = "0123456789abcdef";
    for (source, 0..) |b, i| {
        hex_buf[i * 2] = hex_chars[b >> 4];
        hex_buf[i * 2 + 1] = hex_chars[b & 0x0f];
    }

    const code = try std.fmt.allocPrintSentinel(
        st.allocator,
        \\import builtins
        \\_ns_{d} = {{}}
        \\exec(bytes.fromhex("{s}").decode("utf-8"), _ns_{d})
        \\_zigeng_modules[{d}] = _ns_{d}
    ,
        .{ id, hex_buf, id, id, id },
        0,
    );
    defer st.allocator.free(code);

    if (st.py_run_simple(code) != 0) {
        if (st.py_err_occurred() != null) st.py_err_clear();
        return error.PythonScriptError;
    }
    return id;
}

fn invokePythonScript(raw: *anyopaque, script_id: u64, fn_name: []const u8, arg: []const u8) scripting_host.ScriptResult {
    const st: *PythonRuntimeState = @ptrCast(@alignCast(raw));

    const arg_hex = st.allocator.alloc(u8, arg.len * 2) catch {
        return .{ .ok = false, .error_message = "out of memory" };
    };
    defer st.allocator.free(arg_hex);
    const hex_chars = "0123456789abcdef";
    for (arg, 0..) |b, i| {
        arg_hex[i * 2] = hex_chars[b >> 4];
        arg_hex[i * 2 + 1] = hex_chars[b & 0x0f];
    }

    const code = std.fmt.allocPrintSentinel(
        st.allocator,
        \\try:
        \\    _zigeng_ok = False
        \\    _ns = _zigeng_modules.get({d})
        \\    if _ns is not None and "{s}" in _ns:
        \\        _ns["{s}"](bytes.fromhex("{s}").decode("utf-8"))
        \\        _zigeng_ok = True
        \\except Exception as _e:
        \\    _zigeng_ok = False
        \\    _zigeng_last_err = str(_e)
    ,
        .{ script_id, fn_name, fn_name, arg_hex },
        0,
    ) catch {
        return .{ .ok = false, .error_message = "out of memory" };
    };
    defer st.allocator.free(code);

    if (st.py_run_simple(code) != 0) {
        if (st.py_err_occurred() != null) st.py_err_clear();
        return .{ .ok = false, .error_message = "python execution failed" };
    }

    // Check `_zigeng_ok` via exit code trick? Or PyRun_SimpleString returns 0 even if caught.
    // Use `raise`? No, PyRun_SimpleString prints traceback to stderr if uncaught, whereas
    // checking `assert _zigeng_ok` after catching inside Python is clean:
    const check = "if not _zigeng_ok: raise RuntimeError(_zigeng_last_err)";
    if (st.py_run_simple(check) != 0) {
        if (st.py_err_occurred() != null) st.py_err_clear();
        return .{ .ok = false, .error_message = "python runtime exception" };
    }
    return .{ .ok = true };
}

fn unloadPythonScript(raw: *anyopaque, script_id: u64) void {
    const st: *PythonRuntimeState = @ptrCast(@alignCast(raw));
    const code = std.fmt.allocPrintSentinel(
        st.allocator,
        "_zigeng_modules.pop({d}, None)",
        .{script_id},
        0,
    ) catch return;
    defer st.allocator.free(code);
    if (st.py_run_simple(code) != 0) {
        if (st.py_err_occurred() != null) st.py_err_clear();
    }
}

fn destroyPythonRuntime(raw: *anyopaque, allocator: std.mem.Allocator) void {
    const st: *PythonRuntimeState = @ptrCast(@alignCast(raw));
    g_active_bridge = null;
    st.lib.close();
    allocator.destroy(st);
}

pub const vtable = scripting_host.RuntimeProviderVTable{
    .create = createPythonRuntime,
    .load = loadPythonScript,
    .invoke = invokePythonScript,
    .unload = unloadPythonScript,
    .destroy = destroyPythonRuntime,
};

const PythonModuleHandle = struct {
    runtime_idx: u16,
};

fn buildModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    const host = app.resources.get(scripting_host.ScriptingHost) orelse return error.MissingScriptingHost;
    const rt_idx = try host.registerRuntime(.{
        .language_id = "python",
        .language_version = "3.12",
        .api_version = 1,
    }, vtable);

    try app.resources.insert(PythonModuleHandle, .{ .runtime_idx = rt_idx });
}

fn stopModule(raw_app: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    if (app.resources.get(PythonModuleHandle)) |h| {
        if (app.resources.get(scripting_host.ScriptingHost)) |host| {
            host.destroyRuntime(h.runtime_idx);
        }
        _ = app.resources.remove(PythonModuleHandle);
    }
}

pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = "official.script.python",
            .version = "0.1.0",
            .provides_capabilities = &.{"engine.script.runtime.python/1"},
            .required_capabilities = &.{"engine.script.host/1"},
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
