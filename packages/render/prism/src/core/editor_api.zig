//! Stage 10 Custom Material Hot-Reload & Editor Viewport API (`packages/render/prism/src/core/editor_api.zig`).
//!
//! Pure-Zig production and editor-facing contracts with zero UI-toolkit dependency:
//! - Transactional `MaterialShaderRegistry` (retains last-good pipeline on hot-reload failure)
//! - Offscreen object-ID `PickingTarget` and `SelectionSet` for editor selection outlines
//! - Per-view GPU resource memory accounting (`ViewMemoryReport`)

const std = @import("std");
const area_lights = @import("../lighting/area_lights.zig");

/// Registered custom material shader entry with transactional hot-reload state.
pub const CustomMaterialEntry = struct {
    id: u64,
    name: []const u8,
    active_pipeline: u64,
    pending_pipeline: ?u64 = null,
    fallback_pipeline: u64,
    feature_flags: area_lights.MaterialFeatureFlags = .{},
    revision: u64 = 1,
};

/// Result of committing a transactional shader hot-reload.
pub const HotReloadCommit = struct {
    superseded_pipeline: u64,
    new_revision: u64,
};

/// Registry for custom materials/shaders supporting transactional hot-reload without broken frames.
pub const MaterialShaderRegistry = struct {
    allocator: std.mem.Allocator,
    entries: std.AutoHashMapUnmanaged(u64, CustomMaterialEntry),

    /// Initializes an empty `MaterialShaderRegistry`.
    pub fn init(allocator: std.mem.Allocator) MaterialShaderRegistry {
        return .{ .allocator = allocator, .entries = .empty };
    }

    /// Releases registry storage.
    pub fn deinit(self: *MaterialShaderRegistry) void {
        self.entries.deinit(self.allocator);
    }

    /// Registers or replaces a custom material manifest with its initial good pipeline and fallback.
    pub fn register(self: *MaterialShaderRegistry, entry: CustomMaterialEntry) !void {
        try self.entries.put(self.allocator, entry.id, entry);
    }

    /// Begins a hot-reload transaction by staging `candidate_pipeline` while keeping `active_pipeline` intact.
    pub fn beginHotReload(self: *MaterialShaderRegistry, id: u64, candidate_pipeline: u64) !void {
        const e = self.entries.getPtr(id) orelse return error.UnknownMaterial;
        e.pending_pipeline = candidate_pipeline;
    }

    /// Commits the staged pipeline and returns the old pipeline handle for completion-aware retirement.
    pub fn commitHotReload(self: *MaterialShaderRegistry, id: u64) !HotReloadCommit {
        const e = self.entries.getPtr(id) orelse return error.UnknownMaterial;
        const next = e.pending_pipeline orelse return error.NoPendingReload;
        const old = e.active_pipeline;
        e.active_pipeline = next;
        e.pending_pipeline = null;
        e.revision += 1;
        return .{ .superseded_pipeline = old, .new_revision = e.revision };
    }

    /// Aborts a failed hot-reload transaction, preserving the last-known-good `active_pipeline`.
    pub fn rollbackHotReload(self: *MaterialShaderRegistry, id: u64) !void {
        const e = self.entries.getPtr(id) orelse return error.UnknownMaterial;
        e.pending_pipeline = null;
    }

    /// Returns the currently active pipeline handle for `id`, or `null` if unregistered.
    pub fn activePipeline(self: *const MaterialShaderRegistry, id: u64) ?u64 {
        const e = self.entries.get(id) orelse return null;
        return if (e.active_pipeline != 0) e.active_pipeline else e.fallback_pipeline;
    }
};

