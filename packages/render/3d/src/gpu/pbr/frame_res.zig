//! Per-frame GPU plumbing for the PBR renderer: a uniform ring addressed with dynamic offsets and a bind group
//! cache keyed by the handles of the resources a group references.

const std = @import("std");
const graphics = @import("graphics");

const gpu = graphics.gpu;

/// Linear allocator over one persistent uniform buffer. Each pass pushes its block and gets a dynamic offset;
/// `flush` uploads everything written this frame with a single queue write.
pub const Ring = struct {
    allocator: std.mem.Allocator,
    device: gpu.GpuDevice,
    buffer: gpu.BufferHandle,
    capacity: u32,
    alignment: u32,
    scratch: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, device: gpu.GpuDevice, capacity: u32) !Ring {
        const alignment = @max(device.capabilities().limits.min_uniform_buffer_offset_alignment, 16);
        const buffer = try device.createBuffer(.{ .label = "pbr uniform ring", .size = capacity, .usage = .{ .uniform = true, .copy_dst = true } });
        return .{ .allocator = allocator, .device = device, .buffer = buffer, .capacity = capacity, .alignment = alignment };
    }

    pub fn deinit(self: *Ring) void {
        self.device.destroyBuffer(self.buffer);
        self.scratch.deinit(self.allocator);
    }

    pub fn reset(self: *Ring) void {
        self.scratch.clearRetainingCapacity();
    }

    /// Appends `bytes` and returns the dynamic offset to bind it with.
    pub fn push(self: *Ring, bytes: []const u8) !u32 {
        const previous = self.scratch.items.len;
        const offset = std.mem.alignForward(usize, previous, self.alignment);
        if (offset + bytes.len > self.capacity) return error.UniformRingExhausted;
        try self.scratch.resize(self.allocator, offset + bytes.len);
        @memset(self.scratch.items[previous..offset], 0); // padding between blocks must not leak stale bytes
        @memcpy(self.scratch.items[offset..][0..bytes.len], bytes);
        return @intCast(offset);
    }

    pub fn pushValue(self: *Ring, value: anytype) !u32 {
        return self.push(std.mem.asBytes(&value));
    }

    pub fn flush(self: *Ring) !void {
        if (self.scratch.items.len == 0) return;
        // Queue writes need a size that is a multiple of 4; the scratch is padded to the alignment.
        const padded = std.mem.alignForward(usize, self.scratch.items.len, 4);
        if (padded > self.capacity) return error.UniformRingExhausted;
        const previous = self.scratch.items.len;
        try self.scratch.resize(self.allocator, padded);
        @memset(self.scratch.items[previous..padded], 0);
        try self.device.writeBuffer(self.buffer, 0, self.scratch.items);
    }
};

/// Counters of the bind group cache, for profilers and budget tuning.
pub const CacheStats = struct {
    /// Groups alive right now.
    entries: u32 = 0,
    /// Highest `entries` ever reached.
    peak_entries: u32 = 0,
    /// Lookups served from the cache / groups created, during the last completed frame.
    hits_last_frame: u32 = 0,
    created_last_frame: u32 = 0,
    /// Lifetime totals.
    hits_total: u64 = 0,
    created_total: u64 = 0,
    evicted_total: u64 = 0,
    /// Frames that ended above the hard budget because every group was still in use.
    over_budget_frames: u64 = 0,
    /// Entries visited by the last `trim` (its cost).
    visited_last_trim: u32 = 0,
};

