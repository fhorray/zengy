//! C ABI Dynamic Plugin Entrypoint (`ae_plugin_entry`) for `official.physics.rapier`.
//!
//! Allows `zigeng-runtime` (or any host implementing `include/engine_extension.h`)
//! to load `zigeng_physics_rapier.{dll,so,dylib}` dynamically and attach `RapierBackend`
//! to the host's `engine.physics.backend/1` C-ABI slot.

const std = @import("std");
const engine = @import("engine");
const physics = @import("physics");
const physics_rapier = @import("physics_rapier");

const AEStatus = i32;
const AE_OK: AEStatus = 0;
const AE_ERROR: AEStatus = 1;
const AE_UNSUPPORTED_ABI: AEStatus = 2;
const AE_MISSING_SERVICE: AEStatus = 3;

const AEStringView = extern struct {
    data: ?[*]const u8,
    length: usize,

    fn fromSlice(s: []const u8) AEStringView {
        return .{ .data = s.ptr, .length = s.len };
    }
};

const AEHostApi = extern struct {
    struct_size: u32,
    abi_major: u32,
    abi_minor: u32,
    host_context: ?*anyopaque,
    log: ?*const fn (host_context: ?*anyopaque, level: u32, message: AEStringView) callconv(.c) void,
    get_service: ?*const fn (
        host_context: ?*anyopaque,
        service_id: AEStringView,
        requested_major: u32,
        out_service_api: *?*const anyopaque,
        out_api_size: *u32,
    ) callconv(.c) i32,
};

const AEPluginApi = extern struct {
    struct_size: u32,
    abi_major: u32,
    abi_minor: u32,
    plugin_id: AEStringView,
    load: ?*const fn (host: *const AEHostApi, out_state: *?*anyopaque) callconv(.c) i32,
    start: ?*const fn (state: ?*anyopaque) callconv(.c) i32,
    stop: ?*const fn (state: ?*anyopaque) callconv(.c) void,
    unload: ?*const fn (state: ?*anyopaque) callconv(.c) void,
};

const PluginState = struct {
    backend: physics_rapier.RapierBackend,
    slot: *physics.cabi.Slot,
};

fn pluginLoad(host: *const AEHostApi, out_state: *?*anyopaque) callconv(.c) i32 {
    if (host.abi_major != 1) return AE_UNSUPPORTED_ABI;
    const get_svc = host.get_service orelse return AE_MISSING_SERVICE;

    var svc_ptr: ?*const anyopaque = null;
    var svc_size: u32 = 0;
    const rc = get_svc(
        host.host_context,
        AEStringView.fromSlice(physics.cabi.CAPABILITY),
        1,
        &svc_ptr,
        &svc_size,
    );
    if (rc != AE_OK or svc_ptr == null or svc_size != @sizeOf(physics.cabi.Slot)) {
        return AE_MISSING_SERVICE;
    }

    // Only plain `extern` types cross the plugin boundary (see physics `cabi.zig`); verify the host speaks our ABI.
    const slot: *physics.cabi.Slot = @ptrCast(@alignCast(@constCast(svc_ptr.?)));
    if (!physics.cabi.slotIsCompatible(slot)) return AE_UNSUPPORTED_ABI;

    const st = std.heap.c_allocator.create(PluginState) catch return AE_ERROR;
    st.backend = physics_rapier.RapierBackend.init() catch {
        std.heap.c_allocator.destroy(st);
        return AE_ERROR;
    };
    st.slot = slot;
    slot.ctx = &st.backend;
    slot.vtable = physics.cabi.vtableFor(physics_rapier.RapierBackend);

    if (host.log) |log_fn| {
        log_fn(host.host_context, 1, AEStringView.fromSlice("official.physics.rapier attached to engine.physics/1"));
    }

    out_state.* = st;
    return AE_OK;
}

fn pluginStart(_: ?*anyopaque) callconv(.c) i32 {
    return AE_OK;
}

fn pluginStop(_: ?*anyopaque) callconv(.c) void {}

fn pluginUnload(raw_state: ?*anyopaque) callconv(.c) void {
    const st: *PluginState = @ptrCast(@alignCast(raw_state orelse return));
    st.slot.vtable = null;
    st.slot.ctx = null;
    st.backend.deinit();
    std.heap.c_allocator.destroy(st);
}

const g_plugin_api = AEPluginApi{
    .struct_size = @sizeOf(AEPluginApi),
    .abi_major = 1,
    .abi_minor = 0,
    .plugin_id = AEStringView.fromSlice("official.physics.rapier"),
    .load = pluginLoad,
    .start = pluginStart,
    .stop = pluginStop,
    .unload = pluginUnload,
};

export fn ae_plugin_entry() callconv(.c) *const AEPluginApi {
    return &g_plugin_api;
}
