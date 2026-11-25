//! Bounded CPU reference radiance cache. Directional entries isolate opposite-facing surfaces.
//! This is not a GPU DDGI implementation and does not establish geometric visibility.
const std = @import("std");

pub const WorldCellKey = struct {
    x: i32,
    y: i32,
    z: i32,
    lod: u8 = 0,
    normal_bin: u8 = 0, // 0 = legacy nondirectional; 1..6 = signed dominant axis.
};

pub const RadianceCell = struct {
    rgb: [3]f32 = .{ 0, 0, 0 },
    sample_count: u32 = 0,
    confidence: f32 = 0.0,
    last_used_frame: u64 = 0,
    last_updated_frame: u64 = 0,
    older: ?WorldCellKey = null,
    newer: ?WorldCellKey = null,
};

pub const WorldRadianceCache = struct {
    allocator: std.mem.Allocator,
    cell_size: f32 = 2.0,
    max_cells: usize = 4096,
    cells: std.AutoHashMapUnmanaged(WorldCellKey, RadianceCell),
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,
    max_sample_age: u64 = 180,
    oldest_key: ?WorldCellKey = null,
    newest_key: ?WorldCellKey = null,

    pub fn init(allocator: std.mem.Allocator, cell_size: f32, max_cells: usize) WorldRadianceCache {
        return .{
            .allocator = allocator,
            .cell_size = if (std.math.isFinite(cell_size)) @max(cell_size, 0.25) else 2.0,
            .max_cells = @max(max_cells, 16),
            .cells = .empty,
        };
    }

    pub fn deinit(self: *WorldRadianceCache) void {
        self.cells.deinit(self.allocator);
    }

    fn quantize(value: f32, scale: f64) i32 {
        if (!std.math.isFinite(value)) return 0;
        // Use f64 bounds: maxInt(i32) is not exactly representable as f32.
        const v = @floor(@as(f64, value) / scale);
        return @intFromFloat(std.math.clamp(v, @as(f64, -2147483648.0), @as(f64, 2147483647.0)));
    }

    pub fn keyForPosition(self: *const WorldRadianceCache, world_pos: [3]f32, lod: u8) WorldCellKey {
        const scale = @as(f64, self.cell_size) * std.math.pow(f64, 2.0, @floatFromInt(@min(lod, 24)));
        return .{
            .x = quantize(world_pos[0], scale),
            .y = quantize(world_pos[1], scale),
            .z = quantize(world_pos[2], scale),
            .lod = lod,
        };
    }

    pub fn keyForSurface(self: *const WorldRadianceCache, world_pos: [3]f32, normal: [3]f32, lod: u8) WorldCellKey {
        var key = self.keyForPosition(world_pos, lod);
        if (!std.math.isFinite(normal[0]) or !std.math.isFinite(normal[1]) or !std.math.isFinite(normal[2])) return key;
        var axis: usize = 0;
        if (@abs(normal[1]) > @abs(normal[axis])) axis = 1;
        if (@abs(normal[2]) > @abs(normal[axis])) axis = 2;
        if (@abs(normal[axis]) <= 1e-6) return key;
        key.normal_bin = @as(u8, @intCast(axis * 2)) + (if (normal[axis] >= 0.0) @as(u8, 1) else @as(u8, 2));
        return key;
    }

    fn validPosition(position: [3]f32) bool {
        for (position) |v| if (!std.math.isFinite(v)) return false;
        return true;
    }

    fn stale(self: *const WorldRadianceCache, cell: RadianceCell, frame_index: u64) bool {
        return frame_index < cell.last_updated_frame or frame_index - cell.last_updated_frame > self.max_sample_age;
    }

    fn accumulateKey(self: *WorldRadianceCache, key: WorldCellKey, rgb: [3]f32, frame_index: u64) !void {
        for (rgb) |v| if (!std.math.isFinite(v) or v < 0.0) return;
        const initial = RadianceCell{
            .rgb = rgb, .sample_count = 1, .confidence = 1.0 / 8.0,
            .last_used_frame = frame_index, .last_updated_frame = frame_index,
        };
        if (self.cells.getPtr(key)) |cell| {
            if (self.stale(cell.*, frame_index)) {
                const older = cell.older;
                const newer = cell.newer;
                cell.* = initial;
                cell.older = older;
                cell.newer = newer;
                self.touchKey(key);
                return;
            }
            const alpha: f32 = 1.0 / @as(f32, @floatFromInt(@min(cell.sample_count + 1, 32)));
            for (0..3) |i| {
                const a: f64=alpha;
                const value=@as(f64,cell.rgb[i])*(1.0-a)+@as(f64,rgb[i])*a;
                cell.rgb[i]=@floatCast(@min(value,@as(f64,std.math.floatMax(f32))));
            }
            cell.sample_count = @min(cell.sample_count + 1, 1000);
            cell.confidence = @min(1.0, @as(f32, @floatFromInt(cell.sample_count)) / 8.0);
            cell.last_used_frame = frame_index;
            cell.last_updated_frame = frame_index;
            self.touchKey(key);
            return;
        }
        // Reserve before evicting so allocation failure preserves the existing cache.
        try self.cells.ensureUnusedCapacity(self.allocator, 1);
        if (self.cells.count() >= self.max_cells) _ = self.evictOldest();
        self.cells.putAssumeCapacity(key, initial);
        self.appendNewest(key);
    }

    pub fn accumulate(self: *WorldRadianceCache, world_pos: [3]f32, lod: u8, rgb: [3]f32, frame_index: u64) !void {
        if (!validPosition(world_pos)) return;
        try self.accumulateKey(self.keyForPosition(world_pos, lod), rgb, frame_index);
    }

    pub fn accumulateSurface(self: *WorldRadianceCache, world_pos: [3]f32, normal: [3]f32, lod: u8, rgb: [3]f32, frame_index: u64) !void {
        if (!validPosition(world_pos)) return;
        const key = self.keyForSurface(world_pos, normal, lod);
        if (key.normal_bin == 0) return;
        try self.accumulateKey(key, rgb, frame_index);
    }

    fn queryKey(self: *WorldRadianceCache, key: WorldCellKey, frame_index: u64) ?RadianceCell {
        if (self.cells.getPtr(key)) |cell| {
            if (!self.stale(cell.*, frame_index)) {
                cell.last_used_frame = frame_index;
                self.hits += 1;
                self.touchKey(key);
                return cell.*;
            }
        }
        self.misses += 1;
        return null;
    }

    pub fn query(self: *WorldRadianceCache, world_pos: [3]f32, lod: u8, frame_index: u64) ?RadianceCell {
        if (!validPosition(world_pos)) return null;
        return self.queryKey(self.keyForPosition(world_pos, lod), frame_index);
    }

    pub fn querySurface(self: *WorldRadianceCache, world_pos: [3]f32, normal: [3]f32, lod: u8, frame_index: u64) ?RadianceCell {
        if (!validPosition(world_pos)) return null;
        const key = self.keyForSurface(world_pos, normal, lod);
        if (key.normal_bin == 0) return null;
        return self.queryKey(key, frame_index);
    }

    // Unlink and append update only the adjacent entries. Hash-map lookups do not
    // change the allocation; no retained pointers survive a put/remove operation.
    fn unlink(self: *WorldRadianceCache, key: WorldCellKey) void {
        const cell = self.cells.getPtr(key) orelse return;
        const older = cell.older;
        const newer = cell.newer;
        if (older) |k| {
            self.cells.getPtr(k).?.newer = newer;
        } else {
            self.oldest_key = newer;
        }
        if (newer) |k| {
            self.cells.getPtr(k).?.older = older;
        } else {
            self.newest_key = older;
        }
        cell.older = null;
        cell.newer = null;
    }

    fn appendNewest(self: *WorldRadianceCache, key: WorldCellKey) void {
        const cell = self.cells.getPtr(key).?;
        cell.older = self.newest_key;
        cell.newer = null;
        if (self.newest_key) |k| {
            self.cells.getPtr(k).?.newer = key;
        } else {
            self.oldest_key = key;
        }
        self.newest_key = key;
    }

    fn touchKey(self: *WorldRadianceCache, key: WorldCellKey) void {
        if (self.newest_key) |k| if (std.meta.eql(k, key)) return;
        self.unlink(key);
        self.appendNewest(key);
    }

    fn removeKey(self: *WorldRadianceCache, key: WorldCellKey) void {
        self.unlink(key);
        if (self.cells.remove(key)) self.evictions += 1;
    }

    pub fn evictStale(self: *WorldRadianceCache, current_frame: u64, max_age_frames: u64) usize {
        // Walk the intrusive LRU chain; save the next key before removal.
        // This periodic O(N) pass performs no temporary allocations.
        var next = self.oldest_key;
        var removed: usize = 0;
        while (next) |key| {
            const cell = self.cells.get(key).?;
            next = cell.newer;
            const last = cell.last_updated_frame;
            if (current_frame < last or current_frame - last > max_age_frames) {
                self.removeKey(key);
                removed += 1;
            }
        }
        return removed;
    }

    fn evictOldest(self: *WorldRadianceCache) bool {
        const key = self.oldest_key orelse return false;
        self.removeKey(key);
        return true;
    }

    pub fn invalidateAll(self: *WorldRadianceCache) void {
        self.cells.clearRetainingCapacity();
        self.oldest_key = null;
        self.newest_key = null;
    }

    pub fn occupancyRatio(self: *const WorldRadianceCache) f32 {
        return @as(f32, @floatFromInt(self.cells.count())) / @as(f32, @floatFromInt(self.max_cells));
    }
};
