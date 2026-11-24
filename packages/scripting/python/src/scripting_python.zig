//! Optional PocketPy Scripting Runtime Package (`official.script.python`).
//!
//! Integrates the PocketPy VM (Python-subset, v2.2.0, MIT, `github.com/pocketpy/pocketpy`)
//! as an optional `engine.Module` registered with `official.script.host` (`engine.script.host/1`).
//!
//! Design:
//! - PocketPy sources are vendored in `packages/scripting/python/third_party/pocketpy/` and compiled as a single C11 unit.
//!   No system Python is required on the build or target machine.
//! - Each `ScriptingHost` runtime owns one PocketPy VM (`py_switchvm`, indices 1..15).
//!   Scripts of one runtime never see the globals of another.
//! - `engine.log`, `engine.spawn_entity` and `engine.post_event` are bound into a per-VM
//!   `engine` module. The `ScriptEngineBridge` pointer is stored in that module, so the
//!   native callbacks need no globals.
//! - Errors are returned as `ScriptResult` from `py_formatexc()`; they never abort the host.

const std = @import("std");
const engine = @import("engine");
const scripting_host = @import("scripting_host");
const c = @import("pocketpy_c");

pub const MODULE_OWNER_ID: u64 = 2021;

/// PocketPy VM slots: index 0 is the default VM, so runtimes use 1..15.
const FIRST_VM_INDEX: c_int = 1;
const VM_SLOT_COUNT: usize = 16;

var g_vm_in_use: [VM_SLOT_COUNT]bool = @splat(false);
var g_initialized: bool = false;

fn acquireVmIndex() !c_int {
    var i: usize = @intCast(FIRST_VM_INDEX);
    while (i < VM_SLOT_COUNT) : (i += 1) {
        if (!g_vm_in_use[i]) {
            g_vm_in_use[i] = true;
            return @intCast(i);
        }
    }
    return error.TooManyPythonRuntimes;
}

fn releaseVmIndex(idx: c_int) void {
    g_vm_in_use[@intCast(idx)] = false;
}

/// Reads the bridge pointer stored in the current VM's `engine` module.
fn bridgeFromEngineModule() ?*scripting_host.ScriptEngineBridge {
    const mod = c.py_getmodule("engine");
    if (mod == null) return null;
    const item = c.py_getdict(mod, c.py_name("__bridge"));
    if (item == null) return null;
    const raw: usize = @intCast(c.py_toint(item));
    if (raw == 0) return null;
    return @ptrFromInt(raw);
}

fn engineLog(argc: c_int, argv: c.py_StackRef) callconv(.c) bool {
    if (argc != 1) return c.py_exception(c.tp_TypeError, "engine.log() expects 1 argument");
    if (!c.py_checkstr(&argv[0])) return false;
    const bridge = bridgeFromEngineModule() orelse return false;
    var n: c_int = 0;
    const p = c.py_tostrn(&argv[0], &n);
    bridge.log(.info, p[0..@intCast(n)]) catch {};
    c.py_newnone(c.py_retval());
    return true;
}

fn engineSpawnEntity(argc: c_int, argv: c.py_StackRef) callconv(.c) bool {
    _ = argv;
    if (argc != 0) return c.py_exception(c.tp_TypeError, "engine.spawn_entity() takes no arguments");
    const bridge = bridgeFromEngineModule() orelse return false;
    const handle = bridge.spawnEntity() catch 0;
    c.py_newint(c.py_retval(), @intCast(handle));
    return true;
}

fn enginePostEvent(argc: c_int, argv: c.py_StackRef) callconv(.c) bool {
    if (argc < 1 or argc > 2) return c.py_exception(c.tp_TypeError, "engine.post_event(name, payload='') expects 1 or 2 arguments");
    if (!c.py_checkstr(&argv[0])) return false;
    var name_len: c_int = 0;
    const name_ptr = c.py_tostrn(&argv[0], &name_len);
    var payload: []const u8 = "";
    if (argc == 2) {
        if (!c.py_checkstr(&argv[1])) return false;
        var payload_len: c_int = 0;
        const payload_ptr = c.py_tostrn(&argv[1], &payload_len);
        payload = payload_ptr[0..@intCast(payload_len)];
    }
    const bridge = bridgeFromEngineModule() orelse return false;
    bridge.postEvent(name_ptr[0..@intCast(name_len)], payload, 0) catch {};
    c.py_newnone(c.py_retval());
    return true;
}

fn pyNumberArg(val: c.py_Ref) ?f32 {
    var out: c.py_f64 = 0.0;
    if (!c.py_castfloat(val, &out)) return null;
    return @floatCast(out);
}

