//! Deterministic point-light ranking for the volumetric fog pass (`render-3d` GPU renderer).
//!
//! Pure Zig with no GPU or SDL dependency, so the selection is unit-tested headlessly.

const std = @import("std");

/// Number of point lights the volumetric pass lights and shadows at once.
pub const SLOTS = 4;

/// Result of `selectRelevantLights`: light indices sorted by relevance, most relevant first.
pub const Selection = struct {
    /// Indices into the input slice; only the first `count` entries are meaningful.
    idx: [SLOTS]usize = @splat(0),
    score: [SLOTS]f32 = @splat(-1.0),
    count: usize = 0,
};

/// Computes a continuous relevance score for a point or spot light relative to `cam`.
/// Inside `pl.range`, closer lights still strictly outscore farther ones so lights do not tie on a flat plateau.
pub fn lightScore(pl: anytype, cam: [3]f32) f32 {
    const dx = pl.position[0] - cam[0];
    const dy = pl.position[1] - cam[1];
    const dz = pl.position[2] - cam[2];
    const dist = @sqrt(dx * dx + dy * dy + dz * dz);
    const outside = @max(dist - pl.range, 0.0);
    const inside_norm = @min(dist, pl.range) / pl.range;
    return pl.intensity_lumens / (1.0 + 0.25 * inside_norm * inside_norm + outside * outside);
}

/// Ranks point lights by how much they can light fog between the camera and them.
///
/// `lights` is any slice whose elements expose `position: [3]f32`, `range: f32` and
/// `intensity_lumens: f32`. Score = intensity attenuated continuously by distance inside and
/// outside the light's range sphere, so a bright light next to the camera beats a dim or far one.
/// Lights with a non-positive range are skipped. Ties keep the earlier light, so the result is deterministic.
pub fn selectRelevantLights(lights: anytype, cam: [3]f32) Selection {
    var sel: Selection = .{};
    for (lights, 0..) |pl, li| {
        if (pl.range <= 0.0) continue;
        const score = lightScore(pl, cam);

        // Find the insertion slot in the descending top-K list. A score that does not beat the last slot is dropped.
        var pos: usize = SLOTS;
        while (pos > 0 and score > sel.score[pos - 1]) : (pos -= 1) {}
        if (pos >= SLOTS) continue;
        var k: usize = SLOTS - 1;
        while (k > pos) : (k -= 1) {
            sel.score[k] = sel.score[k - 1];
            sel.idx[k] = sel.idx[k - 1];
        }
        sel.score[pos] = score;
        sel.idx[pos] = li;
        if (sel.count < SLOTS) sel.count += 1;
    }
    return sel;
}

