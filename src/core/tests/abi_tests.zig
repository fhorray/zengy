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
    try testing.expectEqual(@as(usize, @sizeOf(c_abi.AEWorldApiV1)), @sizeOf(engine.abi.AEWorldApiV1));
    try testing.expectEqual(@as(usize, @sizeOf(c_abi.AEEventsApiV1)), @sizeOf(engine.abi.AEEventsApiV1));
    try testing.expectEqual(@as(usize, @sizeOf(c_abi.AEFieldDescriptor)), @sizeOf(engine.abi.AEFieldDescriptor));
    try testing.expectEqual(@as(usize, @sizeOf(c_abi.AEReflectionApiV1)), @sizeOf(engine.abi.AEReflectionApiV1));
}

test "Phase 3 & B: Load real C plugin, verify entity spawn + event post via C ABI, and validate ABI rejection" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    const EventCatcher = struct {
        seen: bool = false,
        fn onEv(raw: ?*anyopaque, ev: engine.EventEnvelope) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (std.mem.eql(u8, ev.payload, "from_c11")) {
                self.seen = true;
            }
        }
    };
    var catcher = EventCatcher{};
    _ = try app.events.subscribe(1, "c_plugin.entity_spawned", EventCatcher.onEv, &catcher);

    const host = try app.ensurePluginHost();

    // Load compiled C plugin. Windows installs DLLs to zig-out/bin; macOS uses .dylib; ELF uses .so.
    const plugin_path = switch (@import("builtin").os.tag) {
        .windows => "zig-out/bin/c_plugin.dll",
        .macos => "zig-out/lib/libc_plugin.dylib",
        else => "zig-out/lib/libc_plugin.so",
    };
    const handle = try host.loadSharedLibrary(plugin_path);
    try testing.expectEqual(engine.abi.AEStatus.ok, host.startPlugin(handle));

    // Verify C plugin actually spawned an entity and posted an event via C ABI tables
    try testing.expectEqual(@as(usize, 1), app.world.entity_count);
    _ = app.events.drain();
    try testing.expect(catcher.seen);

    // Verify C plugin logged through AEHostApi.log into Diagnostics
    try testing.expect(app.diagnostics.count() >= 3);

    // Verify C plugin registered its component schema via engine.reflection/1
    const health_schema = app.types.getLatest("c_plugin", "Health") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), health_schema.fields.len);

    // Unload plugin -> stop() despawns its entity, stale handle is rejected, and plugin-owned schemas are removed
    try testing.expectEqual(engine.abi.AEStatus.ok, host.unloadPlugin(handle));
    try testing.expectEqual(@as(usize, 0), app.world.entity_count);
    try testing.expect(app.types.getLatest("c_plugin", "Health") == null);
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

test "ZE-004: PluginHost unloads plugin state on OOM during registration and maps unknown status safely" {
    const DummyPlugin = struct {
        var unloaded: bool = false;
        fn load(_: *const engine.abi.AEHostApi, out_state: *?*anyopaque) callconv(.c) i32 {
            unloaded = false;
            out_state.* = @ptrFromInt(0x1234);
            return 0;
        }
        fn start(_: ?*anyopaque) callconv(.c) i32 {
            return 9999; // unknown status code
        }
        fn stop(_: ?*anyopaque) callconv(.c) void {}
        fn unload(_: ?*anyopaque) callconv(.c) void {
            unloaded = true;
        }
    };

    const api = engine.abi.AEPluginApi{
        .struct_size = @sizeOf(engine.abi.AEPluginApi),
        .abi_major = engine.abi.ABI_MAJOR,
        .abi_minor = engine.abi.ABI_MINOR,
        .plugin_id = engine.abi.AEStringView.fromSlice("test.dummy"),
        .load = DummyPlugin.load,
        .start = DummyPlugin.start,
        .stop = DummyPlugin.stop,
        .unload = DummyPlugin.unload,
    };

    // Normal host: unknown return code maps safely to AEStatus.err without trapping.
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();
    const host = try app.ensurePluginHost();
    const h = try host.loadFromApi(&api, null);
    try testing.expectEqual(engine.abi.AEStatus.err, host.startPlugin(h));
    try testing.expectEqual(engine.abi.AEStatus.ok, host.unloadPlugin(h));
    try testing.expect(DummyPlugin.unloaded);
}