fn engineDrawRect(argc: c_int, argv: c.py_StackRef) callconv(.c) bool {
    if (argc < 4 or argc > 8) return c.py_exception(c.tp_TypeError, "engine.draw_rect(x, y, w, h, r=1, g=1, b=1, a=1) expects 4..8 args");
    const x = pyNumberArg(&argv[0]) orelse return false;
    const y = pyNumberArg(&argv[1]) orelse return false;
    const w = pyNumberArg(&argv[2]) orelse return false;
    const h = pyNumberArg(&argv[3]) orelse return false;
    const r: f32 = if (argc >= 5) (pyNumberArg(&argv[4]) orelse return false) else 1.0;
    const g: f32 = if (argc >= 6) (pyNumberArg(&argv[5]) orelse return false) else 1.0;
    const b: f32 = if (argc >= 7) (pyNumberArg(&argv[6]) orelse return false) else 1.0;
    const a: f32 = if (argc >= 8) (pyNumberArg(&argv[7]) orelse return false) else 1.0;

    const bridge = bridgeFromEngineModule() orelse return false;
    bridge.drawRect(.{ .x = x, .y = y, .width = w, .height = h, .r = r, .g = g, .b = b, .a = a }) catch {};
    c.py_newnone(c.py_retval());
    return true;
}

fn engineIsKeyDown(argc: c_int, argv: c.py_StackRef) callconv(.c) bool {
    if (argc != 1) return c.py_exception(c.tp_TypeError, "engine.is_key_down(scancode) expects 1 argument");
    if (!c.py_checkint(&argv[0])) return false;
    const raw = c.py_toint(&argv[0]);
    const bridge = bridgeFromEngineModule() orelse return false;
    const down = if (raw >= 0 and raw < 256) bridge.isKeyDown(@intCast(raw)) else false;
    c.py_newbool(c.py_retval(), down);
    return true;
}

fn engineMouseX(argc: c_int, argv: c.py_StackRef) callconv(.c) bool {
    _ = argv;
    if (argc != 0) return c.py_exception(c.tp_TypeError, "engine.mouse_x() takes no arguments");
    const bridge = bridgeFromEngineModule() orelse return false;
    c.py_newfloat(c.py_retval(), bridge.mouseX());
    return true;
}

fn engineMouseY(argc: c_int, argv: c.py_StackRef) callconv(.c) bool {
    _ = argv;
    if (argc != 0) return c.py_exception(c.tp_TypeError, "engine.mouse_y() takes no arguments");
    const bridge = bridgeFromEngineModule() orelse return false;
    c.py_newfloat(c.py_retval(), bridge.mouseY());
    return true;
}

fn engineIsMouseDown(argc: c_int, argv: c.py_StackRef) callconv(.c) bool {
    _ = argv;
    if (argc != 0) return c.py_exception(c.tp_TypeError, "engine.is_mouse_down() takes no arguments");
    const bridge = bridgeFromEngineModule() orelse return false;
    c.py_newbool(c.py_retval(), bridge.isMouseDown());
    return true;
}

fn engineWasMouseClicked(argc: c_int, argv: c.py_StackRef) callconv(.c) bool {
    _ = argv;
    if (argc != 0) return c.py_exception(c.tp_TypeError, "engine.was_mouse_clicked() takes no arguments");
    const bridge = bridgeFromEngineModule() orelse return false;
    c.py_newbool(c.py_retval(), bridge.wasMouseClicked());
    return true;
}

const PythonRuntimeState = struct {
    allocator: std.mem.Allocator,
    vm_index: c_int,
    bridge: *scripting_host.ScriptEngineBridge,
    /// script id -> owned module name inside this VM (`zigeng_script_<id>`).
    modules: std.AutoHashMapUnmanaged(u64, [:0]u8),
    next_mod_id: u64,
    /// Storage for the last error message returned in `ScriptResult`.
    last_error: [512]u8 = undefined,
    last_error_len: usize = 0,
};

/// Copies the pending PocketPy exception into the runtime error buffer and clears it.
fn captureError(st: *PythonRuntimeState) []const u8 {
    const formatted = c.py_formatexc();
    defer c.py_clearexc(null);
    if (formatted == null) return "unknown python error";
    defer std.c.free(@ptrCast(formatted));
    const msg = std.mem.span(formatted);
    const n = @min(msg.len, st.last_error.len);
    @memcpy(st.last_error[0..n], msg[0..n]);
    st.last_error_len = n;
    return st.last_error[0..n];
}