/// Stateful temporal cross-fader for the `SLOTS` volumetric light channels.
///
/// Prevents abrupt popping when camera motion swaps lights in or out of the top-`SLOTS` budget
/// without dimming unrelated lights:
/// - Empty slots fill immediately at weight `1.0` on initial fill (zero delay on scene load or `<= SLOTS` scenes).
/// - When all `SLOTS` are full and a new light overtakes an existing one (with hysteresis), the outgoing
///   light fades smoothly `1.0 -> 0.0` before the slot switches to the incoming light and fades `0.0 -> 1.0`.
pub const SlotFader = struct {
    pub const FADE_RATE: f32 = 3.5;
    pub const HYSTERESIS_BONUS: f32 = 1.15;

    pub const Slot = struct {
        active: bool = false,
        idx: usize = 0,
        weight: f32 = 0.0,
        fading_out: bool = false,
    };

    slots: [SLOTS]Slot = @splat(.{}),
    last_light_count: usize = 0,

    pub fn reset(self: *SlotFader) void {
        self.slots = @splat(.{});
        self.last_light_count = 0;
    }

    pub fn update(self: *SlotFader, lights: anytype, cam: [3]f32, dt: f32) void {
        if (lights.len == 0) {
            self.reset();
            return;
        }
        if (self.last_light_count != lights.len) {
            self.reset();
            self.last_light_count = lights.len;
        }

        const step = std.math.clamp(dt, 1.0 / 240.0, 0.1) * FADE_RATE;

        // Rank lights with a hysteresis bonus for currently stable active slots.
        var target: Selection = .{};
        for (lights, 0..) |pl, li| {
            if (pl.range <= 0.0) continue;
            var score = lightScore(pl, cam);
            for (self.slots) |s| {
                if (s.active and !s.fading_out and s.idx == li) {
                    score *= HYSTERESIS_BONUS;
                    break;
                }
            }
            var pos: usize = SLOTS;
            while (pos > 0 and score > target.score[pos - 1]) : (pos -= 1) {}
            if (pos >= SLOTS) continue;
            var k: usize = SLOTS - 1;
            while (k > pos) : (k -= 1) {
                target.score[k] = target.score[k - 1];
                target.idx[k] = target.idx[k - 1];
            }
            target.score[pos] = score;
            target.idx[pos] = li;
            if (target.count < SLOTS) target.count += 1;
        }

        const first_fill = blk: {
            for (self.slots) |s| if (s.active) break :blk false;
            break :blk true;
        };

        // Fade kept slots up to 1.0 and dropped slots down to 0.0.
        for (&self.slots) |*s| {
            if (!s.active) continue;
            if (s.idx >= lights.len or lights[s.idx].range <= 0.0) {
                s.* = .{};
                continue;
            }
            var in_target = false;
            for (0..target.count) |ti| {
                if (target.idx[ti] == s.idx) {
                    in_target = true;
                    break;
                }
            }
            if (in_target) {
                s.fading_out = false;
                s.weight = @min(1.0, s.weight + step);
            } else {
                s.fading_out = true;
                s.weight -= step;
                if (s.weight <= 0.0) s.* = .{};
            }
        }

        // Fill any free slots with newly ranked lights.
        for (0..target.count) |ti| {
            const li = target.idx[ti];
            var already = false;
            for (self.slots) |s| {
                if (s.active and s.idx == li) {
                    already = true;
                    break;
                }
            }
            if (already) continue;
            for (&self.slots) |*s| {
                if (!s.active) {
                    s.* = .{
                        .active = true,
                        .idx = li,
                        .weight = if (first_fill) 1.0 else @min(1.0, step),
                        .fading_out = false,
                    };
                    break;
                }
            }
        }
    }
};

const TestLight = struct {
    position: [3]f32,
    range: f32,
    intensity_lumens: f32,
};

test "selectRelevantLights ranks by attenuated intensity and breaks ties by index" {
    const lights = [_]TestLight{
        .{ .position = .{ 2, 0, 0 }, .range = 1, .intensity_lumens = 100 }, // score 50
        .{ .position = .{ 20, 0, 0 }, .range = 5, .intensity_lumens = 1000 }, // score ~4.4
        .{ .position = .{ 5, 0, 0 }, .range = 5, .intensity_lumens = 10 }, // score 10
        .{ .position = .{ 0, 5, 0 }, .range = 5, .intensity_lumens = 10 }, // score 10, ties with index 2
        .{ .position = .{ 50, 0, 0 }, .range = 1, .intensity_lumens = 1 }, // score ~0, dropped
    };
    const sel = selectRelevantLights(&lights, .{ 0, 0, 0 });
    try std.testing.expectEqual(@as(usize, 4), sel.count);
    try std.testing.expectEqual(@as(usize, 0), sel.idx[0]);
    try std.testing.expectEqual(@as(usize, 2), sel.idx[1]);
    try std.testing.expectEqual(@as(usize, 3), sel.idx[2]);
    try std.testing.expectEqual(@as(usize, 1), sel.idx[3]);
}

test "selectRelevantLights skips non-positive ranges and reports fewer lights than slots" {
    const lights = [_]TestLight{
        .{ .position = .{ 1, 0, 0 }, .range = 0, .intensity_lumens = 500 },
        .{ .position = .{ 3, 0, 0 }, .range = 4, .intensity_lumens = 50 },
    };
    const sel = selectRelevantLights(&lights, .{ 0, 0, 0 });
    try std.testing.expectEqual(@as(usize, 1), sel.count);
    try std.testing.expectEqual(@as(usize, 1), sel.idx[0]);
}

test "selectRelevantLights on an empty slice returns no lights" {
    const lights = [_]TestLight{};
    const sel = selectRelevantLights(&lights, .{ 0, 0, 0 });
    try std.testing.expectEqual(@as(usize, 0), sel.count);
}

