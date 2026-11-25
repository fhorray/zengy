//! PBR forward+ renderer on the neutral `graphics.gpu` contract.
//!
//! Port of the previous SDL_GPU backend, pass for pass and with the same algorithms: directional cascades, local
//! shadow atlas, clustered point/spot/rect lights, depth prepass with SSAO and contact shadows, sky, the lit pass,
//! bloom and the post-process composite. It implements `render_3d.pbr.PbrBackendVTable`, so the ECS-facing frontend
//! (materials, lights, cameras) is unchanged.

const std = @import("std");
const graphics = @import("graphics");
const render_3d = @import("render_3d");
const layout = @import("layout.zig");
const util = @import("util.zig");
const shadow_cull = @import("shadow_cull.zig");
const shadow_plan = @import("shadow_plan.zig");
const volumetric_lights = @import("volumetric_lights.zig");
const gpu_gi = @import("gpu_gi.zig");
const screen_transport = @import("screen_transport.zig");
const gpu_timing = @import("gpu_timing.zig");

/// Receiver of GPU pass timings (see `PbrRenderer.setTimingSink`).
pub const TimingSink = gpu_timing.Sink;
/// Pass groups reported through `TimingSink`.
pub const TimingCategory = gpu_timing.Category;
const gpu_objects = @import("gpu.zig");
const frame_res = @import("frame_res.zig");
const base = @import("../renderer.zig");

const gpu = graphics.gpu;
const frame = graphics.frame;
const pbr = render_3d.pbr;
const ibl = render_3d.ibl;
const cluster = render_3d.cluster;
const math3d = render_3d.math3d;
const Gpu = gpu_objects.Gpu;

const hdr_format = gpu_objects.hdr_format;
const ao_format = gpu_objects.ao_format;

/// Render target owned by the renderer, recreated when the frame size changes.
const Target = struct {
    texture: gpu.TextureHandle,
    view: gpu.TextureViewHandle,
    width: u32,
    height: u32,
};

/// In-flight environment rebuild. Stages: convert a new HDRI to half floats (only when its content changed),
/// build the equirectangular sky, prefilter one mip per step, then upload and swap everything at once.
const IblJob = struct {
    const Stage = enum { hdri_convert, sky, mips, finish };
    stage: Stage,
    sun_dir: [3]f32,
    sun_col: [3]f32,
    sun_int: f32,
    /// A directional light lights the scene analytically; its sun is left out of the diffuse SH when configured.
    analytic_sun: bool = false,
    /// Sky image without the sun, used for the diffuse SH when `analytic_sun` and the quality switch ask for it.
    sky_no_sun: ?[][4]f32 = null,
    hdri_ptr: usize,
    hdri_hash: u64,
    /// Half-float copy of a new HDRI, filled in slices and uploaded once complete.
    hdri_cpu: ?[]f16 = null,
    next_pixel: usize = 0,
    sky: ?[][4]f32 = null,
    mips: [layout.ENV_MIPS]?[][4]f32 = @splat(null),
    next_level: u32 = 1,
};

