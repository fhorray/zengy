//! Persistent Dense Render World, Frustum Culling & Batch Queues (`packages/render/prism/src/core/render_world.zig`).
//!
//! Stage 02 foundation:
//! - Dense contiguous `RenderInstance` store with O(1) entity lookup and swap-remove compaction.
//! - Tracks `prev_model` vs `curr_model` transforms for temporal reprojection and velocity passes.
//! - Per-view frustum culling, stable opaque/transparent sort keys, and contiguous `DrawBatch` grouping.

const std = @import("std");
const engine = @import("engine");

/// Persistent render-side instance record mirroring a scene entity.
pub const RenderInstance = struct {
    entity: engine.EntityHandle,
    mesh_asset: u64,
    material_handle: u32,
    pipeline_key: u64 = 0,
    curr_model: [16]f32,
    prev_model: [16]f32,
    bounds_center: [3]f32 = .{ 0, 0, 0 },
    bounds_radius: f32 = 1.0,
    is_transparent: bool = false,
    visible: bool = true,
    last_seen_epoch: u64 = 0,
};

/// Single draw entry emitted into an opaque or transparent render phase queue.
pub const QueueEntry = struct {
    slot_index: u32,
    entity_bits: u64,
    pipeline_key: u64,
    material_handle: u32,
    mesh_asset: u64,
    dist_sq: f32,
};

/// Contiguous batch of opaque queue entries sharing `(pipeline_key, material_handle, mesh_asset)`.
pub const DrawBatch = struct {
    pipeline_key: u64,
    material_handle: u32,
    mesh_asset: u64,
    first_entry: u32,
    instance_count: u32,
};

/// Visibility & batching statistics produced by `cullAndQueue`.
pub const VisibilityStats = struct {
    total_instances: usize = 0,
    visible_opaque: usize = 0,
    visible_transparent: usize = 0,
    culled_count: usize = 0,
    opaque_batches: usize = 0,
};

