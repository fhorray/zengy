//! C ABI Compatibility & Dynamic Plugin Loader Tests (`src/core/tests/abi_tests.zig`).
//!
//! Validates Phase 3:
//! - Exact `sizeof`, `alignof`, and `offsetof` parity between `include/engine_extension.h`
//!   and `engine.abi` structs via `translate-c`.
//! - Dynamic loading, lifecycle execution, logging, service lookup, and unloading
//!   of the compiled C11 shared library (`zig-out/lib/libc_plugin.so`).
//! - Stale handle rejection (`AEStatus.invalid_handle`) and ABI major mismatch rejection.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const c_abi = @import("c_abi");

test "Phase 3: C ABI struct layout parity with include/engine_extension.h" {
    try testing.expectEqual(@as(usize, @sizeOf(c_abi.AEStringView)), @sizeOf(engine.abi.AEStringView));
    try testing.expectEqual(@as(usize, @alignOf(c_abi.AEStringView)), @alignOf(engine.abi.AEStringView));
    try testing.expectEqual(@as(usize, @sizeOf(c_abi.AEHostApi)), @sizeOf(engine.abi.AEHostApi));
    try testing.expectEqual(@as(usize, @offsetOf(c_abi.AEHostApi, "get_service")), @offsetOf(engine.abi.AEHostApi, "get_service"));
    try testing.expectEqual(@as(usize, @sizeOf(c_abi.AEPluginApi)), @sizeOf(engine.abi.AEPluginApi));
    try testing.expectEqual(@as(usize, @offsetOf(c_abi.AEPluginApi, "unload")), @offsetOf(engine.abi.AEPluginApi, "unload"));
}

test "Phase 3: Load real compiled C shared library plugin and validate ABI rejection" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    const host = try app.ensurePluginHost();

    // Load compiled C plugin. Windows installs DLLs to zig-out/bin; ELF shared objects go to zig-out/lib.
    const plugin_path = if (@import("builtin").os.tag == .windows)
        "zig-out/bin/c_plugin.dll"
    else
        "zig-out/lib/libc_plugin.so";
    const handle = try host.loadSharedLibrary(plugin_path);
    try testing.expectEqual(engine.abi.AEStatus.ok, host.startPlugin(handle));

    // Verify C plugin logged through AEHostApi.log into Diagnostics
    try testing.expect(app.diagnostics.count() >= 3);

    // Unload plugin and verify stale handle is rejected
    try testing.expectEqual(engine.abi.AEStatus.ok, host.unloadPlugin(handle));
    try testing.expectEqual(engine.abi.AEStatus.invalid_handle, host.startPlugin(handle));

    // Reject incompatible ABI major version
    const bad_api = engine.abi.AEPluginApi{
        .struct_size = @sizeOf(engine.abi.AEPluginApi),
        .abi_major = 99,
        .abi_minor = 0,
        .plugin_id = engine.abi.AEStringView.fromSlice("bad.major"),
        .load = null,
        .start = null,
        .stop = null,
        .unload = null,
    };
    try testing.expectError(error.UnsupportedAbi, host.loadFromApi(&bad_api, null));
}
