//! Stage 10 Render Extension Hooks & Quality Presets (`packages/render/prism/src/core/extensions.zig`).
//!
//! Provides versioned third-party render pass extension points (`before_opaque`,
//! `after_opaque`, `before_tonemap`, `after_tonemap`) with scoped owner revocation,
//! plus the canonical Prism quality preset matrix (`low`, `medium`, `high`, `ultra`).

const std = @import("std");
const types = @import("types.zig");

/// Ordered hook points where external packages can inject custom render work.
pub const RenderHookPoint = enum(u8) {
    before_opaque = 0,
    after_opaque = 1,
    before_tonemap = 2,
    after_tonemap = 3,
};

/// Callback invoked for a registered render extension hook.
pub const RenderHookFn = *const fn (ctx: ?*anyopaque, view_id: types.RenderViewId, frame_epoch: u64) anyerror!void;

/// Descriptor for a third-party render extension hook.
pub const RenderExtensionHook = struct {
    id: []const u8,
    owner_id: u64,
    point: RenderHookPoint,
    priority: i32 = 0,
    ctx: ?*anyopaque = null,
    execute: RenderHookFn,
};

/// Registry managing versioned third-party render hooks with deterministic ordering and owner revocation.
pub const ExtensionRegistry = struct {
    allocator: std.mem.Allocator,
    hooks: std.ArrayList(RenderExtensionHook),

    /// Initializes an empty `ExtensionRegistry`.
    pub fn init(allocator: std.mem.Allocator) ExtensionRegistry {
        return .{
            .allocator = allocator,
            .hooks = .empty,
        };
    }

    /// Releases owned hook ID copies and storage.
    pub fn deinit(self: *ExtensionRegistry) void {
        for (self.hooks.items) |h| self.allocator.free(h.id);
        self.hooks.deinit(self.allocator);
    }

    /// Registers a render extension hook. Rejects duplicate `id` with `error.DuplicateRenderHook`.
    pub fn registerHook(self: *ExtensionRegistry, hook: RenderExtensionHook) !void {
        for (self.hooks.items) |existing| {
            if (std.mem.eql(u8, existing.id, hook.id)) return error.DuplicateRenderHook;
        }
        const id_copy = try self.allocator.dupe(u8, hook.id);
        errdefer self.allocator.free(id_copy);
        var copy = hook;
        copy.id = id_copy;
        try self.hooks.append(self.allocator, copy);
    }

    /// Removes all hooks owned by `owner_id` (used on plugin unload / module stop).
    pub fn unregisterByOwner(self: *ExtensionRegistry, owner_id: u64) usize {
        var removed: usize = 0;
        var i: usize = 0;
        while (i < self.hooks.items.len) {
            if (self.hooks.items[i].owner_id == owner_id) {
                const h = self.hooks.orderedRemove(i);
                self.allocator.free(h.id);
                removed += 1;
            } else {
                i += 1;
            }
        }
        return removed;
    }

    /// Executes all hooks registered at `point` in deterministic `(priority, id)` order.
    pub fn executePoint(self: *const ExtensionRegistry, point: RenderHookPoint, view_id: types.RenderViewId, frame_epoch: u64) !usize {
        var matching = std.ArrayList(RenderExtensionHook).empty;
        defer matching.deinit(self.allocator);

        for (self.hooks.items) |h| {
            if (h.point == point) try matching.append(self.allocator, h);
        }
        std.mem.sort(RenderExtensionHook, matching.items, {}, struct {
            fn lessThan(_: void, a: RenderExtensionHook, b: RenderExtensionHook) bool {
                if (a.priority != b.priority) return a.priority < b.priority;
                return std.mem.lessThan(u8, a.id, b.id);
            }
        }.lessThan);

        for (matching.items) |h| {
            try h.execute(h.ctx, view_id, frame_epoch);
        }
        return matching.items.len;
    }

    /// Returns total registered hook count.
    pub fn count(self: *const ExtensionRegistry) usize {
        return self.hooks.items.len;
    }
};

/// High-level Prism quality preset tier.
pub const QualityPreset = enum(u8) {
    low = 0,
    medium = 1,
    high = 2,
    ultra = 3,
};

/// Resolved feature policy for a `QualityPreset`.
pub const QualityPresetConfig = struct {
    shadow_cascades: u32,
    pcss_enabled: bool,
    ssao_enabled: bool,
    volumetric_enabled: bool,
    bloom_enabled: bool,
    anti_aliasing: types.AntiAliasingMode,
    resolution_scale: f32,
};

/// Returns the canonical Prism feature policy for `preset`.
pub fn presetConfig(preset: QualityPreset) QualityPresetConfig {
    return switch (preset) {
        .low => .{
            .shadow_cascades = 2,
            .pcss_enabled = false,
            .ssao_enabled = false,
            .volumetric_enabled = false,
            .bloom_enabled = false,
            .anti_aliasing = .fxaa,
            .resolution_scale = 0.85,
        },
        .medium => .{
            .shadow_cascades = 3,
            .pcss_enabled = false,
            .ssao_enabled = true,
            .volumetric_enabled = false,
            .bloom_enabled = true,
            .anti_aliasing = .fxaa,
            .resolution_scale = 1.0,
        },
        .high => .{
            .shadow_cascades = 4,
            .pcss_enabled = true,
            .ssao_enabled = true,
            .volumetric_enabled = true,
            .bloom_enabled = true,
            .anti_aliasing = .taa,
            .resolution_scale = 1.0,
        },
        .ultra => .{
            .shadow_cascades = 4,
            .pcss_enabled = true,
            .ssao_enabled = true,
            .volumetric_enabled = true,
            .bloom_enabled = true,
            .anti_aliasing = .taa,
            .resolution_scale = 1.0,
        },
    };
}
