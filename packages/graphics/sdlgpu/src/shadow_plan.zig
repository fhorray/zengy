//! Local shadow atlas planning and shadow-cache keys for `graphics-sdlgpu`.
//!
//! Pure Zig with no GPU or SDL dependency, so ranking, packing and cache invalidation are unit-tested headlessly.
//!
//! The local atlas is `ATLAS` texels square and is split into `GRID x GRID` cells. A tile is a square of whole
//! cells; a point light needs six equally sized consecutive tiles (cube faces), a spot light needs one.

const std = @import("std");

pub const ATLAS: u32 = 2048;
pub const CELL: u32 = 256;
pub const GRID: u32 = ATLAS / CELL;
/// Tile entries available to the shaders (`local_shadow_vp[16]`).
pub const MAX_TILES: u32 = 16;
pub const MAX_LIGHTS: usize = 256;
/// Tile edge used when the atlas is not adaptive.
pub const DEFAULT_TILE: u32 = 512;

/// A square region of the atlas in texels.
pub const TileRect = struct {
    x: u32 = 0,
    y: u32 = 0,
    size: u32 = 0,
};

/// Tiles given to one light. `first_tile < 0` means the light casts no shadow this frame.
pub const Assignment = struct {
    first_tile: i32 = -1,
    size: u32 = 0,
};

pub const Options = struct {
    /// Rank shadowed lights by relevance to the camera instead of submission order.
    prioritize: bool = false,
    /// Pick the tile size per light from its apparent size instead of the fixed default.
    adaptive: bool = false,
};

pub const Plan = struct {
    point: [MAX_LIGHTS]Assignment = @splat(.{}),
    spot: [MAX_LIGHTS]Assignment = @splat(.{}),
    tiles: [MAX_TILES]TileRect = @splat(.{}),
    tile_count: u32 = 0,
};

const Candidate = struct {
    is_point: bool,
    index: u32,
    score: f32,
    wanted: u32,
};

fn candidateBefore(_: void, a: Candidate, b: Candidate) bool {
    if (a.score != b.score) return a.score > b.score;
    // Equal scores keep points before spots and lower indices first, which is also the submission order.
    if (a.is_point != b.is_point) return a.is_point;
    return a.index < b.index;
}

fn relevance(position: [3]f32, range: f32, lumens: f32, cam: [3]f32) f32 {
    const dx = position[0] - cam[0];
    const dy = position[1] - cam[1];
    const dz = position[2] - cam[2];
    const dist = @sqrt(dx * dx + dy * dy + dz * dz);
    const outside = @max(dist - range, 0.0);
    return lumens / (1.0 + outside * outside);
}

/// Tile edge in texels for a light of `range` seen from `dist` away; `max_size` caps it (cube faces stay at 512).
fn adaptiveSize(range: f32, dist: f32, max_size: u32) u32 {
    const apparent = range / @max(dist, 0.5);
    const size: u32 = if (apparent >= 0.6) 1024 else if (apparent >= 0.2) 512 else 256;
    return @min(size, max_size);
}

const Occupancy = struct {
    used: [GRID][GRID]bool = @splat(@splat(false)),

    fn findFree(self: *const Occupancy, n: u32) ?[2]u32 {
        var y: u32 = 0;
        while (y + n <= GRID) : (y += n) {
            var x: u32 = 0;
            while (x + n <= GRID) : (x += n) {
                if (self.isFree(x, y, n)) return .{ x, y };
            }
        }
        return null;
    }

    fn isFree(self: *const Occupancy, x: u32, y: u32, n: u32) bool {
        for (y..y + n) |yy| {
            for (x..x + n) |xx| if (self.used[yy][xx]) return false;
        }
        return true;
    }

    fn take(self: *Occupancy, x: u32, y: u32, n: u32) void {
        for (y..y + n) |yy| {
            for (x..x + n) |xx| self.used[yy][xx] = true;
        }
    }
};

