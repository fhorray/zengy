//! Immutable Frame Snapshot, Incremental Extraction & Multi-View Orchestration (`packages/render/prism/src/core/snapshot.zig`).
//!
//! Stage 02 completion:
//! - `FrameSnapshot`: immutable per-frame copy with explicit ownership (zero borrowed ECS pointers).
//! - `ExtractionStats` & `IncrementalExtractor`: tracks added/updated/removed/unchanged counts with full-resync fallback.
//! - `MultiViewSet`: manages multiple independent views sharing immutable geometry/materials while keeping separate history/exposure.

const std = @import("std");
const types = @import("types.zig");
const render_world = @import("render_world.zig");

/// Immutable per-frame render snapshot owned independently of ECS storage.
pub const FrameSnapshot = struct {
    allocator: std.mem.Allocator,
    world_id: u64,
    frame_epoch: u64,
    instances: []render_world.RenderInstance,

    /// Publishes an immutable deep copy of `rw.instances` tagged with `(world_id, frame_epoch)`.
    pub fn publishFrom(
        allocator: std.mem.Allocator,
        world_id: u64,
        frame_epoch: u64,
        rw: *const render_world.RenderWorld,
    ) !FrameSnapshot {
        const copy = try allocator.dupe(render_world.RenderInstance, rw.instances.items);
        return .{
            .allocator = allocator,
            .world_id = world_id,
            .frame_epoch = frame_epoch,
            .instances = copy,
        };
    }

    /// Releases snapshot memory.
    pub fn deinit(self: *FrameSnapshot) void {
        self.allocator.free(self.instances);
    }
};

/// Telemetry comparing incremental vs full render extraction work.
pub const ExtractionStats = struct {
    added: usize = 0,
    updated: usize = 0,
    unchanged: usize = 0,
    removed: usize = 0,
    was_full_resync: bool = false,
};

/// Per-entity revision tracker enabling incremental render-world extraction with full-resync fallback.
pub const IncrementalExtractor = struct {
    allocator: std.mem.Allocator,
    last_revisions: std.AutoHashMapUnmanaged(u64, u64),
    force_full_resync: bool = true,

    /// Initializes an empty `IncrementalExtractor`.
    pub fn init(allocator: std.mem.Allocator) IncrementalExtractor {
        return .{
            .allocator = allocator,
            .last_revisions = .empty,
        };
    }

    /// Releases revision tracking table.
    pub fn deinit(self: *IncrementalExtractor) void {
        self.last_revisions.deinit(self.allocator);
    }

    /// Requests a full resync on the next extraction (e.g. after world switch or scene reload).
    pub fn requestFullResync(self: *IncrementalExtractor) void {
        self.force_full_resync = true;
        self.last_revisions.clearRetainingCapacity();
    }

    /// Checks whether `entity_bits` changed since its last extracted `revision` and records the new revision.
    /// Returns `true` if the caller should upsert into `RenderWorld`.
    pub fn shouldUpload(self: *IncrementalExtractor, entity_bits: u64, revision: u64, stats: *ExtractionStats) !bool {
        if (self.force_full_resync) {
            try self.last_revisions.put(self.allocator, entity_bits, revision);
            stats.added += 1;
            return true;
        }
        const gop = try self.last_revisions.getOrPut(self.allocator, entity_bits);
        if (!gop.found_existing) {
            gop.value_ptr.* = revision;
            stats.added += 1;
            return true;
        }
        if (gop.value_ptr.* != revision) {
            gop.value_ptr.* = revision;
            stats.updated += 1;
            return true;
        }
        stats.unchanged += 1;
        return false;
    }

    /// Completes an extraction pass, clearing the `force_full_resync` flag.
    pub fn finishPass(self: *IncrementalExtractor, stats: *ExtractionStats) void {
        stats.was_full_resync = self.force_full_resync;
        self.force_full_resync = false;
    }
};

/// Per-view independent state inside a multi-view render frame.
pub const ActiveViewDescriptor = struct {
    view_id: types.RenderViewId,
    label: []const u8,
    exposure_ev100: f32 = 0.0,
    is_offscreen: bool = false,
};

/// Tracks multiple active views (e.g. main viewport + offscreen editor preview) sharing one `FrameSnapshot`.
pub const MultiViewSet = struct {
    allocator: std.mem.Allocator,
    views: std.ArrayList(ActiveViewDescriptor),

    /// Initializes an empty `MultiViewSet`.
    pub fn init(allocator: std.mem.Allocator) MultiViewSet {
        return .{
            .allocator = allocator,
            .views = .empty,
        };
    }

    /// Releases view list.
    pub fn deinit(self: *MultiViewSet) void {
        self.views.deinit(self.allocator);
    }

    /// Registers an active view for this frame.
    pub fn addView(self: *MultiViewSet, desc: ActiveViewDescriptor) !void {
        try self.views.append(self.allocator, desc);
    }

    /// Updates exposure independently for one view without affecting sibling views.
    pub fn setViewExposure(self: *MultiViewSet, view_id: types.RenderViewId, ev100: f32) bool {
        for (self.views.items) |*v| {
            if (v.view_id.index == view_id.index and v.view_id.generation == view_id.generation) {
                v.exposure_ev100 = ev100;
                return true;
            }
        }
        return false;
    }

    /// Returns count of registered active views.
    pub fn count(self: *const MultiViewSet) usize {
        return self.views.items.len;
    }
};
