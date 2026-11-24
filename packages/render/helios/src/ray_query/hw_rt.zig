//! Stage 12 Hardware Ray Tracing Capability Contract & BLAS/TLAS Cache (`packages/render/helios/src/ray_query/hw_rt.zig`).
//!
//! Defines the optional versioned acceleration-structure contract (`RtAccelerationVTable`)
//! so native Vulkan/D3D12 providers can plug in hardware ray queries while portable SDL GPU
//! providers explicitly report unsupported without crashing or faking support.

const std = @import("std");

/// Generational handle to a bottom-level acceleration structure (per-mesh geometry).
pub const BlasHandle = packed struct(u64) {
    index: u32,
    generation: u32,

    /// Invalid sentinel handle.
    pub const invalid: BlasHandle = .{ .index = std.math.maxInt(u32), .generation = 0 };
};

/// Generational handle to a top-level acceleration structure (scene instances).
pub const TlasHandle = packed struct(u64) {
    index: u32,
    generation: u32,

    /// Invalid sentinel handle.
    pub const invalid: TlasHandle = .{ .index = std.math.maxInt(u32), .generation = 0 };
};

/// Hardware ray-tracing capabilities reported individually by a native graphics provider.
pub const HardwareRtCapabilities = struct {
    supports_ray_query: bool = false,
    supports_acceleration_structure: bool = false,
    supports_compaction: bool = false,
    scratch_alignment: u32 = 256,
    max_geometry_instances: u32 = 0,
};

/// Single instance entry submitted to build or refit a TLAS.
pub const TlasInstanceDesc = struct {
    blas: BlasHandle,
    transform_3x4: [12]f32,
    instance_custom_index: u32 = 0,
    mask: u8 = 0xFF,
    opaque_only: bool = true,
};

/// Versioned optional hardware acceleration structure backend interface.
pub const RtAccelerationVTable = struct {
    provider_id: []const u8,
    capabilities: HardwareRtCapabilities = .{},
    ctx: ?*anyopaque = null,
    build_blas: *const fn (ctx: ?*anyopaque, mesh_id: u64, vertex_bytes: []const u8, index_bytes: []const u8) anyerror!BlasHandle,
    destroy_blas: *const fn (ctx: ?*anyopaque, handle: BlasHandle) void,
    build_tlas: *const fn (ctx: ?*anyopaque, instances: []const TlasInstanceDesc) anyerror!TlasHandle,
    destroy_tlas: *const fn (ctx: ?*anyopaque, handle: TlasHandle) void,
};

fn unsupportedBuildBlas(_: ?*anyopaque, _: u64, _: []const u8, _: []const u8) !BlasHandle {
    return error.UnsupportedHardwareRayTracing;
}
fn unsupportedDestroyBlas(_: ?*anyopaque, _: BlasHandle) void {}
fn unsupportedBuildTlas(_: ?*anyopaque, _: []const TlasInstanceDesc) !TlasHandle {
    return error.UnsupportedHardwareRayTracing;
}
fn unsupportedDestroyTlas(_: ?*anyopaque, _: TlasHandle) void {}

/// Default portable fallback vtable (used by SDL GPU) that explicitly reports hardware RT unsupported.
pub const UNSUPPORTED_RT_VTABLE = RtAccelerationVTable{
    .provider_id = "official.render.helios.rt_unsupported",
    .capabilities = .{},
    .ctx = null,
    .build_blas = unsupportedBuildBlas,
    .destroy_blas = unsupportedDestroyBlas,
    .build_tlas = unsupportedBuildTlas,
    .destroy_tlas = unsupportedDestroyTlas,
};

/// Cached BLAS entry keyed by `(mesh_asset_id, revision)`.
pub const CachedBlasEntry = struct {
    handle: BlasHandle,
    revision: u64,
};

/// Per-mesh BLAS cache with revision-based invalidation and deferred cleanup.
pub const BlasCache = struct {
    allocator: std.mem.Allocator,
    entries: std.AutoHashMapUnmanaged(u64, CachedBlasEntry),

    /// Initializes an empty `BlasCache`.
    pub fn init(allocator: std.mem.Allocator) BlasCache {
        return .{
            .allocator = allocator,
            .entries = .empty,
        };
    }

    /// Destroys all cached BLAS handles via `backend` and releases map storage.
    pub fn deinit(self: *BlasCache, backend: RtAccelerationVTable) void {
        var it = self.entries.valueIterator();
        while (it.next()) |e| backend.destroy_blas(backend.ctx, e.handle);
        self.entries.deinit(self.allocator);
    }

    /// Returns a cached BLAS if `(mesh_id, revision)` matches, or builds/replaces it via `backend`.
    pub fn getOrBuild(
        self: *BlasCache,
        backend: RtAccelerationVTable,
        mesh_id: u64,
        revision: u64,
        vertex_bytes: []const u8,
        index_bytes: []const u8,
    ) !BlasHandle {
        if (!backend.capabilities.supports_acceleration_structure) {
            return error.UnsupportedHardwareRayTracing;
        }
        if (self.entries.get(mesh_id)) |existing| {
            if (existing.revision == revision) return existing.handle;
            backend.destroy_blas(backend.ctx, existing.handle);
        }
        const handle = try backend.build_blas(backend.ctx, mesh_id, vertex_bytes, index_bytes);
        try self.entries.put(self.allocator, mesh_id, .{ .handle = handle, .revision = revision });
        return handle;
    }

    /// Returns count of cached BLAS entries.
    pub fn count(self: *const BlasCache) usize {
        return self.entries.count();
    }
};