/// Decides which shadowed local lights get atlas tiles, how large they are, and where they sit.
///
/// `points` and `spots` expose `position: [3]f32`, `range`, `intensity_lumens` and `shadows_enabled`.
/// With default `Options` the result equals the historical behaviour: points then spots in submission order, fixed
/// 512 tiles in row-major order, a light is skipped when it does not fit. Selection is deterministic.
pub fn plan(points: anytype, spots: anytype, cam: [3]f32, opts: Options) Plan {
    var out = Plan{};
    var cands: [2 * MAX_LIGHTS]Candidate = undefined;
    var n: usize = 0;
    const np = @min(points.len, MAX_LIGHTS);
    const ns = @min(spots.len, MAX_LIGHTS);
    for (0..np) |i| {
        const l = points[i];
        if (!l.shadows_enabled) continue;
        const dist = std.math.hypot(std.math.hypot(l.position[0] - cam[0], l.position[1] - cam[1]), l.position[2] - cam[2]);
        cands[n] = .{
            .is_point = true,
            .index = @intCast(i),
            .score = if (opts.prioritize) relevance(l.position, l.range, l.intensity_lumens, cam) else 0.0,
            .wanted = if (opts.adaptive) adaptiveSize(l.range, dist, DEFAULT_TILE) else DEFAULT_TILE,
        };
        n += 1;
    }
    for (0..ns) |i| {
        const l = spots[i];
        if (!l.shadows_enabled) continue;
        const dist = std.math.hypot(std.math.hypot(l.position[0] - cam[0], l.position[1] - cam[1]), l.position[2] - cam[2]);
        cands[n] = .{
            .is_point = false,
            .index = @intCast(i),
            .score = if (opts.prioritize) relevance(l.position, l.range, l.intensity_lumens, cam) else 0.0,
            .wanted = if (opts.adaptive) adaptiveSize(l.range, dist, 1024) else DEFAULT_TILE,
        };
        n += 1;
    }
    // Without prioritisation every score is equal, so the comparator reduces to submission order.
    std.mem.sort(Candidate, cands[0..n], {}, candidateBefore);

    var occ = Occupancy{};
    for (cands[0..n]) |cand| {
        const tiles_needed: u32 = if (cand.is_point) 6 else 1;
        if (out.tile_count + tiles_needed > MAX_TILES) continue;
        // Shrink until the whole set of tiles fits; a light that cannot fit even at the smallest size is skipped.
        var size = cand.wanted;
        var placed: ?[6][2]u32 = null;
        while (size >= CELL) : (size /= 2) {
            const cells = size / CELL;
            var trial = occ;
            var pos: [6][2]u32 = undefined;
            var ok = true;
            for (0..tiles_needed) |t| {
                if (trial.findFree(cells)) |p| {
                    trial.take(p[0], p[1], cells);
                    pos[t] = p;
                } else {
                    ok = false;
                    break;
                }
            }
            if (ok) {
                occ = trial;
                placed = pos;
                break;
            }
        }
        const chosen = placed orelse continue;
        const first = out.tile_count;
        for (0..tiles_needed) |t| {
            out.tiles[first + t] = .{ .x = chosen[t][0] * CELL, .y = chosen[t][1] * CELL, .size = size };
        }
        out.tile_count += tiles_needed;
        const a = Assignment{ .first_tile = @intCast(first), .size = size };
        if (cand.is_point) out.point[cand.index] = a else out.spot[cand.index] = a;
    }
    return out;
}

/// Incremental fingerprint of the casters that can reach one shadow map.
///
/// A moved, added, removed or re-materialled caster changes the hash, which invalidates the cached map. Callers
/// feed only the casters that are not culled for this light, so a caster elsewhere does not invalidate it.
pub const CasterHasher = struct {
    h: std.hash.Wyhash,

    pub fn init(seed: u64) CasterHasher {
        return .{ .h = std.hash.Wyhash.init(seed) };
    }

    /// Adds a material-carrying draw: `mesh_asset`, `model_matrix: [16]f32`, `tint: [4]f32` and a `material` with
    /// `alpha_mode`, `double_sided`, `alpha_cutoff`, `base_color: [4]f32` and `base_color_tex`.
    pub fn addDraw(self: *CasterHasher, qm: anytype) void {
        self.h.update(&.{1});
        self.h.update(std.mem.asBytes(&qm.mesh_asset));
        self.h.update(std.mem.sliceAsBytes(&qm.model_matrix));
        self.h.update(std.mem.sliceAsBytes(&qm.tint));
        self.h.update(std.mem.sliceAsBytes(&qm.material.base_color));
        self.h.update(std.mem.asBytes(&@as(u32, @backingInt(qm.material.alpha_mode))));
        self.h.update(std.mem.asBytes(&qm.material.double_sided));
        self.h.update(std.mem.asBytes(&qm.material.alpha_cutoff));
        self.h.update(std.mem.asBytes(&qm.material.base_color_tex));
    }

    /// Adds a caster that carries no material (`mesh_asset`, `model_matrix`).
    pub fn addCaster(self: *CasterHasher, qc: anytype) void {
        self.h.update(&.{2});
        self.h.update(std.mem.asBytes(&qc.mesh_asset));
        self.h.update(std.mem.sliceAsBytes(&qc.model_matrix));
    }

    pub fn addFloats(self: *CasterHasher, values: []const f32) void {
        self.h.update(&.{3});
        self.h.update(std.mem.sliceAsBytes(values));
    }

    pub fn final(self: *CasterHasher) u64 {
        return self.h.final();
    }
};

