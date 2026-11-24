//! Shader Manifest, Pipeline Cache Keys & Completion-Aware Retirement (`packages/render/prism/src/resources/manifest.zig`).

const std = @import("std");

/// Shader execution stage.
pub const ShaderStage = enum(u8) {
    vertex = 0,
    fragment = 1,
    compute = 2,
};

/// Interface contract for a compiled shader binary, used to catch CPU/GPU struct drift.
pub const ShaderInterfaceDesc = struct {
    name: []const u8,
    stage: ShaderStage,
    version: u32 = 1,
    uniform_bytes: usize = 0,
    sampler_count: u8 = 0,
    storage_buffer_count: u8 = 0,
    vertex_stride: usize = 0,
};

/// Validates at comptime that a Zig extern uniform struct matches a shader manifest byte size.
pub fn validateUniformLayout(comptime T: type, desc: ShaderInterfaceDesc) bool {
    return @sizeOf(T) == desc.uniform_bytes;
}

/// Deterministic pipeline cache key covering shader, format, raster, blend, and feature state.
pub const PipelineCacheKey = struct {
    vertex_shader_hash: u64,
    fragment_shader_hash: u64,
    shader_version: u32 = 1,
    vertex_stride: u16 = 32,
    color_format: u16 = 0,
    depth_format: u16 = 0,
    sample_count: u8 = 1,
    double_sided: bool = false,
    depth_write: bool = true,
    blend_enabled: bool = false,
    feature_mask: u32 = 0,

    /// Computes a deterministic 64-bit hash for pipeline cache lookup.
    pub fn hash(self: PipelineCacheKey) u64 {
        var hasher = std.hash.Wyhash.init(0x5052_4953_4D31);
        std.hash.autoHash(&hasher, self);
        return hasher.final();
    }
};

/// Callback invoked when a retired GPU resource's frame epoch has completed.
pub const RetireDestroyFn = *const fn (ctx: ?*anyopaque, handle: u64) void;

/// Deferred resource destruction entry queued until `completed_epoch >= retired_epoch`.
pub const RetiredResource = struct {
    handle: u64,
    retired_epoch: u64,
    ctx: ?*anyopaque = null,
    destroy_fn: RetireDestroyFn,
};

/// Completion-aware resource retirement queue that prevents use-after-free while frames are in flight.
pub const RetirementQueue = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(RetiredResource),
    retired_total: u64 = 0,
    reclaimed_total: u64 = 0,

    /// Initializes an empty `RetirementQueue`.
    pub fn init(allocator: std.mem.Allocator) RetirementQueue {
        return .{
            .allocator = allocator,
            .entries = .empty,
        };
    }

    /// Releases queue storage. Call `flushAll` before `deinit` if resources must be destroyed on shutdown.
    pub fn deinit(self: *RetirementQueue) void {
        self.entries.deinit(self.allocator);
    }

    /// Schedules `handle` for destruction once `completed_epoch >= current_epoch`.
    pub fn retire(
        self: *RetirementQueue,
        handle: u64,
        current_epoch: u64,
        ctx: ?*anyopaque,
        destroy_fn: RetireDestroyFn,
    ) !void {
        try self.entries.append(self.allocator, .{
            .handle = handle,
            .retired_epoch = current_epoch,
            .ctx = ctx,
            .destroy_fn = destroy_fn,
        });
        self.retired_total += 1;
    }

    /// Destroys all entries whose `retired_epoch <= completed_epoch`. Returns count reclaimed.
    pub fn reclaim(self: *RetirementQueue, completed_epoch: u64) usize {
        var reclaimed: usize = 0;
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (self.entries.items[i].retired_epoch <= completed_epoch) {
                const entry = self.entries.swapRemove(i);
                entry.destroy_fn(entry.ctx, entry.handle);
                reclaimed += 1;
                self.reclaimed_total += 1;
            } else {
                i += 1;
            }
        }
        return reclaimed;
    }

    /// Destroys all pending entries unconditionally (used during device shutdown).
    pub fn flushAll(self: *RetirementQueue) usize {
        return self.reclaim(std.math.maxInt(u64));
    }

    /// Returns the number of entries still awaiting GPU completion.
    pub fn pendingCount(self: *const RetirementQueue) usize {
        return self.entries.items.len;
    }
};
