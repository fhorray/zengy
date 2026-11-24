//! Core Prism View, Capability & Configuration Types (`packages/render/prism/src/core/types.zig`).

const std = @import("std");

/// High-level lighting strategy requested by a render view.
pub const LightingMode = enum(u8) {
    rasterized = 0,
    hybrid = 1,
    ray_traced = 2,
};

/// Anti-aliasing strategy requested by a render view.
pub const AntiAliasingMode = enum(u8) {
    none = 0,
    fxaa = 1,
    taa = 2,
};

/// Per-view rendering settings requested by an application or editor viewport.
pub const RenderViewSettings = struct {
    lighting: LightingMode = .rasterized,
    anti_aliasing: AntiAliasingMode = .fxaa,
    resolution_scale: f32 = 1.0,
    allow_fallback: bool = true,
};

/// Generational handle identifying a registered Prism render view.
pub const RenderViewId = packed struct(u64) {
    index: u32,
    generation: u32,

    /// Invalid sentinel handle.
    pub const invalid: RenderViewId = .{
        .index = std.math.maxInt(u32),
        .generation = 0,
    };

    /// Returns `true` when this handle is not the invalid sentinel.
    pub fn isValid(self: RenderViewId) bool {
        return self.index != std.math.maxInt(u32) and self.generation != 0;
    }
};

/// Hardware/backend feature capabilities reported by the active render provider.
pub const BackendCapabilities = struct {
    supports_hybrid_lighting: bool = false,
    supports_ray_tracing: bool = false,
    supports_taa: bool = false,
    supports_compute: bool = true,
    max_resolution_scale: f32 = 2.0,
};

/// Reason why a requested view feature fell back to a supported alternative.
pub const FallbackReason = enum(u8) {
    none = 0,
    ray_tracing_unsupported = 1,
    hybrid_lighting_unsupported = 2,
    taa_unsupported = 3,
    resolution_scale_clamped = 4,
};

/// Effective configuration resolved against `BackendCapabilities`.
pub const EffectiveViewConfig = struct {
    lighting: LightingMode,
    anti_aliasing: AntiAliasingMode,
    resolution_scale: f32,
    fallback_reason: FallbackReason = .none,
};

/// Resolves requested `RenderViewSettings` against `BackendCapabilities`.
/// Returns `error.UnsupportedRenderFeature` when `allow_fallback == false` and a feature is unavailable.
pub fn resolveViewConfig(
    requested: RenderViewSettings,
    caps: BackendCapabilities,
) error{UnsupportedRenderFeature}!EffectiveViewConfig {
    var eff = EffectiveViewConfig{
        .lighting = requested.lighting,
        .anti_aliasing = requested.anti_aliasing,
        .resolution_scale = requested.resolution_scale,
        .fallback_reason = .none,
    };

    if (eff.lighting == .ray_traced and !caps.supports_ray_tracing) {
        if (!requested.allow_fallback) return error.UnsupportedRenderFeature;
        eff.lighting = if (caps.supports_hybrid_lighting) .hybrid else .rasterized;
        eff.fallback_reason = .ray_tracing_unsupported;
    }
    if (eff.lighting == .hybrid and !caps.supports_hybrid_lighting) {
        if (!requested.allow_fallback) return error.UnsupportedRenderFeature;
        eff.lighting = .rasterized;
        eff.fallback_reason = .hybrid_lighting_unsupported;
    }
    if (eff.anti_aliasing == .taa and !caps.supports_taa) {
        if (!requested.allow_fallback) return error.UnsupportedRenderFeature;
        eff.anti_aliasing = .fxaa;
        if (eff.fallback_reason == .none) eff.fallback_reason = .taa_unsupported;
    }

    const clamped = std.math.clamp(eff.resolution_scale, 0.25, caps.max_resolution_scale);
    if (clamped != eff.resolution_scale) {
        eff.resolution_scale = clamped;
        if (eff.fallback_reason == .none) eff.fallback_reason = .resolution_scale_clamped;
    }
    return eff;
}

