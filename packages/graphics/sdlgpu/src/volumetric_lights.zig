//! Deterministic point-light ranking for the volumetric fog pass (`graphics-sdlgpu`).
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

/// Ranks point lights by how much they can light fog between the camera and them.
///
/// `lights` is any slice whose elements expose `position: [3]f32`, `range: f32` and
/// `intensity_lumens: f32`. Score = intensity attenuated by the camera's distance to the light's
/// range sphere, so a bright light next to the camera beats a dim one far away. Lights with a
/// non-positive range are skipped. Ties keep the earlier light, so the result is deterministic.
pub fn selectRelevantLights(lights: anytype, cam: [3]f32) Selection {
    var sel: Selection = .{};
    for (lights, 0..) |pl, li| {
        if (pl.range <= 0.0) continue;
        const dx = pl.position[0] - cam[0];
        const dy = pl.position[1] - cam[1];
        const dz = pl.position[2] - cam[2];
        const dist = @sqrt(dx * dx + dy * dy + dz * dz);
        const outside = @max(dist - pl.range, 0.0);
        const score = pl.intensity_lumens / (1.0 + outside * outside);

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
