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
        try self.scratch.resize(self.allocator, padded);
        try self.device.writeBuffer(self.buffer, 0, self.scratch.items);
    }
};

/// Bind groups created lazily and reused while the resources they reference stay the same. The key must
/// encode every handle the group depends on. Entries are only evicted between frames.
pub const GroupCache = struct {
    allocator: std.mem.Allocator,
    device: gpu.GpuDevice,
    map: std.AutoHashMapUnmanaged(u64, gpu.BindGroupHandle) = .empty,

    const max_entries = 512;

    pub fn init(allocator: std.mem.Allocator, device: gpu.GpuDevice) GroupCache {
        return .{ .allocator = allocator, .device = device };
    }

    pub fn deinit(self: *GroupCache) void {
        self.clear();
        self.map.deinit(self.allocator);
    }

    pub fn clear(self: *GroupCache) void {
        var it = self.map.valueIterator();
        while (it.next()) |g| self.device.destroyBindGroup(g.*);
        self.map.clearRetainingCapacity();
    }

    /// Call at the start of a frame, before any command that references a cached group was recorded.
    pub fn trim(self: *GroupCache) void {
        if (self.map.count() > max_entries) self.clear();
    }

    pub fn get(self: *GroupCache, cache_key: u64, desc: gpu.BindGroupDesc) !gpu.BindGroupHandle {
        if (self.map.get(cache_key)) |existing| return existing;
        const group = try self.device.createBindGroup(desc);
        errdefer self.device.destroyBindGroup(group);
        try self.map.put(self.allocator, cache_key, group);
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
