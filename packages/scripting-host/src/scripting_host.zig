//! Optional Scripting Host Protocol (`official.script.host`).
//!
//! Provides `ScriptingHost` (`engine.script.host/1`), allowing multiple independent
//! scripting language runtimes (e.g., Lua, Python, QuickJS) to coexist without
//! introducing any language-specific branches into `src/core/`.
//!
//! Safety & Ownership:
//! - Scripts interact with the engine through `ScriptEngineBridge` using opaque handles.
//! - `ScriptModuleHandle` includes a runtime/module generation that is invalidated on unload.
//! - Destroying a runtime automatically revokes all `EventBus` subscriptions it owns.

const std = @import("std");
const engine = @import("engine");

pub const MODULE_OWNER_ID: u64 = 2005;

pub const RuntimeDescriptor = struct {
    language_id: []const u8,
    language_version: []const u8,
    api_version: u32 = 1,
    supports_hot_reload: bool = true,
    thread_affinity: engine.scheduler.ThreadAffinity = .main,
};

pub const ScriptModuleHandle = packed struct(u64) {
    runtime_idx: u16,
    module_idx: u16,
    generation: u32,
};

pub const ScriptResult = struct {
    ok: bool,
    error_message: []const u8 = "",
};

/// Handle-based bridge exposed to scripting runtimes without leaking raw ECS pointers.
pub const ScriptEngineBridge = struct {
    app: *engine.App,
    owner_id: u64,

    pub fn spawnEntity(self: *ScriptEngineBridge) !u64 {
        const e = try self.app.world.spawn();
        return e.toU64();
    }

    pub fn isEntityAlive(self: *const ScriptEngineBridge, raw_handle: u64) bool {
        return self.app.world.isAlive(engine.EntityHandle.fromU64(raw_handle));
    }

    pub fn postEvent(self: *ScriptEngineBridge, name: []const u8, payload: []const u8, entity_handle: u64) !void {
        try self.app.commands.emit(.{
            .name = name,
            .payload = payload,
            .entity_handle = entity_handle,
        });
    }

    pub fn subscribeEvent(
        self: *ScriptEngineBridge,
        name: []const u8,
        cb: engine.events.EventCallback,
        user_data: ?*anyopaque,
    ) !engine.events.SubscriptionId {
        return self.app.events.subscribe(self.owner_id, name, cb, user_data);
    }

    pub fn log(self: *ScriptEngineBridge, level: engine.LogLevel, msg: []const u8) !void {
        try self.app.diagnostics.log(level, "script", msg);
    }
};

pub const RuntimeProviderVTable = struct {
    create: *const fn (allocator: std.mem.Allocator, bridge: *ScriptEngineBridge) anyerror!*anyopaque,
    load: *const fn (runtime_state: *anyopaque, source_name: []const u8, source: []const u8) anyerror!u64,
    invoke: *const fn (runtime_state: *anyopaque, script_id: u64, fn_name: []const u8, arg: []const u8) ScriptResult,
    unload: *const fn (runtime_state: *anyopaque, script_id: u64) void,
    destroy: *const fn (runtime_state: *anyopaque, allocator: std.mem.Allocator) void,
};

const RegisteredRuntime = struct {
    descriptor: RuntimeDescriptor,
    vtable: RuntimeProviderVTable,
    state: *anyopaque,
    bridge: *ScriptEngineBridge,
    generation: u32,
    active: bool,
};

const LoadedScript = struct {
    runtime_idx: u16,
    internal_id: u64,
    generation: u32,
    active: bool,
};

