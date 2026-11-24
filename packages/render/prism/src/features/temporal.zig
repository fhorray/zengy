//! Shared Hi-Z Depth Pyramid, Blue-Noise/IGN & Temporal History Manager (`packages/render/prism/src/features/temporal.zig`).
//!
//! Stage 03 shared infrastructure reused by contact shadows, SSR, SSGI, volumetric fog, and TAA.

const std = @import("std");
const types = @import("../core/types.zig");

/// Deterministic Interleaved Gradient Noise (IGN) in `[0, 1)` with optional temporal frame offset.
pub fn interleavedGradientNoise(pixel_x: u32, pixel_y: u32, frame_index: u64) f32 {
    const f_off: f32 = @floatFromInt(frame_index % 64);
    const x: f32 = @as(f32, @floatFromInt(pixel_x)) + 5.588238 * f_off;
    const y: f32 = @as(f32, @floatFromInt(pixel_y)) + 5.588238 * f_off;
    const v = 52.9829189 * @mod(0.06711056 * x + 0.00583715 * y, 1.0);
    return @mod(v, 1.0);
}

/// Conservative Hi-Z depth pyramid (min-depth reduction for `[0..1]` near-is-0 depth)
/// handling arbitrary even and odd viewport dimensions.
pub const HiZPyramid = struct {
    allocator: std.mem.Allocator,
    base_width: u32 = 0,
    base_height: u32 = 0,
    mip_widths: std.ArrayList(u32),
    mip_heights: std.ArrayList(u32),
    mip_offsets: std.ArrayList(usize),
    data: std.ArrayList(f32),

    /// Initializes an empty `HiZPyramid`.
    pub fn init(allocator: std.mem.Allocator) HiZPyramid {
        return .{
            .allocator = allocator,
            .mip_widths = .empty,
            .mip_heights = .empty,
            .mip_offsets = .empty,
            .data = .empty,
        };
    }

    /// Releases mip metadata and depth storage.
    pub fn deinit(self: *HiZPyramid) void {
        self.mip_widths.deinit(self.allocator);
        self.mip_heights.deinit(self.allocator);
        self.mip_offsets.deinit(self.allocator);
        self.data.deinit(self.allocator);
    }

    /// Builds a full min-depth mip chain from `src_depth` (`width * height` floats).
    pub fn buildFromDepth(self: *HiZPyramid, src_depth: []const f32, width: u32, height: u32) !void {
        if (width == 0 or height == 0 or src_depth.len < @as(usize, width) * @as(usize, height)) {
            return error.InvalidDepthDimensions;
        }
        self.mip_widths.clearRetainingCapacity();
        self.mip_heights.clearRetainingCapacity();
        self.mip_offsets.clearRetainingCapacity();
        self.data.clearRetainingCapacity();

        self.base_width = width;
        self.base_height = height;

        // Mip 0: direct copy of base depth
        try self.mip_widths.append(self.allocator, width);
        try self.mip_heights.append(self.allocator, height);
        try self.mip_offsets.append(self.allocator, 0);
        try self.data.appendSlice(self.allocator, src_depth[0 .. @as(usize, width) * @as(usize, height)]);

        var prev_w = width;
        var prev_h = height;
        var prev_off: usize = 0;

        while (prev_w > 1 or prev_h > 1) {
            const next_w = @max(@as(u32, 1), prev_w / 2);
            const next_h = @max(@as(u32, 1), prev_h / 2);
            const next_off = self.data.items.len;

            try self.mip_widths.append(self.allocator, next_w);
            try self.mip_heights.append(self.allocator, next_h);
            try self.mip_offsets.append(self.allocator, next_off);
            try self.data.resize(self.allocator, next_off + @as(usize, next_w) * @as(usize, next_h));

            const odd_x = (prev_w & 1) != 0 and prev_w > 1;
            const odd_y = (prev_h & 1) != 0 and prev_h > 1;

            var y: u32 = 0;
            while (y < next_h) : (y += 1) {
                var x: u32 = 0;
                while (x < next_w) : (x += 1) {
                    const sx = x * 2;
                    const sy = y * 2;
                    const sx1 = @min(sx + 1, prev_w - 1);
                    const sy1 = @min(sy + 1, prev_h - 1);

                    var min_d = self.data.items[prev_off + @as(usize, sy) * prev_w + sx];
                    min_d = @min(min_d, self.data.items[prev_off + @as(usize, sy) * prev_w + sx1]);
                    min_d = @min(min_d, self.data.items[prev_off + @as(usize, sy1) * prev_w + sx]);
                    min_d = @min(min_d, self.data.items[prev_off + @as(usize, sy1) * prev_w + sx1]);

                    // Conservative extra taps for odd dimensions so boundary texels are never missed.
                    if (odd_x and x == next_w - 1) {
                        const ex = prev_w - 1;
                        min_d = @min(min_d, self.data.items[prev_off + @as(usize, sy) * prev_w + ex]);
                        min_d = @min(min_d, self.data.items[prev_off + @as(usize, sy1) * prev_w + ex]);
                    }
                    if (odd_y and y == next_h - 1) {
                        const ey = prev_h - 1;
                        min_d = @min(min_d, self.data.items[prev_off + @as(usize, ey) * prev_w + sx]);
                        min_d = @min(min_d, self.data.items[prev_off + @as(usize, ey) * prev_w + sx1]);
                    }
                    if (odd_x and odd_y and x == next_w - 1 and y == next_h - 1) {
                        min_d = @min(min_d, self.data.items[prev_off + @as(usize, prev_h - 1) * prev_w + (prev_w - 1)]);
                    }

                    self.data.items[next_off + @as(usize, y) * next_w + x] = min_d;
                }
            }

            prev_w = next_w;
            prev_h = next_h;
            prev_off = next_off;
        }
    }

    /// Returns the number of mip levels built.
    pub fn mipCount(self: *const HiZPyramid) usize {
        return self.mip_widths.items.len;
    }

    /// Samples `(x, y)` from mip level `mip`, clamped to mip bounds.
    pub fn sampleMip(self: *const HiZPyramid, mip: usize, x: u32, y: u32) ?f32 {
        if (mip >= self.mip_widths.items.len) return null;
        const w = self.mip_widths.items[mip];
        const h = self.mip_heights.items[mip];
        const off = self.mip_offsets.items[mip];
        const cx = @min(x, w - 1);
        const cy = @min(y, h - 1);
        return self.data.items[off + @as(usize, cy) * w + cx];
    }
};

