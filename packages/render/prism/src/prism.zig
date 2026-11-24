//! Prism Modular Rendering Framework (`official.render.prism`, Stage 01 Foundation).
//!
//! Provides `PrismService` (`engine.render.prism/1`):
//! - Generational `ViewRegistry` with per-view settings, capability fallback,
//!   and temporal history invalidation.
//! - Declarative `PassGraph` with cycle detection, read-before-write checks,
//!   and deterministic topological schedule compilation.
//! - `ShaderInterfaceDesc`, `PipelineCacheKey`, and completion-aware `RetirementQueue`.
//! - Headless `RecordingBackend` for contract validation without a GPU.

const std = @import("std");
const engine = @import("engine");

pub const types = @import("core/types.zig");
pub const pass_graph = @import("core/pass_graph.zig");
pub const render_world = @import("core/render_world.zig");
pub const coordinates = @import("core/coordinates.zig");
pub const extensions = @import("core/extensions.zig");
pub const temporal = @import("features/temporal.zig");
pub const reflections = @import("features/reflections.zig");
pub const atmosphere = @import("features/atmosphere.zig");
pub const shadows = @import("passes/shadows.zig");
pub const photometry = @import("lighting/photometry.zig");
pub const baked_gi = @import("lighting/baked_gi.zig");
pub const manifest = @import("resources/manifest.zig");
pub const recording_backend = @import("resources/recording_backend.zig");

pub const LightingMode = types.LightingMode;
pub const AntiAliasingMode = types.AntiAliasingMode;
pub const RenderViewSettings = types.RenderViewSettings;
pub const RenderViewId = types.RenderViewId;
pub const BackendCapabilities = types.BackendCapabilities;
pub const EffectiveViewConfig = types.EffectiveViewConfig;
pub const FallbackReason = types.FallbackReason;
pub const ViewRegistry = types.ViewRegistry;
pub const PassGraph = pass_graph.PassGraph;
pub const PassDesc = pass_graph.PassDesc;
pub const RenderWorld = render_world.RenderWorld;
pub const RenderInstance = render_world.RenderInstance;
pub const QueueEntry = render_world.QueueEntry;
pub const DrawBatch = render_world.DrawBatch;
pub const VisibilityStats = render_world.VisibilityStats;
pub const HiZPyramid = temporal.HiZPyramid;
pub const TemporalHistoryManager = temporal.TemporalHistoryManager;
pub const ViewTemporalState = temporal.ViewTemporalState;
pub const PipelineCacheKey = manifest.PipelineCacheKey;
pub const RetirementQueue = manifest.RetirementQueue;
pub const PrismBackendVTable = recording_backend.PrismBackendVTable;
pub const RecordingBackend = recording_backend.RecordingBackend;

/// Owner ID used when registering `official.render.prism` services.
pub const MODULE_OWNER_ID: u64 = 2046;

/// Feature toggles controlling which passes are active in the default Forward+ graph.
pub const ForwardPlusGraphOptions = struct {
    enable_shadows: bool = true,
    enable_ssao: bool = true,
    enable_volumetric: bool = false,
    enable_bloom: bool = true,
};

/// Orchestrates Prism views, frame epochs, resource retirement, and pass execution (`engine.render.prism/1`).
pub const PrismService = struct {
    allocator: std.mem.Allocator,
    views: ViewRegistry,
    world: RenderWorld,
    history: TemporalHistoryManager,
    extensions: extensions.ExtensionRegistry,
    retirement: RetirementQueue,
    backend: ?PrismBackendVTable = null,
    frame_epoch: u64 = 0,
    completed_epoch: u64 = 0,

    /// Initializes `PrismService`.
    pub fn init(allocator: std.mem.Allocator) PrismService {
        return .{
            .allocator = allocator,
            .views = ViewRegistry.init(allocator),
            .world = RenderWorld.init(allocator),
            .history = TemporalHistoryManager.init(allocator),
            .extensions = extensions.ExtensionRegistry.init(allocator),
            .retirement = RetirementQueue.init(allocator),
        };
    }

    /// Flushes remaining retired resources and releases service storage.
    pub fn deinit(self: *PrismService) void {
        _ = self.retirement.flushAll();
        self.retirement.deinit();
        self.extensions.deinit();
        self.history.deinit();
        self.world.deinit();
        self.views.deinit();
    }

    /// Attaches or detaches the active `PrismBackendVTable`.
    pub fn setBackend(self: *PrismService, backend: ?PrismBackendVTable) void {
        self.backend = backend;
    }

    /// Returns capabilities reported by the active backend (or conservative headless defaults).
    pub fn capabilities(self: *const PrismService) BackendCapabilities {
        return if (self.backend) |b| b.capabilities else .{};
    }

    /// Resolves effective view settings against active backend capabilities.
    pub fn resolveView(self: *const PrismService, id: RenderViewId) !EffectiveViewConfig {
        const v = self.views.getViewConst(id) orelse return error.InvalidRenderView;
        return types.resolveViewConfig(v.settings, self.capabilities());
    }

    /// Compiles `graph` and executes its schedule for `view_id` through the active backend.
    pub fn executeGraphForView(self: *PrismService, view_id: RenderViewId, graph: *const PassGraph) !void {
        const view = self.views.getView(view_id) orelse return error.InvalidRenderView;
        var schedule = try graph.compile(self.allocator);
        defer schedule.deinit();

        self.frame_epoch += 1;
        if (self.backend) |b| {
            try b.begin_frame(b.ctx, self.frame_epoch);
            for (schedule.order) |pass_idx| {
                try b.execute_pass(b.ctx, view_id, graph.passes.items[pass_idx]);
            }
            try b.end_frame(b.ctx, self.frame_epoch);
        }

        view.frame_index += 1;
        view.history_valid = true;
    }

    /// Marks `completed_epoch` as finished on the GPU and reclaims eligible retired resources.
    pub fn notifyFrameCompleted(self: *PrismService, completed_epoch: u64) usize {
        if (completed_epoch > self.completed_epoch) {
            self.completed_epoch = completed_epoch;
        }
        return self.retirement.reclaim(self.completed_epoch);
    }
};

