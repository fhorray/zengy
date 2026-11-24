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
const world_mod = @import("world.zig");
const reflection_mod = @import("reflection.zig");

/// Cross-platform dynamic library loader supporting Windows (kernel32) and POSIX (std.DynLib).
pub const NativeLib = if (builtin.os.tag == .windows) struct {
    handle: std.os.windows.HMODULE,

    extern "kernel32" fn LoadLibraryW(lpLibFileName: [*:0]const u16) callconv(.winapi) ?std.os.windows.HMODULE;
    extern "kernel32" fn GetProcAddress(hModule: std.os.windows.HMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn FreeLibrary(hLibModule: std.os.windows.HMODULE) callconv(.winapi) std.os.windows.BOOL;

    pub fn open(path: []const u8) !NativeLib {
        var buf: [4096]u16 = undefined;
        const len = std.unicode.utf8ToUtf16Le(&buf, path) catch return error.InvalidUtf8;
        if (len >= buf.len) return error.NameTooLong;
        buf[len] = 0;
        const h = LoadLibraryW(@ptrCast(buf[0..len :0])) orelse return error.FileNotFound;
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

pub const AEWorldApiV1 = extern struct {
    struct_size: u32,
    abi_major: u32,
    world_context: ?*anyopaque,
    spawn: ?*const fn (world_context: ?*anyopaque, out_entity: *AEHandle) callconv(.c) i32,
    despawn: ?*const fn (world_context: ?*anyopaque, entity: AEHandle) callconv(.c) i32,
    is_alive: ?*const fn (world_context: ?*anyopaque, entity: AEHandle) callconv(.c) u32,
    entity_count: ?*const fn (world_context: ?*anyopaque) callconv(.c) usize,
};

pub const AEEventsApiV1 = extern struct {
    struct_size: u32,
    abi_major: u32,
    events_context: ?*anyopaque,
    post: ?*const fn (events_context: ?*anyopaque, name: AEStringView, payload: AEStringView, entity: AEHandle) callconv(.c) i32,
};

pub const AEFieldDescriptor = extern struct {
    name: AEStringView,
    field_type: u32,
};

pub const AEReflectionApiV1 = extern struct {
    struct_size: u32,
    abi_major: u32,
    reflection_context: ?*anyopaque,
    register_component_schema: ?*const fn (
        reflection_context: ?*anyopaque,
        owner_plugin_id: AEStringView,
        namespace_name: AEStringView,
        type_name: AEStringView,
        version: u32,
        storage_policy: u32,
        fields: ?[*]const AEFieldDescriptor,
        field_count: usize,
        out_schema_id: ?*u64,
    ) callconv(.c) i32,
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
    world: *world_mod.World,
    diagnostics: *diagnostics_mod.Diagnostics,
    services: *service_mod.ServiceRegistry,
    events: *events_mod.EventBus,
    reflection: *reflection_mod.TypeRegistry,
};

pub const PluginHost = struct {
    allocator: std.mem.Allocator,
    host_ctx: HostContext,
    host_api: AEHostApi,
    world_api: AEWorldApiV1,
    events_api: AEEventsApiV1,
    reflection_api: AEReflectionApiV1,
    plugins: std.ArrayList(LoadedPlugin),
    next_owner_id: u64,

    pub fn init(
        allocator: std.mem.Allocator,
        world: *world_mod.World,
        diagnostics: *diagnostics_mod.Diagnostics,
        services: *service_mod.ServiceRegistry,
        events: *events_mod.EventBus,
        reflection: *reflection_mod.TypeRegistry,
    ) !*PluginHost {
        const self = try allocator.create(PluginHost);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .host_ctx = .{
                .world = world,
                .diagnostics = diagnostics,
                .services = services,
                .events = events,
                .reflection = reflection,
            },
            .host_api = undefined,
            .world_api = undefined,
            .events_api = undefined,
            .reflection_api = undefined,
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
        self.world_api = .{
            .struct_size = @sizeOf(AEWorldApiV1),
            .abi_major = ABI_MAJOR,
            .world_context = world,
            .spawn = cWorldSpawn,
            .despawn = cWorldDespawn,
            .is_alive = cWorldIsAlive,
            .entity_count = cWorldEntityCount,
        };
        self.events_api = .{
            .struct_size = @sizeOf(AEEventsApiV1),
            .abi_major = ABI_MAJOR,
            .events_context = events,
            .post = cEventsPost,
        };
        self.reflection_api = .{
            .struct_size = @sizeOf(AEReflectionApiV1),
            .abi_major = ABI_MAJOR,
            .reflection_context = self,
            .register_component_schema = cRegisterComponentSchema,
        };

        try services.register(.{
            .capability = "engine.world",
            .major_version = 1,
            .provider_id = "core.world.c_abi_v1",
            .owner_id = 1,
            .exclusive = true,
            .api_ptr = &self.world_api,
            .api_size = @sizeOf(AEWorldApiV1),
        });
        errdefer _ = services.unregisterByOwner(1);

        try services.register(.{
            .capability = "engine.events",
            .major_version = 1,
            .provider_id = "core.events.c_abi_v1",
            .owner_id = 1,
            .exclusive = true,
            .api_ptr = &self.events_api,
            .api_size = @sizeOf(AEEventsApiV1),
        });

        try services.register(.{
            .capability = "engine.reflection",
            .major_version = 1,
            .provider_id = "core.reflection.c_abi_v1",
            .owner_id = 1,
            .exclusive = true,
            .api_ptr = &self.reflection_api,
            .api_size = @sizeOf(AEReflectionApiV1),
        });

        return self;
    }

    fn cWorldSpawn(raw_world: ?*anyopaque, out_entity: *AEHandle) callconv(.c) i32 {
        const w: *world_mod.World = @ptrCast(@alignCast(raw_world orelse return @intFromEnum(AEStatus.err)));
        const e = w.spawn() catch return @intFromEnum(AEStatus.err);
        out_entity.* = e.toU64();
        return @intFromEnum(AEStatus.ok);
    }

    fn cWorldDespawn(raw_world: ?*anyopaque, entity: AEHandle) callconv(.c) i32 {
        const w: *world_mod.World = @ptrCast(@alignCast(raw_world orelse return @intFromEnum(AEStatus.err)));
        const ok = w.despawn(world_mod.EntityHandle.fromU64(entity)) catch return @intFromEnum(AEStatus.err);
        return if (ok) @intFromEnum(AEStatus.ok) else @intFromEnum(AEStatus.invalid_handle);
    }

    fn cWorldIsAlive(raw_world: ?*anyopaque, entity: AEHandle) callconv(.c) u32 {
        const w: *world_mod.World = @ptrCast(@alignCast(raw_world orelse return 0));
        return if (w.isAlive(world_mod.EntityHandle.fromU64(entity))) 1 else 0;
    }

    fn cWorldEntityCount(raw_world: ?*anyopaque) callconv(.c) usize {
        const w: *world_mod.World = @ptrCast(@alignCast(raw_world orelse return 0));
        return w.entity_count;
    }

    fn cEventsPost(raw_events: ?*anyopaque, name: AEStringView, payload: AEStringView, entity: AEHandle) callconv(.c) i32 {
        const bus: *events_mod.EventBus = @ptrCast(@alignCast(raw_events orelse return @intFromEnum(AEStatus.err)));
        bus.post(.{
            .name = name.toSlice(),
            .payload = payload.toSlice(),
            .entity_handle = entity,
        }) catch return @intFromEnum(AEStatus.err);
        return @intFromEnum(AEStatus.ok);
    }

    fn fieldTypeFromC(raw: u32) ?reflection_mod.FieldType {
        return switch (raw) {
            0 => .bool_t,
            1 => .i32_t,
            2 => .i64_t,
            3 => .u32_t,
            4 => .u64_t,
            5 => .f32_t,
            6 => .f64_t,
            7 => .vec2_t,
            8 => .vec3_t,
            9 => .vec4_t,
            10 => .enum_u32_t,
            11 => .entity_ref_t,
            12 => .asset_ref_t,
            13 => .fixed_str64_t,
            else => null,
        };
    }

    fn storagePolicyFromC(raw: u32) ?reflection_mod.StoragePolicy {
        return switch (raw) {
            0 => .blittable,
            1 => .managed_handle,
            2 => .blob,
            else => null,
        };
    }

    fn cRegisterComponentSchema(
        raw_ctx: ?*anyopaque,
        owner_plugin_id: AEStringView,
        namespace_name: AEStringView,
        type_name: AEStringView,
        version: u32,
        storage_policy: u32,
        fields: ?[*]const AEFieldDescriptor,
        field_count: usize,
        out_schema_id: ?*u64,
    ) callconv(.c) i32 {
        const self: *PluginHost = @ptrCast(@alignCast(raw_ctx orelse return @intFromEnum(AEStatus.err)));
        const pid_slice = owner_plugin_id.toSlice();
        var owner_id: ?u64 = null;
        for (self.plugins.items) |p| {
            if (p.active and std.mem.eql(u8, p.plugin_id, pid_slice)) {
                owner_id = p.owner_id;
                break;
            }
        }
        const resolved_owner = owner_id orelse return @intFromEnum(AEStatus.invalid_handle);
        const storage = storagePolicyFromC(storage_policy) orelse return @intFromEnum(AEStatus.err);
        if (field_count > 0 and fields == null) return @intFromEnum(AEStatus.err);

        const ns_slice = namespace_name.toSlice();
        const name_slice = type_name.toSlice();
        if (ns_slice.len == 0 or name_slice.len == 0) return @intFromEnum(AEStatus.err);

        const zig_fields = self.allocator.alloc(reflection_mod.FieldDescriptor, field_count) catch {
            return @intFromEnum(AEStatus.err);
        };
        defer self.allocator.free(zig_fields);

        if (field_count > 0) {
            const c_fields = fields.?[0..field_count];
            for (c_fields, 0..) |cf, i| {
                const ft = fieldTypeFromC(cf.field_type) orelse return @intFromEnum(AEStatus.err);
                zig_fields[i] = .{
                    .name = cf.name.toSlice(),
                    .field_type = ft,
                };
            }
        }

        const schema = self.host_ctx.reflection.registerSchemaWithOwner(
            resolved_owner,
            ns_slice,
            name_slice,
            version,
            storage,
            zig_fields,
        ) catch return @intFromEnum(AEStatus.err);

        if (out_schema_id) |out_ptr| out_ptr.* = schema.schema_id;
        return @intFromEnum(AEStatus.ok);
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
        _ = self.host_ctx.services.unregisterByOwner(1);
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

    pub fn statusFromInt(rc: i32) AEStatus {
        return switch (rc) {
            0 => .ok,
            1 => .err,
            2 => .unsupported_abi,
            3 => .missing_service,
            4 => .invalid_handle,
            5 => .permission_denied,
            6 => .busy,
            else => .err,
        };
    }

    pub fn loadFromApi(self: *PluginHost, api: *const AEPluginApi, lib: ?NativeLib) !PluginHandle {
        const status = validatePluginApi(api);
        if (status != .ok) return error.UnsupportedAbi;

        var state: ?*anyopaque = null;
        const load_rc = api.load.?(&self.host_api, &state);
        if (load_rc != @intFromEnum(AEStatus.ok)) {
            return error.PluginLoadFailed;
        }
        errdefer api.unload.?(state);

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
        if (plugin.started) return .ok;
        const rc = plugin.api.start.?(plugin.state);
        const st = statusFromInt(rc);
        if (st != .ok) return st;
        plugin.started = true;
        return .ok;
    }

    pub fn unloadPlugin(self: *PluginHost, handle: PluginHandle) AEStatus {
        const plugin = self.getPluginMut(handle) orelse return .invalid_handle;

        // Quiesce: revoke event subscriptions, services, and reflection schemas owned by this plugin first.
        _ = self.host_ctx.events.unsubscribeByOwner(plugin.owner_id);
        _ = self.host_ctx.services.unregisterByOwner(plugin.owner_id);
        _ = self.host_ctx.reflection.unregisterByOwner(plugin.owner_id);

        if (plugin.started) {
            plugin.api.stop.?(plugin.state);
            plugin.started = false;
        }
        plugin.api.unload.?(plugin.state);
        plugin.state = null;
        plugin.active = false;
        plugin.generation +%= 1;

        if (plugin.plugin_id.len > 0) {
            self.allocator.free(plugin.plugin_id);
            plugin.plugin_id = &.{};
        }

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