/// Returns `true` when temporal history should be rejected due to depth or normal disocclusion.
pub fn isDisoccluded(
    curr_linear_depth: f32,
    prev_linear_depth: f32,
    curr_normal: [3]f32,
    prev_normal: [3]f32,
    rel_depth_threshold: f32,
    min_normal_dot: f32,
) bool {
    const denom = @max(@abs(curr_linear_depth), 1e-4);
    const rel_diff = @abs(curr_linear_depth - prev_linear_depth) / denom;
    if (rel_diff > rel_depth_threshold) return true;

    const ndot = curr_normal[0] * prev_normal[0] + curr_normal[1] * prev_normal[1] + curr_normal[2] * prev_normal[2];
    return ndot < min_normal_dot;
}

/// Clamps RGB history color into the current neighborhood AABB `[min_rgb, max_rgb]` to suppress ghosting.
pub fn clampHistoryRgb(history: [3]f32, min_rgb: [3]f32, max_rgb: [3]f32) [3]f32 {
    return .{
        std.math.clamp(history[0], min_rgb[0], max_rgb[0]),
        std.math.clamp(history[1], min_rgb[1], max_rgb[1]),
        std.math.clamp(history[2], min_rgb[2], max_rgb[2]),
    };
}

/// Per-view temporal history state tracked by `TemporalHistoryManager`.
pub const ViewTemporalState = struct {
    width: u32 = 0,
    height: u32 = 0,
    prev_clip_from_world: [16]f32 = .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    },
    prev_camera_pos: [3]f32 = .{ 0, 0, 0 },
    prev_jitter_ndc: [2]f32 = .{ 0, 0 },
    valid_frames: u64 = 0,
    exposure_scale: f32 = 1.0,
    cut_detected: bool = true,
};

