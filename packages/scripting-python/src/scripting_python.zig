//! Optional CPython 3 Runtime Package (`official.script.python`).
//!
//! Integrates a real embedded CPython 3 interpreter as an optional `engine.Module`
//! registered with `official.script.host` (`engine.script.host/1`).
//!
//! Cross-platform design:
//! - Loads `libpython3` dynamically at runtime via `RTLD_GLOBAL` (POSIX) or
//!   `NativeLib` (Windows), so cross-compilation for Linux, Windows, and macOS
//!   requires zero target `Python.h` headers or import libraries on the build machine.
//! - Binds `engine.log`, `engine.spawn_entity`, and `engine.post_event` into Python's
//!   `sys.modules['engine']` with per-runtime `ScriptEngineBridge` closures (no globals).
//! - Compiles and invokes scripts directly via CPython C-API (`Py_CompileString`,
//!   `PyEval_EvalCode`, `PyObject_CallOneArg`, `PyErr_Fetch`) without shell/string
//!   interpolation or stderr traceback spam.

const std = @import("std");
const builtin = @import("builtin");
const engine = @import("engine");
const scripting_host = @import("scripting_host");

pub const MODULE_OWNER_ID: u64 = 2021;
const PY_FILE_INPUT: c_int = 257;

const PyObject = opaque {};

const PyInitializeExFn = *const fn (initsigs: c_int) callconv(.c) void;
const PyIsInitializedFn = *const fn () callconv(.c) c_int;
const PyRunSimpleStringFn = *const fn (command: [*:0]const u8) callconv(.c) c_int;
const PyDecRefFn = *const fn (obj: ?*PyObject) callconv(.c) void;
const PyDictNewFn = *const fn () callconv(.c) ?*PyObject;
const PyDictSetItemStringFn = *const fn (dp: *PyObject, key: [*:0]const u8, item: *PyObject) callconv(.c) c_int;
const PyDictGetItemStringFn = *const fn (dp: *PyObject, key: [*:0]const u8) callconv(.c) ?*PyObject;
const PyEvalGetBuiltinsFn = *const fn () callconv(.c) ?*PyObject;
const PyCompileStringFn = *const fn (str: [*:0]const u8, filename: [*:0]const u8, start: c_int) callconv(.c) ?*PyObject;
const PyEvalEvalCodeFn = *const fn (co: *PyObject, globals: *PyObject, locals: *PyObject) callconv(.c) ?*PyObject;
const PyObjectCallOneArgFn = *const fn (callable: *PyObject, arg: *PyObject) callconv(.c) ?*PyObject;
const PyObjectStrFn = *const fn (obj: *PyObject) callconv(.c) ?*PyObject;
const PyUnicodeFromStringAndSizeFn = *const fn (u: [*]const u8, size: isize) callconv(.c) ?*PyObject;
const PyUnicodeAsUTF8Fn = *const fn (unicode: *PyObject) callconv(.c) ?[*:0]const u8;
const PyErrOccurredFn = *const fn () callconv(.c) ?*PyObject;
const PyErrFetchFn = *const fn (ptype: *?*PyObject, pvalue: *?*PyObject, ptraceback: *?*PyObject) callconv(.c) void;
const PyErrNormalizeExceptionFn = *const fn (exc: *?*PyObject, val: *?*PyObject, tb: *?*PyObject) callconv(.c) void;
const PyErrClearFn = *const fn () callconv(.c) void;

fn pyBridgeLog(bridge_raw: usize, msg_ptr: ?[*]const u8, msg_len: usize) callconv(.c) void {
    if (bridge_raw == 0) return;
    const ptr = msg_ptr orelse return;
    const bridge: *scripting_host.ScriptEngineBridge = @ptrFromInt(bridge_raw);
    bridge.log(.info, ptr[0..msg_len]) catch {};
}

fn pyBridgeSpawn(bridge_raw: usize) callconv(.c) u64 {
    if (bridge_raw == 0) return 0;
    const bridge: *scripting_host.ScriptEngineBridge = @ptrFromInt(bridge_raw);
    return bridge.spawnEntity() catch 0;
}