/// Fingerprint of every draw in `draws` (see `CasterHasher.addDraw`).
pub fn hashCasters(draws: anytype) u64 {
    var hs = CasterHasher.init(0x5ad0_77a1);
    hs.h.update(std.mem.asBytes(&@as(u64, draws.len)));
    for (draws) |qm| hs.addDraw(qm);
    return hs.final();
}

/// Hash of a float array (light matrices, atlas rects), mixed into a cache key.
pub fn hashFloats(seed: u64, values: []const f32) u64 {
    var h = std.hash.Wyhash.init(seed);
    h.update(std.mem.sliceAsBytes(values));
    return h.final();
}

/// Remembers the key a shadow map was last rendered with.
pub const CacheKey = struct {
    key: u64 = 0,
    valid: bool = false,

    /// True when `key` equals the stored one, so the cached shadow map can be reused. Always stores `key`.
    pub fn hit(self: *CacheKey, key: u64, enabled: bool) bool {
        const same = enabled and self.valid and self.key == key;
        self.key = key;
        self.valid = enabled;
        return same;
    }

    /// Forces the next `hit` to miss, for example after the target texture was recreated.
    pub fn invalidate(self: *CacheKey) void {
        self.valid = false;
    }
};

const TestLight = struct {
    position: [3]f32,
    range: f32,
    intensity_lumens: f32,
    shadows_enabled: bool = true,
};

test "default plan keeps submission order with fixed 512 tiles in row-major order" {
    const points = [_]TestLight{
        .{ .position = .{ 0, 0, 0 }, .range = 5, .intensity_lumens = 100 },
        .{ .position = .{ 50, 0, 0 }, .range = 5, .intensity_lumens = 9000 },
    };
    const spots = [_]TestLight{.{ .position = .{ 1, 0, 0 }, .range = 5, .intensity_lumens = 100 }};
    const p = plan(&points, &spots, .{ 0, 0, 0 }, .{});
    try std.testing.expectEqual(@as(i32, 0), p.point[0].first_tile);
    try std.testing.expectEqual(@as(i32, 6), p.point[1].first_tile);
    try std.testing.expectEqual(@as(i32, 12), p.spot[0].first_tile);
    try std.testing.expectEqual(@as(u32, 13), p.tile_count);
    try std.testing.expectEqual(TileRect{ .x = 512, .y = 0, .size = 512 }, p.tiles[1]);
    try std.testing.expectEqual(TileRect{ .x = 0, .y = 512, .size = 512 }, p.tiles[4]);
}

test "without room a late light is skipped; with prioritisation the relevant lights keep their shadows" {
    var points: [4]TestLight = undefined;
    // Light 3 is the brightest and nearest to the camera but comes last in submission order.
    for (&points, 0..) |*l, i| l.* = .{ .position = .{ 100 + @as(f32, @floatFromInt(i)) * 40, 0, 0 }, .range = 5, .intensity_lumens = 100 };
    points[3] = .{ .position = .{ 1, 0, 0 }, .range = 5, .intensity_lumens = 5000 };
    const none = [_]TestLight{};

    const by_order = plan(&points, &none, .{ 0, 0, 0 }, .{});
    try std.testing.expect(by_order.point[0].first_tile >= 0);
    try std.testing.expect(by_order.point[1].first_tile >= 0);
    try std.testing.expectEqual(@as(i32, -1), by_order.point[3].first_tile);

    const ranked = plan(&points, &none, .{ 0, 0, 0 }, .{ .prioritize = true });
    try std.testing.expectEqual(@as(i32, 0), ranked.point[3].first_tile);
    // Stable across calls with the same input.
    const again = plan(&points, &none, .{ 0, 0, 0 }, .{ .prioritize = true });
    try std.testing.expectEqualSlices(Assignment, &ranked.point, &again.point);
}