pub const ScriptingHost = struct {
    allocator: std.mem.Allocator,
    app: *engine.App,
    runtimes: std.ArrayList(RegisteredRuntime),
    scripts: std.ArrayList(LoadedScript),
    next_owner_id: u64,

    pub fn init(allocator: std.mem.Allocator, app: *engine.App) ScriptingHost {
        return .{
            .allocator = allocator,
            .app = app,
            .runtimes = .empty,
            .scripts = .empty,
            .next_owner_id = 5000,
        };
    }

    pub fn deinit(self: *ScriptingHost) void {
        for (self.runtimes.items, 0..) |*rt, idx| {
            if (rt.active) {
                self.destroyRuntime(@intCast(idx));
            }
        }
        self.runtimes.deinit(self.allocator);
        self.scripts.deinit(self.allocator);
    }

    pub fn registerRuntime(
        self: *ScriptingHost,
        descriptor: RuntimeDescriptor,
        vtable: RuntimeProviderVTable,
    ) !u16 {
        const owner_id = self.next_owner_id;
        self.next_owner_id += 1;

        const bridge = try self.allocator.create(ScriptEngineBridge);
        errdefer self.allocator.destroy(bridge);
        bridge.* = .{ .app = self.app, .owner_id = owner_id };

        const state = try vtable.create(self.allocator, bridge);
        errdefer vtable.destroy(state, self.allocator);

        const idx: u16 = @intCast(self.runtimes.items.len);
        try self.runtimes.append(self.allocator, .{
            .descriptor = descriptor,
            .vtable = vtable,
            .state = state,
            .bridge = bridge,
            .generation = 1,
            .active = true,
        });
        return idx;
    }

    pub fn loadScript(self: *ScriptingHost, runtime_idx: u16, source_name: []const u8, source: []const u8) !ScriptModuleHandle {
        if (runtime_idx >= self.runtimes.items.len or !self.runtimes.items[runtime_idx].active) {
            return error.InvalidRuntime;
        }
        const rt = &self.runtimes.items[runtime_idx];
        const internal_id = try rt.vtable.load(rt.state, source_name, source);
        errdefer rt.vtable.unload(rt.state, internal_id);

        const mod_idx: u16 = @intCast(self.scripts.items.len);
        try self.scripts.append(self.allocator, .{
            .runtime_idx = runtime_idx,
            .internal_id = internal_id,
            .generation = rt.generation,
            .active = true,
        });
        return .{
            .runtime_idx = runtime_idx,
            .module_idx = mod_idx,
            .generation = rt.generation,
        };
    }

    pub fn invokeScript(self: *ScriptingHost, handle: ScriptModuleHandle, fn_name: []const u8, arg: []const u8) ScriptResult {
        if (handle.module_idx >= self.scripts.items.len) {
            return .{ .ok = false, .error_message = "invalid script module handle" };
        }
        const script = &self.scripts.items[handle.module_idx];
        if (!script.active or script.generation != handle.generation) {
            return .{ .ok = false, .error_message = "stale script module handle" };
        }
        const rt = &self.runtimes.items[script.runtime_idx];
        if (!rt.active or rt.generation != handle.generation) {
            return .{ .ok = false, .error_message = "runtime destroyed" };
        }
        return rt.vtable.invoke(rt.state, script.internal_id, fn_name, arg);
    }

    pub fn unloadScript(self: *ScriptingHost, handle: ScriptModuleHandle) bool {
        if (handle.module_idx >= self.scripts.items.len) return false;
        const script = &self.scripts.items[handle.module_idx];
        if (!script.active or script.generation != handle.generation) return false;

        const rt = &self.runtimes.items[script.runtime_idx];
        if (rt.active) {
            rt.vtable.unload(rt.state, script.internal_id);
        }
        script.active = false;
        script.generation +%= 1;
        return true;
    }

    pub fn destroyRuntime(self: *ScriptingHost, runtime_idx: u16) void {
        if (runtime_idx >= self.runtimes.items.len) return;
        const rt = &self.runtimes.items[runtime_idx];
        if (!rt.active) return;

        // Cancel all subscriptions owned by this runtime
        _ = self.app.events.unsubscribeByOwner(rt.bridge.owner_id);

        for (self.scripts.items) |*s| {
            if (s.active and s.runtime_idx == runtime_idx) {
                rt.vtable.unload(rt.state, s.internal_id);
                s.active = false;
                s.generation +%= 1;
            }
        }

        rt.vtable.destroy(rt.state, self.allocator);
        self.allocator.destroy(rt.bridge);
        rt.active = false;
        rt.generation +%= 1;
    }
};

fn buildModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    try app.resources.insert(ScriptingHost, ScriptingHost.init(app.allocator, app));
    const host = app.resources.get(ScriptingHost).?;

    try app.services.register(.{
        .capability = "engine.script.host",
        .major_version = 1,
        .provider_id = "official.script.host",
        .owner_id = MODULE_OWNER_ID,
        .exclusive = true,
        .api_ptr = host,
        .api_size = @sizeOf(ScriptingHost),
    });
}

fn stopModule(raw_app: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    _ = app.services.unregisterByOwner(MODULE_OWNER_ID);
    if (app.resources.get(ScriptingHost)) |host| {
        host.deinit();
        _ = app.resources.remove(ScriptingHost);
    }
}

pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = "official.script.host",
            .version = "0.1.0",
            .provides_capabilities = &.{"engine.script.host/1"},
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
