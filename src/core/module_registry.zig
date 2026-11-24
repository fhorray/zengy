//! Topological Module Lifecycle Registry (`core/modules`).
//!
//! Manages optional engine and application modules (`ModuleDescriptor` + `build`/`start`/`stop`).
//!
//! Guarantees:
//! - Resolves module initialization order via topological sort over `provides_capabilities`,
//!   `required_capabilities`, and `optional_capabilities` — independent of registration order.
//! - Rejects missing required capabilities (`MissingRequiredCapability`) and cycles (`DependencyCycle`).
//! - Rolls back already-initialized modules in reverse order if any `build()` or `start()` fails.
//! - Executes `stopAll()` in exact reverse topological order on shutdown.

const std = @import("std");

/// Capability and lifecycle metadata declared by every `Module`.
pub const ModuleDescriptor = struct {
    id: []const u8,
    version: []const u8,
    provides_capabilities: []const []const u8 = &.{},
    required_capabilities: []const []const u8 = &.{},
    optional_capabilities: []const []const u8 = &.{},
};

/// Execution lifecycle state tracked for each registered module.
pub const ModuleLifecycleState = enum {
    discovered,
    resolved,
    built,
    started,
    stopped,
    failed,
};

/// Pluggable application module with lifecycle hooks (`build`, `start`, `stop`).
pub const Module = struct {
    descriptor: ModuleDescriptor,
    build: *const fn (app_ctx: *anyopaque) anyerror!void,
    start: ?*const fn (app_ctx: *anyopaque) anyerror!void = null,
    stop: ?*const fn (app_ctx: *anyopaque) void = null,
};

const RegisteredModule = struct {
    module: Module,
    state: ModuleLifecycleState = .discovered,
};

/// Errors emitted while registering or topologically resolving modules.
pub const ModuleError = error{
    DuplicateModule,
    MissingRequiredCapability,
    AmbiguousProvider,
    DependencyCycle,
    OutOfMemory,
};