fn pyBridgePostEvent(
    bridge_raw: usize,
    name_ptr: ?[*]const u8,
    name_len: usize,
    payload_ptr: ?[*]const u8,
    payload_len: usize,
) callconv(.c) void {
    if (bridge_raw == 0) return;
    const n_ptr = name_ptr orelse return;
    const p_slice: []const u8 = if (payload_ptr) |pp| pp[0..payload_len] else "";
    const bridge: *scripting_host.ScriptEngineBridge = @ptrFromInt(bridge_raw);
    bridge.postEvent(n_ptr[0..name_len], p_slice, 0) catch {};
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

var g_cached_python_lib: ?PythonLib = null;

fn acquirePythonLib() !PythonLib {
    if (g_cached_python_lib) |cached| return cached;

    const candidates: []const []const u8 = switch (builtin.os.tag) {
        .windows => &.{ "python312.dll", "python311.dll", "python313.dll", "python3.dll" },
        .macos => &.{
            "libpython3.12.dylib",
            "libpython3.11.dylib",
            "libpython3.13.dylib",
            "/opt/homebrew/Frameworks/Python.framework/Versions/3.12/Python",
        },
        else => &.{
            "libpython3.12.so",
            "libpython3.12.so.1.0",
            "libpython3.11.so",
            "libpython3.13.so",
            "libpython3.so",
            "/opt/pyenv/versions/3.12.16/lib/libpython3.12.so",
        },
    };

    for (candidates) |path| {
        if (PythonLib.open(path)) |lib| {
            g_cached_python_lib = lib;
            return lib;
        } else |_| {}
    }
    return error.PythonLibraryNotFound;
}

const PythonRuntimeState = struct {
    allocator: std.mem.Allocator,
    py_dec_ref: PyDecRefFn,
    py_dict_new: PyDictNewFn,
    py_dict_set_item_str: PyDictSetItemStringFn,
    py_dict_get_item_str: PyDictGetItemStringFn,
    py_eval_get_builtins: PyEvalGetBuiltinsFn,
    py_compile_string: PyCompileStringFn,
    py_eval_eval_code: PyEvalEvalCodeFn,
    py_object_call_one_arg: PyObjectCallOneArgFn,
    py_object_str: PyObjectStrFn,
    py_unicode_from_str_size: PyUnicodeFromStringAndSizeFn,
    py_unicode_as_utf8: PyUnicodeAsUTF8Fn,
    py_err_occurred: PyErrOccurredFn,
    py_err_fetch: PyErrFetchFn,
    py_err_normalize: PyErrNormalizeExceptionFn,
    py_err_clear: PyErrClearFn,
    bridge: *scripting_host.ScriptEngineBridge,
    modules: std.AutoHashMapUnmanaged(u64, *PyObject),
    next_mod_id: u64,
    last_error: [256]u8 = undefined,
    last_error_len: usize = 0,
};

fn capturePythonError(st: *PythonRuntimeState) []const u8 {
    var ptype: ?*PyObject = null;
    var pvalue: ?*PyObject = null;
    var ptraceback: ?*PyObject = null;
    st.py_err_fetch(&ptype, &pvalue, &ptraceback);
    st.py_err_normalize(&ptype, &pvalue, &ptraceback);
    defer {
        if (ptype) |p| st.py_dec_ref(p);
        if (pvalue) |v| st.py_dec_ref(v);
        if (ptraceback) |t| st.py_dec_ref(t);
    }

    if (pvalue) |val| {
        if (st.py_object_str(val)) |str_obj| {
            defer st.py_dec_ref(str_obj);
            if (st.py_unicode_as_utf8(str_obj)) |utf8_z| {
                const msg = std.mem.span(utf8_z);
                const n = @min(msg.len, st.last_error.len);
                @memcpy(st.last_error[0..n], msg[0..n]);
                st.last_error_len = n;
                return st.last_error[0..n];
            }
        }
    }
    return "python runtime exception";
}

fn createPythonRuntime(allocator: std.mem.Allocator, bridge: *scripting_host.ScriptEngineBridge) !*anyopaque {
    var lib = try acquirePythonLib();

    const py_init = lib.lookup(PyInitializeExFn, "Py_InitializeEx") orelse return error.MissingPythonSymbol;
    const py_is_init = lib.lookup(PyIsInitializedFn, "Py_IsInitialized") orelse return error.MissingPythonSymbol;
    const py_run = lib.lookup(PyRunSimpleStringFn, "PyRun_SimpleString") orelse return error.MissingPythonSymbol;
    const py_dec_ref = lib.lookup(PyDecRefFn, "Py_DecRef") orelse return error.MissingPythonSymbol;
    const py_dict_new = lib.lookup(PyDictNewFn, "PyDict_New") orelse return error.MissingPythonSymbol;
    const py_dict_set = lib.lookup(PyDictSetItemStringFn, "PyDict_SetItemString") orelse return error.MissingPythonSymbol;
    const py_dict_get = lib.lookup(PyDictGetItemStringFn, "PyDict_GetItemString") orelse return error.MissingPythonSymbol;
    const py_builtins = lib.lookup(PyEvalGetBuiltinsFn, "PyEval_GetBuiltins") orelse return error.MissingPythonSymbol;
    const py_compile = lib.lookup(PyCompileStringFn, "Py_CompileString") orelse return error.MissingPythonSymbol;
    const py_eval = lib.lookup(PyEvalEvalCodeFn, "PyEval_EvalCode") orelse return error.MissingPythonSymbol;
    const py_call1 = lib.lookup(PyObjectCallOneArgFn, "PyObject_CallOneArg") orelse return error.MissingPythonSymbol;
    const py_str = lib.lookup(PyObjectStrFn, "PyObject_Str") orelse return error.MissingPythonSymbol;
    const py_u_from = lib.lookup(PyUnicodeFromStringAndSizeFn, "PyUnicode_FromStringAndSize") orelse return error.MissingPythonSymbol;
    const py_u_utf8 = lib.lookup(PyUnicodeAsUTF8Fn, "PyUnicode_AsUTF8") orelse return error.MissingPythonSymbol;
    const py_err_occ = lib.lookup(PyErrOccurredFn, "PyErr_Occurred") orelse return error.MissingPythonSymbol;
    const py_err_fetch = lib.lookup(PyErrFetchFn, "PyErr_Fetch") orelse return error.MissingPythonSymbol;
    const py_err_norm = lib.lookup(PyErrNormalizeExceptionFn, "PyErr_NormalizeException") orelse return error.MissingPythonSymbol;
    const py_err_clr = lib.lookup(PyErrClearFn, "PyErr_Clear") orelse return error.MissingPythonSymbol;

    if (py_is_init() == 0) {
        py_init(0);
    }

    // Bind `engine` module with per-runtime bridge pointer captured in closures (no global state).
    const bootstrap = try std.fmt.allocPrintSentinel(
        allocator,
        \\import sys, types, ctypes
        \\_log_cb = ctypes.CFUNCTYPE(None, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t)({d})
        \\_spawn_cb = ctypes.CFUNCTYPE(ctypes.c_uint64, ctypes.c_size_t)({d})
        \\_post_cb = ctypes.CFUNCTYPE(None, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t)({d})
        \\_b = {d}
        \\engine_mod = types.ModuleType("engine")
        \\def _log(msg, _b=_b):
        \\    b = str(msg).encode("utf-8")
        \\    _log_cb(_b, b, len(b))
        \\def _spawn(_b=_b):
        \\    return int(_spawn_cb(_b))
        \\def _post(name, payload="", _b=_b):
        \\    nb = str(name).encode("utf-8")
        \\    pb = str(payload).encode("utf-8")
        \\    _post_cb(_b, nb, len(nb), pb, len(pb))
        \\engine_mod.log = _log
        \\engine_mod.spawn_entity = _spawn
        \\engine_mod.post_event = _post
        \\sys.modules["engine"] = engine_mod
    ,
        .{
            @intFromPtr(&pyBridgeLog),
            @intFromPtr(&pyBridgeSpawn),
            @intFromPtr(&pyBridgePostEvent),
            @intFromPtr(bridge),
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
        .py_dec_ref = py_dec_ref,
        .py_dict_new = py_dict_new,
        .py_dict_set_item_str = py_dict_set,
        .py_dict_get_item_str = py_dict_get,
        .py_eval_get_builtins = py_builtins,
        .py_compile_string = py_compile,
        .py_eval_eval_code = py_eval,
        .py_object_call_one_arg = py_call1,
        .py_object_str = py_str,
        .py_unicode_from_str_size = py_u_from,
        .py_unicode_as_utf8 = py_u_utf8,
        .py_err_occurred = py_err_occ,
        .py_err_fetch = py_err_fetch,
        .py_err_normalize = py_err_norm,
        .py_err_clear = py_err_clr,
        .bridge = bridge,
        .modules = .empty,
        .next_mod_id = 1,
    };
    return st;
}

fn loadPythonScript(raw: *anyopaque, source_name: []const u8, source: []const u8) !u64 {
    const st: *PythonRuntimeState = @ptrCast(@alignCast(raw));

    const src_z = try std.fmt.allocPrintSentinel(st.allocator, "{s}", .{source}, 0);
    defer st.allocator.free(src_z);

    var name_buf: [256]u8 = undefined;
    const filename_z: [:0]const u8 = if (source_name.len > 0 and source_name.len < name_buf.len) blk: {
        @memcpy(name_buf[0..source_name.len], source_name);
        name_buf[source_name.len] = 0;
        break :blk name_buf[0..source_name.len :0];
    } else "<script>";

    const code_obj = st.py_compile_string(src_z.ptr, filename_z.ptr, PY_FILE_INPUT) orelse {
        const err_msg = capturePythonError(st);
        st.bridge.log(.err, err_msg) catch {};
        return error.PythonScriptError;
    };
    defer st.py_dec_ref(code_obj);

    const ns_dict = st.py_dict_new() orelse return error.OutOfMemory;
    errdefer st.py_dec_ref(ns_dict);

    if (st.py_eval_get_builtins()) |builtins| {
        _ = st.py_dict_set_item_str(ns_dict, "__builtins__", builtins);
    }

    const eval_res = st.py_eval_eval_code(code_obj, ns_dict, ns_dict) orelse {
        const err_msg = capturePythonError(st);
        st.bridge.log(.err, err_msg) catch {};
        return error.PythonScriptError;
    };
    st.py_dec_ref(eval_res);

    const id = st.next_mod_id;
    try st.modules.put(st.allocator, id, ns_dict);
    st.next_mod_id += 1;
    return id;
}

fn invokePythonScript(raw: *anyopaque, script_id: u64, fn_name: []const u8, arg: []const u8) scripting_host.ScriptResult {
    const st: *PythonRuntimeState = @ptrCast(@alignCast(raw));

    const ns_dict = st.modules.get(script_id) orelse {
        return .{ .ok = false, .error_message = "python script not found" };
    };

    var stack_fn_buf: [128]u8 = undefined;
    var heap_fn: ?[:0]u8 = null;
    defer if (heap_fn) |h| st.allocator.free(h);

    const z_fn: [:0]const u8 = if (fn_name.len < stack_fn_buf.len) blk: {
        @memcpy(stack_fn_buf[0..fn_name.len], fn_name);
        stack_fn_buf[fn_name.len] = 0;
        break :blk stack_fn_buf[0..fn_name.len :0];
    } else blk: {
        heap_fn = std.fmt.allocPrintSentinel(st.allocator, "{s}", .{fn_name}, 0) catch {
            return .{ .ok = false, .error_message = "out of memory" };
        };
        break :blk heap_fn.?;
    };

    const fn_obj = st.py_dict_get_item_str(ns_dict, z_fn.ptr) orelse {
        return .{ .ok = false, .error_message = "python function not found" };
    };

    const arg_obj = st.py_unicode_from_str_size(arg.ptr, @intCast(arg.len)) orelse {
        if (st.py_err_occurred() != null) st.py_err_clear();
        return .{ .ok = false, .error_message = "out of memory" };
    };
    defer st.py_dec_ref(arg_obj);

    const res = st.py_object_call_one_arg(fn_obj, arg_obj) orelse {
        const err_msg = capturePythonError(st);
        return .{ .ok = false, .error_message = err_msg };
    };
    st.py_dec_ref(res);
    return .{ .ok = true };
}

fn unloadPythonScript(raw: *anyopaque, script_id: u64) void {
    const st: *PythonRuntimeState = @ptrCast(@alignCast(raw));
    if (st.modules.fetchRemove(script_id)) |kv| {
        st.py_dec_ref(kv.value);
    }
}

fn destroyPythonRuntime(raw: *anyopaque, allocator: std.mem.Allocator) void {
    const st: *PythonRuntimeState = @ptrCast(@alignCast(raw));
    var it = st.modules.valueIterator();
    while (it.next()) |ns_dict| {
        st.py_dec_ref(ns_dict.*);
    }
    st.modules.deinit(st.allocator);
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
        .language_version = "3",
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