pub const PbrRenderer = struct {
    allocator: std.mem.Allocator,
    base: *base.Renderer3D,
    gpu: ?*Gpu = null,
    ring: ?frame_res.Ring = null,
    groups: ?frame_res.GroupCache = null,
    device: ?gpu.GpuDevice = null,

    // Fullscreen pass uniform bind groups over the ring.
    g_sky: gpu.BindGroupHandle = undefined,
    g_ssao: gpu.BindGroupHandle = undefined,
    g_blur: gpu.BindGroupHandle = undefined,
    g_bloom: gpu.BindGroupHandle = undefined,
    g_post: gpu.BindGroupHandle = undefined,

    // Per-draw uniform storage (dynamic offsets).
    draw_vs: DrawBuffer = .{},
    draw_fs: DrawBuffer = .{},
    shadow_vs: DrawBuffer = .{},
    mask_params: DrawBuffer = .{},
    vs_scratch: std.ArrayList(u8) = .empty,
    fs_scratch: std.ArrayList(u8) = .empty,
    shadow_scratch: std.ArrayList(u8) = .empty,
    mask_scratch: std.ArrayList(u8) = .empty,

    // Targets.
    hdr: ?Target = null,
    ssao: ?Target = null,
    ssao_blur: ?Target = null,
    bloom: [layout.BLOOM_MIPS]?Target = @splat(null),

    // Environment lighting.
    sky_sh: ibl.SkyDiffuseSH = .{},
    ibl_initialized: bool = false,
    ibl_job: ?IblJob = null,
    hdri_texture: ?Target = null,
    hdri_tex_ptr: usize = 0,
    hdri_tex_hash: u64 = 0,
    hdri_tex_w: u32 = 0,
    hdri_tex_h: u32 = 0,
    last_sun_dir: [3]f32 = .{ 0, 0, 0 },
    last_sun_col: [3]f32 = .{ 0, 0, 0 },
    last_sun_int: f32 = -1.0,
    last_sky_kind: pbr.SkyboxKind = .procedural,
    last_sky_tint: [3]f32 = .{ 0, 0, 0 },
    last_horizon_tint: [3]f32 = .{ 0, 0, 0 },
    last_ground_albedo: [3]f32 = .{ 0, 0, 0 },
    last_solid_color: [3]f32 = .{ 0, 0, 0 },
    last_atmo_thick: f32 = -1.0,
    last_hdri_ev: f32 = 0.0,
    last_hdri_ptr: usize = 0,
    last_hdri_hash: u64 = 0,
    last_hdri_rot: f32 = 0.0,
    last_sun_size: f32 = 0.0,
    last_sun_disk: pbr.SunDisk = .none,
    last_analytic_sun: bool = false,
    last_hdri_width: u32 = 0,
    last_hdri_height: u32 = 0,

    // GPU pass timing (timestamp queries); absent when the adapter does not support them.
    timing: ?gpu_timing.Timing = null,
    timing_probed: bool = false,
    timing_sink: ?gpu_timing.Sink = null,

    // Screen-space transport: metadata targets, Hi-Z pyramid and the resolved HDR image.
    screen: ?ScreenState = null,
    screen_failed: bool = false,
    screen_idle_frames: u32 = 0,
    screen_failure_size: [2]u32 = .{ 0, 0 },
    /// Set per frame: the lit pass writes the transport metadata targets.
    screen_on: bool = false,

    // Helios GPU GI: BVH snapshot, probe history and reservoirs.
    gi: gpu_gi.State = .{},

    // Volumetric fog targets and temporal history.
    vol_target: ?Target = null,
    vol_history: [2]?Target = @splat(null),
    vol_history_read: u8 = 0,
    vol_history_valid: bool = false,
    vol_history_camera_key: u64 = 0,
    vol_history_epoch: u64 = 0,
    vol_prev_view_proj: [16]f32 = @splat(0),
    vol_prev_cam: [3]f32 = .{ 0, 0, 0 },
    vol_prev_fwd: [3]f32 = .{ 0, 0, -1 },
    /// Hash of the fog parameters and light slots the temporal history was built with.
    vol_light_key: u64 = 0,
    vol_frame: u32 = 0,
    vol_sp_fader: volumetric_lights.SlotFader = .{},
    vol_pt_fader: volumetric_lights.SlotFader = .{},
    froxel_texture: ?Target = null,
    froxel_failed: bool = false,

    // Automatic exposure history (see `AutoExposureSettings`).
    exposure_history_valid: bool = false,
    exposure_frame: u32 = 0,
    exposure_camera_key: u64 = 0,
    exposure_physical_mode: bool = false,
    exposure_scale_log2: f32 = 0.0,
    exposure_history_epoch: u64 = 0,
    exposure_prev_camera: [3]f32 = .{ 0, 0, 0 },

    // Shadow caches (see `ShadowQuality.static_cache`).
    dir_cascade_cache: [4]shadow_plan.CacheKey = @splat(.{}),
    dir_atlas_valid: bool = false,
    local_tile_cache: [shadow_plan.MAX_TILES]shadow_plan.CacheKey = @splat(.{}),
    local_atlas_valid: bool = false,

    // Per-frame submission.
    queued_draws: std.ArrayList(layout.QueuedPbrDraw) = .empty,
    shadow_casters: std.ArrayList(layout.QueuedShadowCaster) = .empty,
    pending_layers: u32 = pbr.DEFAULT_LAYER,
    frame_active: bool = false,
    frame_data: pbr.ExtractedPbrFrame = .{},
    dir_lights_copy: std.ArrayList(pbr.ExtractedDirectionalLight) = .empty,
    point_lights_copy: std.ArrayList(pbr.ExtractedPointLight) = .empty,
    spot_lights_copy: std.ArrayList(pbr.ExtractedSpotLight) = .empty,
    rect_lights_copy: std.ArrayList(pbr.ExtractedRectLight) = .empty,
    reflection_probes_copy: std.ArrayList(pbr.ExtractedReflectionProbe) = .empty,

    // Reused across frames so cluster construction does not allocate in steady state.
    cluster_scratch: cluster.ClusterScratch = .{},
    cluster_lights: *layout.ClusterLightsBuffer = undefined,
    local_shadow: *layout.LocalShadowBuffer = undefined,
    draw_order: std.ArrayList(layout.DrawOrderEntry) = .empty,
    last_cluster_drops: u32 = 0,

    /// True once this renderer drew the frame; the unlit mesh pass then stays out of the way.
    rendered_this_frame: bool = false,

    const DrawBuffer = struct {
        buffer: ?gpu.BufferHandle = null,
        group: ?gpu.BindGroupHandle = null,
        capacity: u64 = 0,
    };

    pub fn init(allocator: std.mem.Allocator, r3d: *base.Renderer3D) !PbrRenderer {
        const lights = try allocator.create(layout.ClusterLightsBuffer);
        errdefer allocator.destroy(lights);
        lights.* = .{};
        const local = try allocator.create(layout.LocalShadowBuffer);
        errdefer allocator.destroy(local);
        local.* = .{};
        return .{ .allocator = allocator, .base = r3d, .cluster_lights = lights, .local_shadow = local };
    }

    pub fn deinit(self: *PbrRenderer) void {
        if (self.device) |device| self.releaseGpu(device);
        const a = self.allocator;
        self.cancelIblJob();
        self.queued_draws.deinit(a);
        self.shadow_casters.deinit(a);
        self.dir_lights_copy.deinit(a);
        self.point_lights_copy.deinit(a);
        self.spot_lights_copy.deinit(a);
        self.rect_lights_copy.deinit(a);
        self.reflection_probes_copy.deinit(a);
        self.cluster_scratch.deinit(a);
        self.draw_order.deinit(a);
        self.vs_scratch.deinit(a);
        self.fs_scratch.deinit(a);
        self.shadow_scratch.deinit(a);
        self.mask_scratch.deinit(a);
        a.destroy(self.cluster_lights);
        a.destroy(self.local_shadow);
    }

    pub fn frameRenderer(self: *PbrRenderer) frame.FrameRenderer {
        // Runs before the unlit mesh renderer so a PBR frame replaces the unlit pass.
        return .{ .name = "official.render.3d.gpu.pbr", .ctx = self, .order = frame.Order.world - 10, .render = renderThunk, .release = releaseThunk, .frame_result = frameResultThunk, .forget_texture = forgetTextureThunk };
    }

    fn renderThunk(ctx: *anyopaque, input: *frame.FrameInput) anyerror!void {
        const self: *PbrRenderer = @ptrCast(@alignCast(ctx));
        try self.render(input);
    }

    fn frameResultThunk(ctx: *anyopaque, submitted: bool) void {
        const self: *PbrRenderer = @ptrCast(@alignCast(ctx));
        if (submitted) {
            if (self.timing) |*t| t.last_recorded = null;
            return;
        }
        self.invalidateRecordedFrame();
    }

    fn invalidateRecordedFrame(self: *PbrRenderer) void {
        self.exposure_history_valid = false;
        self.vol_history_valid = false;
        self.gi.valid = false;
        self.dir_atlas_valid = false;
        self.local_atlas_valid = false;
        for (&self.dir_cascade_cache) |*key| key.invalidate();
        for (&self.local_tile_cache) |*key| key.invalidate();
        if (self.timing) |*t| t.abortRecorded();
        self.rendered_this_frame = false;
        self.base.pbr_rendered = false;
    }

    fn forgetTextureThunk(ctx: *anyopaque, _: gpu.GpuDevice, _: graphics.TextureId) void {
        const self: *PbrRenderer = @ptrCast(@alignCast(ctx));
        // Shared texture deletion happens outside frame recording.
        if (self.groups) |*groups| groups.clear();
        self.dir_atlas_valid = false;
        self.local_atlas_valid = false;
        for (&self.dir_cascade_cache) |*key| key.invalidate();
        for (&self.local_tile_cache) |*key| key.invalidate();
    }

    fn releaseThunk(ctx: *anyopaque, device: gpu.GpuDevice) void {
        const self: *PbrRenderer = @ptrCast(@alignCast(ctx));
        self.releaseGpu(device);
    }

    // --------------------------------------------------------------------------------------------
    // Backend vtable (ECS-facing frontend)
    // --------------------------------------------------------------------------------------------

    pub fn vtable(self: *PbrRenderer) pbr.PbrBackendVTable {
        return .{
            .ctx = self,
            .beginPbrFrame = beginPbrFrame,
            .submitLitMesh = submitLitMesh,
            .submitShadowCaster = submitShadowCaster,
            .setDrawLayers = setDrawLayers,
            .endPbrFrame = endPbrFrame,
        };
    }

    fn beginPbrFrame(raw: *anyopaque, data: *const pbr.ExtractedPbrFrame) anyerror!void {
        const self: *PbrRenderer = @ptrCast(@alignCast(raw));
        const a = self.allocator;
        self.queued_draws.clearRetainingCapacity();
        self.shadow_casters.clearRetainingCapacity();
        self.dir_lights_copy.clearRetainingCapacity();
        self.point_lights_copy.clearRetainingCapacity();
        self.spot_lights_copy.clearRetainingCapacity();
        self.rect_lights_copy.clearRetainingCapacity();
        self.reflection_probes_copy.clearRetainingCapacity();
        try self.dir_lights_copy.appendSlice(a, data.directional_lights);
        try self.point_lights_copy.appendSlice(a, data.point_lights);
        try self.spot_lights_copy.appendSlice(a, data.spot_lights);
        try self.rect_lights_copy.appendSlice(a, data.rect_lights);
        try self.reflection_probes_copy.appendSlice(a, data.reflection_probes);
        self.frame_data = data.*;
        self.frame_data.directional_lights = self.dir_lights_copy.items;
        self.frame_data.point_lights = self.point_lights_copy.items;
        self.frame_data.spot_lights = self.spot_lights_copy.items;
        self.frame_data.rect_lights = self.rect_lights_copy.items;
        self.frame_data.reflection_probes = self.reflection_probes_copy.items;
        self.frame_active = true;
    }

    fn submitLitMesh(raw: *anyopaque, mesh_asset: u64, model_matrix: [16]f32, mvp_matrix: [16]f32, material: pbr.StandardMaterial, tint: [4]f32) anyerror!void {
        const self: *PbrRenderer = @ptrCast(@alignCast(raw));
        try self.queued_draws.append(self.allocator, .{
            .mesh_asset = mesh_asset,
            .model_matrix = model_matrix,
            .mvp_matrix = mvp_matrix,
            .material = material,
            .tint = tint,
            .layers = self.pending_layers,
        });
        self.pending_layers = pbr.DEFAULT_LAYER;
    }

    fn setDrawLayers(raw: *anyopaque, layers: u32) void {
        const self: *PbrRenderer = @ptrCast(@alignCast(raw));
        self.pending_layers = layers;
    }

    fn submitShadowCaster(raw: *anyopaque, mesh_asset: u64, model_matrix: [16]f32) anyerror!void {
        const self: *PbrRenderer = @ptrCast(@alignCast(raw));
        try self.shadow_casters.append(self.allocator, .{ .mesh_asset = mesh_asset, .model_matrix = model_matrix, .layers = self.pending_layers });
        self.pending_layers = pbr.DEFAULT_LAYER;
    }

    fn endPbrFrame(_: *anyopaque) anyerror!void {}

    // --------------------------------------------------------------------------------------------
    // GPU lifetime
    // --------------------------------------------------------------------------------------------

    fn ensureGpu(self: *PbrRenderer, device: gpu.GpuDevice) !*Gpu {
        if (self.gpu) |g| return g;
        self.device = device;
        const g = try Gpu.init(self.allocator, device);
        errdefer g.deinit();
        var ring = try frame_res.Ring.init(self.allocator, device, 1024 * 1024);
        errdefer ring.deinit();
        const ring_entry = struct {
            fn group(gp: *Gpu, lay: gpu.BindGroupLayoutHandle, buf: gpu.BufferHandle, size: u64) !gpu.BindGroupHandle {
                return gp.newBindGroup(.{ .layout = lay, .entries = &.{.{ .binding = 0, .resource = .{ .buffer = .{ .buffer = buf, .size = size } } }} });
            }
        };
        self.g_sky = try ring_entry.group(g, g.l_u_sky, ring.buffer, @sizeOf(layout.SkyUniforms));
        self.g_ssao = try ring_entry.group(g, g.l_u_ssao, ring.buffer, @sizeOf(layout.SsaoParams));
        self.g_blur = try ring_entry.group(g, g.l_u_blur, ring.buffer, @sizeOf(layout.SsaoBlurParams));
        self.g_bloom = try ring_entry.group(g, g.l_u_bloom, ring.buffer, @sizeOf(layout.BloomParams));
        self.g_post = try ring_entry.group(g, g.l_u_post, ring.buffer, @sizeOf(layout.PostFxParams));
        self.ring = ring;
        self.groups = frame_res.GroupCache.init(self.allocator, device);
        self.gpu = g;
        return g;
    }

    fn releaseGpu(self: *PbrRenderer, device: gpu.GpuDevice) void {
        if (self.gpu == null) return;
        if (self.groups) |*g| g.deinit();
        self.groups = null;
        for ([_]*DrawBuffer{ &self.draw_vs, &self.draw_fs, &self.shadow_vs, &self.mask_params }) |db| {
            if (db.group) |g| device.destroyBindGroup(g);
            if (db.buffer) |b| device.destroyBuffer(b);
            db.* = .{};
        }
        if (self.timing) |*t| t.deinit();
        self.timing = null;
        self.timing_probed = false;
        self.destroyTargets(device);
        self.destroyScreen(device);
        self.gi.deinit(device);
        if (self.hdri_texture) |t| self.destroyTarget(device, t);
        self.hdri_texture = null;
        if (self.ring) |*r| r.deinit();
        self.ring = null;
        self.gpu.?.deinit();
        self.gpu = null;
        self.device = null;
        self.ibl_initialized = false;
    }

    fn destroyTarget(_: *PbrRenderer, device: gpu.GpuDevice, t: Target) void {
        device.destroyTextureView(t.view);
        device.destroyTexture(t.texture);
    }

    fn destroyTargets(self: *PbrRenderer, device: gpu.GpuDevice) void {
        if (self.hdr) |t| self.destroyTarget(device, t);
        if (self.ssao) |t| self.destroyTarget(device, t);
        if (self.ssao_blur) |t| self.destroyTarget(device, t);
        for (self.bloom) |b| if (b) |t| self.destroyTarget(device, t);
        self.hdr = null;
        self.ssao = null;
        self.ssao_blur = null;
        self.bloom = @splat(null);
        if (self.vol_target) |t| self.destroyTarget(device, t);
        self.vol_target = null;
        for (self.vol_history) |h| if (h) |t| self.destroyTarget(device, t);
        self.vol_history = @splat(null);
        self.vol_history_valid = false;
        if (self.froxel_texture) |t| self.destroyTarget(device, t);
        self.froxel_texture = null;
    }

    fn newTarget(device: gpu.GpuDevice, width: u32, height: u32, format: gpu.TextureFormat, label: []const u8) !Target {
        const t = try device.createTexture(.{ .label = label, .width = width, .height = height, .format = format, .usage = .{ .render_attachment = true, .texture_binding = true, .copy_src = true } });
        errdefer device.destroyTexture(t);
        const v = try device.createTextureView(.{ .texture = t });
        return .{ .texture = t, .view = v, .width = width, .height = height };
    }

    /// Recreates the HDR, SSAO and bloom targets when the frame size changes.
    fn ensureTargets(self: *PbrRenderer, device: gpu.GpuDevice, w: u32, h: u32) !void {
        if (self.hdr) |t| if (t.width == w and t.height == h) return;
        // Release references to resized resources before destroying them.
        if (self.groups) |*groups| groups.clear();
        const hdr = try newTarget(device, w, h, hdr_format, "pbr hdr");
        errdefer self.destroyTarget(device, hdr);
        const ssao = try newTarget(device, @max(w / 2, 1), @max(h / 2, 1), ao_format, "pbr ssao");
        errdefer self.destroyTarget(device, ssao);
        const blur = try newTarget(device, w, h, ao_format, "pbr ssao blur");
        errdefer self.destroyTarget(device, blur);
        var bloom: [layout.BLOOM_MIPS]?Target = @splat(null);
        errdefer {
            for (bloom) |b| if (b) |t| self.destroyTarget(device, t);
        }
        var mw = @max(w / 2, 1);
        var mh = @max(h / 2, 1);
        for (0..layout.BLOOM_MIPS) |i| {
            bloom[i] = try newTarget(device, mw, mh, hdr_format, "pbr bloom");
            mw = @max(mw / 2, 1);
            mh = @max(mh / 2, 1);
        }
        self.destroyTargets(device);
        self.hdr = hdr;
        self.ssao = ssao;
        self.ssao_blur = blur;
        self.bloom = bloom;
    }

    // --------------------------------------------------------------------------------------------
    // Environment lighting (IBL)
    // --------------------------------------------------------------------------------------------

    fn cancelIblJob(self: *PbrRenderer) void {
        const job = &(self.ibl_job orelse return);
        if (job.hdri_cpu) |p| self.allocator.free(p);
        if (job.sky) |s| self.allocator.free(s);
        if (job.sky_no_sun) |s| self.allocator.free(s);
        for (job.mips) |m| if (m) |mm| self.allocator.free(mm);
        self.ibl_job = null;
    }

    fn startIblJob(self: *PbrRenderer, sun_dir: [3]f32, sun_col: [3]f32, sun_int: f32, hdri_ptr: usize, hdri_hash: u64) !void {
        self.cancelIblJob();
        const sky = self.frame_data.sky;
        var job = IblJob{
            .stage = .sky,
            .sun_dir = sun_dir,
            .sun_col = sun_col,
            .sun_int = sun_int,
            .analytic_sun = self.frame_data.directional_lights.len > 0 and !self.frame_data.post_process.quality.sun_in_ibl_diffuse,
            .hdri_ptr = hdri_ptr,
            .hdri_hash = hdri_hash,
        };
        const has_hdri = sky.kind == .hdri and sky.hdri_pixels != null and sky.hdri_width > 0 and sky.hdri_height > 0;
        if (has_hdri) {
            const resident = self.hdri_texture != null and self.hdri_tex_ptr == hdri_ptr and self.hdri_tex_hash == hdri_hash and
                self.hdri_tex_w == sky.hdri_width and self.hdri_tex_h == sky.hdri_height;
            if (!resident) {
                const px_count: usize = @as(usize, sky.hdri_width) * @as(usize, sky.hdri_height);
                job.hdri_cpu = try self.allocator.alloc(f16, px_count * 4);
                job.stage = .hdri_convert;
            }
        }
        self.ibl_job = job;
    }

    fn advanceIblJob(self: *PbrRenderer, device: gpu.GpuDevice, g: *Gpu, budget: pbr.IblRebuildBudget) !void {
        while (self.ibl_job != null) {
            self.stepIblJob(device, g, budget) catch |err| {
                self.cancelIblJob();
                self.ibl_initialized = false; // Retry instead of accepting an incomplete environment.
                return err;
            };
            if (budget == .sliced) return;
        }
    }

    fn uploadHalfLevel(g: *Gpu, image: Gpu.Image, level: u32, w: u32, h: u32, pixels: []const [4]f32) !void {
        const allocator = g.allocator;
        const halves = try allocator.alloc(f16, pixels.len * 4);
        defer allocator.free(halves);
        for (pixels, 0..) |px, k| {
            halves[k * 4 + 0] = util.clampToF16(px[0]);
            halves[k * 4 + 1] = util.clampToF16(px[1]);
            halves[k * 4 + 2] = util.clampToF16(px[2]);
            halves[k * 4 + 3] = util.clampToF16(px[3]);
        }
        try g.upload(image, level, w, h, std.mem.sliceAsBytes(halves), 8);
    }

    fn stepIblJob(self: *PbrRenderer, device: gpu.GpuDevice, g: *Gpu, budget: pbr.IblRebuildBudget) !void {
        const job = &self.ibl_job.?;
        const sky_cfg = self.frame_data.sky;
        switch (job.stage) {
            .hdri_convert => {
                const hp = sky_cfg.hdri_pixels.?;
                const total: usize = @as(usize, sky_cfg.hdri_width) * @as(usize, sky_cfg.hdri_height);
                const end = if (budget == .sliced) @min(job.next_pixel + layout.HDRI_PIXELS_PER_SLICE, total) else total;
                const dst = job.hdri_cpu.?;
                for (job.next_pixel..end) |k| {
                    dst[k * 4 + 0] = util.clampToF16(hp[k][0]);
                    dst[k * 4 + 1] = util.clampToF16(hp[k][1]);
                    dst[k * 4 + 2] = util.clampToF16(hp[k][2]);
                    dst[k * 4 + 3] = util.clampToF16(hp[k][3]);
                }
                job.next_pixel = end;
                if (end < total) return;
                job.stage = .sky;
            },
            .sky => {
                const has_hdri = sky_cfg.kind == .hdri and sky_cfg.hdri_pixels != null and sky_cfg.hdri_width > 0 and sky_cfg.hdri_height > 0;
                const sky_f32: [][4]f32 = if (has_hdri) blk: {
                    const ds = try ibl.downsampleEquirectRgba32f(self.allocator, sky_cfg.hdri_pixels.?, sky_cfg.hdri_width, sky_cfg.hdri_height, layout.ENV_W, layout.ENV_H);
                    errdefer self.allocator.free(ds);
                    // Same rotation as the sky shader, so reflections and the visible sky agree.
                    try ibl.rotateEquirectColumns(self.allocator, ds, layout.ENV_W, layout.ENV_H, sky_cfg.hdri_rotation_rad / (2.0 * std.math.pi));
                    const ev_scale = std.math.pow(f32, 2.0, sky_cfg.hdri_exposure_ev);
                    if (@abs(ev_scale - 1.0) > 1e-4) {
                        for (ds) |*px_val| {
                            px_val[0] *= ev_scale;
                            px_val[1] *= ev_scale;
                            px_val[2] *= ev_scale;
                        }
                    }
                    break :blk ds;
                } else try ibl.generateProceduralEquirectSky(self.allocator, sky_cfg, job.sun_dir, job.sun_col, job.sun_int, layout.ENV_W, layout.ENV_H);
                job.sky = sky_f32;
                if (job.analytic_sun and !has_hdri and sky_cfg.sun_disk != .none) {
                    job.sky_no_sun = try ibl.generateProceduralEquirectSky(self.allocator, sky_cfg, job.sun_dir, job.sun_col, 0.0, layout.ENV_W, layout.ENV_H);
                }
                job.mips[0] = try self.allocator.dupe([4]f32, sky_f32);
                job.next_level = 1;
                job.stage = .mips;
            },
            .mips => {
                const sky_f32 = job.sky.?;
                // One level per step; for `.unlimited` the caller loops until the job finishes.
                job.mips[job.next_level] = try ibl.buildPrefilteredEnvMipLevel(self.allocator, sky_f32, layout.ENV_W, layout.ENV_H, layout.ENV_MIPS, job.next_level);
                job.next_level += 1;
                if (job.next_level >= layout.ENV_MIPS) job.stage = .finish;
            },
            .finish => {
                var mw: u32 = layout.ENV_W;
                var mh: u32 = layout.ENV_H;
                for (0..layout.ENV_MIPS) |lvl| {
                    try uploadHalfLevel(g, g.env_prefilter, @intCast(lvl), mw, mh, job.mips[lvl].?);
                    mw = @max(mw / 2, 1);
                    mh = @max(mh / 2, 1);
                }
                // Swap: diffuse SH, prefiltered mips and (if converted) the sky texture change in the same frame.
                self.sky_sh = ibl.projectSkyDiffuse(job.sky_no_sun orelse job.sky.?, layout.ENV_W, layout.ENV_H);
                if (job.hdri_cpu) |pixels| {
                    const image = try device.createTexture(.{ .label = "hdri sky", .width = sky_cfg.hdri_width, .height = sky_cfg.hdri_height, .format = .rgba16_float, .usage = .{ .texture_binding = true, .copy_dst = true } });
                    errdefer device.destroyTexture(image);
                    const view = try device.createTextureView(.{ .texture = image });
                    try device.writeTexture(.{ .texture = image }, std.mem.sliceAsBytes(pixels), .{ .bytes_per_row = sky_cfg.hdri_width * 8, .rows_per_image = sky_cfg.hdri_height }, .{ .width = sky_cfg.hdri_width, .height = sky_cfg.hdri_height });
                    if (self.hdri_texture) |old| self.destroyTarget(device, old);
                    self.hdri_texture = .{ .texture = image, .view = view, .width = sky_cfg.hdri_width, .height = sky_cfg.hdri_height };
                    self.hdri_tex_ptr = job.hdri_ptr;
                    self.hdri_tex_hash = job.hdri_hash;
                    self.hdri_tex_w = sky_cfg.hdri_width;
                    self.hdri_tex_h = sky_cfg.hdri_height;
                }
                self.cancelIblJob();
            },
        }
    }

    // --------------------------------------------------------------------------------------------
    // Per-draw uniform storage
    // --------------------------------------------------------------------------------------------

    /// Grows a dynamic-offset uniform buffer (and its bind group) to hold `bytes`.
    fn ensureDrawBuffer(self: *PbrRenderer, g: *Gpu, db: *DrawBuffer, lay: gpu.BindGroupLayoutHandle, bind_size: u64, bytes: usize, label: []const u8) !void {
        const needed: u64 = @max(bytes, 256);
        if (db.buffer != null and db.capacity >= needed) return;
        var capacity: u64 = @max(db.capacity, 16 * 1024);
        const device = self.device.?;
        const limit = device.capabilities().limits.max_buffer_size;
        if (needed > limit) return error.DrawBufferTooLarge;
        while (capacity < needed) capacity = @min(capacity *| 2, limit);
        capacity = @min(capacity, limit);
        const buffer = try device.createBuffer(.{ .label = label, .size = capacity, .usage = .{ .uniform = true, .copy_dst = true } });
        errdefer device.destroyBuffer(buffer);
        const group = try device.createBindGroup(.{ .layout = lay, .entries = &.{.{ .binding = 0, .resource = .{ .buffer = .{ .buffer = buffer, .size = bind_size } } }} });
        _ = g;
        if (db.group) |old| device.destroyBindGroup(old);
        if (db.buffer) |old| device.destroyBuffer(old);
        db.buffer = buffer;
        db.group = group;
        db.capacity = capacity;
    }

    fn pushSlot(list: *std.ArrayList(u8), allocator: std.mem.Allocator, stride: u32, bytes: []const u8) !u32 {
        const offset: u32 = @intCast(list.items.len);
        try list.resize(allocator, offset + stride);
        @memset(list.items[offset..][0..stride], 0);
        @memcpy(list.items[offset..][0..bytes.len], bytes);
        return offset;
    }

    fn flushScratch(self: *PbrRenderer, g: *Gpu, db: *DrawBuffer, list: *std.ArrayList(u8), lay: gpu.BindGroupLayoutHandle, bind_size: u64, label: []const u8) !void {
        if (list.items.len == 0) return;
        try self.ensureDrawBuffer(g, db, lay, bind_size, list.items.len, label);
        try self.device.?.writeBuffer(db.buffer.?, 0, list.items);
    }

    // --------------------------------------------------------------------------------------------
    // Frame
    // --------------------------------------------------------------------------------------------

    const ShadowKind = layout.ShadowDrawKind;

    /// Depth-only draws: shadow cascades/tiles (`.light`) or the camera depth prepass (`.depth_prepass`).
    fn drawShadowQueue(
        self: *PbrRenderer,
        g: *Gpu,
        rec: *gpu.CommandRecorder,
        store: *const graphics.textures.TextureStore,
        kind: ShadowKind,
        light_vp: math3d.Mat4,
        light_layers: u32,
        sl: u32,
        sm: u32,
    ) !void {
        var active: ?gpu.RenderPipelineHandle = null;
        const groups = &self.groups.?;
        for (self.queued_draws.items) |qm| {
            // Transparent surfaces must not write depth in the prepass, or SSAO and contact shadows treat them as solid.
            if (kind == .depth_prepass and qm.material.alpha_mode == .blend) continue;
            // Only meshes that share a layer with the light cast into its map (the prepass draws everything).
            if (kind == .light and !pbr.layersOverlap(light_layers, qm.layers)) continue;
            const mesh = self.base.meshes.get(@bitCast(qm.mesh_asset)) orelse continue;
            // Casters fully outside this light's frustum cannot put a shadow inside it.
            if (kind == .light and shadow_cull.sphereOutsideLightFrustum(light_vp.m, shadow_cull.transformSphere(qm.model_matrix, mesh.bounds))) continue;
            const mat = qm.material;
            const pipe = if (mat.alpha_mode == .mask)
                (if (mat.double_sided) g.shadow_mask_double_sided else g.shadow_mask)
            else
                (if (mat.double_sided) g.shadow_double_sided else g.shadow_opaque);
            if (active == null or !active.?.eql(pipe)) {
                try rec.setRenderPipeline(pipe);
                active = pipe;
            }
            if (mat.alpha_mode == .mask) {
                const base_entry = store.get(mat.base_color_tex);
                const base_view = if (base_entry) |e| e.view else g.white.view;
                const group = try groups.get(frame_res.key(&.{ 0x6d61, frame_res.bits(base_view) }), .{ .layout = g.l_mask_tex, .entries = &.{
                    .{ .binding = 0, .resource = .{ .texture_view = base_view } },
                    .{ .binding = 32, .resource = .{ .sampler = g.material } },
                } });
                try rec.setBindGroup(2, group, &.{});
                // Same alpha inputs as pbr.frag (base color * tint, texture alpha) so casters match what is shaded.
                const params = layout.ShadowMaskParams{
                    .base_color = .{ mat.base_color[0] * qm.tint[0], mat.base_color[1] * qm.tint[1], mat.base_color[2] * qm.tint[2], mat.base_color[3] * qm.tint[3] },
                    .params = .{ mat.alpha_cutoff, 0, 0, 0 },
                };
                const mask_offset = try pushSlot(&self.mask_scratch, self.allocator, sm, std.mem.asBytes(&params));
                try rec.setBindGroup(3, self.mask_group(), &.{mask_offset});
            }
            const mvp: [16]f32 = switch (kind) {
                .light => math3d.Mat4.mul(light_vp, .{ .m = qm.model_matrix }).m,
                .depth_prepass => qm.mvp_matrix,
            };
            const offset = try pushSlot(&self.shadow_scratch, self.allocator, sl, std.mem.asBytes(&mvp));
            try rec.setBindGroup(1, self.shadow_group(), &.{offset});
            try rec.setVertexBuffer(0, mesh.vertex_buffer, 0, 0);
            try rec.setIndexBuffer(mesh.index_buffer, .uint32, 0, 0);
            try rec.drawIndexed(mesh.index_count, 1, 0, 0, 0);
        }
        if (kind != .light) return;

        for (self.shadow_casters.items) |sc| {
            if (!pbr.layersOverlap(light_layers, sc.layers)) continue;
            const mesh = self.base.meshes.get(@bitCast(sc.mesh_asset)) orelse continue;
            if (shadow_cull.sphereOutsideLightFrustum(light_vp.m, shadow_cull.transformSphere(sc.model_matrix, mesh.bounds))) continue;
            // Casters carry no material, so they always use the opaque, back-face-culled pipeline.
            if (active == null or !active.?.eql(g.shadow_opaque)) {
                try rec.setRenderPipeline(g.shadow_opaque);
                active = g.shadow_opaque;
            }
            const lmvp = math3d.Mat4.mul(light_vp, .{ .m = sc.model_matrix });
            const offset = try pushSlot(&self.shadow_scratch, self.allocator, sl, std.mem.asBytes(&lmvp.m));
            try rec.setBindGroup(1, self.shadow_group(), &.{offset});
            try rec.setVertexBuffer(0, mesh.vertex_buffer, 0, 0);
            try rec.setIndexBuffer(mesh.index_buffer, .uint32, 0, 0);
            try rec.drawIndexed(mesh.index_count, 1, 0, 0, 0);
        }
    }

    /// The shadow/mask uniform buffers are written once per frame after recording, but the bind groups they live
    /// in must exist while recording: reserve generous capacity up front so the handles stay stable.
    fn shadow_group(self: *PbrRenderer) gpu.BindGroupHandle {
        return self.shadow_vs.group.?;
    }

    fn mask_group(self: *PbrRenderer) gpu.BindGroupHandle {
        return self.mask_params.group.?;
    }

    /// Routes GPU pass timings (available two to three frames after recording) to `sink`; null disables reporting.
    pub fn setTimingSink(self: *PbrRenderer, sink: ?gpu_timing.Sink) void {
        self.timing_sink = sink;
    }

    pub fn render(self: *PbrRenderer, input: *frame.FrameInput) !void {
        defer {
            self.queued_draws.clearRetainingCapacity();
            self.shadow_casters.clearRetainingCapacity();
            self.frame_active = false;
        }
        self.rendered_this_frame = false;
        if (!self.frame_active) return;
        const device = input.device;
        const g = try self.ensureGpu(device);
        const rec = input.recorder;

        // Timestamp spans are injected into the passes recorded below, then resolved for async readback.
        if (!self.timing_probed and self.timing_sink != null) {
            self.timing_probed = true;
            self.timing = gpu_timing.Timing.init(device);
        }
        const first_command = rec.commands.items.len;
        const frame_ns: u64 = if (std.math.isFinite(self.frame_data.dt) and self.frame_data.dt > 0) @intFromFloat(@as(f64, self.frame_data.dt) * 1e9) else 0;
        if (self.timing) |*t| t.beginFrame(self.timing_sink, frame_ns);
        errdefer self.invalidateRecordedFrame();
        // Stamp only after successful recording and uploads. See frame_result for submit failures.
        const tex_w = input.target.width;
        const tex_h = input.target.height;
        try self.ensureTargets(device, tex_w, tex_h);
        self.groups.?.trim();
        self.ring.?.reset();
        self.vs_scratch.clearRetainingCapacity();
        self.fs_scratch.clearRetainingCapacity();
        self.shadow_scratch.clearRetainingCapacity();
        self.mask_scratch.clearRetainingCapacity();
        const ring = &self.ring.?;
        const groups = &self.groups.?;
        const depth_view = try self.base.ensureDepth(device, tex_w, tex_h);

        const hdr = self.hdr.?;
        const pp = self.frame_data.post_process;
        const physical_cfg = pp.auto_exposure.physical;
        const pre_log2: f32 = if (physical_cfg.enabled and std.math.isFinite(physical_cfg.pre_exposure_stops))
            std.math.clamp(physical_cfg.pre_exposure_stops, -12.0, 12.0)
        else
            0.0;
        const pre_gain = @exp2(pre_log2);

        // Screen-space transport needs the four-target lit pass and an adapter that can hold it.
        const st_cfg = pp.quality.screen_transport;
        const screen_requested = (st_cfg.ssr_strength > 0 or st_cfg.ssgi_strength > 0) and
            (!self.frame_data.fog.enabled or self.frame_data.fog.volumetric.enabled);
        if (!screen_requested) {
            self.screen_failed = false;
            self.screen_idle_frames +|= 1;
            if (self.screen_idle_frames >= 120 and self.screen != null) {
                self.groups.?.clear();
                self.destroyScreen(device);
            }
        } else self.screen_idle_frames = 0;
        if (self.screen_failure_size[0] != tex_w or self.screen_failure_size[1] != tex_h) self.screen_failed = false;
        self.screen_on = screen_requested and !self.screen_failed;
        if (self.screen_on) {
            if (!g.supportsScreenTransport()) {
                self.screen_failed = true;
                self.screen_on = false;
                std.debug.print("[pbr] screen transport needs {d} colour bytes per sample; using the legacy indirect lighting\n", .{Gpu.screen_color_bytes});
            } else if (self.ensureScreen(device, tex_w, tex_h)) |_| {
                _ = g.ensureScreen(ring.buffer) catch |err| {
                    self.screen_failed = true;
                    self.screen_on = false;
                    std.debug.print("[pbr] screen transport unavailable ({s}); using the legacy indirect lighting\n", .{@errorName(err)});
                };
            } else |err| {
                self.screen_failed = true;
                self.screen_on = false;
                std.debug.print("[pbr] screen transport unavailable ({s}); using the legacy indirect lighting\n", .{@errorName(err)});
            }
        }
        if (self.screen_failed) {
            self.screen_failure_size = .{ tex_w, tex_h };
            if (self.screen != null) {
                self.groups.?.clear();
                self.destroyScreen(device);
            }
        }
        const fog = self.frame_data.fog;
        const volumetric_active = fog.enabled and fog.volumetric.enabled and
            (fog.density > 0.0 or (!fog.volumetric.physical_scattering and fog.volumetric.scattering > 0.0));

        const dirs = self.frame_data.directional_lights;
        const sun_dir: [3]f32 = if (dirs.len > 0) .{ -dirs[0].direction[0], -dirs[0].direction[1], -dirs[0].direction[2] } else .{ 0.4, 0.8, 0.45 };
        const sun_col: [3]f32 = if (dirs.len > 0) dirs[0].color else .{ 1.0, 0.96, 0.90 };
        const sun_int: f32 = if (dirs.len > 0) dirs[0].illuminance_lux / 10_000.0 else 1.0;

        // 0. Rebuild the equirectangular IBL + SH9 when sun, sky or HDRI change.
        const sky_cfg = self.frame_data.sky;
        const hdri_ptr: usize = if (sky_cfg.hdri_pixels) |px| @intFromPtr(px.ptr) else 0;
        const hdri_hash = util.hdriSampleHash(sky_cfg.hdri_pixels);
        const dsun = @abs(sun_dir[0] - self.last_sun_dir[0]) + @abs(sun_dir[1] - self.last_sun_dir[1]) + @abs(sun_dir[2] - self.last_sun_dir[2]);
        const sun_moved_enough = (sky_cfg.kind == .procedural) and (dsun > 0.15 or !std.mem.eql(f32, &self.last_sun_col, &sun_col) or @abs(sun_int - self.last_sun_int) > 0.15);
        const analytic_sun = dirs.len > 0 and !pp.quality.sun_in_ibl_diffuse;
        const sky_changed = !self.ibl_initialized or
            self.last_analytic_sun != analytic_sun or
            self.last_hdri_width != sky_cfg.hdri_width or
            self.last_hdri_height != sky_cfg.hdri_height or
            sun_moved_enough or
            self.last_sky_kind != sky_cfg.kind or
            !std.mem.eql(f32, &self.last_sky_tint, &sky_cfg.sky_tint) or
            !std.mem.eql(f32, &self.last_horizon_tint, &sky_cfg.horizon_tint) or
            !std.mem.eql(f32, &self.last_ground_albedo, &sky_cfg.ground_albedo) or
            !std.mem.eql(f32, &self.last_solid_color, &sky_cfg.solid_color) or
            self.last_atmo_thick != sky_cfg.atmosphere_thickness or
            self.last_hdri_ev != sky_cfg.hdri_exposure_ev or
            hdri_ptr != self.last_hdri_ptr or
            hdri_hash != self.last_hdri_hash or
            self.last_hdri_rot != sky_cfg.hdri_rotation_rad or
            self.last_sun_size != sky_cfg.sun_size or
            self.last_sun_disk != sky_cfg.sun_disk;
        if (sky_changed) {
            // The very first build is always synchronous: there is no previous environment to keep showing.
            const first_build = !self.ibl_initialized;
            self.startIblJob(sun_dir, sun_col, sun_int, hdri_ptr, hdri_hash) catch |err| {
                self.ibl_initialized = false;
                return err;
            };
            if (first_build) try self.advanceIblJob(device, g, .unlimited);
            self.last_sun_dir = sun_dir;
            self.last_sun_col = sun_col;
            self.last_sun_int = sun_int;
            self.last_sky_kind = sky_cfg.kind;
            self.last_sky_tint = sky_cfg.sky_tint;
            self.last_horizon_tint = sky_cfg.horizon_tint;
            self.last_ground_albedo = sky_cfg.ground_albedo;
            self.last_solid_color = sky_cfg.solid_color;
            self.last_atmo_thick = sky_cfg.atmosphere_thickness;
            self.last_hdri_ev = sky_cfg.hdri_exposure_ev;
            self.last_hdri_ptr = hdri_ptr;
            self.last_hdri_hash = hdri_hash;
            self.last_hdri_rot = sky_cfg.hdri_rotation_rad;
            self.last_sun_size = sky_cfg.sun_size;
            self.last_sun_disk = sky_cfg.sun_disk;
            self.last_analytic_sun = analytic_sun;
            self.last_hdri_width = sky_cfg.hdri_width;
            self.last_hdri_height = sky_cfg.hdri_height;
            self.ibl_initialized = true;
        }
        try self.advanceIblJob(device, g, pp.quality.ibl_rebuild_budget);

        // Uniform storage for the depth-only passes must exist while recording (bind groups are created up front).
        const shadow_slot = gpu_objects.slotSize(device, 64);
        const mask_slot = gpu_objects.slotSize(device, @sizeOf(layout.ShadowMaskParams));
        const max_shadow_draws = (self.queued_draws.items.len + self.shadow_casters.items.len + 1) * (4 + shadow_plan.MAX_TILES + 2) + 64;
        try self.ensureDrawBuffer(g, &self.shadow_vs, g.l_vs_shadow, 64, max_shadow_draws * shadow_slot, "shadow vs uniforms");
        try self.ensureDrawBuffer(g, &self.mask_params, g.l_mask_params, @sizeOf(layout.ShadowMaskParams), max_shadow_draws * mask_slot, "shadow mask uniforms");

        // 1. Four-cascade directional shadow atlas (2x2 quadrants).
        var light_vps: [4]math3d.Mat4 = @splat(math3d.Mat4.identity());
        var cascade_splits: [4]f32 = .{ 10.0, 23.0, 52.0, 120.0 };
        var cascade_depth_ranges: [4]f32 = .{ 80.0, 100.0, 140.0, 220.0 };
        var cascade_texel_world: [4]f32 = @splat(0.0);
        var cascade_overlap: f32 = 0.18;
        var shadows_enabled: f32 = 0.0;
        var cascade_count: f32 = 0.0;
        var shadow_bias: f32 = 0.005;
        var normal_offset_texels: f32 = 0.0;
        const sun_layers: u32 = if (dirs.len > 0) dirs[0].layers else pbr.ALL_LAYERS;
        const shadow_q = pp.quality.shadows;
        if (dirs.len > 0 and dirs[0].shadows_enabled) {
            const dl = dirs[0];
            shadows_enabled = 1.0;
            shadow_bias = dl.shadow_depth_bias;
            if (shadow_q.normal_offset) normal_offset_texels = dl.shadow_normal_bias * 50.0;
            cascade_splits = dl.cascade_bounds;
            cascade_overlap = dl.overlap_proportion;
            const ldir = math3d.Vec3.normalize(.{ .x = dl.direction[0], .y = dl.direction[1], .z = dl.direction[2] });
            const cam_p = math3d.Vec3{ .x = self.frame_data.camera_position[0], .y = self.frame_data.camera_position[1], .z = self.frame_data.camera_position[2] };
            const cam_f = math3d.Vec3.normalize(.{ .x = self.frame_data.camera_forward[0], .y = self.frame_data.camera_forward[1], .z = self.frame_data.camera_forward[2] });
            const half_w: f32 = @floatFromInt(layout.SHADOW_W / 2);
            const half_h: f32 = @floatFromInt(layout.SHADOW_H / 2);
            var prev_b: f32 = dl.minimum_distance;
            const active_cascades: usize = @min(dl.cascade_count, 4);
            cascade_count = @floatFromInt(active_cascades);
            for (0..active_cascades) |ci| {
                const far_b = cascade_splits[ci];
                const center_d = (prev_b + far_b) * 0.5;
                const center = math3d.Vec3{ .x = cam_p.x + cam_f.x * center_d, .y = cam_p.y + cam_f.y * center_d, .z = cam_p.z + cam_f.z * center_d };
                const half_ext = @max(far_b * 1.25, 12.0);
                const d_range = @max(far_b * 2.5, 100.0);
                cascade_depth_ranges[ci] = d_range;
                cascade_texel_world[ci] = 2.0 * half_ext / half_w;
                light_vps[ci] = util.computeCascadeMatrix(ldir, center, half_ext, half_w, d_range);
                prev_b = far_b;
            }

            // Cached cascades are reused only while the casters that reach them and their matrices are unchanged.
            const cache_on = shadow_q.static_cache;
            var cascade_miss: [4]bool = @splat(true);
            var any_miss = false;
            for (0..active_cascades) |ci| {
                if (cache_on) {
                    const key = self.shadowMapKey(light_vps[ci], sun_layers, &.{ @floatFromInt(ci), cascade_count });
                    cascade_miss[ci] = !self.dir_cascade_cache[ci].hit(key, true);
                } else {
                    self.dir_cascade_cache[ci].invalidate();
                    cascade_miss[ci] = true;
                }
                any_miss = any_miss or cascade_miss[ci];
            }
            for (active_cascades..4) |ci| self.dir_cascade_cache[ci].invalidate();
            if (any_miss) {
                // Without the cache every cascade is redrawn into a cleared atlas. With it, an atlas that already
                // holds valid content is kept and only the missed quadrants are reset and redrawn.
                const keep = cache_on and self.dir_atlas_valid;
                try rec.beginRenderPass(.{ .label = "shadow cascades", .depth = .{ .view = g.shadow_atlas.view, .depth_load = if (keep) .load else .clear } });
                try rec.setBindGroup(0, g.empty_group, &.{});
                for (0..active_cascades) |ci| {
                    if (!cascade_miss[ci]) continue;
                    const qx: u32 = @intCast((ci & 1) * (layout.SHADOW_W / 2));
                    const qy: u32 = @intCast((ci >> 1) * (layout.SHADOW_H / 2));
                    try rec.setViewport(@floatFromInt(qx), @floatFromInt(qy), half_w, half_h);
                    try rec.setScissor(qx, qy, layout.SHADOW_W / 2, layout.SHADOW_H / 2);
                    if (keep) {
                        try rec.setRenderPipeline(g.depth_clear);
                        try rec.draw(3, 1, 0, 0);
                    }
                    try self.drawShadowQueue(g, rec, input.textures, .light, light_vps[ci], sun_layers, shadow_slot, mask_slot);
                }
                try rec.endRenderPass();
            }
            self.dir_atlas_valid = cache_on;
        } else {
            for (&self.dir_cascade_cache) |*k| k.invalidate();
            self.dir_atlas_valid = false;
        }

        // 1.2 Local shadow atlas (4x4 tiles) + clustered forward+ light/probe buffers.
        const cl_lights = self.cluster_lights;
        cl_lights.* = .{};
        cl_lights.gi = self.frame_data.dynamic_gi;
        const local_sh = self.local_shadow;
        local_sh.* = .{};
        const pt_count = @min(self.frame_data.point_lights.len, 256);
        const sp_count = @min(self.frame_data.spot_lights.len, 256);
        const splan = shadow_plan.plan(
            self.frame_data.point_lights[0..pt_count],
            self.frame_data.spot_lights[0..sp_count],
            self.frame_data.camera_position,
            .{ .prioritize = shadow_q.prioritize_local_lights, .adaptive = shadow_q.adaptive_atlas },
        );
        const next_tile: u32 = splan.tile_count;
        var tile_layers: [shadow_plan.MAX_TILES]u32 = @splat(pbr.ALL_LAYERS);
        const atlas_f: f32 = @floatFromInt(shadow_plan.ATLAS);
        for (0..next_tile) |t| {
            const r = splan.tiles[t];
            local_sh.atlas_rect[t] = .{
                @as(f32, @floatFromInt(r.x)) / atlas_f,
                @as(f32, @floatFromInt(r.y)) / atlas_f,
                @as(f32, @floatFromInt(r.size)) / atlas_f,
                @as(f32, @floatFromInt(r.size)) / atlas_f,
            };
        }

        for (0..pt_count) |i| {
            const pl = self.frame_data.point_lights[i];
            const sc = pl.intensity_lumens / 100.0;
            var tile_id: f32 = -1.0;
            const asg = splan.point[i];
            if (asg.first_tile >= 0) {
                const first: usize = @intCast(asg.first_tile);
                tile_id = @floatFromInt(first);
                const cube_dirs = [6]math3d.Vec3{
                    .{ .x = 1, .y = 0, .z = 0 }, .{ .x = -1, .y = 0, .z = 0 },
                    .{ .x = 0, .y = 1, .z = 0 }, .{ .x = 0, .y = -1, .z = 0 },
                    .{ .x = 0, .y = 0, .z = 1 }, .{ .x = 0, .y = 0, .z = -1 },
                };
                const ups = [6]math3d.Vec3{
                    .{ .x = 0, .y = 1, .z = 0 },  .{ .x = 0, .y = 1, .z = 0 },
                    .{ .x = 0, .y = 0, .z = -1 }, .{ .x = 0, .y = 0, .z = 1 },
                    .{ .x = 0, .y = 1, .z = 0 },  .{ .x = 0, .y = 1, .z = 0 },
                };
                // Slightly >90 deg FOV (92 deg) gives an 8-texel overlap margin that removes 45-degree cubemap seams.
                const p_proj = util.perspectiveMat(std.math.pi * 0.512, 1.0, 0.1, @max(pl.range, 1.0));
                const eye = math3d.Vec3{ .x = pl.position[0], .y = pl.position[1], .z = pl.position[2] };
                for (0..6) |f| {
                    const tgt = math3d.Vec3{ .x = eye.x + cube_dirs[f].x, .y = eye.y + cube_dirs[f].y, .z = eye.z + cube_dirs[f].z };
                    local_sh.shadow_vp[first + f] = math3d.Mat4.mul(p_proj, math3d.Mat4.lookAt(eye, tgt, ups[f])).m;
                    tile_layers[first + f] = pl.layers;
                    local_sh.info[first + f] = .{ @tan(std.math.pi * 0.256), 0.1, @max(pl.range, 1.0), 0 };
                }
            }
            cl_lights.points[i] = .{
                .pos_range = .{ pl.position[0], pl.position[1], pl.position[2], pl.range },
                .col_radius = .{ pl.color[0] * sc, pl.color[1] * sc, pl.color[2] * sc, tile_id },
                .shadow_params = .{ pl.radius, @floatFromInt(pl.layers & pbr.ALL_LAYERS), pl.specular_scale, 0 },
            };
        }

        for (0..sp_count) |i| {
            const sl = self.frame_data.spot_lights[i];
            const sc = sl.intensity_lumens / 100.0;
            var tile_id: f32 = -1.0;
            const asg = splan.spot[i];
            if (asg.first_tile >= 0) {
                const tile: usize = @intCast(asg.first_tile);
                tile_id = @floatFromInt(tile);
                const eye = math3d.Vec3{ .x = sl.position[0], .y = sl.position[1], .z = sl.position[2] };
                const dir = math3d.Vec3.normalize(.{ .x = sl.direction[0], .y = sl.direction[1], .z = sl.direction[2] });
                const up = math3d.Vec3{ .x = 0, .y = if (@abs(dir.y) > 0.95) 0.0 else 1.0, .z = if (@abs(dir.y) > 0.95) 1.0 else 0.0 };
                const tgt = math3d.Vec3{ .x = eye.x + dir.x, .y = eye.y + dir.y, .z = eye.z + dir.z };
                const spot_fov = std.math.clamp(sl.outer_angle_rad * 2.0, 0.2, std.math.pi * 0.9);
                const s_proj = util.perspectiveMat(spot_fov, 1.0, 0.1, @max(sl.range, 1.0));
                local_sh.shadow_vp[tile] = math3d.Mat4.mul(s_proj, math3d.Mat4.lookAt(eye, tgt, up)).m;
                tile_layers[tile] = sl.layers;
                local_sh.info[tile] = .{ @tan(spot_fov * 0.5), 0.1, @max(sl.range, 1.0), 0 };
            }
            cl_lights.spots[i] = .{
                .pos_range = .{ sl.position[0], sl.position[1], sl.position[2], sl.range },
                .dir_cos_inner = .{ sl.direction[0], sl.direction[1], sl.direction[2], @cos(sl.inner_angle_rad) },
                .col_cos_outer = .{ sl.color[0] * sc, sl.color[1] * sc, sl.color[2] * sc, @cos(sl.outer_angle_rad) },
                .shadow_params = .{ tile_id, sl.shadow_depth_bias, sl.radius, @floatFromInt(sl.layers & pbr.ALL_LAYERS) },
            };
        }

        const rc_count = @min(self.frame_data.rect_lights.len, 64);
        for (0..rc_count) |i| {
            const rl = self.frame_data.rect_lights[i];
            const sc = rl.intensity_lumens / 100.0;
            cl_lights.rects[i] = .{
                .pos_range = .{ rl.position[0], rl.position[1], rl.position[2], rl.range },
                .dir_two = .{ rl.direction[0], rl.direction[1], rl.direction[2], if (rl.two_sided) 1.0 else 0.0 },
                .right_hx = .{ rl.right[0], rl.right[1], rl.right[2], rl.half_extents[0] },
                .up_hy = .{ rl.up[0], rl.up[1], rl.up[2], rl.half_extents[1] },
                .col_pad = .{ rl.color[0] * sc, rl.color[1] * sc, rl.color[2] * sc, @floatFromInt(rl.layers & pbr.ALL_LAYERS) },
            };
        }

        const pr_count = @min(self.frame_data.reflection_probes.len, 32);
        var probe_view: gpu.TextureViewHandle = g.env_prefilter.view;
        var authored_probe: ?usize = null;
        var best_probe_score: f32 = -1;
        for (self.frame_data.reflection_probes[0..pr_count], 0..) |pr, i| {
            if (pr.environment_texture == 0) continue;
            const entry = input.textures.get(pr.environment_texture) orelse continue;
            const cam = self.frame_data.camera_position;
            const dx = cam[0] - pr.position[0];
            const dy = cam[1] - pr.position[1];
            const dz = cam[2] - pr.position[2];
            const score = @max(pr.intensity, 0) / (1 + dx * dx + dy * dy + dz * dz);
            if (score > best_probe_score) {
                best_probe_score = score;
                authored_probe = i;
                probe_view = entry.view;
            }
        }
        for (0..pr_count) |i| {
            const pr = self.frame_data.reflection_probes[i];
            cl_lights.probes[i] = .{
                .pos_int = .{ pr.position[0], pr.position[1], pr.position[2], pr.intensity },
                .half_blend = .{ pr.half_extents[0], pr.half_extents[1], pr.half_extents[2], pr.blend_distance },
                .sky_box = .{ pr.sky_tint[0], pr.sky_tint[1], pr.sky_tint[2], if (pr.box_projection) 1.0 else 0.0 },
                .ground_pad = .{ pr.ground_tint[0], pr.ground_tint[1], pr.ground_tint[2], pr.diffuse_scale },
                .environment_info = .{ if (authored_probe != null and authored_probe.? == i) 1 else 0, @floatFromInt(std.math.clamp(pr.environment_mips, 1, 16) - 1), 0, 0 },
            };
        }

        // Per-tile cache: a tile is redrawn only when a caster that reaches it, its matrix or its rect changed.
        var tile_miss: [shadow_plan.MAX_TILES]bool = @splat(true);
        var any_tile_miss = false;
        for (0..next_tile) |tidx| {
            if (shadow_q.static_cache) {
                const key = self.shadowMapKey(.{ .m = local_sh.shadow_vp[tidx] }, tile_layers[tidx], &local_sh.atlas_rect[tidx]);
                tile_miss[tidx] = !self.local_tile_cache[tidx].hit(key, true);
            } else {
                self.local_tile_cache[tidx].invalidate();
                tile_miss[tidx] = true;
            }
            any_tile_miss = any_tile_miss or tile_miss[tidx];
        }
        for (next_tile..shadow_plan.MAX_TILES) |tidx| self.local_tile_cache[tidx].invalidate();
        if (any_tile_miss) {
            const keep = shadow_q.static_cache and self.local_atlas_valid;
            try rec.beginRenderPass(.{ .label = "local shadow atlas", .depth = .{ .view = g.local_shadow.view, .depth_load = if (keep) .load else .clear } });
            try rec.setBindGroup(0, g.empty_group, &.{});
            for (0..next_tile) |tidx| {
                if (!tile_miss[tidx]) continue;
                const tr = splan.tiles[tidx];
                try rec.setViewport(@floatFromInt(tr.x), @floatFromInt(tr.y), @floatFromInt(tr.size), @floatFromInt(tr.size));
                try rec.setScissor(tr.x, tr.y, tr.size, tr.size);
                if (keep) {
                    try rec.setRenderPipeline(g.depth_clear);
                    try rec.draw(3, 1, 0, 0);
                }
                try self.drawShadowQueue(g, rec, input.textures, .light, .{ .m = local_sh.shadow_vp[tidx] }, tile_layers[tidx], shadow_slot, mask_slot);
            }
            try rec.endRenderPass();
        }
        self.local_atlas_valid = shadow_q.static_cache and next_tile > 0;

        // Near/far come from the active camera's projection, so the depth slicing matches what is rendered.
        const cluster_range = cluster.perspectiveNearFar(self.frame_data.proj_matrix) orelse cluster.NearFar{ .near = 0.1, .far = 200.0 };
        const built_clusters = try cluster.buildClustersInto(
            &self.cluster_scratch,
            self.allocator,
            self.frame_data.view_matrix,
            self.frame_data.proj_matrix,
            cluster_range.near,
            cluster_range.far,
            self.frame_data.point_lights[0..pt_count],
            self.frame_data.spot_lights[0..sp_count],
            self.frame_data.rect_lights[0..rc_count],
        );
        if (built_clusters.dropped_refs != self.last_cluster_drops) {
            self.last_cluster_drops = built_clusters.dropped_refs;
            if (built_clusters.dropped_refs > 0) std.debug.print("[pbr] cluster light references dropped: {d}\n", .{built_clusters.dropped_refs});
        }

        // Helios GPU GI keeps the probe grid resident on the GPU, so the CPU upload must not overwrite it.
        const gi_input = self.frame_data.gpu_gi;
        const gi_requested = gi_input.enabled and cl_lights.gi.origin_enabled[3] > 0;
        if (!gi_requested) {
            self.gi.valid = false;
            self.gi.failed = false;
        }
        var gi_active = gi_requested and !self.gi.failed;
        if (gi_active) {
            self.gi.prepare(g, self.ring.?.buffer, gi_input) catch |err| {
                self.gi.failed = true;
                self.gi.valid = false;
                gi_active = false;
                std.debug.print("[pbr] GPU GI unavailable ({s}); using the CPU grid or the IBL fallback\n", .{@errorName(err)});
            };
        }
        const preserve_gi_grid = gi_active and self.gi.valid and self.gi.grid_epoch != null and self.gi.grid_epoch.? == gi_input.grid_epoch;
        if (gi_active and !preserve_gi_grid) cl_lights.gi.probes = @splat(.{});

        // Light/cluster/shadow buffers are persistent storage buffers rewritten every frame.
        {
            // Only overwrite the light prefix when the probe cache is GPU-resident.
            const lights_bytes = std.mem.asBytes(cl_lights)[0..if (preserve_gi_grid) @offsetOf(layout.ClusterLightsBuffer, "gi") else @sizeOf(layout.ClusterLightsBuffer)];
            const grid_bytes = std.mem.sliceAsBytes(built_clusters.entries);
            const idx_raw = std.mem.sliceAsBytes(built_clusters.indices);
            const idx_bytes = idx_raw[0..@min(idx_raw.len, 65536 * 4)];
            try device.writeBuffer(g.cluster_lights, 0, lights_bytes);
            if (grid_bytes.len > 0) try device.writeBuffer(g.cluster_grid, 0, grid_bytes);
            if (idx_bytes.len > 0) try device.writeBuffer(g.cluster_indices, 0, idx_bytes);
            try device.writeBuffer(g.local_shadow_buf, 0, std.mem.asBytes(local_sh));
        }

        if (gi_active) {
            const params = self.giParams(cl_lights, pt_count, sun_dir, sun_col);
            self.gi.dispatch(&self.groups.?, &self.ring.?, rec, g.cluster_lights, @offsetOf(layout.ClusterLightsBuffer, "gi"), gi_input, params) catch |err| {
                self.gi.valid = false;
                return err;
            };
        }

        // 1.5 Depth prepass + SSAO + contact shadows + bilateral blur.
        const prepass_ran = pp.ssao.enabled or pp.contact_shadows.enabled;
        const reuse_depth = prepass_ran and pp.quality.reuse_depth_prepass;
        const ssao_t = self.ssao.?;
        const blur_t = self.ssao_blur.?;
        if (prepass_ran) {
            try rec.beginRenderPass(.{ .label = "depth prepass", .depth = .{ .view = depth_view } });
            try rec.setBindGroup(0, g.empty_group, &.{});
            try rec.setViewport(0, 0, @floatFromInt(tex_w), @floatFromInt(tex_h));
            try self.drawShadowQueue(g, rec, input.textures, .depth_prepass, math3d.Mat4.identity(), pbr.ALL_LAYERS, shadow_slot, mask_slot);
            try rec.endRenderPass();

            const vw = self.frame_data.view_matrix;
            const sd_w = if (dirs.len > 0) [3]f32{ -dirs[0].direction[0], -dirs[0].direction[1], -dirs[0].direction[2] } else [3]f32{ 0.4, 0.8, 0.45 };
            const sun_view = [3]f32{
                vw[0] * sd_w[0] + vw[4] * sd_w[1] + vw[8] * sd_w[2],
                vw[1] * sd_w[0] + vw[5] * sd_w[1] + vw[9] * sd_w[2],
                vw[2] * sd_w[0] + vw[6] * sd_w[1] + vw[10] * sd_w[2],
            };
            const ssao_u = layout.SsaoParams{
                .proj = self.frame_data.proj_matrix,
                .inv_proj = util.invertMat4(self.frame_data.proj_matrix),
                .params = .{ pp.ssao.radius, pp.ssao.bias, pp.ssao.intensity, if (pp.ssao.enabled) 1.0 else 0.0 },
                .sun_view_dir = .{ sun_view[0], sun_view[1], sun_view[2], pp.contact_shadows.length },
                .contact_params = .{ pp.contact_shadows.opacity, pp.contact_shadows.thickness, @floatFromInt(pp.contact_shadows.sample_count), if (pp.contact_shadows.enabled) 1.0 else 0.0 },
                .fade_range = .{ pp.contact_shadows.distance_fade * 0.5, pp.contact_shadows.distance_fade, if (pp.ssao.horizon_based) 1.0 else 0.0, 0 },
            };
            const ssao_group = try groups.get(frame_res.key(&.{ 0x55a0, frame_res.bits(depth_view) }), .{ .layout = g.l_ssao, .entries = &.{
                .{ .binding = 0, .resource = .{ .texture_view = depth_view } },
                .{ .binding = 32, .resource = .{ .sampler = g.nearest } },
            } });
            const ssao_attachments = [_]gpu.ColorAttachment{.{ .target = .{ .view = ssao_t.view }, .load = .clear }};
            try rec.beginRenderPass(.{ .label = "ssao", .color_attachments = &ssao_attachments });
            try rec.setRenderPipeline(g.ssao);
            try rec.setBindGroup(0, ssao_group, &.{});
            try rec.setBindGroup(1, self.g_ssao, &.{try ring.pushValue(ssao_u)});
            try rec.draw(3, 1, 0, 0);
            try rec.endRenderPass();

            const blur_nf = cluster.perspectiveNearFar(self.frame_data.proj_matrix) orelse cluster.NearFar{ .near = 0.1, .far = 200.0 };
            const blur_u = layout.SsaoBlurParams{ .depth_range = .{ blur_nf.near, blur_nf.far, 0, 0 } };
            const blur_group = try groups.get(frame_res.key(&.{ 0x55a1, frame_res.bits(ssao_t.view), frame_res.bits(depth_view) }), .{ .layout = g.l_ssao_blur, .entries = &.{
                .{ .binding = 0, .resource = .{ .texture_view = ssao_t.view } },
                .{ .binding = 32, .resource = .{ .sampler = g.nearest } },
                .{ .binding = 1, .resource = .{ .texture_view = depth_view } },
                .{ .binding = 33, .resource = .{ .sampler = g.nearest } },
            } });
            const blur_attachments = [_]gpu.ColorAttachment{.{ .target = .{ .view = blur_t.view }, .load = .clear }};
            // The blur is also the bilateral upsample, so it writes full resolution.
            try rec.beginRenderPass(.{ .label = "ssao blur", .color_attachments = &blur_attachments });
            try rec.setRenderPipeline(g.ssao_blur);
            try rec.setBindGroup(0, blur_group, &.{});
            try rec.setBindGroup(1, self.g_blur, &.{try ring.pushValue(blur_u)});
            try rec.draw(3, 1, 0, 0);
            try rec.endRenderPass();
        }

        // 2. Sky pass into the HDR target.
        {
            const sky = self.frame_data.sky;
            const sky_mode: f32 = switch (sky.kind) {
                .procedural => 0.0,
                .solid_color => 1.0,
                .hdri => 2.0,
            };
            const sky_u = layout.SkyUniforms{
                .inv_view_proj = util.invertMat4(self.frame_data.view_proj),
                .sun_dir_size = .{ sun_dir[0], sun_dir[1], sun_dir[2], sky.sun_size },
                .sky_zenith_thick = .{ sky.sky_tint[0], sky.sky_tint[1], sky.sky_tint[2], sky.atmosphere_thickness },
                .sky_horizon_mode = .{ sky.horizon_tint[0], sky.horizon_tint[1], sky.horizon_tint[2], sky_mode },
                .ground_solid = .{
                    if (sky.kind == .solid_color) sky.solid_color[0] else sky.ground_albedo[0],
                    if (sky.kind == .solid_color) sky.solid_color[1] else sky.ground_albedo[1],
                    if (sky.kind == .solid_color) sky.solid_color[2] else sky.ground_albedo[2],
                    @floatFromInt(@backingInt(sky.sun_disk)),
                },
                .sun_col_intensity = .{ sun_col[0], sun_col[1], sun_col[2], if (sky.kind == .hdri) sky.hdri_exposure_ev else sun_int },
                .hdri_rotation = .{ sky.hdri_rotation_rad / (2.0 * std.math.pi), pre_gain, 0, 0 },
            };
            const sky_view = if (self.hdri_texture) |t| t.view else g.black.view;
            const sky_group = try groups.get(frame_res.key(&.{ 0x5b79, frame_res.bits(sky_view) }), .{ .layout = g.l_sky, .entries = &.{
                .{ .binding = 0, .resource = .{ .texture_view = sky_view } },
                .{ .binding = 32, .resource = .{ .sampler = g.ibl } },
            } });
            const sky_attachments = [_]gpu.ColorAttachment{.{ .target = .{ .view = hdr.view }, .load = .clear, .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 } }};
            try rec.beginRenderPass(.{ .label = "sky", .color_attachments = &sky_attachments });
            try rec.setRenderPipeline(g.sky);
            try rec.setBindGroup(0, sky_group, &.{});
            try rec.setBindGroup(1, self.g_sky, &.{try ring.pushValue(sky_u)});
            try rec.draw(3, 1, 0, 0);
            try rec.endRenderPass();
        }

        // 3. PBR lit meshes into the HDR target.
        try self.litPass(input, g, hdr, depth_view, probe_view, reuse_depth, .{
            .light_vps = light_vps,
            .cascade_texel_world = cascade_texel_world,
            .cascade_splits = cascade_splits,
            .cascade_depth_ranges = cascade_depth_ranges,
            .cascade_overlap = cascade_overlap,
            .cascade_count = cascade_count,
            .shadows_enabled = shadows_enabled,
            .shadow_bias = shadow_bias,
            .normal_offset_texels = normal_offset_texels,
            .sun_layers = sun_layers,
            .pre_gain = pre_gain,
            .pr_count = pr_count,
            .z_scale = built_clusters.factors.z_scale,
            .z_bias = built_clusters.factors.z_bias,
            .volumetric_active = volumetric_active,
            .ssao_view = if (prepass_ran) blur_t.view else g.white.view,
        });

        // 3.2 Screen-space transport replaces indirect lighting with traced reflections / diffuse bounces.
        var scene = hdr;
        if (self.screen_on) {
            try self.screenResolve(input, g, hdr, depth_view, pre_gain);
            scene = self.screen.?.resolved;
        }

        // 3.5 Volumetric fog and god rays: scattering is composited onto the HDR scene.
        if (volumetric_active) {
            try self.volumetricPass(input, g, scene, depth_view, .{
                .light_vps = light_vps,
                .cascade_splits = cascade_splits,
                .cascade_count = cascade_count,
                .shadows_enabled = shadows_enabled,
                .pre_gain = pre_gain,
                .pt_count = pt_count,
                .sp_count = sp_count,
            });
        } else {
            self.vol_history_valid = false;
        }

        // 4. Automatic exposure: luminance histogram, then adaptation into the 1x1 exposure texture.
        try self.autoExposure(input, g, scene, pre_log2);

        // 5. Bloom: downsample chain, then additive upsample back to the first level.
        const bloom_view: gpu.TextureViewHandle = if (pp.bloom.enabled) blk: {
            for (0..layout.BLOOM_MIPS) |i| {
                const src_view = if (i == 0) scene.view else self.bloom[i - 1].?.view;
                const src_w: f32 = @floatFromInt(if (i == 0) tex_w else self.bloom[i - 1].?.width);
                const src_h: f32 = @floatFromInt(if (i == 0) tex_h else self.bloom[i - 1].?.height);
                const dst = self.bloom[i].?;
                const group = try groups.get(frame_res.key(&.{ 0xb100, frame_res.bits(src_view) }), .{ .layout = g.l_float1, .entries = &.{
                    .{ .binding = 0, .resource = .{ .texture_view = src_view } },
                    .{ .binding = 32, .resource = .{ .sampler = g.linear } },
                } });
                const attachments = [_]gpu.ColorAttachment{.{ .target = .{ .view = dst.view }, .load = .clear }};
                try rec.beginRenderPass(.{ .label = "bloom down", .color_attachments = &attachments });
                try rec.setRenderPipeline(g.bloom_down);
                try rec.setBindGroup(0, group, &.{});
                const params = layout.BloomParams{ .p = .{ 1.0 / src_w, 1.0 / src_h, pp.bloom.threshold * pre_gain, if (i == 0) 1.0 else 0.0 } };
                try rec.setBindGroup(1, self.g_bloom, &.{try ring.pushValue(params)});
                try rec.draw(3, 1, 0, 0);
                try rec.endRenderPass();
            }
            var i: usize = layout.BLOOM_MIPS - 1;
            while (i > 0) : (i -= 1) {
                const src = self.bloom[i].?;
                const dst = self.bloom[i - 1].?;
                const group = try groups.get(frame_res.key(&.{ 0xb100, frame_res.bits(src.view) }), .{ .layout = g.l_float1, .entries = &.{
                    .{ .binding = 0, .resource = .{ .texture_view = src.view } },
                    .{ .binding = 32, .resource = .{ .sampler = g.linear } },
                } });
                const attachments = [_]gpu.ColorAttachment{.{ .target = .{ .view = dst.view }, .load = .load }};
                try rec.beginRenderPass(.{ .label = "bloom up", .color_attachments = &attachments });
                try rec.setRenderPipeline(g.bloom_up);
                try rec.setBindGroup(0, group, &.{});
                const params = layout.BloomParams{ .p = .{ 1.0 / @as(f32, @floatFromInt(src.width)), 1.0 / @as(f32, @floatFromInt(src.height)), pp.bloom.scatter, 0.0 } };
                try rec.setBindGroup(1, self.g_bloom, &.{try ring.pushValue(params)});
                try rec.draw(3, 1, 0, 0);
                try rec.endRenderPass();
            }
            break :blk self.bloom[0].?.view;
        } else g.black.view;

        input.offerCapture(.hdr, .{ .texture = scene.texture, .format = hdr_format, .width = scene.width, .height = scene.height });
        if (prepass_ran) input.offerCapture(.ssao, .{ .texture = blur_t.texture, .format = ao_format, .width = blur_t.width, .height = blur_t.height });

        // 6. Post-process composite + tonemap into the frame target.
        {
            const post_pipeline = try g.postfxFor(input.target.color_format);
            const scale_log2 = physical_cfg.scaleLog2();
            const camera_ev_bias: f32 = if (physical_cfg.enabled)
                @log2(@as(f32, 1.2)) - scale_log2 + (if (pp.auto_exposure.enabled) @as(f32, 0.0) else physical_cfg.manualEv100())
            else
                0.0;
            const pf_u = layout.PostFxParams{
                .bloom_tint_int = .{ pp.bloom.tint[0], pp.bloom.tint[1], pp.bloom.tint[2], if (pp.bloom.enabled) pp.bloom.intensity else 0.0 },
                .grade_params = .{ pp.color_adjustments.exposure_ev + camera_ev_bias + pre_log2, pp.color_adjustments.contrast, pp.color_adjustments.saturation, @floatFromInt(@backingInt(pp.tonemap_mode)) },
                .grade_tint_look = .{ pp.color_adjustments.filter_tint[0], pp.color_adjustments.filter_tint[1], pp.color_adjustments.filter_tint[2], if (pp.tonemap_look == .punchy) 1.0 else 0.0 },
                .vignette_params = .{ pp.vignette.color[0], pp.vignette.color[1], pp.vignette.color[2], if (pp.vignette.enabled) pp.vignette.intensity else 0.0 },
                .vignette_extra = .{ pp.vignette.smoothness, if (pp.auto_exposure.enabled) 1.0 else 0.0, if (pp.anti_aliasing == .fxaa) 1.0 else 0.0, pre_gain },
                .local_exposure = .{ physical_cfg.local_exposure_strength, physical_cfg.local_exposure_radius, physical_cfg.local_exposure_max_stops, 0 },
            };
            const group = try groups.get(frame_res.key(&.{ 0x9057, frame_res.bits(scene.view), frame_res.bits(bloom_view), frame_res.bits(g.exposure.view) }), .{ .layout = g.l_post, .entries = &.{
                .{ .binding = 0, .resource = .{ .texture_view = scene.view } },
                .{ .binding = 32, .resource = .{ .sampler = g.linear } },
                .{ .binding = 1, .resource = .{ .texture_view = bloom_view } },
                .{ .binding = 33, .resource = .{ .sampler = g.linear } },
                .{ .binding = 2, .resource = .{ .texture_view = g.exposure.view } },
                .{ .binding = 34, .resource = .{ .sampler = g.nearest } },
            } });
            const attachment = input.colorAttachment();
            var out_attachment = attachment;
            // The composite writes every pixel, so there is nothing to preserve from earlier passes.
            out_attachment.load = .clear;
            const attachments = [_]gpu.ColorAttachment{out_attachment};
            try rec.beginRenderPass(.{ .label = "postfx", .color_attachments = &attachments });
            try rec.setRenderPipeline(post_pipeline);
            try rec.setBindGroup(0, group, &.{});
            try rec.setBindGroup(1, self.g_post, &.{try ring.pushValue(pf_u)});
            try rec.draw(3, 1, 0, 0);
            try rec.endRenderPass();
        }

        // Upload everything written this frame, now that recording is complete.
        try ring.flush();
        try self.flushScratch(g, &self.shadow_vs, &self.shadow_scratch, g.l_vs_shadow, 64, "shadow vs uniforms");
        try self.flushScratch(g, &self.mask_params, &self.mask_scratch, g.l_mask_params, @sizeOf(layout.ShadowMaskParams), "shadow mask uniforms");
        self.rendered_this_frame = true;
        self.base.pbr_rendered = true;
        if (self.timing) |*t| t.endFrame(rec, first_command) catch { t.abortRecorded(); };
    }

    /// Light importance table and sky constants for the GI compute pass.
    fn giParams(self: *PbrRenderer, lights: *const layout.ClusterLightsBuffer, count: usize, sun_dir: [3]f32, sun_color: [3]f32) gpu_gi.Params {
        var cdf: [64][4]f32 = @splat(@splat(0));
        var weights: [256]f64 = @splat(0);
        var total: f64 = 0;
        for (lights.points[0..count], 0..) |light, i| {
            const rgb = light.col_radius;
            const lum = @as(f64, rgb[0]) * 0.2126 + @as(f64, rgb[1]) * 0.7152 + @as(f64, rgb[2]) * 0.0722;
            if (std.math.isFinite(lum) and lum > 0 and light.shadow_params[2] > 0) {
                weights[i] = lum;
                total += lum;
            }
        }
        var cumulative: f64 = 0;
        for (0..count) |i| {
            cumulative += if (total > 0) weights[i] / total else 1.0 / @as(f64, @floatFromInt(count));
            cdf[i / 4][i % 4] = if (i + 1 == count) 1.0 else @floatCast(@min(cumulative, 1));
        }
        const hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(lights.points[0..count]));
        const sky = self.frame_data.sky;
        const zenith = if (sky.kind == .solid_color) sky.solid_color else sky.sky_tint;
        const horizon = if (sky.kind == .solid_color) sky.solid_color else sky.horizon_tint;
        const ground = if (sky.kind == .solid_color) sky.solid_color else sky.ground_albedo;
        const intensity: f32 = if (self.frame_data.directional_lights.len > 0) self.frame_data.directional_lights[0].illuminance_lux / 2500.0 else 0;
        return .{
            .counts = .{ 0, 0, 0, @intCast(count) },
            .offsets = .{ 0, 0, 0, 0 },
            .dispatch_info = .{ 0, 0, 0, 0 },
            .light_key = .{ @truncate(hash), @truncate(hash >> 32), 0, 0 },
            .config = .{ 16, 0.85, 0.4, 0 },
            .sun_dir_int = .{ sun_dir[0], sun_dir[1], sun_dir[2], intensity },
            .sun_color = .{ sun_color[0], sun_color[1], sun_color[2], 0 },
            .sky_zenith = .{ zenith[0], zenith[1], zenith[2], 0 },
            .sky_horizon = .{ horizon[0], horizon[1], horizon[2], 0 },
            .sky_ground = .{ ground[0], ground[1], ground[2], 0 },
            .cdf = cdf,
        };
    }

    const ScreenState = struct {
        width: u32,
        height: u32,
        layout: screen_transport.Layout,
        bounds: gpu.BufferHandle,
        surface: Target,
        diffuse: Target,
        specular: Target,
        resolved: Target,
    };

    fn destroyScreen(self: *PbrRenderer, device: gpu.GpuDevice) void {
        if (self.screen) |s| {
            device.destroyBuffer(s.bounds);
            for ([_]Target{ s.surface, s.diffuse, s.specular, s.resolved }) |t| self.destroyTarget(device, t);
        }
        self.screen = null;
    }

    /// (Re)allocates the transport targets when the frame size changes; they exist only while a view uses them.
    fn ensureScreen(self: *PbrRenderer, device: gpu.GpuDevice, w: u32, h: u32) !*ScreenState {
        if (self.screen) |*s| if (s.width == w and s.height == h) return s;
        if (self.groups) |*groups| groups.clear();
        self.destroyScreen(device);
        const lay = try screen_transport.Layout.init(w, h);
        const limits = device.capabilities().limits;
        if (lay.bytes > limits.max_buffer_size or lay.bytes > limits.max_storage_buffer_binding_size) return error.ScreenBufferTooLarge;
        const bounds = try device.createBuffer(.{ .label = "hiz bounds", .size = lay.bytes, .usage = .{ .storage = true } });
        errdefer device.destroyBuffer(bounds);
        const surface = try newTarget(device, w, h, .rgba32_float, "screen surface");
        errdefer self.destroyTarget(device, surface);
        const diffuse = try newTarget(device, w, h, hdr_format, "screen diffuse");
        errdefer self.destroyTarget(device, diffuse);
        const specular = try newTarget(device, w, h, hdr_format, "screen specular");
        errdefer self.destroyTarget(device, specular);
        const resolved = try newTarget(device, w, h, hdr_format, "screen resolved");
        self.screen = .{ .width = w, .height = h, .layout = lay, .bounds = bounds, .surface = surface, .diffuse = diffuse, .specular = specular, .resolved = resolved };
        return &self.screen.?;
    }

    /// Hi-Z reduction of the depth buffer, then the SSR/SSGI resolve into `resolved`.
    fn screenResolve(self: *PbrRenderer, input: *frame.FrameInput, g: *Gpu, hdr: Target, depth_view: gpu.TextureViewHandle, pre_gain: f32) !void {
        const rec = input.recorder;
        const ring = &self.ring.?;
        const groups = &self.groups.?;
        const sc = &self.screen.?;
        const ex = g.screen_gpu.?;
        const cfg = self.frame_data.post_process.quality.screen_transport;

        const depth_group = try groups.get(frame_res.key(&.{ 0x5c01, frame_res.bits(depth_view) }), .{ .layout = ex.l_reduce_depth, .entries = &.{
            .{ .binding = 0, .resource = .{ .texture_view = depth_view } },
            .{ .binding = 32, .resource = .{ .sampler = g.nearest } },
        } });
        const bounds_group = try groups.get(frame_res.key(&.{ 0x5c02, frame_res.bits(sc.bounds) }), .{ .layout = ex.l_reduce_bounds, .entries = &.{
            .{ .binding = 0, .resource = .{ .buffer = .{ .buffer = sc.bounds } } },
        } });
        // One pass per pyramid level: each level reads the storage the previous pass wrote.
        for (0..sc.layout.count) |i| {
            const dst = sc.layout.levels[i];
            try rec.beginComputePass(.{ .label = "hiz reduce" });
            try rec.setComputePipeline(ex.reduce);
            try rec.setBindGroup(0, depth_group, &.{});
            try rec.setBindGroup(1, bounds_group, &.{});
            try rec.setBindGroup(2, ex.g_u_reduce, &.{try ring.pushValue(sc.layout.reduceParams(i))});
            try rec.dispatch((dst[1] + 15) / 16, (dst[2] + 15) / 16, 1);
            try rec.endComputePass();
        }

        const res_group = try groups.get(frame_res.key(&.{ 0x5c03, frame_res.bits(hdr.view), frame_res.bits(depth_view), frame_res.bits(sc.surface.view), frame_res.bits(sc.diffuse.view), frame_res.bits(sc.specular.view), frame_res.bits(sc.bounds) }), .{ .layout = ex.l_resolve, .entries = &.{
            .{ .binding = 0, .resource = .{ .texture_view = hdr.view } },
            .{ .binding = 32, .resource = .{ .sampler = g.linear } },
            .{ .binding = 1, .resource = .{ .texture_view = depth_view } },
            .{ .binding = 33, .resource = .{ .sampler = g.nearest } },
            .{ .binding = 2, .resource = .{ .texture_view = sc.surface.view } },
            .{ .binding = 34, .resource = .{ .sampler = g.nearest } },
            .{ .binding = 3, .resource = .{ .texture_view = sc.diffuse.view } },
            .{ .binding = 35, .resource = .{ .sampler = g.nearest } },
            .{ .binding = 4, .resource = .{ .texture_view = sc.specular.view } },
            .{ .binding = 36, .resource = .{ .sampler = g.nearest } },
            .{ .binding = 5, .resource = .{ .texture_view = g.brdf_lut.view } },
            .{ .binding = 37, .resource = .{ .sampler = g.linear } },
            .{ .binding = 6, .resource = .{ .buffer = .{ .buffer = sc.bounds } } },
        } });
        const cam = self.frame_data.camera_position;
        const params = screen_transport.Params{
            .view_proj = self.frame_data.view_proj,
            .inv_view_proj = util.invertMat4(self.frame_data.view_proj),
            .camera_gain = .{ cam[0], cam[1], cam[2], pre_gain },
            .controls = .{ clampOr(cfg.ssr_strength, 0, 1, 0), clampOr(cfg.ssgi_strength, 0, 1, 0), clampOr(cfg.max_distance, 0.5, 100, 20), clampOr(cfg.thickness, 0.02, 2, 0.15) },
            .levels = sc.layout.levels,
            .budget = .{ sc.layout.count, std.math.clamp(cfg.max_iterations, 8, 128), std.math.clamp(cfg.diffuse_rays, 1, 4), 0 },
        };
        const attachments = [_]gpu.ColorAttachment{.{ .target = .{ .view = sc.resolved.view }, .load = .clear }};
        try rec.beginRenderPass(.{ .label = "screen transport", .color_attachments = &attachments });
        try rec.setRenderPipeline(ex.resolve);
        try rec.setBindGroup(0, res_group, &.{});
        try rec.setBindGroup(1, ex.g_u_resolve, &.{try ring.pushValue(params)});
        try rec.draw(3, 1, 0, 0);
        try rec.endRenderPass();
    }

    /// Clamps a user setting, mapping NaN/inf to `fallback`.
    fn clampOr(value: f32, lo: f32, hi: f32, fallback: f32) f32 {
        return if (std.math.isFinite(value)) std.math.clamp(value, lo, hi) else fallback;
    }

    const VolCtx = struct {
        light_vps: [4]math3d.Mat4,
        cascade_splits: [4]f32,
        cascade_count: f32,
        shadows_enabled: f32,
        pre_gain: f32,
        pt_count: usize,
        sp_count: usize,
    };

    /// Keeps `slot` at `w x h` in the HDR format, recreating it only when the size changes.
    fn ensureHdrTarget(self: *PbrRenderer, device: gpu.GpuDevice, slot: *?Target, w: u32, h: u32, label: []const u8) !Target {
        if (slot.*) |t| if (t.width == w and t.height == h) return t;
        const fresh = try newTarget(device, w, h, hdr_format, label);
        if (slot.*) |old| self.destroyTarget(device, old);
        slot.* = fresh;
        return fresh;
    }

    fn volumetricPass(self: *PbrRenderer, input: *frame.FrameInput, g: *Gpu, hdr: Target, depth_view: gpu.TextureViewHandle, vc: VolCtx) !void {
        const device = input.device;
        const rec = input.recorder;
        const ring = &self.ring.?;
        const groups = &self.groups.?;
        const vol = try g.ensureVolumetric(ring.buffer);
        const tex_w = input.target.width;
        const tex_h = input.target.height;
        const fogc = self.frame_data.fog;
        const vol_cfg = fogc.volumetric;
        const pp = self.frame_data.post_process;
        const local_sh = self.local_shadow;
        const cl_lights = self.cluster_lights;
        const dirs = self.frame_data.directional_lights;

        // Ray-march at half resolution by default; the composite pass upsamples depth-aware (~4x fewer marched pixels).
        const vol_half = vol_cfg.half_resolution;
        if (!vol_cfg.froxel_enabled) self.froxel_failed = false;
        var froxel_on = vol_cfg.froxel_enabled and !self.froxel_failed;
        var froxel_pixel = std.math.clamp(vol_cfg.froxel_pixel_size, 8, 32);
        const froxel_slices = std.math.clamp(vol_cfg.froxel_slices, 8, 64);
        const max_dim = @max(device.capabilities().limits.max_texture_dimension_2d, 1);
        const max_rows = max_dim / froxel_slices;
        if (max_rows == 0) froxel_on = false;
        if (max_rows > 0) froxel_pixel = @max(froxel_pixel, (tex_h + max_rows - 1) / max_rows);
        froxel_pixel = @max(froxel_pixel, (tex_w + max_dim - 1) / max_dim);
        const fw = @max((tex_w + froxel_pixel - 1) / froxel_pixel, 1);
        const fh = @max((tex_h + froxel_pixel - 1) / froxel_pixel, 1);
        var froxel_target: ?Target = null;
        if (froxel_on) {
            froxel_target = self.ensureHdrTarget(device, &self.froxel_texture, fw, fh * froxel_slices, "froxels") catch blk: {
                froxel_on = false;
                self.froxel_failed = true;
                std.debug.print("[pbr] froxel allocation failed; falling back to ray marching\n", .{});
                break :blk null;
            };
        }
        const vol_w: u32 = if (vol_half) @max(tex_w / 2, 1) else tex_w;
        const vol_h: u32 = if (vol_half) @max(tex_h / 2, 1) else tex_h;
        const vol_t = try self.ensureHdrTarget(device, &self.vol_target, vol_w, vol_h, "volumetric");
        const temporal = vol_cfg.temporal;
        if (temporal) {
            // A size change drops the history.
            const have = self.vol_history[0] != null and self.vol_history[0].?.width == vol_w and self.vol_history[0].?.height == vol_h;
            if (!have) {
                const first = try newTarget(device, vol_w, vol_h, hdr_format, "volumetric history");
                errdefer self.destroyTarget(device, first);
                const second = try newTarget(device, vol_w, vol_h, hdr_format, "volumetric history");
                for (self.vol_history) |h| if (h) |t| self.destroyTarget(device, t);
                self.vol_history = .{ first, second };
                self.vol_history_read = 0;
                self.vol_history_valid = false;
            }
        }
        // Golden-ratio sequence: successive frames sample different positions along each ray.
        self.vol_frame +%= 1;
        const jitter_offset: f32 = if (temporal) @floatCast(@mod(@as(f64, @floatFromInt(self.vol_frame)) * 0.6180339887498949, 1.0)) else 0.0;

        const has_dir_vf = dirs.len > 0;
        const vf_sun_dir: [3]f32 = if (has_dir_vf) .{ -dirs[0].direction[0], -dirs[0].direction[1], -dirs[0].direction[2] } else .{ 0.4, 0.8, 0.45 };
        const vf_sun_col: [3]f32 = if (has_dir_vf) dirs[0].color else .{ 1, 1, 1 };
        const vf_sun_int: f32 = if (has_dir_vf) dirs[0].illuminance_lux / 2500.0 else 0.0;

        // Spot lights get the same relevance ranking as point lights, with one local-atlas tile per shadowed slot.
        var vf_sp_pos: [4][4]f32 = @splat(.{ 0, 0, 0, 1 });
        var vf_sp_dir: [4][4]f32 = @splat(.{ 0, -1, 0, 0.8 });
        var vf_sp_col: [4][4]f32 = @splat(.{ 0, 0, 0, 0 });
        var vf_sp_shadow: [4][4]f32 = @splat(.{ 0, 0, 0, 0 });
        self.vol_sp_fader.update(self.frame_data.spot_lights[0..vc.sp_count], self.frame_data.camera_position, self.frame_data.dt);
        for (self.vol_sp_fader.slots, 0..) |s, slot| {
            if (!s.active or s.weight <= 0.0) continue;
            const li = s.idx;
            const sl = self.frame_data.spot_lights[li];
            const sc = (sl.intensity_lumens / 100.0) * s.weight;
            vf_sp_pos[slot] = .{ sl.position[0], sl.position[1], sl.position[2], sl.range };
            vf_sp_dir[slot] = .{ sl.direction[0], sl.direction[1], sl.direction[2], @cos(sl.outer_angle_rad) };
            vf_sp_col[slot] = .{ sl.color[0] * sc, sl.color[1] * sc, sl.color[2] * sc, 1.0 };
            const tile = cl_lights.spots[li].shadow_params[0];
            if (tile >= 0.0) vf_sp_shadow[slot] = .{ tile, 1.0, 0.0, 0.0 };
        }

        var vf_pt_pos: [4][4]f32 = @splat(.{ 0, 0, 0, 1 });
        var vf_pt_col: [4][4]f32 = @splat(.{ 0, 0, 0, 0 });
        var vf_pt_shadow: [4][4]f32 = @splat(.{ 0, 0, 0, 0 });
        // Only lights that received a cluster entry this frame are candidates, so `cl_lights` indices stay valid.
        self.vol_pt_fader.update(self.frame_data.point_lights[0..vc.pt_count], self.frame_data.camera_position, self.frame_data.dt);
        for (self.vol_pt_fader.slots, 0..) |s, slot| {
            if (!s.active or s.weight <= 0.0) continue;
            const li = s.idx;
            const pl = self.frame_data.point_lights[li];
            const sc = (pl.intensity_lumens / 100.0) * s.weight;
            vf_pt_pos[slot] = .{ pl.position[0], pl.position[1], pl.position[2], pl.range };
            vf_pt_col[slot] = .{ pl.color[0] * sc, pl.color[1] * sc, pl.color[2] * sc, 1.0 };
            // Local-atlas tile of the first cube face (six consecutive tiles), or -1 when unshadowed.
            const tile = cl_lights.points[li].col_radius[3];
            if (tile >= 0.0) vf_pt_shadow[slot] = .{ tile, 1.0, 0.0, 0.0 };
        }

        const inv_view_proj = util.invertMat4(self.frame_data.view_proj);
        const vfp = layout.VolFogParams{
            .inv_view_proj = inv_view_proj,
            .light_vp = .{ vc.light_vps[0].m, vc.light_vps[1].m, vc.light_vps[2].m, vc.light_vps[3].m },
            .cam_pos_density = .{ self.frame_data.camera_position[0], self.frame_data.camera_position[1], self.frame_data.camera_position[2], fogc.density },
            .sun_dir_int = .{ vf_sun_dir[0], vf_sun_dir[1], vf_sun_dir[2], vf_sun_int },
            .sun_col_aniso = .{ vf_sun_col[0], vf_sun_col[1], vf_sun_col[2], vol_cfg.anisotropy },
            .fog_col_scat = .{ fogc.color[0], fogc.color[1], fogc.color[2], vol_cfg.scattering },
            .cascade_splits = if (vc.shadows_enabled > 0.5) vc.cascade_splits else .{ -1.0, -1.0, -1.0, -1.0 },
            .cam_fwd_maxd = .{ self.frame_data.camera_forward[0], self.frame_data.camera_forward[1], self.frame_data.camera_forward[2], vol_cfg.max_distance },
            .spot_pos_range = vf_sp_pos,
            .spot_dir_cos = vf_sp_dir,
            .spot_col_on = vf_sp_col,
            .spot_shadow = vf_sp_shadow,
            .point_pos = vf_pt_pos,
            .point_col = vf_pt_col,
            .local_vp = local_sh.shadow_vp,
            .local_rect = local_sh.atlas_rect,
            .point_shadow = vf_pt_shadow,
            .cascade_info = .{ vc.cascade_count, jitter_offset, @floatFromInt(std.math.clamp(vol_cfg.raymarch_steps, 8, 128)), if (vol_cfg.physical_scattering) 1.0 else 0.0 },
            .froxel_params = .{ @floatFromInt(fw), @floatFromInt(fh), @floatFromInt(froxel_slices), if (froxel_on) 1 else 0 },
        };

        const fog_group = try groups.get(frame_res.key(&.{ 0x70a1, frame_res.bits(depth_view) }), .{ .layout = vol.l_fog, .entries = &.{
            .{ .binding = 0, .resource = .{ .texture_view = depth_view } },
            .{ .binding = 32, .resource = .{ .sampler = g.nearest } },
            .{ .binding = 1, .resource = .{ .texture_view = g.shadow_atlas.view } },
            .{ .binding = 33, .resource = .{ .sampler = g.shadow_cmp } },
            .{ .binding = 2, .resource = .{ .texture_view = g.local_shadow.view } },
            .{ .binding = 34, .resource = .{ .sampler = g.shadow_cmp } },
        } });
        const fog_target = if (froxel_on) froxel_target.? else vol_t;
        const fog_attachments = [_]gpu.ColorAttachment{.{ .target = .{ .view = fog_target.view }, .load = .clear, .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 } }};
        try rec.beginRenderPass(.{ .label = "volumetric fog", .color_attachments = &fog_attachments });
        try rec.setRenderPipeline(vol.fog);
        try rec.setBindGroup(0, fog_group, &.{});
        try rec.setBindGroup(1, vol.g_u_fog, &.{try ring.pushValue(vfp)});
        try rec.draw(3, 1, 0, 0);
        try rec.endRenderPass();

        if (froxel_on) {
            const froxel_group = try groups.get(frame_res.key(&.{ 0x70a2, frame_res.bits(froxel_target.?.view), frame_res.bits(depth_view) }), .{ .layout = vol.l_froxel, .entries = &.{
                .{ .binding = 0, .resource = .{ .texture_view = froxel_target.?.view } },
                .{ .binding = 32, .resource = .{ .sampler = g.linear } },
                .{ .binding = 1, .resource = .{ .texture_view = depth_view } },
                .{ .binding = 33, .resource = .{ .sampler = g.nearest } },
            } });
            const cam = self.frame_data.camera_position;
            const params = layout.FroxelIntegrateParams{
                .inv_view_proj = inv_view_proj,
                .cam_max = .{ cam[0], cam[1], cam[2], vol_cfg.max_distance },
                .dimensions = .{ @floatFromInt(fw), @floatFromInt(fh), @floatFromInt(froxel_slices), fogc.density },
            };
            const attachments = [_]gpu.ColorAttachment{.{ .target = .{ .view = vol_t.view }, .load = .clear }};
            try rec.beginRenderPass(.{ .label = "froxel integrate", .color_attachments = &attachments });
            try rec.setRenderPipeline(vol.froxel);
            try rec.setBindGroup(0, froxel_group, &.{});
            try rec.setBindGroup(1, vol.g_u_froxel, &.{try ring.pushValue(params)});
            try rec.draw(3, 1, 0, 0);
            try rec.endRenderPass();
        }

        // Temporal resolve: reproject the previous result, clip it to this frame's neighbourhood and blend.
        var vol_final = vol_t;
        if (temporal) {
            const cam_now = self.frame_data.camera_position;
            const fwd_now = self.frame_data.camera_forward;
            // History also dies when the fog itself changed: density, scattering, the sun, or any light that the
            // volume uses moved, recoloured or switched slot. Reprojecting old scatter would trail behind the change.
            var key_hasher = std.hash.Wyhash.init(0x76f6);
            key_hasher.update(std.mem.asBytes(&vfp.sun_dir_int));
            key_hasher.update(std.mem.asBytes(&vfp.sun_col_aniso));
            key_hasher.update(std.mem.asBytes(&vfp.fog_col_scat));
            key_hasher.update(std.mem.asBytes(&vfp.cam_pos_density[3]));
            key_hasher.update(std.mem.asBytes(&vfp.spot_pos_range));
            key_hasher.update(std.mem.asBytes(&vfp.spot_dir_cos));
            key_hasher.update(std.mem.asBytes(&vfp.spot_col_on));
            key_hasher.update(std.mem.asBytes(&vfp.point_pos));
            key_hasher.update(std.mem.asBytes(&vfp.point_col));
            key_hasher.update(std.mem.asBytes(&vfp.point_shadow));
            key_hasher.update(std.mem.asBytes(&vfp.spot_shadow));
            key_hasher.update(std.mem.asBytes(&vfp.cam_fwd_maxd[3]));
            key_hasher.update(std.mem.asBytes(&vfp.cascade_info[2]));
            key_hasher.update(std.mem.asBytes(&vfp.cascade_info[3]));
            key_hasher.update(std.mem.asBytes(&vfp.froxel_params));
            var caster_hash = shadow_plan.CasterHasher.init(0x30b0_116a);
            for (self.queued_draws.items) |draw| caster_hash.addDraw(draw);
            for (self.shadow_casters.items) |caster| caster_hash.addCaster(caster);
            const geometry_key = caster_hash.final();
            key_hasher.update(std.mem.asBytes(&geometry_key));
            const light_key = key_hasher.final();
            const fog_unchanged = light_key == self.vol_light_key;
            self.vol_light_key = light_key;
            const usable = self.vol_history_valid and self.vol_history_camera_key == self.frame_data.camera_key and
                self.vol_history_epoch == pp.auto_exposure.history_epoch and fog_unchanged and
                volumetric_lights.historyUsable(self.vol_prev_cam, self.vol_prev_fwd, cam_now, fwd_now);
            const read_idx: usize = self.vol_history_read;
            const write_idx: usize = 1 - read_idx;
            const write_t = self.vol_history[write_idx].?;
            const read_t = self.vol_history[read_idx].?;
            const res_group = try groups.get(frame_res.key(&.{ 0x70a3, frame_res.bits(vol_t.view), frame_res.bits(read_t.view), frame_res.bits(depth_view) }), .{ .layout = vol.l_resolve, .entries = &.{
                .{ .binding = 0, .resource = .{ .texture_view = vol_t.view } },
                .{ .binding = 32, .resource = .{ .sampler = g.nearest } },
                .{ .binding = 1, .resource = .{ .texture_view = read_t.view } },
                .{ .binding = 33, .resource = .{ .sampler = g.linear } },
                .{ .binding = 2, .resource = .{ .texture_view = depth_view } },
                .{ .binding = 34, .resource = .{ .sampler = g.nearest } },
            } });
            const res_u = layout.VolResolveParams{
                .inv_view_proj = inv_view_proj,
                .prev_view_proj = self.vol_prev_view_proj,
                .cam_pos_max = .{ cam_now[0], cam_now[1], cam_now[2], vol_cfg.max_distance },
                .size_blend = .{ @floatFromInt(vol_w), @floatFromInt(vol_h), std.math.clamp(vol_cfg.temporal_blend, 0.02, 1.0), if (usable) 1.0 else 0.0 },
            };
            const attachments = [_]gpu.ColorAttachment{.{ .target = .{ .view = write_t.view }, .load = .clear }};
            try rec.beginRenderPass(.{ .label = "volumetric resolve", .color_attachments = &attachments });
            try rec.setRenderPipeline(vol.resolve);
            try rec.setBindGroup(0, res_group, &.{});
            try rec.setBindGroup(1, vol.g_u_resolve, &.{try ring.pushValue(res_u)});
            try rec.draw(3, 1, 0, 0);
            try rec.endRenderPass();

            vol_final = write_t;
            self.vol_history_read = @intCast(write_idx);
            self.vol_history_valid = true;
            self.vol_history_camera_key = self.frame_data.camera_key;
            self.vol_history_epoch = pp.auto_exposure.history_epoch;
            self.vol_prev_view_proj = self.frame_data.view_proj;
            self.vol_prev_cam = cam_now;
            self.vol_prev_fwd = fwd_now;
        } else {
            self.vol_history_valid = false;
        }

        // Physically based composition on the HDR scene: L = L_scene * T + L_scatter.
        // Pass 0 multiplies by T; pass 1 adds the upsampled in-scatter plus the ambient fog colour (1 - T) * C.
        const vc_base = layout.VolCompositeParams{
            .inv_view_proj = inv_view_proj,
            .cam_pos = .{ self.frame_data.camera_position[0], self.frame_data.camera_position[1], self.frame_data.camera_position[2], vc.pre_gain },
            .vol_size_dist = .{ @floatFromInt(vol_w), @floatFromInt(vol_h), vol_cfg.max_distance, 0 },
            .fog_color_density = .{ fogc.color[0], fogc.color[1], fogc.color[2], fogc.density },
        };
        const comp_group = try groups.get(frame_res.key(&.{ 0x70a4, frame_res.bits(vol_final.view), frame_res.bits(depth_view) }), .{ .layout = vol.l_composite, .entries = &.{
            .{ .binding = 0, .resource = .{ .texture_view = vol_final.view } },
            .{ .binding = 32, .resource = .{ .sampler = g.nearest } },
            .{ .binding = 1, .resource = .{ .texture_view = depth_view } },
            .{ .binding = 33, .resource = .{ .sampler = g.nearest } },
        } });
        const passes = [_]struct { mode: f32, pipeline: gpu.RenderPipelineHandle }{
            .{ .mode = 0.0, .pipeline = vol.transmittance },
            .{ .mode = 1.0, .pipeline = vol.composite },
        };
        for (passes) |p| {
            var vcp = vc_base;
            vcp.vol_size_dist[3] = p.mode;
            const attachments = [_]gpu.ColorAttachment{.{ .target = .{ .view = hdr.view }, .load = .load }};
            try rec.beginRenderPass(.{ .label = "volumetric composite", .color_attachments = &attachments });
            try rec.setRenderPipeline(p.pipeline);
            try rec.setBindGroup(0, comp_group, &.{});
            try rec.setBindGroup(1, vol.g_u_composite, &.{try ring.pushValue(vcp)});
            try rec.draw(3, 1, 0, 0);
            try rec.endRenderPass();
        }
    }

    fn autoExposure(self: *PbrRenderer, input: *frame.FrameInput, g: *Gpu, hdr: Target, pre_log2: f32) !void {
        const pp = self.frame_data.post_process;
        const exposure = pp.auto_exposure;
        const physical = exposure.physical;
        if (!exposure.enabled) {
            self.exposure_history_valid = false;
            return;
        }
        const rec = input.recorder;
        const ring = &self.ring.?;
        const groups = &self.groups.?;
        const ex = try g.ensureExposure(ring.buffer);
        const tex_w = input.target.width;
        const tex_h = input.target.height;

        const scale_log2 = physical.scaleLog2();
        const hist_a = if (std.math.isFinite(exposure.histogram_min_log2)) std.math.clamp(exposure.histogram_min_log2, -32.0, 32.0) else -12.0;
        const hist_b = if (std.math.isFinite(exposure.histogram_max_log2)) std.math.clamp(exposure.histogram_max_log2, -32.0, 32.0) else 12.0;
        const min_log2 = @min(hist_a, hist_b);
        const log2_range = @max(@abs(hist_b - hist_a), 0.25);
        const stride = std.math.clamp(exposure.metering_stride, 1, 16);
        const meter_w = @max((tex_w + stride - 1) / stride, 1);
        const meter_h = @max((tex_h + stride - 1) / stride, 1);
        const cam = self.frame_data.camera_position;
        const dx = cam[0] - self.exposure_prev_camera[0];
        const dy = cam[1] - self.exposure_prev_camera[1];
        const dz = cam[2] - self.exposure_prev_camera[2];
        const reset = !self.exposure_history_valid or exposure.reset_history or
            self.exposure_camera_key != self.frame_data.camera_key or
            self.exposure_history_epoch != exposure.history_epoch or
            self.exposure_physical_mode != physical.enabled or
            (physical.enabled and self.exposure_scale_log2 != scale_log2) or
            dx * dx + dy * dy + dz * dz > 400.0;
        self.exposure_history_valid = false; // Only commit validity after both passes are recorded.
        const frame_phase: f32 = @floatFromInt(self.exposure_frame % 256);
        const phase_x: f32 = if (stride == 1) 0.5 else @mod(frame_phase * 0.754877666 + 0.5, 1.0);
        const phase_y: f32 = if (stride == 1) 0.5 else @mod(frame_phase * 0.569840296 + 0.5, 1.0);
        const center_weight: f32 = if (std.math.isFinite(exposure.metering_center_weight)) std.math.clamp(exposure.metering_center_weight, 0.0, 1.0) else 0.0;

        const hdr_group = try groups.get(frame_res.key(&.{ 0xe501, frame_res.bits(hdr.view) }), .{ .layout = ex.l_hist_hdr, .entries = &.{
            .{ .binding = 0, .resource = .{ .texture_view = hdr.view } },
        } });
        const hp = layout.HistParams{
            .range_params = .{ min_log2 + pre_log2, 1.0 / log2_range, @floatFromInt(meter_w), @floatFromInt(meter_h) },
            .metering_params = .{ center_weight, phase_x, phase_y, @floatFromInt(@max(@as(u64, 1), @min(@as(u64, 8), @as(u64, std.math.maxInt(u32)) / (@as(u64, meter_w) * meter_h)))) },
        };
        if (reset) try rec.clearBuffer(g.histogram, 0, 66 * 4);
        try rec.beginComputePass(.{ .label = "exposure histogram" });
        try rec.setComputePipeline(ex.hist);
        try rec.setBindGroup(0, hdr_group, &.{});
        try rec.setBindGroup(1, ex.g_hist_buffer, &.{});
        try rec.setBindGroup(2, ex.g_hist_uniform, &.{try ring.pushValue(hp)});
        try rec.dispatch((meter_w + 15) / 16, (meter_h + 15) / 16, 1);
        try rec.endComputePass();

        const ap = layout.AdaptParams{
            .ev_bounds = .{ if (physical.enabled) physical.min_ev100 else exposure.min_ev100, if (physical.enabled) physical.max_ev100 else exposure.max_ev100, exposure.low_percent, exposure.high_percent },
            .speed_dt = .{ exposure.speed_brighten, exposure.speed_darken, if (std.math.isFinite(self.frame_data.dt)) std.math.clamp(self.frame_data.dt, 0.0, 0.1) else 0.0, exposure.compensation_ev },
            .hist_range = .{ min_log2, log2_range, if (reset) 2.0 else 1.0, exposure.hybrid_transition_stops },
            .physical_params = .{ if (physical.enabled) 1.0 else 0.0, scale_log2, physical.manualEv100(), 0.0 },
        };
        try rec.beginComputePass(.{ .label = "exposure adapt" });
        try rec.setComputePipeline(ex.adapt);
        try rec.setBindGroup(0, g.empty_group, &.{});
        try rec.setBindGroup(1, ex.g_adapt_out, &.{});
        try rec.setBindGroup(2, ex.g_adapt_uniform, &.{try ring.pushValue(ap)});
        try rec.dispatch(1, 1, 1);
        try rec.endComputePass();

        self.exposure_history_valid = true;
        self.exposure_prev_camera = cam;
        self.exposure_camera_key = self.frame_data.camera_key;
        self.exposure_physical_mode = physical.enabled;
        self.exposure_scale_log2 = scale_log2;
        self.exposure_history_epoch = exposure.history_epoch;
        self.exposure_frame +%= 1;
    }

    const LitParams = struct {
        light_vps: [4]math3d.Mat4,
        cascade_texel_world: [4]f32,
        cascade_splits: [4]f32,
        cascade_depth_ranges: [4]f32,
        cascade_overlap: f32,
        cascade_count: f32,
        shadows_enabled: f32,
        shadow_bias: f32,
        normal_offset_texels: f32,
        sun_layers: u32,
        pre_gain: f32,
        pr_count: usize,
        z_scale: f32,
        z_bias: f32,
        volumetric_active: bool,
        ssao_view: gpu.TextureViewHandle,
    };

    fn shadowMapKey(self: *PbrRenderer, light_vp: math3d.Mat4, light_layers: u32, extra: []const f32) u64 {
        var hs = shadow_plan.CasterHasher.init(0x5ad0_77a1);
        for (self.queued_draws.items) |qm| {
            if (!pbr.layersOverlap(light_layers, qm.layers)) continue;
            const mesh = self.base.meshes.get(@bitCast(qm.mesh_asset)) orelse continue;
            if (shadow_cull.sphereOutsideLightFrustum(light_vp.m, shadow_cull.transformSphere(qm.model_matrix, mesh.bounds))) continue;
            hs.addDraw(qm);
        }
        for (self.shadow_casters.items) |sc| {
            if (!pbr.layersOverlap(light_layers, sc.layers)) continue;
            const mesh = self.base.meshes.get(@bitCast(sc.mesh_asset)) orelse continue;
            if (shadow_cull.sphereOutsideLightFrustum(light_vp.m, shadow_cull.transformSphere(sc.model_matrix, mesh.bounds))) continue;
            hs.addCaster(sc);
        }
        hs.addFloats(&.{@as(f32, @floatFromInt(light_layers & pbr.ALL_LAYERS))});
        hs.addFloats(&light_vp.m);
        hs.addFloats(extra);
        return hs.final();
    }

    /// The lit pass: opaque draws front to back, then blended draws back to front, into the HDR target.
    fn litPass(self: *PbrRenderer, input: *frame.FrameInput, g: *Gpu, hdr: Target, depth_view: gpu.TextureViewHandle, probe_view: gpu.TextureViewHandle, reuse_depth: bool, lp: LitParams) !void {
        const rec = input.recorder;
        const device = input.device;
        const groups = &self.groups.?;
        const pp = self.frame_data.post_process;
        const dirs = self.frame_data.directional_lights;
        const shadow_q = pp.quality.shadows;
        const tex_w = input.target.width;
        const tex_h = input.target.height;

        var pt_pos: [4][4]f32 = @splat(.{ 0, 0, 0, 1 });
        var pt_col: [4][4]f32 = @splat(.{ 0, 0, 0, 0 });
        const p_n = @min(self.frame_data.point_lights.len, 4);
        for (0..p_n) |i| {
            const pl = self.frame_data.point_lights[i];
            const sc = pl.intensity_lumens / 100.0;
            pt_pos[i] = .{ pl.position[0], pl.position[1], pl.position[2], pl.range };
            pt_col[i] = .{ pl.color[0] * sc, pl.color[1] * sc, pl.color[2] * sc, pl.radius };
        }
        var sp_pos: [2][4]f32 = @splat(.{ 0, 0, 0, 1 });
        var sp_dir: [2][4]f32 = @splat(.{ 0, -1, 0, 0.9 });
        var sp_col: [2][4]f32 = @splat(.{ 0, 0, 0, 0.8 });
        const s_n = @min(self.frame_data.spot_lights.len, 2);
        for (0..s_n) |i| {
            const sl = self.frame_data.spot_lights[i];
            const sc = sl.intensity_lumens / 100.0;
            sp_pos[i] = .{ sl.position[0], sl.position[1], sl.position[2], sl.range };
            sp_dir[i] = .{ sl.direction[0], sl.direction[1], sl.direction[2], @cos(sl.inner_angle_rad) };
            sp_col[i] = .{ sl.color[0] * sc, sl.color[1] * sc, sl.color[2] * sc, @cos(sl.outer_angle_rad) };
        }

        const has_dir = dirs.len > 0;
        const dl_dir: [3]f32 = if (has_dir) .{ -dirs[0].direction[0], -dirs[0].direction[1], -dirs[0].direction[2] } else .{ 0.4, 0.8, 0.45 };
        const dl_col: [3]f32 = if (has_dir) dirs[0].color else .{ 1, 1, 1 };
        const dl_int: f32 = if (has_dir) dirs[0].illuminance_lux / 2500.0 else 0.0;

        var sh_arr: [9][4]f32 = undefined;
        for (0..9) |i| sh_arr[i] = .{ self.sky_sh.coeffs[i][0], self.sky_sh.coeffs[i][1], self.sky_sh.coeffs[i][2], 0.0 };
        sh_arr[0][3] = if (pp.ssao.enabled) 1.0 else 0.0;
        sh_arr[1][3] = 1.0 / @as(f32, @floatFromInt(tex_w));
        sh_arr[2][3] = 1.0 / @as(f32, @floatFromInt(tex_h));
        sh_arr[3][3] = if (pp.contact_shadows.enabled) 1.0 else 0.0;
        sh_arr[4][3] = if (pp.quality.specular_aa) 1.0 else 0.0;
        // 1 = distance-widened filter, 2 = blocker-search PCSS (needs the quality switch as well).
        const pcss_on: f32 = if (has_dir and dirs[0].pcss_enabled) (if (shadow_q.pcss) 2.0 else 1.0) else 0.0;
        const vol_on: f32 = if (lp.volumetric_active) 1.0 else 0.0;

        // Opaque before transparent; transparent back to front, so alpha blending composes correctly.
        self.draw_order.clearRetainingCapacity();
        try self.draw_order.ensureTotalCapacity(self.allocator, self.queued_draws.items.len);
        const cam_p = self.frame_data.camera_position;
        for (self.queued_draws.items, 0..) |qm, i| {
            const dx = qm.model_matrix[12] - cam_p[0];
            const dy = qm.model_matrix[13] - cam_p[1];
            const dz = qm.model_matrix[14] - cam_p[2];
            self.draw_order.appendAssumeCapacity(.{
                .index = @intCast(i),
                .depth = dx * dx + dy * dy + dz * dz,
                .blend = qm.material.alpha_mode == .blend,
                .double_sided = qm.material.double_sided,
            });
        }
        std.mem.sort(layout.DrawOrderEntry, self.draw_order.items, {}, layout.drawOrderLess);

        // Per-draw uniform buffers must be big enough before recording (their bind groups are referenced below).
        const vs_stride = gpu_objects.slotSize(device, @sizeOf(layout.PbrVertUniforms));
        const fs_stride = gpu_objects.slotSize(device, @sizeOf(layout.PbrFragUniforms));
        const draws = self.queued_draws.items.len;
        try self.ensureDrawBuffer(g, &self.draw_vs, g.l_vs_pbr, @sizeOf(layout.PbrVertUniforms), @max(draws, 1) * vs_stride, "pbr vs uniforms");
        try self.ensureDrawBuffer(g, &self.draw_fs, g.l_fs_pbr, @sizeOf(layout.PbrFragUniforms), @max(draws, 1) * fs_stride, "pbr fs uniforms");

        const frame_group = try groups.get(frame_res.key(&.{ 0xf4a3, frame_res.bits(lp.ssao_view), frame_res.bits(probe_view) }), .{ .layout = g.l_frame, .entries = &.{
            .{ .binding = 3, .resource = .{ .texture_view = g.shadow_atlas.view } },
            .{ .binding = 35, .resource = .{ .sampler = g.shadow_cmp } },
            .{ .binding = 4, .resource = .{ .texture_view = g.env_prefilter.view } },
            .{ .binding = 36, .resource = .{ .sampler = g.ibl } },
            .{ .binding = 5, .resource = .{ .texture_view = g.brdf_lut.view } },
            .{ .binding = 37, .resource = .{ .sampler = g.linear } },
            .{ .binding = 6, .resource = .{ .texture_view = lp.ssao_view } },
            .{ .binding = 38, .resource = .{ .sampler = g.linear } },
            .{ .binding = 7, .resource = .{ .texture_view = g.local_shadow.view } },
            .{ .binding = 39, .resource = .{ .sampler = g.shadow_cmp } },
            .{ .binding = 10, .resource = .{ .texture_view = g.shadow_atlas.view } },
            .{ .binding = 42, .resource = .{ .sampler = g.nearest } },
            .{ .binding = 11, .resource = .{ .texture_view = g.local_shadow.view } },
            .{ .binding = 43, .resource = .{ .sampler = g.nearest } },
            .{ .binding = 12, .resource = .{ .texture_view = probe_view } },
            .{ .binding = 44, .resource = .{ .sampler = g.ibl } },
            .{ .binding = 13, .resource = .{ .texture_view = if (g.ltc) |l| l.view else g.black.view } },
            .{ .binding = 45, .resource = .{ .sampler = g.nearest } },
            .{ .binding = 14, .resource = .{ .buffer = .{ .buffer = g.cluster_lights } } },
            .{ .binding = 15, .resource = .{ .buffer = .{ .buffer = g.cluster_grid } } },
            .{ .binding = 16, .resource = .{ .buffer = .{ .buffer = g.cluster_indices } } },
            .{ .binding = 17, .resource = .{ .buffer = .{ .buffer = g.local_shadow_buf } } },
        } });

        // With screen transport the lit pass also writes surface/diffuse/specular metadata; they start as "no data".
        var lit_attachments: [4]gpu.ColorAttachment = undefined;
        lit_attachments[0] = .{ .target = .{ .view = hdr.view }, .load = .load };
        var lit_attachment_count: usize = 1;
        const transport: ?Gpu.Screen = if (self.screen_on) g.screen_gpu.? else null;
        if (self.screen_on) {
            const sc = self.screen.?;
            lit_attachments[1] = .{ .target = .{ .view = sc.surface.view }, .load = .clear, .clear_value = .{ .r = 0, .g = 0, .b = -1, .a = 0 } };
            lit_attachments[2] = .{ .target = .{ .view = sc.diffuse.view }, .load = .clear, .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 } };
            lit_attachments[3] = .{ .target = .{ .view = sc.specular.view }, .load = .clear, .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 } };
            lit_attachment_count = 4;
        }
        try rec.beginRenderPass(.{
            .label = "pbr lit",
            .color_attachments = lit_attachments[0..lit_attachment_count],
            // Reusing the prepass depth relies on both passes producing identical depth (same MVP, invariant
            // position, same alpha-mask discard) and on the less-or-equal pipelines.
            .depth = .{ .view = depth_view, .depth_load = if (reuse_depth) .load else .clear },
        });
        try rec.setViewport(0, 0, @floatFromInt(tex_w), @floatFromInt(tex_h));
        try rec.setBindGroup(2, frame_group, &.{});

        var active_pipe: ?gpu.RenderPipelineHandle = null;
        for (self.draw_order.items) |entry| {
            const qm = self.queued_draws.items[entry.index];
            const mesh = self.base.meshes.get(@bitCast(qm.mesh_asset)) orelse continue;
            const mat = qm.material;
            const want: gpu.RenderPipelineHandle = if (transport) |t|
                (if (mat.alpha_mode == .blend)
                    t.pbr_blend
                else if (mat.double_sided)
                    (if (reuse_depth) t.pbr_reuse_double_sided else t.pbr_double_sided)
                else
                    (if (reuse_depth) t.pbr_reuse else t.pbr_opaque))
            else if (mat.alpha_mode == .blend)
                g.pbr_blend
            else if (mat.double_sided)
                (if (reuse_depth) g.pbr_reuse_double_sided else g.pbr_double_sided)
            else
                (if (reuse_depth) g.pbr_reuse else g.pbr_opaque);
            if (active_pipe == null or !active_pipe.?.eql(want)) {
                try rec.setRenderPipeline(want);
                active_pipe = want;
            }
            const store = input.textures;
            const base_v = if (store.get(mat.base_color_tex)) |e| e.view else g.white.view;
            const norm_v = if (store.get(mat.normal_tex)) |e| e.view else g.flat_normal.view;
            const mr_v = if (store.get(mat.metallic_roughness_tex)) |e| e.view else g.white.view;
            const ao_v = if (store.get(mat.ao_tex)) |e| e.view else g.white.view;
            const em_v = if (store.get(mat.emissive_tex)) |e| e.view else g.white.view;
            const mat_group = try groups.get(frame_res.key(&.{ 0x6d01, frame_res.bits(base_v), frame_res.bits(norm_v), frame_res.bits(mr_v), frame_res.bits(ao_v), frame_res.bits(em_v) }), .{ .layout = g.l_material, .entries = &.{
                .{ .binding = 0, .resource = .{ .texture_view = base_v } },
                .{ .binding = 32, .resource = .{ .sampler = g.material } },
                .{ .binding = 1, .resource = .{ .texture_view = norm_v } },
                .{ .binding = 33, .resource = .{ .sampler = g.material } },
                .{ .binding = 2, .resource = .{ .texture_view = mr_v } },
                .{ .binding = 34, .resource = .{ .sampler = g.material } },
                .{ .binding = 8, .resource = .{ .texture_view = ao_v } },
                .{ .binding = 40, .resource = .{ .sampler = g.material } },
                .{ .binding = 9, .resource = .{ .texture_view = em_v } },
                .{ .binding = 41, .resource = .{ .sampler = g.material } },
            } });

            const vu = layout.PbrVertUniforms{
                .model = qm.model_matrix,
                .normal_matrix = util.normalMatrixFromModel(qm.model_matrix),
                .mvp = qm.mvp_matrix,
                .light_vp = .{ lp.light_vps[0].m, lp.light_vps[1].m, lp.light_vps[2].m, lp.light_vps[3].m },
                .shadow_offset = .{ lp.normal_offset_texels, 0, 0, 0 },
                .cascade_texel = lp.cascade_texel_world,
                .to_sun = .{ dl_dir[0], dl_dir[1], dl_dir[2], 0 },
            };
            sh_arr[5][3] = if (mat.alpha_mode == .blend) 1.0 else 0.0;
            const fu = layout.PbrFragUniforms{
                .camera_pos_fog = .{ self.frame_data.camera_position[0], self.frame_data.camera_position[1], self.frame_data.camera_position[2], if (self.frame_data.fog.enabled) 1.0 else 0.0 },
                .base_color = .{ mat.base_color[0] * qm.tint[0], mat.base_color[1] * qm.tint[1], mat.base_color[2] * qm.tint[2], mat.base_color[3] * qm.tint[3] },
                .emissive_weight = .{ mat.emissive[0], mat.emissive[1], mat.emissive[2], mat.emissive_exposure_weight },
                .mat_params = .{ mat.metallic, mat.roughness, mat.reflectance, mat.ao_strength },
                .mat_flags = .{ if (mat.unlit) 1.0 else 0.0, if (mat.normal_tex != 0) mat.normal_scale else 0.0, lp.shadow_bias, lp.shadows_enabled },
                .ambient_sky = .{ self.frame_data.ambient.color[0] * self.frame_data.ambient.brightness, self.frame_data.ambient.color[1] * self.frame_data.ambient.brightness, self.frame_data.ambient.color[2] * self.frame_data.ambient.brightness, self.frame_data.fog.density },
                .fog_color_start = .{ self.frame_data.fog.color[0], self.frame_data.fog.color[1], self.frame_data.fog.color[2], self.frame_data.fog.start_distance },
                .dir_light_dir = .{ dl_dir[0], dl_dir[1], dl_dir[2], dl_int },
                .dir_light_col = .{ dl_col[0], dl_col[1], dl_col[2], @floatFromInt(p_n) },
                .point_pos = pt_pos,
                .point_col = pt_col,
                .sky_zenith = .{ self.frame_data.sky.sky_tint[0], self.frame_data.sky.sky_tint[1], self.frame_data.sky.sky_tint[2], @floatFromInt(s_n) },
                .sky_horizon = .{ self.frame_data.sky.horizon_tint[0], self.frame_data.sky.horizon_tint[1], self.frame_data.sky.horizon_tint[2], @floatFromInt(layout.ENV_MIPS - 1) },
                .spot_pos = sp_pos,
                .spot_dir = sp_dir,
                .spot_col = sp_col,
                .sh_coeffs = sh_arr,
                .camera_fwd_overlap = .{ self.frame_data.camera_forward[0], self.frame_data.camera_forward[1], self.frame_data.camera_forward[2], lp.cascade_overlap },
                .cascade_splits = lp.cascade_splits,
                .cascade_depth_ranges = lp.cascade_depth_ranges,
                .cluster_factors = .{ lp.z_scale, lp.z_bias, 1.0, if (mat.alpha_mode == .mask) mat.alpha_cutoff else -1.0 },
                .probe_volumetric = .{ @floatFromInt(lp.pr_count), pcss_on, vol_on, self.frame_data.fog.volumetric.scattering },
                .layer_info = .{ @floatFromInt(qm.layers & pbr.ALL_LAYERS), @floatFromInt(lp.sun_layers & pbr.ALL_LAYERS), lp.pre_gain, if (pp.quality.ltc_area_lights and g.ltc != null) 2.0 else if (pp.quality.area_light_quadrature) 1.0 else 0.0 },
                .cascade_info = .{ lp.cascade_count, if (has_dir) dirs[0].pcss_light_size else 0.03, shadow_q.depth_bias_floor_m, if (shadow_q.pcss) 1.0 else 0.0 },
            };
            const vs_off = try pushSlot(&self.vs_scratch, self.allocator, vs_stride, std.mem.asBytes(&vu));
            const fs_off = try pushSlot(&self.fs_scratch, self.allocator, fs_stride, std.mem.asBytes(&fu));
            try rec.setBindGroup(0, mat_group, &.{});
            try rec.setBindGroup(1, self.draw_vs.group.?, &.{vs_off});
            try rec.setBindGroup(3, self.draw_fs.group.?, &.{fs_off});
            try rec.setVertexBuffer(0, mesh.vertex_buffer, 0, 0);
            try rec.setIndexBuffer(mesh.index_buffer, .uint32, 0, 0);
            try rec.drawIndexed(mesh.index_count, 1, 0, 0, 0);
        }
        try rec.endRenderPass();
        try self.flushScratch(g, &self.draw_vs, &self.vs_scratch, g.l_vs_pbr, @sizeOf(layout.PbrVertUniforms), "pbr vs uniforms");
        try self.flushScratch(g, &self.draw_fs, &self.fs_scratch, g.l_fs_pbr, @sizeOf(layout.PbrFragUniforms), "pbr fs uniforms");
    }
};