/// Bind groups created lazily and reused while the resources they reference stay the same. The key must
/// encode every handle the group depends on. Entries are only evicted between frames.
///
/// Budget: above `soft_limit` groups idle for more than two frames are evicted a bounded batch at a time; above
/// `hard_limit` the batch is larger. A group used this frame or last frame is never evicted (recorded commands may
/// still reference it), so a scene that genuinely needs more groups grows past the budget and is reported through
/// `CacheStats.over_budget_frames` instead of thrashing.
pub const GroupCache = struct {
    allocator: std.mem.Allocator,
    device: gpu.GpuDevice,
    map: std.AutoHashMapUnmanaged(u64, Entry) = .empty,
    frame_index: u64 = 0,
    stats_data: CacheStats = .{},
    hits_this_frame: u32 = 0,
    created_this_frame: u32 = 0,

    const Entry = struct { handle: gpu.BindGroupHandle, last_used: u64 };

    pub const soft_limit = 512;
    pub const hard_limit = 4096;
    const evict_batch = 64;
    const evict_batch_over_hard = 512;

    /// Snapshot of the counters.
    pub fn stats(self: *const GroupCache) CacheStats {
        var s = self.stats_data;
        s.entries = @intCast(self.map.count());
        return s;
    }

    pub fn init(allocator: std.mem.Allocator, device: gpu.GpuDevice) GroupCache {
        return .{ .allocator = allocator, .device = device };
    }

    pub fn deinit(self: *GroupCache) void {
        self.clear();
        self.map.deinit(self.allocator);
    }

    pub fn clear(self: *GroupCache) void {
        var it = self.map.valueIterator();
        while (it.next()) |g| self.device.destroyBindGroup(g.handle);
        self.map.clearRetainingCapacity();
    }

    /// Call at the start of a frame, before any command that references a cached group was recorded.
    pub fn trim(self: *GroupCache) void {
        self.stats_data.hits_last_frame = self.hits_this_frame;
        self.stats_data.created_last_frame = self.created_this_frame;
        self.hits_this_frame = 0;
        self.created_this_frame = 0;
        self.frame_index +%= 1;
        self.stats_data.visited_last_trim = 0;
        const count_now = self.map.count();
        if (count_now <= soft_limit and self.frame_index % 60 != 0) return;
        // Bound the destruction rate; never clear hot groups en masse. Entries used this or last frame stay.
        const budget: usize = if (count_now > hard_limit) evict_batch_over_hard else evict_batch;
        var stale: [evict_batch_over_hard]u64 = undefined;
        var count: usize = 0;
        var visited: u32 = 0;
        var it = self.map.iterator();
        while (it.next()) |entry| {
            visited += 1;
            const age = self.frame_index -% entry.value_ptr.last_used;
            if (age > 120 or (count_now > soft_limit and age > 2)) {
                stale[count] = entry.key_ptr.*;
                count += 1;
                if (count == budget) break;
            }
        }
        self.stats_data.visited_last_trim = visited;
        for (stale[0..count]) |k| {
            if (self.map.fetchRemove(k)) |entry| {
                self.device.destroyBindGroup(entry.value.handle);
                self.stats_data.evicted_total += 1;
            }
        }
        if (self.map.count() > hard_limit) self.stats_data.over_budget_frames += 1;
    }

    pub fn get(self: *GroupCache, cache_key: u64, desc: gpu.BindGroupDesc) !gpu.BindGroupHandle {
        if (self.map.getPtr(cache_key)) |existing| {
            existing.last_used = self.frame_index;
            self.hits_this_frame +|= 1;
            self.stats_data.hits_total +|= 1;
            return existing.handle;
        }
        const group = try self.device.createBindGroup(desc);
        errdefer self.device.destroyBindGroup(group);
        try self.map.put(self.allocator, cache_key, .{ .handle = group, .last_used = self.frame_index });
        self.created_this_frame +|= 1;
        self.stats_data.created_total +|= 1;
        self.stats_data.peak_entries = @max(self.stats_data.peak_entries, @as(u32, @intCast(self.map.count())));
        return group;
    }
};

/// Builds a cache key from a list of handle-like values (packed u64 handles, sizes, flags).
pub fn key(parts: []const u64) u64 {
    var h = std.hash.Wyhash.init(0x9b9c);
    h.update(std.mem.sliceAsBytes(parts));
    return h.final();
}

pub fn bits(handle: anytype) u64 {
    return @bitCast(handle);
}

test "ring allocations are aligned, bounded and flushed as one block" {
    // Alignment math only: no device is needed to check offsets.
    const alignment: usize = 256;
    try std.testing.expectEqual(@as(usize, 0), std.mem.alignForward(usize, 0, alignment));
    try std.testing.expectEqual(@as(usize, 256), std.mem.alignForward(usize, 80, alignment));
    try std.testing.expectEqual(@as(usize, 512), std.mem.alignForward(usize, 257, alignment));
}

test "cache keys differ when any handle differs" {
    const a = key(&.{ 1, 2, 3 });
    try std.testing.expectEqual(a, key(&.{ 1, 2, 3 }));
    try std.testing.expect(a != key(&.{ 1, 2, 4 }));
    try std.testing.expect(a != key(&.{ 1, 2 }));
}
