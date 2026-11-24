//! Stage 13.1 Direct Light Sampling, Vose Alias Table, MIS & ReSTIR DI Reservoirs (`packages/render/helios/src/ray_query/light_sampling.zig`).

const std = @import("std");

/// Unified light entry for importance sampling (analytic lights & emissive triangles).
pub const SampleableLight = struct {
    id: u32,
    position: [3]f32,
    radiance: [3]f32,
    weight: f32,
    is_directional: bool = false,
};

/// Single Vose alias-table entry for O(1) discrete importance sampling.
pub const AliasEntry = struct {
    prob: f32,
    alias: u32,
    pdf: f32,
};

/// O(1) discrete importance-sampling distribution (Vose's Alias Method).
pub const AliasTable = struct {
    allocator: std.mem.Allocator,
    entries: []AliasEntry,
    total_weight: f32,

    /// Builds an `AliasTable` from positive `weights`.
    pub fn build(allocator: std.mem.Allocator, weights: []const f32) !AliasTable {
        if (weights.len == 0) {
            return .{ .allocator = allocator, .entries = &.{}, .total_weight = 0.0 };
        }
        var sum: f32 = 0.0;
        for (weights) |w| sum += @max(w, 0.0);

        const entries = try allocator.alloc(AliasEntry, weights.len);
        errdefer allocator.free(entries);

        if (sum <= 1e-8) {
            const uniform_pdf = 1.0 / @as(f32, @floatFromInt(weights.len));
            for (entries, 0..) |*e, i| {
                e.* = .{ .prob = 1.0, .alias = @intCast(i), .pdf = uniform_pdf };
            }
            return .{ .allocator = allocator, .entries = entries, .total_weight = 0.0 };
        }

        const n_f: f32 = @floatFromInt(weights.len);
        const scaled = try allocator.alloc(f32, weights.len);
        defer allocator.free(scaled);
        var small = std.ArrayList(u32).empty;
        defer small.deinit(allocator);
        var large = std.ArrayList(u32).empty;
        defer large.deinit(allocator);

        for (weights, 0..) |w, i| {
            const nw = @max(w, 0.0);
            const p = nw / sum;
            entries[i] = .{ .prob = 1.0, .alias = @intCast(i), .pdf = p };
            scaled[i] = p * n_f;
            if (scaled[i] < 1.0) {
                try small.append(allocator, @intCast(i));
            } else {
                try large.append(allocator, @intCast(i));
            }
        }

        while (small.items.len > 0 and large.items.len > 0) {
            const l = small.pop().?;
            const g = large.pop().?;
            entries[l].prob = scaled[l];
            entries[l].alias = g;
            scaled[g] = (scaled[g] + scaled[l]) - 1.0;
            if (scaled[g] < 1.0) {
                try small.append(allocator, g);
            } else {
                try large.append(allocator, g);
            }
        }
        for (large.items) |g| entries[g].prob = 1.0;
        for (small.items) |l| entries[l].prob = 1.0;

        return .{
            .allocator = allocator,
            .entries = entries,
            .total_weight = sum,
        };
    }

    /// Releases alias table memory.
    pub fn deinit(self: *AliasTable) void {
        if (self.entries.len > 0) self.allocator.free(self.entries);
    }

    /// Samples an index in O(1) from uniform `(u_idx, u_coin)` in `[0, 1)` and returns `(index, pdf)`.
    pub fn sample(self: *const AliasTable, u_idx: f32, u_coin: f32) struct { index: u32, pdf: f32 } {
        if (self.entries.len == 0) return .{ .index = 0, .pdf = 0.0 };
        const n: f32 = @floatFromInt(self.entries.len);
        const col: u32 = @min(@as(u32, @intFromFloat(@max(0.0, u_idx) * n)), @as(u32, @intCast(self.entries.len - 1)));
        const chosen = if (u_coin < self.entries[col].prob) col else self.entries[col].alias;
        return .{ .index = chosen, .pdf = self.entries[chosen].pdf };
    }
};

/// Multiple Importance Sampling (MIS) power heuristic (`beta = 2`).
pub fn misPowerHeuristic(pdf_a: f32, pdf_b: f32) f32 {
    const a2 = pdf_a * pdf_a;
    const b2 = pdf_b * pdf_b;
    const denom = a2 + b2;
    if (denom <= 1e-12) return 0.0;
    return a2 / denom;
}

/// ReSTIR DI weighted reservoir storing a single resampled light candidate.
pub const Reservoir = struct {
    light_index: u32 = 0,
    weight_sum: f32 = 0.0,
    sample_count: u32 = 0,
    target_pdf: f32 = 0.0,
    unbiased_weight: f32 = 0.0,

    /// Streams candidate `light_idx` with weight `w` (`target_pdf / source_pdf`) using uniform `xi` in `[0, 1)`.
    pub fn update(self: *Reservoir, light_idx: u32, target_pdf: f32, weight: f32, xi: f32) bool {
        self.weight_sum += @max(weight, 0.0);
        self.sample_count += 1;
        if (self.weight_sum > 1e-12 and xi * self.weight_sum < weight) {
            self.light_index = light_idx;
            self.target_pdf = target_pdf;
            return true;
        }
        return false;
    }

    /// Finalizes `unbiased_weight = (1 / target_pdf) * (weight_sum / sample_count)`.
    pub fn finalize(self: *Reservoir) void {
        if (self.sample_count == 0 or self.target_pdf <= 1e-12) {
            self.unbiased_weight = 0.0;
        } else {
            self.unbiased_weight = (self.weight_sum / @as(f32, @floatFromInt(self.sample_count))) / self.target_pdf;
        }
    }

    /// Merges another reservoir `other` (temporal or spatial reuse) evaluated at `new_target_pdf`.
    pub fn merge(self: *Reservoir, other: Reservoir, new_target_pdf: f32, xi: f32) bool {
        if (other.sample_count == 0) return false;
        const w = new_target_pdf * other.unbiased_weight * @as(f32, @floatFromInt(other.sample_count));
        const prev_m = self.sample_count;
        const accepted = self.update(other.light_index, new_target_pdf, w, xi);
        self.sample_count = prev_m + other.sample_count;
        return accepted;
    }
};