/// Static resource-access tables for `buildDefaultForwardPlusGraph`.
const SHADOW_ACC = [_]pass_graph.PassResourceAccess{.{ .resource = 0, .usage = .write, .load_op = .clear }};
const SSAO_ACC = [_]pass_graph.PassResourceAccess{
    .{ .resource = 1, .usage = .write, .load_op = .clear },
    .{ .resource = 2, .usage = .write, .load_op = .clear },
};
const FWD_ACC_WITH_SHADOW_SSAO = [_]pass_graph.PassResourceAccess{
    .{ .resource = 0, .usage = .read },
    .{ .resource = 2, .usage = .read },
    .{ .resource = 3, .usage = .write, .load_op = .clear },
};
const FWD_ACC_NO_AUX = [_]pass_graph.PassResourceAccess{
    .{ .resource = 3, .usage = .write, .load_op = .clear },
};
const VOL_ACC = [_]pass_graph.PassResourceAccess{
    .{ .resource = 3, .usage = .read_write },
};
const BLOOM_ACC = [_]pass_graph.PassResourceAccess{
    .{ .resource = 3, .usage = .read },
    .{ .resource = 4, .usage = .write, .load_op = .clear },
};
const POSTFX_ACC_BLOOM = [_]pass_graph.PassResourceAccess{
    .{ .resource = 3, .usage = .read },
    .{ .resource = 4, .usage = .read },
    .{ .resource = 5, .usage = .write, .load_op = .dont_care },
};
const POSTFX_ACC_NO_BLOOM = [_]pass_graph.PassResourceAccess{
    .{ .resource = 3, .usage = .read },
    .{ .resource = 5, .usage = .write, .load_op = .dont_care },
};

/// Builds the canonical Prism Forward+ pass graph (`Shadow -> SSAO -> Forward+ -> Volumetric -> Bloom -> PostFX`).
pub fn buildDefaultForwardPlusGraph(allocator: std.mem.Allocator, opts: ForwardPlusGraphOptions) !PassGraph {
    var g = PassGraph.init(allocator);
    errdefer g.deinit();

    _ = try g.declareResource(.{ .name = "shadow_atlas", .external_initial_state = !opts.enable_shadows });
    _ = try g.declareResource(.{ .name = "depth_prepass" });
    _ = try g.declareResource(.{ .name = "ssao_blur", .external_initial_state = !opts.enable_ssao });
    _ = try g.declareResource(.{ .name = "hdr_color" });
    _ = try g.declareResource(.{ .name = "bloom_mip0", .external_initial_state = !opts.enable_bloom });
    _ = try g.declareResource(.{ .name = "swapchain_color" });

    _ = try g.addPass(.{ .name = "Shadow", .scope = .light, .enabled = opts.enable_shadows, .accesses = &SHADOW_ACC });
    _ = try g.addPass(.{ .name = "SSAO", .scope = .view, .enabled = opts.enable_ssao, .accesses = &SSAO_ACC });
    _ = try g.addPass(.{
        .name = "Forward+",
        .scope = .view,
        .enabled = true,
        .accesses = if (opts.enable_shadows or opts.enable_ssao) &FWD_ACC_WITH_SHADOW_SSAO else &FWD_ACC_NO_AUX,
    });
    _ = try g.addPass(.{ .name = "Volumetric", .scope = .view, .enabled = opts.enable_volumetric, .accesses = &VOL_ACC });
    _ = try g.addPass(.{ .name = "Bloom", .scope = .view, .enabled = opts.enable_bloom, .accesses = &BLOOM_ACC });
    _ = try g.addPass(.{
        .name = "PostFX",
        .scope = .view,
        .enabled = true,
        .accesses = if (opts.enable_bloom) &POSTFX_ACC_BLOOM else &POSTFX_ACC_NO_BLOOM,
    });

    return g;
}

fn buildModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    try app.resources.insert(PrismService, PrismService.init(app.allocator));
    const svc = app.resources.get(PrismService).?;
    try app.services.register(.{
        .capability = "engine.render.prism",
        .major_version = 1,
        .provider_id = "official.render.prism",
        .owner_id = MODULE_OWNER_ID,
        .exclusive = true,
        .api_ptr = svc,
        .api_size = @sizeOf(PrismService),
    });
}

fn stopModule(raw_app: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    _ = app.services.unregisterByOwner(MODULE_OWNER_ID);
    _ = app.resources.remove(PrismService);
}

/// Returns the `official.render.prism` module descriptor.
pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = "official.render.prism",
            .version = "0.1.0",
            .provides_capabilities = &.{"engine.render.prism/1"},
            .required_capabilities = &.{},
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