/// Per-view persistent state managed by `ViewRegistry`.
pub const ViewState = struct {
    id: RenderViewId,
    width: u32,
    height: u32,
    settings: RenderViewSettings,
    history_valid: bool = false,
    frame_index: u64 = 0,
};

/// Generational registry of active Prism render views with per-view history invalidation.
pub const ViewRegistry = struct {
    allocator: std.mem.Allocator,
    slots: std.ArrayList(?ViewState),
    generations: std.ArrayList(u32),

    /// Initializes an empty `ViewRegistry`.
    pub fn init(allocator: std.mem.Allocator) ViewRegistry {
        return .{
            .allocator = allocator,
            .slots = .empty,
            .generations = .empty,
        };
    }

    /// Releases storage owned by `ViewRegistry`.
    pub fn deinit(self: *ViewRegistry) void {
        self.slots.deinit(self.allocator);
        self.generations.deinit(self.allocator);
    }

    /// Creates a new render view with dimensions `(width, height)` and `settings`.
    pub fn createView(self: *ViewRegistry, width: u32, height: u32, settings: RenderViewSettings) !RenderViewId {
        for (self.slots.items, 0..) |*slot, idx| {
            if (slot.* == null) {
                self.generations.items[idx] +%= 1;
                if (self.generations.items[idx] == 0) self.generations.items[idx] = 1;
                const id = RenderViewId{ .index = @intCast(idx), .generation = self.generations.items[idx] };
                slot.* = .{ .id = id, .width = width, .height = height, .settings = settings };
                return id;
            }
        }
        const idx: u32 = @intCast(self.slots.items.len);
        const gen: u32 = 1;
        const id = RenderViewId{ .index = idx, .generation = gen };
        try self.generations.append(self.allocator, gen);
        errdefer _ = self.generations.pop();
        try self.slots.append(self.allocator, .{ .id = id, .width = width, .height = height, .settings = settings });
        return id;
    }

    /// Returns a mutable pointer to a live view, or `null` if stale/destroyed.
    pub fn getView(self: *ViewRegistry, id: RenderViewId) ?*ViewState {
        if (!id.isValid() or id.index >= self.slots.items.len) return null;
        if (self.generations.items[id.index] != id.generation) return null;
        if (self.slots.items[id.index]) |*v| return v;
        return null;
    }

    /// Returns a const pointer to a live view, or `null` if stale/destroyed.
    pub fn getViewConst(self: *const ViewRegistry, id: RenderViewId) ?*const ViewState {
        if (!id.isValid() or id.index >= self.slots.items.len) return null;
        if (self.generations.items[id.index] != id.generation) return null;
        if (self.slots.items[id.index]) |*v| return v;
        return null;
    }

    /// Resizes a view and invalidates its temporal history when dimensions change.
    pub fn resizeView(self: *ViewRegistry, id: RenderViewId, width: u32, height: u32) bool {
        const v = self.getView(id) orelse return false;
        if (v.width != width or v.height != height) {
            v.width = width;
            v.height = height;
            v.history_valid = false;
        }
        return true;
    }

    /// Explicitly invalidates temporal history (e.g. on camera cut, teleport, or world switch).
    pub fn invalidateHistory(self: *ViewRegistry, id: RenderViewId) void {
        if (self.getView(id)) |v| v.history_valid = false;
    }

    /// Destroys a render view, invalidating its generational handle.
    pub fn destroyView(self: *ViewRegistry, id: RenderViewId) bool {
        if (!id.isValid() or id.index >= self.slots.items.len) return false;
        if (self.generations.items[id.index] != id.generation) return false;
        if (self.slots.items[id.index] == null) return false;
        self.slots.items[id.index] = null;
        self.generations.items[id.index] +%= 1;
        return true;
    }

    /// Returns the number of currently active views.
    pub fn activeCount(self: *const ViewRegistry) usize {
        var n: usize = 0;
        for (self.slots.items) |slot| {
            if (slot != null) n += 1;
        }
        return n;
    }
};
