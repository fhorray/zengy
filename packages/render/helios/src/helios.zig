//! Helios Optional Hybrid Indirect Illumination Subsystem (`official.render.helios`, Stage 09).
//!
//! Consumes `official.render.prism` (`HiZPyramid`, `IrradianceProbeVolume`, `reflections`)
//! to provide unified indirect diffuse/specular evaluation (`engine.render.helios/1`)
//! without forcing Helios onto standard Forward+ applications.

const std = @import("std");
const engine = @import("engine");
const prism = @import("prism");

pub const contract = @import("hybrid/lighting_contract.zig");
pub const ssgi = @import("hybrid/ssgi.zig");
pub const radiance_cache = @import("hybrid/radiance_cache.zig");
pub const ray_query = @import("ray_query/bvh.zig");

pub const HeliosQualityTier = contract.HeliosQualityTier;
pub const HeliosDebugMode = contract.HeliosDebugMode;
pub const HeliosViewSettings = contract.HeliosViewSettings;
pub const IndirectLightingOutput = contract.IndirectLightingOutput;
pub const WorldRadianceCache = radiance_cache.WorldRadianceCache;

/// Owner ID used when registering `official.render.helios` services.
pub const MODULE_OWNER_ID: u64 = 2047;

/// Manages Helios hybrid lighting settings, world-space radiance cache, and indirect evaluation (`engine.render.helios/1`).
pub const HeliosService = struct {
    allocator: std.mem.Allocator,
    settings: HeliosViewSettings = .{},
    cache: WorldRadianceCache,
    frame_index: u64 = 0,

    /// Initializes `HeliosService`.
    pub fn init(allocator: std.mem.Allocator) HeliosService {
        return .{
            .allocator = allocator,
            .cache = WorldRadianceCache.init(allocator, 2.5, 2048),
        };
    }

    /// Releases cache storage.
    pub fn deinit(self: *HeliosService) void {
        self.cache.deinit();
    }

    /// Advances Helios frame state and evicts stale radiance cache cells.
    pub fn beginFrame(self: *HeliosService) void {
        self.frame_index += 1;
        if (self.frame_index % 60 == 0) {
            _ = self.cache.evictStale(self.frame_index, 180);
        }
    }

    /// Evaluates unified indirect diffuse/specular illumination at `world_pos` without double-counting.
    pub fn evaluatePoint(
        self: *HeliosService,
        world_pos: [3]f32,
        normal: [3]f32,
        probe_vol: ?*const prism.baked_gi.IrradianceProbeVolume,
        sky_ibl_rgb: [3]f32,
        ssgi_rgb: [3]f32,
        ssgi_confidence: f32,
    ) !IndirectLightingOutput {
        if (self.settings.tier == .off) {
            return .{ .diffuse_rgb = sky_ibl_rgb, .specular_rgb = sky_ibl_rgb };
        }

        const probe_rgb: [3]f32 = if (probe_vol) |pv| pv.sampleIrradiance(world_pos, normal) else .{ 0, 0, 0 };
        const probe_w: f32 = if (probe_vol != null and self.settings.allow_probe_fallback) 1.0 else 0.0;

        // Combine SSGI with probe/sky fallback, then blend with world-space radiance cache.
        var combined = contract.combineIndirectDiffuse(ssgi_rgb, ssgi_confidence, probe_rgb, probe_w, sky_ibl_rgb);
        try self.cache.accumulate(world_pos, 0, combined, self.frame_index);
        if (self.cache.query(world_pos, 0, self.frame_index)) |cell| {
            const cw = cell.confidence * 0.5;
            combined = .{
                combined[0] * (1.0 - cw) + cell.rgb[0] * cw,
                combined[1] * (1.0 - cw) + cell.rgb[1] * cw,
                combined[2] * (1.0 - cw) + cell.rgb[2] * cw,
            };
        }

        return .{
            .diffuse_rgb = combined,
            .specular_rgb = sky_ibl_rgb,
            .diffuse_confidence = @max(ssgi_confidence, probe_w * 0.5),
            .specular_confidence = 0.5,
            .ray_steps_used = self.settings.ssgi_max_steps,
        };
    }
};

fn buildModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    try app.resources.insert(HeliosService, HeliosService.init(app.allocator));
    const svc = app.resources.get(HeliosService).?;
    try app.services.register(.{
        .capability = "engine.render.helios",
        .major_version = 1,
        .provider_id = "official.render.helios",
        .owner_id = MODULE_OWNER_ID,
        .exclusive = true,
        .api_ptr = svc,
        .api_size = @sizeOf(HeliosService),
    });
}

fn stopModule(raw_app: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    _ = app.services.unregisterByOwner(MODULE_OWNER_ID);
    _ = app.resources.remove(HeliosService);
}

/// Returns the `official.render.helios` module descriptor.
pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = "official.render.helios",
            .version = "0.1.0",
            .provides_capabilities = &.{"engine.render.helios/1"},
            .required_capabilities = &.{"engine.render.prism/1"},
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