/// Persistent dense render world storing instances across frames.
pub const RenderWorld = struct {
    allocator: std.mem.Allocator,
    instances: std.ArrayList(RenderInstance),
    entity_to_slot: std.AutoHashMapUnmanaged(u64, usize),
    sync_epoch: u64 = 0,

    /// Initializes an empty `RenderWorld`.
    pub fn init(allocator: std.mem.Allocator) RenderWorld {
        return .{
            .allocator = allocator,
            .instances = .empty,
            .entity_to_slot = .empty,
        };
    }

    /// Releases owned instance buffers and entity map.
    pub fn deinit(self: *RenderWorld) void {
        self.instances.deinit(self.allocator);
        self.entity_to_slot.deinit(self.allocator);
    }

    /// Inserts a new instance or updates an existing one in-place, preserving `prev_model`.
    pub fn upsert(
        self: *RenderWorld,
        entity: engine.EntityHandle,
        mesh_asset: u64,
        material_handle: u32,
        pipeline_key: u64,
        model: [16]f32,
        bounds_center: [3]f32,
        bounds_radius: f32,
        is_transparent: bool,
    ) !void {
        const key: u64 = @bitCast(entity);
        if (self.entity_to_slot.get(key)) |slot| {
            var inst = &self.instances.items[slot];
            inst.prev_model = inst.curr_model;
            inst.curr_model = model;
            inst.mesh_asset = mesh_asset;
            inst.material_handle = material_handle;
            inst.pipeline_key = pipeline_key;
            inst.bounds_center = bounds_center;
            inst.bounds_radius = bounds_radius;
            inst.is_transparent = is_transparent;
            inst.visible = true;
            inst.last_seen_epoch = self.sync_epoch;
            return;
        }

        const slot = self.instances.items.len;
        try self.instances.append(self.allocator, .{
            .entity = entity,
            .mesh_asset = mesh_asset,
            .material_handle = material_handle,
            .pipeline_key = pipeline_key,
            .curr_model = model,
            .prev_model = model,
            .bounds_center = bounds_center,
            .bounds_radius = bounds_radius,
            .is_transparent = is_transparent,
            .visible = true,
            .last_seen_epoch = self.sync_epoch,
        });
        errdefer _ = self.instances.pop();
        try self.entity_to_slot.put(self.allocator, key, slot);
    }

    /// Removes `entity` using O(1) swap-remove compaction. Returns `true` if found.
    pub fn remove(self: *RenderWorld, entity: engine.EntityHandle) bool {
        const key: u64 = @bitCast(entity);
        const slot = self.entity_to_slot.get(key) orelse return false;
        _ = self.entity_to_slot.remove(key);

        const last_idx = self.instances.items.len - 1;
        if (slot != last_idx) {
            const moved = self.instances.items[last_idx];
            self.instances.items[slot] = moved;
            const moved_key: u64 = @bitCast(moved.entity);
            self.entity_to_slot.put(self.allocator, moved_key, slot) catch {};
        }
        _ = self.instances.pop();
        return true;
    }

    /// Begins a new sync epoch; call `pruneUnseen()` afterward to evict destroyed entities.
    pub fn beginSync(self: *RenderWorld) void {
        self.sync_epoch += 1;
    }

    /// Evicts any instance not updated during the current `sync_epoch`. Returns removed count.
    pub fn pruneUnseen(self: *RenderWorld) usize {
        var removed: usize = 0;
        var i: usize = 0;
        while (i < self.instances.items.len) {
            if (self.instances.items[i].last_seen_epoch != self.sync_epoch) {
                const ent = self.instances.items[i].entity;
                _ = self.remove(ent);
                removed += 1;
            } else {
                i += 1;
            }
        }
        return removed;
    }

    /// Returns a pointer to a live instance by entity handle, or `null` if absent.
    pub fn get(self: *const RenderWorld, entity: engine.EntityHandle) ?*const RenderInstance {
        const key: u64 = @bitCast(entity);
        const slot = self.entity_to_slot.get(key) orelse return null;
        return &self.instances.items[slot];
    }

    /// Returns the number of dense instances stored.
    pub fn count(self: *const RenderWorld) usize {
        return self.instances.items.len;
    }

    /// Performs per-view frustum culling against 6 inward-pointing planes `[nx, ny, nz, d]`,
    /// builds sorted opaque (state-batched) and transparent (back-to-front) queues, and groups batches.
    pub fn cullAndQueue(
        self: *const RenderWorld,
        frustum_planes: [6][4]f32,
        camera_pos: [3]f32,
        opaque_out: *std.ArrayList(QueueEntry),
        transparent_out: *std.ArrayList(QueueEntry),
        batches_out: *std.ArrayList(DrawBatch),
        allocator: std.mem.Allocator,
    ) !VisibilityStats {
        opaque_out.clearRetainingCapacity();
        transparent_out.clearRetainingCapacity();
        batches_out.clearRetainingCapacity();

        var stats = VisibilityStats{ .total_instances = self.instances.items.len };

        for (self.instances.items, 0..) |inst, idx| {
            if (!inst.visible or !sphereInFrustum(frustum_planes, inst.bounds_center, inst.bounds_radius)) {
                stats.culled_count += 1;
                continue;
            }
            const dx = inst.bounds_center[0] - camera_pos[0];
            const dy = inst.bounds_center[1] - camera_pos[1];
            const dz = inst.bounds_center[2] - camera_pos[2];
            const entry = QueueEntry{
                .slot_index = @intCast(idx),
                .entity_bits = @bitCast(inst.entity),
                .pipeline_key = inst.pipeline_key,
                .material_handle = inst.material_handle,
                .mesh_asset = inst.mesh_asset,
                .dist_sq = dx * dx + dy * dy + dz * dz,
            };
            if (inst.is_transparent) {
                try transparent_out.append(allocator, entry);
            } else {
                try opaque_out.append(allocator, entry);
            }
        }

        // Opaque sort: pipeline -> material -> mesh -> front-to-back -> entity tie-breaker.
        std.mem.sort(QueueEntry, opaque_out.items, {}, struct {
            fn lessThan(_: void, a: QueueEntry, b: QueueEntry) bool {
                if (a.pipeline_key != b.pipeline_key) return a.pipeline_key < b.pipeline_key;
                if (a.material_handle != b.material_handle) return a.material_handle < b.material_handle;
                if (a.mesh_asset != b.mesh_asset) return a.mesh_asset < b.mesh_asset;
                if (a.dist_sq != b.dist_sq) return a.dist_sq < b.dist_sq;
                return a.entity_bits < b.entity_bits;
            }
        }.lessThan);

        // Transparent sort: back-to-front with deterministic entity tie-breaker.
        std.mem.sort(QueueEntry, transparent_out.items, {}, struct {
            fn lessThan(_: void, a: QueueEntry, b: QueueEntry) bool {
                if (a.dist_sq != b.dist_sq) return a.dist_sq > b.dist_sq;
                return a.entity_bits < b.entity_bits;
            }
        }.lessThan);

        // Group contiguous opaque draws sharing (pipeline, material, mesh) into DrawBatches.
        for (opaque_out.items, 0..) |e, i| {
            if (batches_out.items.len > 0) {
                const last = &batches_out.items[batches_out.items.len - 1];
                if (last.pipeline_key == e.pipeline_key and
                    last.material_handle == e.material_handle and
                    last.mesh_asset == e.mesh_asset)
                {
                    last.instance_count += 1;
                    continue;
                }
            }
            try batches_out.append(allocator, .{
                .pipeline_key = e.pipeline_key,
                .material_handle = e.material_handle,
                .mesh_asset = e.mesh_asset,
                .first_entry = @intCast(i),
                .instance_count = 1,
            });
        }

        stats.visible_opaque = opaque_out.items.len;
        stats.visible_transparent = transparent_out.items.len;
        stats.opaque_batches = batches_out.items.len;
        return stats;
    }
};