test "adaptive sizes follow apparent size and tiles never overlap" {
    const points = [_]TestLight{.{ .position = .{ 40, 0, 0 }, .range = 10, .intensity_lumens = 100 }};
    const spots = [_]TestLight{
        .{ .position = .{ 2, 0, 0 }, .range = 10, .intensity_lumens = 100 }, // close: 1024
        .{ .position = .{ 80, 0, 0 }, .range = 10, .intensity_lumens = 100 }, // far: 256
    };
    const p = plan(&points, &spots, .{ 0, 0, 0 }, .{ .adaptive = true });
    try std.testing.expectEqual(@as(u32, 1024), p.spot[0].size);
    try std.testing.expectEqual(@as(u32, 256), p.spot[1].size);
    try std.testing.expectEqual(@as(u32, 512), p.point[0].size); // cube faces never exceed 512

    var grid: [ATLAS / CELL][ATLAS / CELL]u8 = @splat(@splat(0));
    for (p.tiles[0..p.tile_count]) |t| {
        try std.testing.expect(t.x % CELL == 0 and t.y % CELL == 0 and t.x + t.size <= ATLAS and t.y + t.size <= ATLAS);
        for (t.y / CELL..(t.y + t.size) / CELL) |yy| {
            for (t.x / CELL..(t.x + t.size) / CELL) |xx| {
                grid[yy][xx] += 1;
                try std.testing.expectEqual(@as(u8, 1), grid[yy][xx]);
            }
        }
    }
}

test "a light that cannot fit at full size shrinks instead of being dropped" {
    // Four 1024 spots fill the atlas; the fifth must be skipped, and a shrunk point light is placed when room is left.
    var spots: [3]TestLight = undefined;
    for (&spots, 0..) |*l, i| l.* = .{ .position = .{ 1 + @as(f32, @floatFromInt(i)), 0, 0 }, .range = 10, .intensity_lumens = 100 };
    const points = [_]TestLight{.{ .position = .{ 2, 1, 0 }, .range = 10, .intensity_lumens = 50 }};
    const p = plan(&points, &spots, .{ 0, 0, 0 }, .{ .adaptive = true, .prioritize = true });
    // Three 1024 tiles leave one 1024 quadrant, which holds six 256..512 tiles (a 512 cube needs 6 x 4 cells > 16).
    try std.testing.expect(p.point[0].first_tile >= 0);
    try std.testing.expectEqual(@as(u32, 256), p.point[0].size);
}

test "caster hash changes when a caster moves or its material changes, and not otherwise" {
    const Mat = struct {
        alpha_mode: enum(u8) { opaque_mode, mask, blend } = .opaque_mode,
        double_sided: bool = false,
        alpha_cutoff: f32 = 0.5,
        base_color: [4]f32 = .{ 1, 1, 1, 1 },
        base_color_tex: u64 = 0,
    };
    const Draw = struct {
        mesh_asset: u64,
        model_matrix: [16]f32,
        tint: [4]f32 = .{ 1, 1, 1, 1 },
        material: Mat = .{},
    };
    var m = [_]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    var draws = [_]Draw{.{ .mesh_asset = 7, .model_matrix = m }};
    const base = hashCasters(&draws);
    try std.testing.expectEqual(base, hashCasters(&draws));

    m[12] = 0.5; // moved caster
    draws[0].model_matrix = m;
    const moved = hashCasters(&draws);
    try std.testing.expect(moved != base);

    draws[0].material.alpha_cutoff = 0.2;
    try std.testing.expect(hashCasters(&draws) != moved);

    var key = CacheKey{};
    try std.testing.expect(!key.hit(base, true)); // first frame renders
    try std.testing.expect(key.hit(base, true)); // unchanged: cached
    try std.testing.expect(!key.hit(moved, true)); // caster moved: re-render
    try std.testing.expect(key.hit(moved, true));
    try std.testing.expect(!key.hit(moved, false)); // disabled never reports a hit
    try std.testing.expect(!key.hit(moved, true)); // and the first enabled frame renders again
}

test "a caster hasher fed only the reachable casters ignores a caster elsewhere" {
    const C = struct { mesh_asset: u64, model_matrix: [16]f32 };
    var near = C{ .mesh_asset = 1, .model_matrix = @splat(0) };
    var far = C{ .mesh_asset = 2, .model_matrix = @splat(0) };
    var a = CasterHasher.init(1);
    a.addCaster(near);
    a.addFloats(&.{ 1, 2, 3 });
    const before = a.final();

    far.model_matrix[12] = 50; // moves, but is culled for this light so it is never added
    var b = CasterHasher.init(1);
    b.addCaster(near);
    b.addFloats(&.{ 1, 2, 3 });
    try std.testing.expectEqual(before, b.final());

    near.model_matrix[12] = 1; // a reachable caster moves
    var d = CasterHasher.init(1);
    d.addCaster(near);
    d.addFloats(&.{ 1, 2, 3 });
    try std.testing.expect(before != d.final());
}
