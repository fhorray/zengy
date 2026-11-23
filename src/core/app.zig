const std = @import("std");
const world_mod = @import("world.zig");
const scheduler_mod = @import("scheduler.zig");
const commands_mod = @import("commands.zig");
const events_mod = @import("events.zig");
const resources_mod = @import("resources.zig");
const service_mod = @import("service_registry.zig");
const module_mod = @import("module_registry.zig");
const reflection_mod = @import("reflection.zig");
const diagnostics_mod = @import("diagnostics.zig");
const abi_mod = @import("abi.zig");

pub const AppState = enum {
    created,
    configured,
    initialized,
    running,
    stopping,
    stopped,
};

pub const AppConfig = struct {
    fixed_dt: f64 = 1.0 / 60.0,
    max_fixed_steps: u32 = 8,
    max_frames: ?u64 = null,
    event_queue_capacity: usize = 1024,
    event_overflow_policy: events_mod.OverflowPolicy = .drop_newest,
    log_capacity: usize = 256,
};

pub const App = struct {
    allocator: std.mem.Allocator,
    config: AppConfig,
    state: AppState,
    world: world_mod.World,
    scheduler: scheduler_mod.Scheduler,
    commands: commands_mod.CommandBuffer,
    events: events_mod.EventBus,
    resources: resources_mod.ResourceRegistry,
    services: service_mod.ServiceRegistry,
    modules: module_mod.ModuleRegistry,
    types: reflection_mod.TypeRegistry,
    diagnostics: diagnostics_mod.Diagnostics,
    plugin_host: ?*abi_mod.PluginHost,
    should_quit: bool,

    pub fn init(allocator: std.mem.Allocator, config: AppConfig) App {
        var sched = scheduler_mod.Scheduler.init(allocator);
        sched.fixed_dt = config.fixed_dt;
        sched.max_fixed_steps = config.max_fixed_steps;

        return .{
            .allocator = allocator,
            .config = config,
            .state = .created,
            .world = world_mod.World.init(allocator, .{ .index = 0, .generation = 1 }),
            .scheduler = sched,
            .commands = commands_mod.CommandBuffer.init(allocator),
            .events = events_mod.EventBus.init(allocator, config.event_queue_capacity, config.event_overflow_policy),
            .resources = resources_mod.ResourceRegistry.init(allocator),
            .services = service_mod.ServiceRegistry.init(allocator),
            .modules = module_mod.ModuleRegistry.init(allocator),
            .types = reflection_mod.TypeRegistry.init(allocator),
            .diagnostics = diagnostics_mod.Diagnostics.init(allocator, config.log_capacity),
            .plugin_host = null,
            .should_quit = false,
        };
    }

    pub fn deinit(self: *App) void {
        if (self.state == .initialized or self.state == .running) {
            self.shutdown();
        }
        if (self.plugin_host) |host| {
            host.deinit();
            self.plugin_host = null;
        }
        self.modules.deinit();
        self.services.deinit();
        self.types.deinit();
        self.resources.deinit();
        self.events.deinit();
        self.commands.deinit();
        self.scheduler.deinit();
        self.world.deinit();
        self.diagnostics.deinit();
    }

    pub fn ensurePluginHost(self: *App) !*abi_mod.PluginHost {
        if (self.plugin_host) |host| return host;
        const host = try abi_mod.PluginHost.init(
            self.allocator,
            &self.diagnostics,
            &self.services,
            &self.events,
        );
        self.plugin_host = host;
        return host;
    }

    pub fn registerModule(self: *App, module: module_mod.Module) !void {
        try self.modules.register(module);
        self.state = .configured;
    }

    pub fn registerComponent(self: *App, comptime T: type) !world_mod.ComponentTypeId {
        return self.world.registerComponent(T);
    }

    pub fn addSystem(self: *App, desc: scheduler_mod.SystemDescriptor) !void {
        try self.scheduler.addSystem(desc);
    }

    pub fn makeSystemContext(self: *App, dt: f32) scheduler_mod.SystemContext {
        return .{
            .world = &self.world,
            .commands = &self.commands,
            .events = &self.events,
            .resources = &self.resources,
            .diagnostics = &self.diagnostics,
            .dt = dt,
            .fixed_dt = @floatCast(self.scheduler.fixed_dt),
        };
    }

    pub fn initialize(self: *App) !void {
        if (self.state == .initialized or self.state == .running) return;

        try self.modules.buildAll(self);
        self.state = .configured;

        try self.modules.startAll(self);
        try self.scheduler.buildAll();

        var ctx = self.makeSystemContext(0.0);
        try self.scheduler.runStage(.startup, &ctx);
        _ = self.events.drain();

        self.state = .initialized;
    }

    pub fn tick(self: *App, frame_dt: f64) !void {
        if (self.state == .created or self.state == .configured) {
            try self.initialize();
        }
        if (self.state == .initialized) {
            self.state = .running;
        }
        if (self.state != .running) return error.InvalidAppState;

        var ctx = self.makeSystemContext(@floatCast(frame_dt));
        _ = try self.scheduler.stepFrame(frame_dt, &ctx);
        self.diagnostics.frame_count += 1;
    }

    pub fn run(self: *App) !void {
        try self.initialize();
        self.state = .running;

        var frame: u64 = 0;
        while (!self.should_quit) {
            if (self.config.max_frames) |limit| {
                if (frame >= limit) break;
            }
            try self.tick(self.config.fixed_dt);
            frame += 1;
        }

        self.shutdown();
    }

    pub fn quit(self: *App) void {
        self.should_quit = true;
    }

    pub fn shutdown(self: *App) void {
        if (self.state == .stopped or self.state == .stopping) return;
        self.state = .stopping;

        var ctx = self.makeSystemContext(0.0);
        self.scheduler.runStage(.shutdown, &ctx) catch {};
        _ = self.events.drain();

        self.modules.stopAll(self);
        self.state = .stopped;
    }
};
