//! Declarative Render Pass & Resource Graph (`packages/render/prism/src/core/pass_graph.zig`).
//!
//! Validates declared pass inputs/outputs, detects read-before-write errors and
//! dependency cycles, and compiles an execution schedule deterministically.

const std = @import("std");

/// Execution scope of a render pass.
pub const PassScope = enum(u8) {
    frame = 0,
    view = 1,
    light = 2,
};

/// Resource access intent declared by a pass.
pub const ResourceUsage = enum(u8) {
    read = 0,
    write = 1,
    read_write = 2,
};

/// Render target load action.
pub const LoadOp = enum(u8) {
    load = 0,
    clear = 1,
    dont_care = 2,
};

/// Render target store action.
pub const StoreOp = enum(u8) {
    store = 0,
    dont_care = 1,
};

/// Policy applied if a pass fails or its feature predicate is inactive.
pub const PassFailurePolicy = enum(u8) {
    abort_frame = 0,
    skip_pass = 1,
    fallback = 2,
};

/// Logical resource handle within a `PassGraph`.
pub const ResourceId = u32;

/// Descriptor for a transient or persistent render graph resource.
pub const ResourceDesc = struct {
    name: []const u8,
    persistent: bool = false,
    external_initial_state: bool = false,
};

/// Single resource access entry declared by a pass.
pub const PassResourceAccess = struct {
    resource: ResourceId,
    usage: ResourceUsage,
    load_op: LoadOp = .load,
    store_op: StoreOp = .store,
};

/// Declarative render pass specification.
pub const PassDesc = struct {
    name: []const u8,
    scope: PassScope = .view,
    enabled: bool = true,
    failure_policy: PassFailurePolicy = .abort_frame,
    accesses: []const PassResourceAccess = &.{},
    explicit_deps: []const usize = &.{},
};

/// Compiled deterministic pass execution order.
pub const CompiledSchedule = struct {
    allocator: std.mem.Allocator,
    order: []usize,

    /// Frees the compiled pass index slice.
    pub fn deinit(self: *CompiledSchedule) void {
        self.allocator.free(self.order);
    }
};

/// Validation and compilation errors for `PassGraph`.
pub const GraphError = error{
    InvalidResourceId,
    InvalidPassDependency,
    ReadBeforeWrite,
    CyclicPassDependency,
    OutOfMemory,
};

/// Declarative pass graph that compiles resource dependencies into a deterministic order.
pub const PassGraph = struct {
    allocator: std.mem.Allocator,
    resources: std.ArrayList(ResourceDesc),
    passes: std.ArrayList(PassDesc),

    /// Initializes an empty `PassGraph`.
    pub fn init(allocator: std.mem.Allocator) PassGraph {
        return .{
            .allocator = allocator,
            .resources = .empty,
            .passes = .empty,
        };
    }

    /// Releases graph storage.
    pub fn deinit(self: *PassGraph) void {
        self.resources.deinit(self.allocator);
        self.passes.deinit(self.allocator);
    }

    /// Declares a resource and returns its `ResourceId`.
    pub fn declareResource(self: *PassGraph, desc: ResourceDesc) !ResourceId {
        const id: ResourceId = @intCast(self.resources.items.len);
        try self.resources.append(self.allocator, desc);
        return id;
    }

    /// Adds a pass to the graph and returns its pass index.
    pub fn addPass(self: *PassGraph, desc: PassDesc) !usize {
        const idx = self.passes.items.len;
        try self.passes.append(self.allocator, desc);
        return idx;
    }

    /// Validates all enabled passes and returns a deterministic topological execution order.
    pub fn compile(self: *const PassGraph, allocator: std.mem.Allocator) GraphError!CompiledSchedule {
        const n = self.passes.items.len;
        const rcount = self.resources.items.len;

        // Track last writer per resource as declared, plus explicit edges.
        const in_degree = try allocator.alloc(usize, n);
        defer allocator.free(in_degree);
        @memset(in_degree, 0);

        const adj = try allocator.alloc(std.ArrayList(usize), n);
        defer {
            for (adj) |*list| list.deinit(allocator);
            allocator.free(adj);
        }
        for (adj) |*list| list.* = .empty;

        const has_writer = try allocator.alloc(bool, rcount);
        defer allocator.free(has_writer);
        const last_writer = try allocator.alloc(usize, rcount);
        defer allocator.free(last_writer);
        for (self.resources.items, 0..) |res, ri| {
            has_writer[ri] = res.persistent or res.external_initial_state;
            last_writer[ri] = std.math.maxInt(usize);
        }

        // Validate resource accesses & build implicit write->read/write dependencies.
        for (self.passes.items, 0..) |p, pi| {
            if (!p.enabled) continue;
            for (p.explicit_deps) |dep| {
                if (dep >= n) return GraphError.InvalidPassDependency;
                if (self.passes.items[dep].enabled) {
                    try adj[dep].append(allocator, pi);
                    in_degree[pi] += 1;
                }
            }
            for (p.accesses) |acc| {
                if (acc.resource >= rcount) return GraphError.InvalidResourceId;
                const ri = acc.resource;
                if (acc.usage == .read or acc.usage == .read_write) {
                    if (!has_writer[ri]) return GraphError.ReadBeforeWrite;
                    if (last_writer[ri] != std.math.maxInt(usize) and last_writer[ri] != pi) {
                        try adj[last_writer[ri]].append(allocator, pi);
                        in_degree[pi] += 1;
                    }
                }
                if (acc.usage == .write or acc.usage == .read_write) {
                    if (last_writer[ri] != std.math.maxInt(usize) and last_writer[ri] != pi) {
                        try adj[last_writer[ri]].append(allocator, pi);
                        in_degree[pi] += 1;
                    }
                    has_writer[ri] = true;
                    last_writer[ri] = pi;
                }
            }
        }

        // Kahn's topological sort with deterministic lowest-index tie-breaking.
        var order = std.ArrayList(usize).empty;
        errdefer order.deinit(allocator);
        const visited = try allocator.alloc(bool, n);
        defer allocator.free(visited);
        @memset(visited, false);

        var enabled_count: usize = 0;
        for (self.passes.items) |p| {
            if (p.enabled) enabled_count += 1;
        }

        while (order.items.len < enabled_count) {
            var picked: ?usize = null;
            for (self.passes.items, 0..) |p, i| {
                if (p.enabled and !visited[i] and in_degree[i] == 0) {
                    picked = i;
                    break;
                }
            }
            const next_idx = picked orelse return GraphError.CyclicPassDependency;
            visited[next_idx] = true;
            try order.append(allocator, next_idx);
            for (adj[next_idx].items) |dst| {
                if (in_degree[dst] > 0) in_degree[dst] -= 1;
            }
        }

        return .{
            .allocator = allocator,
            .order = try order.toOwnedSlice(allocator),
        };
    }
};
