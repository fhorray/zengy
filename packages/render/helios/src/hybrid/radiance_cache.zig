//! Helios Bounded World-Space Radiance Cache (`packages/render/helios/src/hybrid/radiance_cache.zig`).
//!
//! Spatial hash-grid cache storing accumulated indirect irradiance/radiance with
//! bounded capacity, age-based eviction, confidence weighting, and occupancy telemetry.

const std = @import("std");

/// Quantized world-space cell key.
pub const WorldCellKey = struct {
    x: i32,
    y: i32,
    z: i32,
    lod: u8 = 0,
};

/// Cached radiance entry for one world-space cell.
pub const RadianceCell = struct {
    rgb: [3]f32 = .{ 0, 0, 0 },
    sample_count: u32 = 0,
    confidence: f32 = 0.0,
    last_used_frame: u64 = 0,
};

/// Bounded spatial hash cache for hybrid indirect radiance reuse.
pub const WorldRadianceCache = struct {
    allocator: std.mem.Allocator,
    cell_size: f32 = 2.0,
    max_cells: usize = 4096,
    cells: std.AutoHashMapUnmanaged(WorldCellKey, RadianceCell),
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,

    /// Initializes a `WorldRadianceCache`.
    pub fn init(allocator: std.mem.Allocator, cell_size: f32, max_cells: usize) WorldRadianceCache {
        return .{
            .allocator = allocator,
            .cell_size = @max(cell_size, 0.25),
            .max_cells = @max(max_cells, 16),
            .cells = .empty,
        };
    }

    /// Releases cache storage.
    pub fn deinit(self: *WorldRadianceCache) void {
        self.cells.deinit(self.allocator);
    }

    /// Maps `world_pos` to its quantized `WorldCellKey`.
    pub fn keyForPosition(self: *const WorldRadianceCache, world_pos: [3]f32, lod: u8) WorldCellKey {
        const scale = self.cell_size * std.math.pow(f32, 2.0, @floatFromInt(lod));
        return .{
            .x = @intFromFloat(@floor(world_pos[0] / scale)),
            .y = @intFromFloat(@floor(world_pos[1] / scale)),
            .z = @intFromFloat(@floor(world_pos[2] / scale)),
            .lod = lod,
        };
    }

    /// Accumulates an indirect radiance sample into the cell for `world_pos`.
    pub fn accumulate(
        self: *WorldRadianceCache,
        world_pos: [3]f32,
        lod: u8,
        rgb: [3]f32,
        frame_index: u64,
    ) !void {
        const key = self.keyForPosition(world_pos, lod);
        if (self.cells.getPtr(key)) |cell| {
            const alpha: f32 = 1.0 / @as(f32, @floatFromInt(@min(cell.sample_count + 1, 32)));
            cell.rgb[0] = cell.rgb[0] * (1.0 - alpha) + rgb[0] * alpha;
            cell.rgb[1] = cell.rgb[1] * (1.0 - alpha) + rgb[1] * alpha;
            cell.rgb[2] = cell.rgb[2] * (1.0 - alpha) + rgb[2] * alpha;
            cell.sample_count = @min(cell.sample_count + 1, 1000);
            cell.confidence = @min(1.0, @as(f32, @floatFromInt(cell.sample_count)) / 8.0);
            cell.last_used_frame = frame_index;
            return;
        }

        if (self.cells.count() >= self.max_cells) {
            _ = self.evictOldest();
        }
        try self.cells.put(self.allocator, key, .{
            .rgb = rgb,
            .sample_count = 1,
            .confidence = 1.0 / 8.0,
            .last_used_frame = frame_index,
        });
    }

    /// Queries the cache at `world_pos` and updates hit/miss counters.
    pub fn query(self: *WorldRadianceCache, world_pos: [3]f32, lod: u8, frame_index: u64) ?RadianceCell {
        const key = self.keyForPosition(world_pos, lod);
        if (self.cells.getPtr(key)) |cell| {
            cell.last_used_frame = frame_index;
            self.hits += 1;
            return cell.*;
        }
        self.misses += 1;
        return null;
    }

    /// Evicts entries not touched within `max_age_frames`. Returns count evicted.
    pub fn evictStale(self: *WorldRadianceCache, current_frame: u64, max_age_frames: u64) usize {
        var to_remove = std.ArrayList(WorldCellKey).empty;
        defer to_remove.deinit(self.allocator);

        var it = self.cells.iterator();
        while (it.next()) |entry| {
            if (current_frame >= entry.value_ptr.last_used_frame and
                (current_frame - entry.value_ptr.last_used_frame) > max_age_frames)
            {
                to_remove.append(self.allocator, entry.key_ptr.*) catch break;
            }
        }
        for (to_remove.items) |k| {
            _ = self.cells.remove(k);
            self.evictions += 1;
        }
        return to_remove.items.len;
    }

    fn evictOldest(self: *WorldRadianceCache) bool {
        var oldest_key: ?WorldCellKey = null;
        var oldest_frame: u64 = std.math.maxInt(u64);
        var it = self.cells.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.last_used_frame < oldest_frame) {
                oldest_frame = entry.value_ptr.last_used_frame;
                oldest_key = entry.key_ptr.*;
            }
        }
        if (oldest_key) |k| {
            _ = self.cells.remove(k);
            self.evictions += 1;
            return true;
        }
        return false;
    }

    /// Clears all cached cells (e.g. on world switch or major lighting change).
    pub fn invalidateAll(self: *WorldRadianceCache) void {
        self.cells.clearRetainingCapacity();
    }

    /// Returns occupancy ratio in `[0.0, 1.0]`.
    pub fn occupancyRatio(self: *const WorldRadianceCache) f32 {
        return @as(f32, @floatFromInt(self.cells.count())) / @as(f32, @floatFromInt(self.max_cells));
    }
};