/// Manages per-view temporal histories, resize resets, and camera-cut detection.
pub const TemporalHistoryManager = struct {
    allocator: std.mem.Allocator,
    entries: std.AutoHashMapUnmanaged(u64, ViewTemporalState),
    camera_cut_distance: f32 = 5.0,

    /// Initializes an empty `TemporalHistoryManager`.
    pub fn init(allocator: std.mem.Allocator) TemporalHistoryManager {
        return .{
            .allocator = allocator,
            .entries = .empty,
        };
    }

    /// Releases temporal state storage.
    pub fn deinit(self: *TemporalHistoryManager) void {
        self.entries.deinit(self.allocator);
    }

    /// Updates temporal state for `view_id`, automatically detecting resize or camera-cut resets.
    pub fn updateView(
        self: *TemporalHistoryManager,
        view_id: types.RenderViewId,
        width: u32,
        height: u32,
        clip_from_world: [16]f32,
        camera_pos: [3]f32,
        jitter_ndc: [2]f32,
        exposure_scale: f32,
        force_reset: bool,
    ) !ViewTemporalState {
        const key: u64 = @bitCast(view_id);
        const gop = try self.entries.getOrPut(self.allocator, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .width = width,
                .height = height,
                .prev_clip_from_world = clip_from_world,
                .prev_camera_pos = camera_pos,
                .prev_jitter_ndc = jitter_ndc,
                .valid_frames = 1,
                .exposure_scale = exposure_scale,
                .cut_detected = true,
            };
            return gop.value_ptr.*;
        }

        var st = gop.value_ptr;
        const dx = camera_pos[0] - st.prev_camera_pos[0];
        const dy = camera_pos[1] - st.prev_camera_pos[1];
        const dz = camera_pos[2] - st.prev_camera_pos[2];
        const moved = @sqrt(dx * dx + dy * dy + dz * dz);
        const resized = st.width != width or st.height != height;
        const is_cut = force_reset or resized or (moved > self.camera_cut_distance);

        const prev_snapshot = st.*;
        st.width = width;
        st.height = height;
        st.prev_clip_from_world = clip_from_world;
        st.prev_camera_pos = camera_pos;
        st.prev_jitter_ndc = jitter_ndc;
        st.exposure_scale = exposure_scale;
        st.cut_detected = is_cut;
        st.valid_frames = if (is_cut) 1 else st.valid_frames + 1;
        return .{
            .width = st.width,
            .height = st.height,
            .prev_clip_from_world = if (is_cut) clip_from_world else prev_snapshot.prev_clip_from_world,
            .prev_camera_pos = if (is_cut) camera_pos else prev_snapshot.prev_camera_pos,
            .prev_jitter_ndc = if (is_cut) jitter_ndc else prev_snapshot.prev_jitter_ndc,
            .valid_frames = st.valid_frames,
            .exposure_scale = st.exposure_scale,
            .cut_detected = is_cut,
        };
    }

    /// Explicitly resets history for `view_id`.
    pub fn resetView(self: *TemporalHistoryManager, view_id: types.RenderViewId) void {
        const key: u64 = @bitCast(view_id);
        if (self.entries.getPtr(key)) |st| {
            st.valid_frames = 0;
            st.cut_detected = true;
        }
    }

    /// Removes temporal state when a view is destroyed.
    pub fn removeView(self: *TemporalHistoryManager, view_id: types.RenderViewId) void {
        _ = self.entries.remove(@bitCast(view_id));
    }
};