fn createPythonRuntime(allocator: std.mem.Allocator, bridge: *scripting_host.ScriptEngineBridge) !*anyopaque {
    if (!g_initialized) {
        c.py_initialize();
        g_initialized = true;
    }

    const idx = try acquireVmIndex();
    errdefer releaseVmIndex(idx);
    c.py_switchvm(idx);

    // Per-VM `engine` module: the bridge pointer is kept in its dict, not in a global.
    const mod = c.py_newmodule("engine");
    var bridge_val: c.py_TValue = undefined;
    c.py_newint(&bridge_val, @intCast(@intFromPtr(bridge)));
    c.py_setdict(mod, c.py_name("__bridge"), &bridge_val);
    c.py_bindfunc(mod, "log", engineLog);
    c.py_bindfunc(mod, "spawn_entity", engineSpawnEntity);
    c.py_bindfunc(mod, "post_event", enginePostEvent);
    c.py_bindfunc(mod, "draw_rect", engineDrawRect);
    c.py_bindfunc(mod, "is_key_down", engineIsKeyDown);
    c.py_bindfunc(mod, "mouse_x", engineMouseX);
    c.py_bindfunc(mod, "mouse_y", engineMouseY);
    c.py_bindfunc(mod, "is_mouse_down", engineIsMouseDown);
    c.py_bindfunc(mod, "was_mouse_clicked", engineWasMouseClicked);

    const st = try allocator.create(PythonRuntimeState);
    st.* = .{
        .allocator = allocator,
        .vm_index = idx,
        .bridge = bridge,
        .modules = .empty,
        .next_mod_id = 1,
    };
    return st;
}

fn loadPythonScript(raw: *anyopaque, source_name: []const u8, source: []const u8) !u64 {
    const st: *PythonRuntimeState = @ptrCast(@alignCast(raw));
    c.py_switchvm(st.vm_index);

    const id = st.next_mod_id;
    const mod_name = try std.fmt.allocPrintSentinel(st.allocator, "zigeng_script_{d}", .{id}, 0);
    errdefer st.allocator.free(mod_name);

    const src_z = try std.fmt.allocPrintSentinel(st.allocator, "{s}", .{source}, 0);
    defer st.allocator.free(src_z);

    const file_z = try std.fmt.allocPrintSentinel(st.allocator, "{s}", .{if (source_name.len > 0) source_name else "<script>"}, 0);
    defer st.allocator.free(file_z);

    const mod = c.py_newmodule(mod_name.ptr);
    if (!c.py_exec(src_z.ptr, file_z.ptr, c.EXEC_MODE, mod)) {
        const err_msg = captureError(st);
        st.bridge.log(.err, err_msg) catch {};
        return error.PythonScriptError;
    }

    try st.modules.put(st.allocator, id, mod_name);
    st.next_mod_id += 1;
    return id;
}

fn invokePythonScript(raw: *anyopaque, script_id: u64, fn_name: []const u8, arg: []const u8) scripting_host.ScriptResult {
    const st: *PythonRuntimeState = @ptrCast(@alignCast(raw));
    c.py_switchvm(st.vm_index);

    const mod_name = st.modules.get(script_id) orelse {
        return .{ .ok = false, .error_message = "python script not found" };
    };
    const mod = c.py_getmodule(mod_name.ptr);
    if (mod == null) return .{ .ok = false, .error_message = "python script not found" };

    const fn_z = std.fmt.allocPrintSentinel(st.allocator, "{s}", .{fn_name}, 0) catch {
        return .{ .ok = false, .error_message = "out of memory" };
    };
    defer st.allocator.free(fn_z);

    const fn_ref = c.py_getdict(mod, c.py_name(fn_z.ptr));
    if (fn_ref == null) return .{ .ok = false, .error_message = "python function not found" };

    const arg_slot = c.py_pushtmp();
    defer c.py_pop();
    c.py_newstrv(arg_slot, .{ .data = arg.ptr, .size = @intCast(arg.len) });

    if (!c.py_call(fn_ref, 1, arg_slot)) {
        const err_msg = captureError(st);
        return .{ .ok = false, .error_message = err_msg };
    }
    return .{ .ok = true };
}

fn unloadPythonScript(raw: *anyopaque, script_id: u64) void {
    const st: *PythonRuntimeState = @ptrCast(@alignCast(raw));
    // PocketPy has no module-delete API; the module stays in this VM until the runtime is destroyed.
    if (st.modules.fetchRemove(script_id)) |kv| {
        st.allocator.free(kv.value);
    }
}

fn destroyPythonRuntime(raw: *anyopaque, allocator: std.mem.Allocator) void {
    const st: *PythonRuntimeState = @ptrCast(@alignCast(raw));
    var it = st.modules.valueIterator();
    while (it.next()) |name| st.allocator.free(name.*);
    st.modules.deinit(st.allocator);

    c.py_switchvm(st.vm_index);
    c.py_resetvm();
    releaseVmIndex(st.vm_index);
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
            .version = "0.2.0",
            .provides_capabilities = &.{"engine.script.runtime.python/1"},
            .required_capabilities = &.{"engine.script.host/1"},
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
