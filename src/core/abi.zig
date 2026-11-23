//! C ABI Extension Host & Dynamic Plugin Loader (`core/abi`).
//!
//! Implements the host side of `include/engine_extension.h` (`AEHostApi`, `AEPluginApi`).
//!
//! Safety & ABI Rules:
//! - Validates `struct_size` and `abi_major` before invoking any plugin callback.
//! - Tracks each loaded plugin with a generational `PluginHandle` and unique `owner_id`.
//! - On `unloadPlugin()`, revokes all `EventBus` subscriptions and `ServiceRegistry`
//!   entries owned by the plugin before calling `stop() -> unload()` and closing `DynLib`.
//! - Rejects stale handles deterministically with `AEStatus.invalid_handle`.

const std = @import("std");
const builtin = @import("builtin");
const diagnostics_mod = @import("diagnostics.zig");
const service_mod = @import("service_registry.zig");
const events_mod = @import("events.zig");

/// Cross-platform dynamic library loader supporting Windows (kernel32) and POSIX (std.DynLib).
pub const NativeLib = if (builtin.os.tag == .windows) struct {
    handle: std.os.windows.HMODULE,

    extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) callconv(.winapi) ?std.os.windows.HMODULE;
    extern "kernel32" fn GetProcAddress(hModule: std.os.windows.HMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn FreeLibrary(hLibModule: std.os.windows.HMODULE) callconv(.winapi) std.os.windows.BOOL;

    pub fn open(path: []const u8) !NativeLib {
        var buf: [4096]u8 = undefined;
        if (path.len >= buf.len) return error.NameTooLong;
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;
        const h = LoadLibraryA(@ptrCast(buf[0..path.len :0])) orelse return error.FileNotFound;
        return .{ .handle = h };
    }

    pub fn lookup(self: *NativeLib, comptime T: type, name: [:0]const u8) ?T {
        const sym = GetProcAddress(self.handle, name.ptr) orelse return null;
        return @ptrCast(@alignCast(sym));
    }

    pub fn close(self: *NativeLib) void {
        _ = FreeLibrary(self.handle);
    }
} else std.DynLib;

pub const ABI_MAJOR: u32 = 1;
pub const ABI_MINOR: u32 = 0;

pub const AEHandle = u64;

pub const AEStatus = enum(i32) {
    ok = 0,
    err = 1,
    unsupported_abi = 2,
    missing_service = 3,
    invalid_handle = 4,
    permission_denied = 5,
    busy = 6,
};

pub const AEStringView = extern struct {
    data: ?[*]const u8,
    length: usize,

    pub fn fromSlice(s: []const u8) AEStringView {
        return .{ .data = s.ptr, .length = s.len };
    }

    pub fn toSlice(self: AEStringView) []const u8 {
        if (self.data) |ptr| {
            return ptr[0..self.length];
        }
        return "";
    }
};