/// Extracts 6 normalized inward-pointing frustum planes `[nx, ny, nz, d]` from a column-major
/// `clip_from_world` matrix (Vulkan/SDL_GPU `[0..1]` depth convention).
pub fn extractFrustumPlanes(m: [16]f32) [6][4]f32 {
    const row0 = [4]f32{ m[0], m[4], m[8], m[12] };
    const row1 = [4]f32{ m[1], m[5], m[9], m[13] };
    const row2 = [4]f32{ m[2], m[6], m[10], m[14] };
    const row3 = [4]f32{ m[3], m[7], m[11], m[15] };

    var planes = [6][4]f32{
        .{ row3[0] + row0[0], row3[1] + row0[1], row3[2] + row0[2], row3[3] + row0[3] }, // Left
        .{ row3[0] - row0[0], row3[1] - row0[1], row3[2] - row0[2], row3[3] - row0[3] }, // Right
        .{ row3[0] + row1[0], row3[1] + row1[1], row3[2] + row1[2], row3[3] + row1[3] }, // Bottom
        .{ row3[0] - row1[0], row3[1] - row1[1], row3[2] - row1[2], row3[3] - row1[3] }, // Top
        .{ row2[0], row2[1], row2[2], row2[3] }, // Near (z >= 0)
        .{ row3[0] - row2[0], row3[1] - row2[1], row3[2] - row2[2], row3[3] - row2[3] }, // Far (z <= w)
    };
    for (&planes) |*p| {
        const len = @sqrt(p[0] * p[0] + p[1] * p[1] + p[2] * p[2]);
        if (len > 1e-6) {
            p[0] /= len;
            p[1] /= len;
            p[2] /= len;
            p[3] /= len;
        }
    }
    return planes;
}

fn sphereInFrustum(planes: [6][4]f32, center: [3]f32, radius: f32) bool {
    for (planes) |p| {
        const dist = p[0] * center[0] + p[1] * center[1] + p[2] * center[2] + p[3];
        if (dist < -radius) return false;
    }
    return true;
}
