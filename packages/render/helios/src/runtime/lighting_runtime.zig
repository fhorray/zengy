//! Persistent CPU lighting scene. The caller owns ECS extraction and GPU publication.
//! Geometry replacement and solve publication are transactional. No GPU DDGI is implied.
const std = @import("std");
const bvh_mod = @import("../ray_query/bvh.zig");
const gi = @import("../ray_query/gi_solver.zig");
const material = @import("../ray_query/indirect_rt.zig");

pub const LightingRuntime = struct {
    allocator: std.mem.Allocator,
    bvh: bvh_mod.Bvh,
    staging_bvh: bvh_mod.Bvh,
    staging_materials: std.ArrayList(material.SurfaceMaterial) = .empty,
    materials: std.ArrayList(material.SurfaceMaterial) = .empty,
    published: std.ArrayList(gi.VirtualPointLight) = .empty,
    staging: std.ArrayList(gi.VirtualPointLight) = .empty,
    geometry_revision: u64 = 0,
    solved_revision: u64 = 0,
    stats: gi.GiSolveStats = .{},
    dirty: bool = true,

    pub fn init(allocator: std.mem.Allocator) LightingRuntime {
        return .{ .allocator = allocator, .bvh = bvh_mod.Bvh.init(allocator), .staging_bvh = bvh_mod.Bvh.init(allocator) };
    }

    pub fn deinit(self: *LightingRuntime) void {
        self.bvh.deinit();
        self.staging_bvh.deinit();
        self.staging_materials.deinit(self.allocator);
        self.materials.deinit(self.allocator);
        self.published.deinit(self.allocator);
        self.staging.deinit(self.allocator);
    }

    /// Accepts world-space mesh triangles, including their instance and material IDs.
    /// A failed build leaves the currently published scene and output intact.
    pub fn replaceGeometry(self: *LightingRuntime, triangles: []const bvh_mod.BvhTriangle, materials: []const material.SurfaceMaterial) !void {
        for (triangles) |tri| {
            if (tri.instance_id >= materials.len) return error.InvalidMaterialIndex;
        }
        self.staging_materials.clearRetainingCapacity();
        try self.staging_materials.appendSlice(self.allocator, materials);
        try self.staging_bvh.build(triangles);
        std.mem.swap(bvh_mod.Bvh, &self.bvh, &self.staging_bvh);
        std.mem.swap(std.ArrayList(material.SurfaceMaterial), &self.materials, &self.staging_materials);
        self.geometry_revision +%= 1;
        self.dirty = true;
    }

    pub fn invalidateLighting(self: *LightingRuntime) void {
        self.dirty = true;
    }

    /// Executes one bounded-quality CPU solve, then publishes only a complete result.
    /// Scheduling frequency is controlled by the caller; this is not an async job.
    pub fn solve(self: *LightingRuntime, emitters: []const gi.DirectPointEmitter, sun: ?gi.DirectSunEmitter, config: gi.GiSolveConfig) !gi.GiSolveStats {
        self.dirty = true;
        const stats = try gi.solveInstantRadiosity(self.allocator, &self.bvh, self.materials.items, emitters, sun, config, &self.staging);
        std.mem.swap(std.ArrayList(gi.VirtualPointLight), &self.staging, &self.published);
        self.stats = stats;
        self.solved_revision = self.geometry_revision;
        self.dirty = false;
        return stats;
    }

    pub fn result(self: *const LightingRuntime) []const gi.VirtualPointLight {
        return self.published.items;
    }
};