/// Offscreen object-ID picking buffer for editor viewport click selection.
pub const PickingTarget = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    ids: []u64,

    /// Allocates a zeroed `width x height` picking buffer.
    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !PickingTarget {
        const ids = try allocator.alloc(u64, @as(usize, width) * @as(usize, height));
        @memset(ids, 0);
        return .{ .allocator = allocator, .width = width, .height = height, .ids = ids };
    }

    /// Releases buffer memory.
    pub fn deinit(self: *PickingTarget) void {
        self.allocator.free(self.ids);
    }

    /// Clears all pixels to `0` (no entity).
    pub fn clear(self: *PickingTarget) void {
        @memset(self.ids, 0);
    }

    /// Writes `entity_id` at `(x, y)` if in bounds.
    pub fn writeEntityId(self: *PickingTarget, x: u32, y: u32, entity_id: u64) void {
        if (x >= self.width or y >= self.height) return;
        self.ids[@as(usize, y) * @as(usize, self.width) + @as(usize, x)] = entity_id;
    }

    /// Reads the entity ID at `(x, y)`, returning `null` for out-of-bounds or background (`0`).
    pub fn pickEntityAt(self: *const PickingTarget, x: u32, y: u32) ?u64 {
        if (x >= self.width or y >= self.height) return null;
        const id = self.ids[@as(usize, y) * @as(usize, self.width) + @as(usize, x)];
        return if (id == 0) null else id;
    }
};

/// Tracks selected entity IDs for editor selection-outline rendering.
pub const SelectionSet = struct {
    allocator: std.mem.Allocator,
    selected: std.AutoHashMapUnmanaged(u64, void),

    /// Initializes an empty `SelectionSet`.
    pub fn init(allocator: std.mem.Allocator) SelectionSet {
        return .{ .allocator = allocator, .selected = .empty };
    }

    /// Releases selection storage.
    pub fn deinit(self: *SelectionSet) void {
        self.selected.deinit(self.allocator);
    }

    /// Adds `entity_id` to the selection set.
    pub fn select(self: *SelectionSet, entity_id: u64) !void {
        try self.selected.put(self.allocator, entity_id, {});
    }

    /// Removes `entity_id` from the selection set.
    pub fn deselect(self: *SelectionSet, entity_id: u64) bool {
        return self.selected.remove(entity_id);
    }

    /// Returns `true` if `entity_id` is currently selected.
    pub fn isSelected(self: *const SelectionSet, entity_id: u64) bool {
        return self.selected.contains(entity_id);
    }

    /// Clears all selected entities.
    pub fn clear(self: *SelectionSet) void {
        self.selected.clearRetainingCapacity();
    }
};

/// Estimated per-view transient and persistent GPU render target footprint in bytes.
pub const ViewMemoryReport = struct {
    hdr_color_bytes: u64 = 0,
    depth_bytes: u64 = 0,
    ssao_bytes: u64 = 0,
    volumetric_bytes: u64 = 0,
    bloom_bytes: u64 = 0,
    history_bytes: u64 = 0,

    /// Total estimated VRAM footprint across all enabled view targets.
    pub fn totalBytes(self: ViewMemoryReport) u64 {
        return self.hdr_color_bytes + self.depth_bytes + self.ssao_bytes +
            self.volumetric_bytes + self.bloom_bytes + self.history_bytes;
    }
};

/// Computes deterministic per-view render target memory accounting for diagnostics and budget gates.
pub fn estimateViewMemoryBytes(
    width: u32,
    height: u32,
    enable_ssao: bool,
    enable_volumetric: bool,
    enable_bloom: bool,
    enable_temporal_history: bool,
) ViewMemoryReport {
    const px: u64 = @as(u64, width) * @as(u64, height);
    const half_px: u64 = @as(u64, @max(width / 2, 1)) * @as(u64, @max(height / 2, 1));
    return .{
        .hdr_color_bytes = px * 8, // RGBA16F
        .depth_bytes = px * 4, // D32F
        .ssao_bytes = if (enable_ssao) px * 2 else 0, // R8/R16 raw + blur
        .volumetric_bytes = if (enable_volumetric) half_px * 8 * 2 else 0, // half-res RGBA16F ping-pong
        .bloom_bytes = if (enable_bloom) half_px * 8 * 2 else 0, // mip chain ~1.33x-2x half-res
        .history_bytes = if (enable_temporal_history) px * 8 else 0, // RGBA16F history
    };
}
