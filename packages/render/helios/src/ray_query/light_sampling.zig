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
        // Normalize against the largest finite weight before accumulation.
        // Prevents overflow when many high-intensity lights contribute.
        var peak: f32 = 0;
        for (weights) |w| if (std.math.isFinite(w)) { peak = @max(peak, w); };
        for (weights) |w| if (std.math.isFinite(w) and peak > 0) { sum += @max(w, 0) / peak; };

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
            const nw = if (std.math.isFinite(w) and peak > 0) @max(w, 0.0) / peak else 0;
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
            .total_weight = if (sum <= std.math.floatMax(f32) / @max(peak, 1e-30)) sum * peak else std.math.floatMax(f32),
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
        const safe_u = if (std.math.isFinite(u_idx)) std.math.clamp(u_idx, 0, 0.99999994) else 0;
        const col: u32 = @min(@as(u32, @intFromFloat(safe_u * n)), @as(u32, @intCast(self.entries.len - 1)));
        const safe_coin = if (std.math.isFinite(u_coin)) std.math.clamp(u_coin, 0, 0.99999994) else 0;
        const chosen = if (safe_coin < self.entries[col].prob) col else self.entries[col].alias;
        return .{ .index = chosen, .pdf = self.entries[chosen].pdf };
    }
};

/// Multiple Importance Sampling (MIS) power heuristic (`beta = 2`).
pub fn misPowerHeuristic(pdf_a: f32, pdf_b: f32) f32 {
    if (!std.math.isFinite(pdf_a) or !std.math.isFinite(pdf_b) or pdf_a <= 0) return 0;
    const scale = @max(pdf_a, @max(pdf_b, 0));
    const a = pdf_a / scale;
    const b = @max(pdf_b, 0) / scale;
    return a*a / (a*a + b*b);
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
        if (self.sample_count == std.math.maxInt(u32)) return false;
        if (!std.math.isFinite(weight) or !std.math.isFinite(target_pdf) or weight < 0 or target_pdf < 0 or !std.math.isFinite(xi)) return false;
        const w = if (target_pdf > 0) weight else 0;
        if (w > std.math.floatMax(f32) - self.weight_sum) return false;
        self.weight_sum += w;
        self.sample_count += 1;
        const u = if (std.math.isFinite(xi)) std.math.clamp(xi, 0, 0.99999994) else 1;
        if (w > 0 and self.weight_sum > 0 and u < w / self.weight_sum) {
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
            const value = @as(f64, self.weight_sum) / @as(f64, @floatFromInt(self.sample_count)) / @as(f64, self.target_pdf);
            self.unbiased_weight = if (std.math.isFinite(value) and value >= 0 and value <= std.math.floatMax(f32)) @floatCast(value) else 0;
        }
    }

    /// Merges another reservoir `other` (temporal or spatial reuse) evaluated at `new_target_pdf`.
    pub fn merge(self: *Reservoir, other: Reservoir, new_target_pdf: f32, xi: f32) bool {
        if (other.sample_count == 0 or other.sample_count > std.math.maxInt(u32) - self.sample_count or !std.math.isFinite(new_target_pdf) or new_target_pdf < 0 or !std.math.isFinite(other.unbiased_weight) or other.unbiased_weight < 0 or !std.math.isFinite(xi)) return false;
        const w = new_target_pdf * other.unbiased_weight * @as(f32, @floatFromInt(other.sample_count));
        if (!std.math.isFinite(w) or w < 0 or w > std.math.floatMax(f32) - self.weight_sum) return false;
        const prev_m = self.sample_count;
        const accepted = self.update(other.light_index, new_target_pdf, w, xi);
        self.sample_count = prev_m + other.sample_count;
        return accepted;
    }
};