pub const AEHostApi = extern struct {
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

pub const AEPluginApi = extern struct {
    struct_size: u32,
    abi_major: u32,
    abi_minor: u32,
    plugin_id: AEStringView,
    load: ?*const fn (host: *const AEHostApi, out_state: *?*anyopaque) callconv(.c) i32,
    start: ?*const fn (state: ?*anyopaque) callconv(.c) i32,
    stop: ?*const fn (state: ?*anyopaque) callconv(.c) void,
    unload: ?*const fn (state: ?*anyopaque) callconv(.c) void,
};

pub const AEPluginEntryFn = *const fn () callconv(.c) ?*const AEPluginApi;

pub const PluginHandle = packed struct(u64) {
    index: u32,
    generation: u32,
};

pub const LoadedPlugin = struct {
    plugin_id: []const u8,
    owner_id: u64,
    generation: u32,
    lib: ?NativeLib,
    api: *const AEPluginApi,
    state: ?*anyopaque,
    started: bool,
    active: bool,
};

pub const HostContext = struct {
    diagnostics: *diagnostics_mod.Diagnostics,
    services: *service_mod.ServiceRegistry,
    events: *events_mod.EventBus,
};

pub const PluginHost = struct {
    allocator: std.mem.Allocator,
    host_ctx: HostContext,
    host_api: AEHostApi,
    plugins: std.ArrayList(LoadedPlugin),
    next_owner_id: u64,

    pub fn init(
        allocator: std.mem.Allocator,
        diagnostics: *diagnostics_mod.Diagnostics,
        services: *service_mod.ServiceRegistry,
        events: *events_mod.EventBus,
    ) !*PluginHost {
        const self = try allocator.create(PluginHost);
        self.* = .{
            .allocator = allocator,
            .host_ctx = .{
                .diagnostics = diagnostics,
                .services = services,
                .events = events,
            },
            .host_api = undefined,
            .plugins = .empty,
            .next_owner_id = 1000,
        };
        self.host_api = .{
            .struct_size = @sizeOf(AEHostApi),
            .abi_major = ABI_MAJOR,
            .abi_minor = ABI_MINOR,
            .host_context = self,
            .log = hostLogCallback,
            .get_service = hostGetServiceCallback,
        };
        return self;
    }

    pub fn deinit(self: *PluginHost) void {
        var i = self.plugins.items.len;
        while (i > 0) {
            i -= 1;
            if (self.plugins.items[i].active) {
                const handle = PluginHandle{
                    .index = @intCast(i),
                    .generation = self.plugins.items[i].generation,
                };
                _ = self.unloadPlugin(handle);
            }
            if (self.plugins.items[i].plugin_id.len > 0) {
                self.allocator.free(self.plugins.items[i].plugin_id);
            }
        }
        self.plugins.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn hostLogCallback(raw_ctx: ?*anyopaque, level_raw: u32, message: AEStringView) callconv(.c) void {
        const self: *PluginHost = @ptrCast(@alignCast(raw_ctx orelse return));
        const level: diagnostics_mod.LogLevel = switch (level_raw) {
            0 => .debug,
            1 => .info,
            2 => .warn,
            else => .err,
        };
        self.host_ctx.diagnostics.log(level, "c_plugin", message.toSlice()) catch {};
    }

    fn hostGetServiceCallback(
        raw_ctx: ?*anyopaque,
        service_id: AEStringView,
        requested_major: u32,
        out_service_api: *?*const anyopaque,
        out_api_size: *u32,
    ) callconv(.c) i32 {
        const self: *PluginHost = @ptrCast(@alignCast(raw_ctx orelse return @intFromEnum(AEStatus.err)));
        const entry = self.host_ctx.services.getService(service_id.toSlice(), requested_major) catch {
            return @intFromEnum(AEStatus.missing_service);
        };
        out_service_api.* = entry.api_ptr;
        out_api_size.* = entry.api_size;
        return @intFromEnum(AEStatus.ok);
    }

    pub fn validatePluginApi(api: *const AEPluginApi) AEStatus {
        // Check prefix size before dereferencing full struct
        if (api.struct_size < @sizeOf(AEPluginApi)) return .unsupported_abi;
        if (api.abi_major != ABI_MAJOR) return .unsupported_abi;
        if (api.load == null or api.start == null or api.stop == null or api.unload == null) {
            return .unsupported_abi;
        }
        return .ok;
    }

    /// Opens a shared library plugin and resolves `ae_plugin_entry`.
    /// Note: On POSIX/Linux, host binaries loading `libc`-linked C plugins must be
    /// built with `.link_libc = true` so `dlopen` performs full dynamic relocations.
    pub fn loadSharedLibrary(self: *PluginHost, path: []const u8) !PluginHandle {
        var lib = try NativeLib.open(path);
        errdefer lib.close();

        const entry_fn = lib.lookup(AEPluginEntryFn, "ae_plugin_entry") orelse return error.MissingEntrySymbol;
        const api = entry_fn() orelse return error.InvalidPluginApi;
        return self.loadFromApi(api, lib);
    }

    pub fn loadFromApi(self: *PluginHost, api: *const AEPluginApi, lib: ?NativeLib) !PluginHandle {
        const status = validatePluginApi(api);
        if (status != .ok) return error.UnsupportedAbi;

        var state: ?*anyopaque = null;
        const load_rc = api.load.?(&self.host_api, &state);
        if (load_rc != @intFromEnum(AEStatus.ok)) {
            return error.PluginLoadFailed;
        }

        const owner_id = self.next_owner_id;
        self.next_owner_id += 1;

        const id_copy = try self.allocator.dupe(u8, api.plugin_id.toSlice());
        errdefer self.allocator.free(id_copy);

        const idx: u32 = @intCast(self.plugins.items.len);
        try self.plugins.append(self.allocator, .{
            .plugin_id = id_copy,
            .owner_id = owner_id,
            .generation = 1,
            .lib = lib,
            .api = api,
            .state = state,
            .started = false,
            .active = true,
        });

        return .{ .index = idx, .generation = 1 };
    }

    pub fn startPlugin(self: *PluginHost, handle: PluginHandle) AEStatus {
        const plugin = self.getPluginMut(handle) orelse return .invalid_handle;
        const rc = plugin.api.start.?(plugin.state);
        if (rc != @intFromEnum(AEStatus.ok)) return @enumFromInt(rc);
        plugin.started = true;
        return .ok;
    }

    pub fn unloadPlugin(self: *PluginHost, handle: PluginHandle) AEStatus {
        const plugin = self.getPluginMut(handle) orelse return .invalid_handle;

        // Quiesce: revoke event subscriptions and services owned by this plugin first.
        _ = self.host_ctx.events.unsubscribeByOwner(plugin.owner_id);
        _ = self.host_ctx.services.unregisterByOwner(plugin.owner_id);

        if (plugin.started) {
            plugin.api.stop.?(plugin.state);
            plugin.started = false;
        }
        plugin.api.unload.?(plugin.state);
        plugin.state = null;
        plugin.active = false;
        plugin.generation +%= 1;

        if (plugin.lib) |*dynlib| {
            dynlib.close();
            plugin.lib = null;
        }
        return .ok;
    }

    pub fn getPluginMut(self: *PluginHost, handle: PluginHandle) ?*LoadedPlugin {
        if (handle.index >= self.plugins.items.len) return null;
        const plugin = &self.plugins.items[handle.index];
        if (!plugin.active or plugin.generation != handle.generation) return null;
        return plugin;
    }
};