/// Topological module registry guaranteeing ordered init, rollback on failure, and reverse teardown.
pub const ModuleRegistry = struct {
    allocator: std.mem.Allocator,
    modules: std.ArrayList(RegisteredModule),
    resolved_order: std.ArrayList(usize),

    pub fn init(allocator: std.mem.Allocator) ModuleRegistry {
        return .{
            .allocator = allocator,
            .modules = .empty,
            .resolved_order = .empty,
        };
    }

    pub fn deinit(self: *ModuleRegistry) void {
        self.modules.deinit(self.allocator);
        self.resolved_order.deinit(self.allocator);
    }

    pub fn register(self: *ModuleRegistry, module: Module) !void {
        for (self.modules.items) |existing| {
            if (std.mem.eql(u8, existing.module.descriptor.id, module.descriptor.id)) {
                return error.DuplicateModule;
            }
        }
        try self.modules.append(self.allocator, .{ .module = module });
    }

    fn findProviderModule(self: *const ModuleRegistry, capability: []const u8) ModuleError!?usize {
        var matched: ?usize = null;
        for (self.modules.items, 0..) |mod, idx| {
            for (mod.module.descriptor.provides_capabilities) |cap| {
                if (std.mem.eql(u8, cap, capability)) {
                    if (matched != null) return error.AmbiguousProvider;
                    matched = idx;
                    break;
                }
            }
        }
        return matched;
    }

    pub fn resolve(self: *ModuleRegistry) ModuleError![]const usize {
        const n = self.modules.items.len;
        self.resolved_order.clearRetainingCapacity();
        if (n == 0) return self.resolved_order.items;

        var adj = try self.allocator.alloc(std.ArrayList(usize), n);
        defer {
            for (adj) |*list| list.deinit(self.allocator);
            self.allocator.free(adj);
        }
        for (adj) |*list| list.* = .empty;

        var indegree = try self.allocator.alloc(usize, n);
        defer self.allocator.free(indegree);
        @memset(indegree, 0);

        for (self.modules.items, 0..) |mod, i| {
            for (mod.module.descriptor.required_capabilities) |req| {
                const provider_idx = (try self.findProviderModule(req)) orelse return error.MissingRequiredCapability;
                if (provider_idx != i) {
                    try adj[provider_idx].append(self.allocator, i);
                    indegree[i] += 1;
                }
            }
            for (mod.module.descriptor.optional_capabilities) |opt| {
                if (try self.findProviderModule(opt)) |provider_idx| {
                    if (provider_idx != i) {
                        try adj[provider_idx].append(self.allocator, i);
                        indegree[i] += 1;
                    }
                }
            }
        }

        var visited = try self.allocator.alloc(bool, n);
        defer self.allocator.free(visited);
        @memset(visited, false);

        var processed: usize = 0;
        while (processed < n) {
            var picked: ?usize = null;
            for (0..n) |i| {
                if (!visited[i] and indegree[i] == 0) {
                    picked = i;
                    break;
                }
            }
            const u = picked orelse return error.DependencyCycle;
            visited[u] = true;
            self.modules.items[u].state = .resolved;
            try self.resolved_order.append(self.allocator, u);
            processed += 1;

            for (adj[u].items) |v| {
                indegree[v] -= 1;
            }
        }

        return self.resolved_order.items;
    }

    pub fn buildAll(self: *ModuleRegistry, app_ctx: *anyopaque) !void {
        _ = try self.resolve();

        var built_count: usize = 0;
        for (self.resolved_order.items) |mod_idx| {
            const mod = &self.modules.items[mod_idx];
            mod.module.build(app_ctx) catch |err| {
                mod.state = .failed;
                // Rollback previously built modules in reverse order
                var j = built_count;
                while (j > 0) {
                    j -= 1;
                    const prev_idx = self.resolved_order.items[j];
                    const prev_mod = &self.modules.items[prev_idx];
                    if (prev_mod.module.stop) |stop_fn| {
                        stop_fn(app_ctx);
                    }
                    prev_mod.state = .stopped;
                }
                return err;
            };
            mod.state = .built;
            built_count += 1;
        }
    }

    pub fn startAll(self: *ModuleRegistry, app_ctx: *anyopaque) !void {
        for (self.resolved_order.items) |mod_idx| {
            const mod = &self.modules.items[mod_idx];
            if (mod.module.start) |start_fn| {
                start_fn(app_ctx) catch |err| {
                    mod.state = .failed;
                    // Rollback all started AND built modules in reverse topological order. The module
                    // whose `start` failed was already built, so its `stop` must release that state too.
                    mod.state = .built;
                    var j = self.resolved_order.items.len;
                    while (j > 0) {
                        j -= 1;
                        const prev_idx = self.resolved_order.items[j];
                        const prev_mod = &self.modules.items[prev_idx];
                        if (prev_mod.state == .started or prev_mod.state == .built) {
                            if (prev_mod.module.stop) |stop_fn| {
                                stop_fn(app_ctx);
                            }
                            prev_mod.state = .stopped;
                        }
                    }
                    mod.state = .failed;
                    return err;
                };
            }
            mod.state = .started;
        }
    }

    pub fn stopAll(self: *ModuleRegistry, app_ctx: *anyopaque) void {
        var i = self.resolved_order.items.len;
        while (i > 0) {
            i -= 1;
            const mod_idx = self.resolved_order.items[i];
            const mod = &self.modules.items[mod_idx];
            if (mod.state == .started or mod.state == .built) {
                if (mod.module.stop) |stop_fn| {
                    stop_fn(app_ctx);
                }
                mod.state = .stopped;
            }
        }
    }

    pub fn getState(self: *const ModuleRegistry, module_id: []const u8) ?ModuleLifecycleState {
        for (self.modules.items) |mod| {
            if (std.mem.eql(u8, mod.module.descriptor.id, module_id)) {
                return mod.state;
            }
        }
        return null;
    }
};