test "SlotFader cross-fades swapped slots without dimming unaffected lights" {
    const lights = [_]TestLight{
        .{ .position = .{ -7.5, 2.8, 4.0 }, .range = 14, .intensity_lumens = 2400 },
        .{ .position = .{ -2.5, 2.8, 4.0 }, .range = 14, .intensity_lumens = 2400 },
        .{ .position = .{ 2.5, 2.8, 4.0 }, .range = 14, .intensity_lumens = 2400 },
        .{ .position = .{ 7.5, 2.8, 4.0 }, .range = 14, .intensity_lumens = 2400 },
        .{ .position = .{ 0.0, 4.2, -4.0 }, .range = 16, .intensity_lumens = 2800 },
    };
    var fader: SlotFader = .{};
    // Initial frame at z=15: 4 neon pillars fill immediately at full weight 1.0.
    fader.update(&lights, .{ 0, 6, 15 }, 0.016);
    for (fader.slots) |s| {
        try std.testing.expect(s.active);
        try std.testing.expectEqual(@as(f32, 1.0), s.weight);
    }

    // Move camera near light 4 (z=-4): one pillar fades out smoothly while the other 3 stay at 1.0.
    fader.update(&lights, .{ 0, 4, -3 }, 0.05);
    var full_count: usize = 0;
    var fading_count: usize = 0;
    for (fader.slots) |s| {
        if (s.active and s.weight == 1.0) full_count += 1;
        if (s.active and s.fading_out and s.weight < 1.0) fading_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), full_count);
    try std.testing.expectEqual(@as(usize, 1), fading_count);

    // Advance enough time for fade-out + fade-in to complete: light 4 is now active at 1.0.
    for (0..30) |_| fader.update(&lights, .{ 0, 4, -3 }, 0.05);
    var has_light4 = false;
    for (fader.slots) |s| {
        try std.testing.expect(s.active);
        try std.testing.expectEqual(@as(f32, 1.0), s.weight);
        if (s.idx == 4) has_light4 = true;
    }
    try std.testing.expect(has_light4);
}

/// Largest camera translation (metres) in one frame for which temporal volumetric history is still trusted.
pub const HISTORY_MAX_MOVE: f32 = 4.0;
/// Smallest dot product between consecutive view directions (about 45 degrees) for trusted history.
pub const HISTORY_MIN_FORWARD_DOT: f32 = 0.7;

/// Whether the previous frame's volumetric result may be reprojected into this frame.
/// A teleport or a very fast turn is treated as a camera cut: reprojection would smear unrelated content.
pub fn historyUsable(prev_pos: [3]f32, prev_fwd: [3]f32, pos: [3]f32, fwd: [3]f32) bool {
    const dx = pos[0] - prev_pos[0];
    const dy = pos[1] - prev_pos[1];
    const dz = pos[2] - prev_pos[2];
    if (dx * dx + dy * dy + dz * dz > HISTORY_MAX_MOVE * HISTORY_MAX_MOVE) return false;
    const pl = @sqrt(prev_fwd[0] * prev_fwd[0] + prev_fwd[1] * prev_fwd[1] + prev_fwd[2] * prev_fwd[2]);
    const nl = @sqrt(fwd[0] * fwd[0] + fwd[1] * fwd[1] + fwd[2] * fwd[2]);
    if (pl < 1e-6 or nl < 1e-6) return false;
    const d = (prev_fwd[0] * fwd[0] + prev_fwd[1] * fwd[1] + prev_fwd[2] * fwd[2]) / (pl * nl);
    return d >= HISTORY_MIN_FORWARD_DOT;
}

test "historyUsable accepts small motion and rejects teleports and fast turns" {
    try std.testing.expect(historyUsable(.{ 0, 0, 0 }, .{ 0, 0, -1 }, .{ 0.1, 0, 0 }, .{ 0.05, 0, -1 }));
    try std.testing.expect(!historyUsable(.{ 0, 0, 0 }, .{ 0, 0, -1 }, .{ 10, 0, 0 }, .{ 0, 0, -1 }));
    try std.testing.expect(!historyUsable(.{ 0, 0, 0 }, .{ 0, 0, -1 }, .{ 0, 0, 0 }, .{ 1, 0, 0 }));
    try std.testing.expect(!historyUsable(.{ 0, 0, 0 }, .{ 0, 0, -1 }, .{ 0, 0, 0 }, .{ 0, 0, 0 }));
}
