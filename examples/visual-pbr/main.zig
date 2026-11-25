//! Visual PBR, Shadows, Sky, Compute Auto Exposure, Bloom & Tonemapping Demo (`examples/visual-pbr/main.zig`).
//!
//! Controls:
//! - W/A/S/D (+Shift sprint, Q/E down/up) + Right-Click Drag: Fly FreeCamera
//! - 1 / 2 / 3 / 4 / 5: Tonemapper (AgX Base, AgX Punchy, ACES, PBR Neutral, Neutral)
//! - X: Toggle Compute Auto Exposure
//! - B: Toggle HDR Bloom
//! - F: Toggle Atmospheric Distance Fog
//! - G: Toggle Directional CSM Shadows
//! - O: Toggle Screen-Space Ambient Occlusion (SSAO)
//! - N: Cycle Sky Brightness (HDRI -> Day -> Dusk -> Night)
//! - V: Toggle Vignette
//! - R: Toggle Sun Rotation (Day/Sunset cycle)
//!
//! Run with: `zig build run-visual-pbr`
//!
//! Capture mode (render regression harness): set `ZENGY_CAPTURE_DIR=<dir>` to render a fixed list of
//! scenarios, write `<name>.png`, `<name>.hdr.png` and `<name>.stats.txt` per scenario into `<dir>`, compare
//! them with the goldens in `ZENGY_CAPTURE_GOLDEN` (default `tests/golden/visual-pbr`) and exit non-zero on a
//! regression. Set `ZENGY_CAPTURE_UPDATE=1` to write the goldens instead of comparing.

const std = @import("std");
const engine = @import("engine");
const window_sdl3 = @import("window_sdl3");
const graphics = @import("graphics");
const wgpu = @import("graphics_wgpu");
const draw_2d = @import("draw_2d");
const gpu_3d = @import("gpu_3d");
const input = @import("input");
const input_sdl3 = @import("input_sdl3");
const camera = @import("camera");
const render_3d = @import("render_3d");
const gizmos = @import("gizmos");

const testing_sdk = @import("testing_sdk");
const capture = testing_sdk.render_regression;

const SKY_HDR_BYTES = @embedFile("assets/sky.hdr");

const PbrDemoState = struct {
    app: *engine.App,
    gfx: *graphics.GraphicsDeviceService,
    rt: graphics.RenderTargetHandle,
    cam_entity: engine.EntityHandle,
    sun_entity: engine.EntityHandle,
    sun_angle: f32 = 0.75,
    rotate_sun: bool = false,
    sky_preset: u8 = 0, // 0=HDRI, 1=Day, 2=Dusk, 3=Night
    hud1: [180]u8 = @splat(0),
    hud1_len: usize = 0,
    hud2: [180]u8 = @splat(0),
    hud2_len: usize = 0,
    in_vol_room: bool = false,
    /// Entity moved by the `nudge` scenarios (the alpha-masked panel, a shadow caster), and its home position.
    nudge_entity: engine.EntityHandle,
    /// The shadowed spot light and the two point lights; `light_radius` scenarios resize their sources.
    local_lights: [3]engine.EntityHandle,
    /// Intensities the three local lights were spawned with, restored by every scenario.
    local_light_lumens: [3]f32,
    /// The sky HDRI and an identical copy at another address; `hdri_swap` scenarios switch between them to force a
    /// re-upload without changing the picture.
    hdri_main: []const [4]f32,
    hdri_alt: []const [4]f32,
    /// Present only in capture mode (`ZENGY_CAPTURE_DIR`); drives the scenarios instead of the keyboard.
    capture: ?CaptureRunner = null,
    show_gizmos: bool = false,
};

/// Failures found by the capture runner; read after the loop to set the process exit status.
var g_capture_failures: u32 = 0;

// ---------------------------------------------------------------------------------------------------------
// Capture scenarios
// ---------------------------------------------------------------------------------------------------------

/// Frames rendered before a scenario is captured, so auto exposure and the IBL cache settle.
const WARMUP_FRAMES: u32 = 90;
/// Frames to wait for a requested capture before the scenario is reported as failed.
const WAIT_LIMIT_FRAMES: u32 = 30;
/// Per-channel difference (0-255) up to which two pixels count as equal.
const PIXEL_THRESHOLD: u8 = 8;
/// Allowed fraction of pixels that differ from the golden image.
const MAX_DIFF_FRACTION: f64 = 0.002;
/// Luma margin (0-255) by which a pixel must exceed all 8 neighbours to count as a speckle.
const SPECKLE_MARGIN: f32 = 40;

const Pose = enum { gallery, vol_room, closeup, materials };

const Scenario = struct {
    name: []const u8,
    pose: Pose = .gallery,
    fog: bool = true,
    ssao: bool = true,
    shadows: bool = true,
    bloom: bool = true,
    aa: bool = true,
    sky_preset: u8 = 0,
    /// Render with `RenderQuality.reuse_depth_prepass`.
    reuse_depth: bool = false,
    /// Rebuild the environment with the time-sliced budget.
    sliced_ibl: bool = false,
    /// Compare against the golden of this other scenario instead of owning one. Switches that must not change
    /// the picture (depth reuse, sliced IBL) are checked this way, with the normal tolerances.
    golden_of: ?[]const u8 = null,
    /// Volumetric temporal accumulation.
    temporal: bool = false,
    /// Move the camera during the warm-up and settle on the exact pose for the last frames, so a wrong
    /// reprojection leaves ghosts that the golden comparison sees.
    shake: bool = false,
    /// Capture a second frame and require it to match the first (frame-to-frame stability under jitter).
    stability: bool = false,
    shadow_normal_offset: bool = false,
    shadow_prioritize: bool = false,
    shadow_cache: bool = false,
    shadow_adaptive: bool = false,
    shadow_pcss: bool = false,
    /// Largest per-channel difference tolerated against the golden, on top of the pixel-fraction limit. Catches
    /// small but strong artefacts such as ghosts that touch few pixels.
    max_delta: u8 = 255,
    /// Share of pixels allowed to differ from the golden. Near-black scenes whose reference is a different scenario
    /// (`golden_of`) differ faintly almost everywhere, so they use a wider share together with a `max_delta` gate.
    max_fraction: f64 = MAX_DIFF_FRACTION,
    /// Half-resolution volumetric march.
    vol_half: bool = false,
    /// Alternate between two distant poses every frame, so the capture frame is a camera cut for the temporal fog.
    cut: bool = false,
    /// Move the panel caster mid warm-up, to check that shadow caches invalidate and match an uncached run.
    nudge: bool = false,
    /// Use the identical HDRI copy at another address, forcing the environment job to re-upload the texture.
    hdri_swap: bool = false,
    /// Sun normal bias for the normal-offset sweep.
    normal_bias: f32 = 0.02,
    /// Part of the normal-offset sweep: compared with `golden_of` by luma and high-frequency energy instead of
    /// pixel difference, because the offset moves shadow edges on purpose.
    bias_gate: bool = false,
    /// Grazing-sun acne study: sun direction, cascade depth-bias floor (metres) and the light's own depth bias.
    sun_dir: [3]f32 = DEFAULT_SUN_DIR,
    bias_floor: f32 = 0.055,
    sun_bias: f32 = 0.005,
    acne_check: AcneCheck = .none,
    /// Source radius (metres) given to the spot and point lights; 0 keeps their defaults.
    light_radius: f32 = 0,
    /// Sun illuminance override (lux); 0 keeps the sky preset's value. A dim sun lets local-light shadows show.
    sun_lux: f32 = 0,
    /// Layer mask given to the spot and point lights (they affect only meshes sharing a layer; meshes use layer 0).
    light_layers: u32 = render_3d.pbr.ALL_LAYERS,
    /// Switch the three local lights off by intensity (the reference for a layer mask that excludes every mesh).
    lights_off: bool = false,
};

/// Expectation on the floor's fine-grained contrast relative to the `acne_ref` golden.
const AcneCheck = enum {
    none,
    /// Acne must be visible: the scene has to be able to produce the artefact the other checks guard against.
    expect_acne,
    /// Acne must be gone (within 5% of the reference) without shifting the floor's mean luma by more than 1%.
    expect_clean,
};

const DEFAULT_SUN_DIR = [3]f32{ -0.45, -0.75, -0.45 };
/// Sun low over the horizon: surfaces face it at a grazing angle, which is where shadow acne appears.
const GRAZING_SUN_DIR = [3]f32{ -0.9, -0.16, -0.4 };

const SCENARIOS = [_]Scenario{
    .{ .name = "gallery_default" },
    .{ .name = "gallery_fog_off", .fog = false },
    .{ .name = "gallery_ssao_off", .ssao = false },
    .{ .name = "gallery_shadows_off", .shadows = false },
    .{ .name = "gallery_bloom_off", .bloom = false },
    .{ .name = "gallery_aa_off", .aa = false },
    .{ .name = "gallery_dusk", .sky_preset = 2 },
    .{ .name = "closeup_default", .pose = .closeup },
    .{ .name = "closeup_fog_off", .pose = .closeup, .fog = false },
    .{ .name = "vol_room_default", .pose = .vol_room },
    .{ .name = "vol_room_fog_off", .pose = .vol_room, .fog = false },
    .{ .name = "materials_default", .pose = .materials },
    .{ .name = "materials_fog_off", .pose = .materials, .fog = false },
    .{ .name = "materials_shadows_off", .pose = .materials, .shadows = false },
    // Must look like their `golden_of` scenario: silhouette integrity for depth reuse, and the settled result of
    // a time-sliced environment rebuild (the preceding scenarios use another sky, so a rebuild happens).
    .{ .name = "gallery_reuse_depth", .reuse_depth = true, .golden_of = "gallery_default" },
    .{ .name = "closeup_reuse_depth", .pose = .closeup, .reuse_depth = true, .golden_of = "closeup_default" },
    .{ .name = "materials_reuse_depth", .pose = .materials, .reuse_depth = true, .golden_of = "materials_default" },
    .{ .name = "vol_room_reuse_depth", .pose = .vol_room, .reuse_depth = true, .golden_of = "vol_room_default" },
    .{ .name = "gallery_dusk_sliced_ibl", .sky_preset = 2, .sliced_ibl = true, .golden_of = "gallery_dusk" },
    // Phase 4: temporal volumetric fog. A static camera must converge to the single-frame result, stay stable from
    // frame to frame, and a moving camera must not leave ghosts once it stops.
    .{ .name = "vol_room_temporal", .pose = .vol_room, .temporal = true, .stability = true, .max_delta = 16, .golden_of = "vol_room_default" },
    .{ .name = "gallery_temporal_shake", .temporal = true, .shake = true, .max_delta = 16, .golden_of = "gallery_default" },
    .{ .name = "gallery_temporal", .temporal = true, .stability = true, .max_delta = 16, .golden_of = "gallery_default" },
    // Phase 5: shadow scalability. Prioritisation and the cache must not change the picture; adaptive tiles change
    // it only slightly; normal offset and PCSS change it on purpose and own goldens.
    .{ .name = "gallery_shadow_prioritize", .shadow_prioritize = true, .golden_of = "gallery_default" },
    .{ .name = "gallery_shadow_cache", .shadow_cache = true, .golden_of = "gallery_default" },
    .{ .name = "vol_room_shadow_cache", .pose = .vol_room, .shadow_cache = true, .golden_of = "vol_room_default" },
    .{ .name = "vol_room_shadow_adaptive", .pose = .vol_room, .shadow_adaptive = true, .golden_of = "vol_room_default" },
    .{ .name = "gallery_normal_offset", .shadow_normal_offset = true },
    // Remaining Phase 3-5 coverage: a cut must not smear history, half-resolution temporal matches half-resolution
    // single frame, caches match an uncached run after a caster moved, and a re-uploaded HDRI is converted in slices.
    .{ .name = "gallery_temporal_cut", .temporal = true, .cut = true, .max_delta = 16, .golden_of = "gallery_default" },
    .{ .name = "gallery_half_res", .vol_half = true },
    .{ .name = "gallery_temporal_half", .vol_half = true, .temporal = true, .stability = true, .max_delta = 16, .golden_of = "gallery_half_res" },
    .{ .name = "materials_nudge", .pose = .materials, .nudge = true },
    .{ .name = "materials_nudge_cache", .pose = .materials, .nudge = true, .shadow_cache = true, .golden_of = "materials_nudge" },
    .{ .name = "gallery_hdri_swap_sliced", .hdri_swap = true, .sliced_ibl = true, .golden_of = "gallery_default" },
    // Acne study (grazing sun, floor in the lower 40% of the frame). `acne_ref` keeps the conservative bias floor; the
    // others remove the depth bias entirely so acne shows, then add normal offset at growing strength (bias x 50
    // texels). hf_floor is the fine-grained contrast of the floor, luma_floor its mean brightness.
    .{ .name = "acne_ref", .sun_dir = GRAZING_SUN_DIR },
    .{ .name = "acne_raw", .sun_dir = GRAZING_SUN_DIR, .bias_floor = 0.0, .sun_bias = 0.0, .acne_check = .expect_acne, .golden_of = "acne_ref" },
    .{ .name = "acne_n_005", .sun_dir = GRAZING_SUN_DIR, .bias_floor = 0.0, .sun_bias = 0.0, .shadow_normal_offset = true, .normal_bias = 0.005, .golden_of = "acne_ref" },
    .{ .name = "acne_n_010", .sun_dir = GRAZING_SUN_DIR, .bias_floor = 0.0, .sun_bias = 0.0, .shadow_normal_offset = true, .normal_bias = 0.01, .golden_of = "acne_ref" },
    .{ .name = "acne_n_020", .sun_dir = GRAZING_SUN_DIR, .bias_floor = 0.0, .sun_bias = 0.0, .shadow_normal_offset = true, .normal_bias = 0.02, .golden_of = "acne_ref" },
    .{ .name = "acne_n_050", .sun_dir = GRAZING_SUN_DIR, .bias_floor = 0.0, .sun_bias = 0.0, .shadow_normal_offset = true, .normal_bias = 0.05, .acne_check = .expect_clean, .golden_of = "acne_ref" },
    .{ .name = "acne_n_100", .sun_dir = GRAZING_SUN_DIR, .bias_floor = 0.0, .sun_bias = 0.0, .shadow_normal_offset = true, .normal_bias = 0.1, .acne_check = .expect_clean, .golden_of = "acne_ref" },
    // Normal-offset sweep (strength = normal_bias * 50 texels). Gated entries must keep the frame's mean luma within
    // 2% and its high-frequency energy within 15% of the plain render; the larger values are informational.
    .{ .name = "bias_sweep_005", .shadow_normal_offset = true, .normal_bias = 0.005, .bias_gate = true, .golden_of = "gallery_default" },
    .{ .name = "bias_sweep_020", .shadow_normal_offset = true, .normal_bias = 0.02, .bias_gate = true, .golden_of = "gallery_default" },
    .{ .name = "bias_sweep_080", .shadow_normal_offset = true, .normal_bias = 0.08, .golden_of = "gallery_default" },
    .{ .name = "bias_sweep_300", .shadow_normal_offset = true, .normal_bias = 0.3, .golden_of = "gallery_default" },
    .{ .name = "gallery_pcss", .shadow_pcss = true },
    // Local-light PCSS in the dark room with large light sources: the penumbra comes from each light's radius.
    // Layer masks: lights restricted to a layer no mesh uses must look like lights that are switched off.
    .{ .name = "vol_room_lights_zero", .pose = .vol_room, .fog = false, .lights_off = true },
    .{ .name = "vol_room_lights_masked", .pose = .vol_room, .fog = false, .light_layers = 0x2, .max_delta = 16, .max_fraction = 0.25, .golden_of = "vol_room_lights_zero" },
    .{ .name = "local_soft_off", .light_radius = 0.6, .sun_lux = 600, .fog = false },
    .{ .name = "local_pcss", .light_radius = 0.6, .sun_lux = 600, .fog = false, .shadow_pcss = true },
};

const CaptureStage = enum { warmup, wait_final, hold, wait_stable, wait_hdr };
/// Warm-up frames at the end of a shake scenario during which the camera holds the exact pose.
/// Panel position (x) the nudge scenarios start from, the warm-up frame at which it moves, and how far.
const NUDGE_HOME_X: f32 = -8.0;
const NUDGE_FRAME: u32 = 40;
const NUDGE_DISTANCE: f32 = 1.4;
const SHAKE_SETTLE_FRAMES: u32 = 4;
/// Allowed fraction of pixels that change between two frames of a stability scenario.
const MAX_FLICKER_FRACTION: f64 = 0.001;

const CaptureRunner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    out_dir: []const u8,
    golden_dir: []const u8,
    update_goldens: bool,
    scenario: usize = 0,
    /// Only scenarios whose name contains this text run (`ZENGY_CAPTURE_FILTER`); null runs all.
    filter: ?[]const u8 = null,
    stage: CaptureStage = .warmup,
    applied: bool = false,
    frames: u32 = 0,
    /// Final-frame RGB8 of the running scenario, kept until its HDR capture completes.
    final_rgb: ?[]u8 = null,
    final_w: u32 = 0,
    final_h: u32 = 0,
    speckle: u64 = 0,
    contrast: f32 = 0,
    hf_energy: f64 = 0,
    /// Fine-grained contrast and mean luma of the lower 40% of the frame (the floor in the gallery pose).
    hf_floor: f64 = 0,
    luma_floor: f64 = 0,
    /// Frame-time samples of the running scenario (CPU frame delta, trend only, never a pass/fail gate).
    dt_sum: f64 = 0,
    dt_max: f64 = 0,
    dt_frames: u32 = 0,

    fn fail(self: *CaptureRunner, name: []const u8, comptime fmt: []const u8, args: anytype) void {
        _ = self;
        g_capture_failures += 1;
        std.debug.print("[capture] FAIL {s}: " ++ fmt ++ "\n", .{name} ++ args);
    }

    fn writeFile(self: *CaptureRunner, dir: []const u8, name: []const u8, ext: []const u8, bytes: []const u8) !void {
        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}{s}", .{ dir, name, ext });
        defer self.allocator.free(path);
        const file = try std.Io.Dir.cwd().createFile(self.io, path, .{});
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, bytes);
    }

    fn readFile(self: *CaptureRunner, dir: []const u8, name: []const u8, ext: []const u8) ?[]u8 {
        const path = std.fmt.allocPrint(self.allocator, "{s}/{s}{s}", .{ dir, name, ext }) catch return null;
        defer self.allocator.free(path);
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(64 * 1024 * 1024)) catch null;
    }

    fn writePng(self: *CaptureRunner, dir: []const u8, name: []const u8, ext: []const u8, w: u32, h: u32, rgb: []const u8) !void {
        const png = try capture.encodePngRgb8(self.allocator, w, h, rgb);
        defer self.allocator.free(png);
        try self.writeFile(dir, name, ext, png);
    }

    /// Stores the final frame, measures it, and compares it with the golden image.
    fn handleFinal(self: *CaptureRunner, sc: Scenario, img: capture.Image) !void {
        const rgb = try capture.displayToRgb8(self.allocator, img);
        errdefer self.allocator.free(rgb);
        try self.writePng(self.out_dir, sc.name, ".png", img.width, img.height, rgb);
        self.speckle = capture.speckleCount(rgb, img.width, img.height, SPECKLE_MARGIN);
        self.contrast = try capture.contrastSpread(self.allocator, rgb);
        self.hf_energy = capture.highFrequencyEnergy(rgb, img.width, img.height);
        const floor_y = img.height * 3 / 5;
        self.hf_floor = capture.highFrequencyEnergyRect(rgb, img.width, img.height, 0, floor_y, img.width, img.height);
        self.luma_floor = capture.meanLumaRect(rgb, img.width, img.height, 0, floor_y, img.width, img.height);
        if (std.mem.startsWith(u8, sc.name, "acne_")) {
            std.debug.print("[capture] {s}: hf_floor={d:.4} luma_floor={d:.3}\n", .{ sc.name, self.hf_floor, self.luma_floor });
        }
        if (self.final_rgb) |old| self.allocator.free(old);
        self.final_rgb = rgb;
        self.final_w = img.width;
        self.final_h = img.height;
        if (self.update_goldens) return;

        const golden_name = sc.golden_of orelse sc.name;
        const golden_bytes = self.readFile(self.golden_dir, golden_name, ".png") orelse {
            self.fail(sc.name, "no golden image in {s} (run with ZENGY_CAPTURE_UPDATE=1 to create it)", .{self.golden_dir});
            return;
        };
        defer self.allocator.free(golden_bytes);
        var golden = capture.decodePngRgb8(self.allocator, golden_bytes) catch |err| {
            self.fail(sc.name, "golden image is unreadable ({s})", .{@errorName(err)});
            return;
        };
        defer golden.deinit(self.allocator);
        if (golden.width != img.width or golden.height != img.height) {
            self.fail(sc.name, "size {d}x{d} differs from golden {d}x{d}", .{ img.width, img.height, golden.width, golden.height });
            return;
        }
        const diff = try capture.compareRgb8(rgb, golden.rgb, PIXEL_THRESHOLD);
        const frac = diff.differingFraction();
        std.debug.print("[capture] {s}: {d:.4}% pixels differ (max delta {d})\n", .{ sc.name, frac * 100.0, diff.max_delta });
        if (diff.max_delta > sc.max_delta) {
            self.fail(sc.name, "max channel delta {d} exceeds {d} (localised artefact such as a ghost)", .{ diff.max_delta, sc.max_delta });
        }
        const sweep = sc.bias_gate or std.mem.startsWith(u8, sc.name, "bias_sweep") or std.mem.startsWith(u8, sc.name, "acne_n_") or sc.acne_check != .none;
        if (frac > sc.max_fraction and !sweep) {
            self.fail(sc.name, "{d:.3}% of pixels differ from the golden (limit {d:.3}%)", .{ frac * 100.0, sc.max_fraction * 100.0 });
            const diff_img = try capture.diffImageRgb8(self.allocator, rgb, golden.rgb, PIXEL_THRESHOLD);
            defer self.allocator.free(diff_img);
            try self.writePng(self.out_dir, sc.name, ".diff.png", img.width, img.height, diff_img);
        }
    }

    /// Writes `<scenario>.timing.txt` and appends a row to `timing.csv` in the output directory.
    fn writeTiming(self: *CaptureRunner, sc: Scenario) !void {
        if (self.dt_frames == 0) return;
        const mean_ms = self.dt_sum / @as(f64, @floatFromInt(self.dt_frames)) * 1000.0;
        const max_ms = self.dt_max * 1000.0;
        const text = try std.fmt.allocPrint(self.allocator, "name={s}\nframes={d}\nmean_ms={d:.3}\nmax_ms={d:.3}\n", .{ sc.name, self.dt_frames, mean_ms, max_ms });
        defer self.allocator.free(text);
        try self.writeFile(self.out_dir, sc.name, ".timing.txt", text);
        std.debug.print("[capture] {s}: frame time mean {d:.2} ms, max {d:.2} ms over {d} frames (trend only)\n", .{ sc.name, mean_ms, max_ms, self.dt_frames });
    }

    /// Measures the HDR frame, writes the stats file, and checks it against the golden stats.
    fn handleHdr(self: *CaptureRunner, sc: Scenario, img: capture.Image) !void {
        const stats = try capture.hdrStats(self.allocator, img);
        const preview = try capture.hdrPreviewRgb8(self.allocator, img);
        defer self.allocator.free(preview);
        try self.writePng(self.out_dir, sc.name, ".hdr.png", img.width, img.height, preview);

        const text = try std.fmt.allocPrint(
            self.allocator,
            "name={s}\nwidth={d}\nheight={d}\nnan={d}\ninf={d}\nmean_luma={d:.4}\np50_luma={d:.4}\np95_luma={d:.4}\nspeckle={d}\ncontrast={d:.2}\nhf_energy={d:.4}\nhf_floor={d:.4}\nluma_floor={d:.4}\n",
            .{ sc.name, img.width, img.height, stats.nan_count, stats.inf_count, stats.mean_luma, stats.p50_luma, stats.p95_luma, self.speckle, self.contrast, self.hf_energy, self.hf_floor, self.luma_floor },
        );
        defer self.allocator.free(text);
        try self.writeFile(self.out_dir, sc.name, ".stats.txt", text);
        std.debug.print("[capture] {s}: nan={d} inf={d} mean_luma={d:.3} speckle={d} contrast={d:.1}\n", .{ sc.name, stats.nan_count, stats.inf_count, stats.mean_luma, self.speckle, self.contrast });

        if (stats.nan_count > 0 or stats.inf_count > 0) {
            self.fail(sc.name, "HDR frame has {d} NaN and {d} Inf pixels", .{ stats.nan_count, stats.inf_count });
        }

        if (self.update_goldens) {
            // Scenarios that borrow another golden never own one.
            if (sc.golden_of != null) return;
            if (self.final_rgb) |rgb| try self.writePng(self.golden_dir, sc.name, ".png", self.final_w, self.final_h, rgb);
            try self.writeFile(self.golden_dir, sc.name, ".stats.txt", text);
            return;
        }

        const golden_text = self.readFile(self.golden_dir, sc.golden_of orelse sc.name, ".stats.txt") orelse return;
        defer self.allocator.free(golden_text);
        if (capture.statValue(golden_text, "speckle")) |g| {
            const limit = @max(g * 1.5, g + 50.0);
            if (@as(f64, @floatFromInt(self.speckle)) > limit) {
                self.fail(sc.name, "speckle count {d} exceeds {d:.0} (golden {d:.0})", .{ self.speckle, limit, g });
            }
        }
        if (capture.statValue(golden_text, "contrast")) |g| {
            if (g > 0 and self.contrast < g * 0.85) {
                self.fail(sc.name, "contrast {d:.1} dropped below 85% of the golden {d:.1} (washed-out frame)", .{ self.contrast, g });
            }
        }
        if (capture.statValue(golden_text, "mean_luma")) |g| {
            if (g > 0 and @abs(@as(f64, stats.mean_luma) - g) / g > 0.25) {
                self.fail(sc.name, "mean luma {d:.3} is more than 25% away from the golden {d:.3}", .{ stats.mean_luma, g });
            }
        }
        if (sc.acne_check != .none) {
            const ref_hf = capture.statValue(golden_text, "hf_floor") orelse 0;
            const ref_luma = capture.statValue(golden_text, "luma_floor") orelse 0;
            if (ref_hf > 0) switch (sc.acne_check) {
                .expect_acne => if (self.hf_floor < ref_hf * 1.25) {
                    self.fail(sc.name, "floor contrast {d:.3} is not at least 25% above the reference {d:.3}: the scene no longer produces acne", .{ self.hf_floor, ref_hf });
                },
                .expect_clean => {
                    if (self.hf_floor > ref_hf * 1.05) {
                        self.fail(sc.name, "acne remains: floor contrast {d:.3} is more than 5% above the reference {d:.3}", .{ self.hf_floor, ref_hf });
                    }
                    if (@abs(self.luma_floor - ref_luma) / @max(ref_luma, 1.0) > 0.01) {
                        self.fail(sc.name, "floor luma {d:.2} moved more than 1% from {d:.2} (shadow thinning)", .{ self.luma_floor, ref_luma });
                    }
                },
                .none => {},
            };
        }
        if (capture.statValue(golden_text, "hf_energy")) |g| {
            std.debug.print("[capture] {s}: hf_energy={d:.4} (golden {d:.4})\n", .{ sc.name, self.hf_energy, g });
            if (sc.bias_gate) {
                if (self.hf_energy > g * 1.15) {
                    self.fail(sc.name, "high-frequency energy {d:.4} is more than 15% above {d:.4} (acne or noise)", .{ self.hf_energy, g });
                }
                if (capture.statValue(golden_text, "mean_luma")) |gm| {
                    if (gm > 0 and @abs(@as(f64, stats.mean_luma) - gm) / gm > 0.02) {
                        self.fail(sc.name, "mean luma {d:.4} moved more than 2% from {d:.4} (shadow thinning or peter-panning)", .{ stats.mean_luma, gm });
                    }
                }
            }
        }
    }
};

fn applySkyPreset(sky: *render_3d.pbr.SkyEnvironment, sun: *render_3d.pbr.DirectionalLight, preset: u8) void {
    switch (preset) {
        0 => {
            sky.kind = .hdri;
            sun.illuminance_lux = 24000.0;
            sun.color = .{ 1.0, 0.96, 0.90 };
        },
        1 => {
            sky.kind = .procedural;
            sky.sky_tint = .{ 0.14, 0.38, 0.85 };
            sky.horizon_tint = .{ 0.52, 0.70, 0.92 };
            sky.ground_albedo = .{ 0.14, 0.14, 0.16 };
            sun.illuminance_lux = 24000.0;
            sun.color = .{ 1.0, 0.96, 0.90 };
        },
        2 => {
            sky.kind = .procedural;
            sky.sky_tint = .{ 0.05, 0.10, 0.28 };
            sky.horizon_tint = .{ 0.35, 0.20, 0.18 };
            sky.ground_albedo = .{ 0.04, 0.04, 0.05 };
            sun.illuminance_lux = 1600.0;
            sun.color = .{ 1.0, 0.62, 0.38 };
        },
        else => {
            sky.kind = .procedural;
            sky.sky_tint = .{ 0.01, 0.02, 0.06 };
            sky.horizon_tint = .{ 0.03, 0.05, 0.12 };
            sky.ground_albedo = .{ 0.01, 0.01, 0.015 };
            sun.illuminance_lux = 180.0;
            sun.color = .{ 0.55, 0.70, 1.0 };
        },
    }
}

/// The free-camera controller rebuilds the pose orientation from its own yaw and pitch every frame, so a pose
/// assigned from outside is lost unless the controller re-reads it. Clearing `initialized` makes it do so.
fn resetFreeCamera(ctx: *engine.SystemContext, st: *PbrDemoState) void {
    if (ctx.world.get(st.cam_entity, camera.FreeCamera)) |fc| fc.state.initialized = false;
}

/// Configures the spot and point lights for a scenario: source radius (0 restores the default), layer mask, and
/// whether they are switched off.
fn applyLocalLights(ctx: *engine.SystemContext, st: *PbrDemoState, sc: Scenario) void {
    const default_radius: f32 = 0.05;
    const r = if (sc.light_radius > 0) sc.light_radius else default_radius;
    const scale: f32 = if (sc.lights_off) 0.0 else 1.0;
    if (ctx.world.get(st.local_lights[0], render_3d.pbr.SpotLight)) |sl| {
        sl.radius = r;
        sl.layers = sc.light_layers;
        sl.intensity_lumens = st.local_light_lumens[0] * scale;
    }
    for (1..3) |i| {
        if (ctx.world.get(st.local_lights[i], render_3d.pbr.PointLight)) |pl| {
            pl.radius = r;
            pl.layers = sc.light_layers;
            pl.intensity_lumens = st.local_light_lumens[i] * scale;
        }
    }
}

/// Camera pose of a scenario; `dx`/`dz` shift the eye (and a third of it the target) for the shake scenarios.
fn scenarioPose(pose: Pose, dx: f32, dz: f32) camera.CameraPose {
    const base: [2][3]f32 = switch (pose) {
        .gallery => .{ .{ 0, 2.6, 10.0 }, .{ 0, 2.6, 0 } },
        .vol_room => .{ .{ 11.2, 2.1, 2.8 }, .{ 15.2, 2.3, -1.2 } },
        .closeup => .{ .{ 0.5, 2.4, 5.5 }, .{ 0, 2.0, 0 } },
        .materials => .{ .{ -8.0, 1.9, 10.0 }, .{ -8.0, 1.2, 6.0 } },
    };
    const eye = [3]f32{ base[0][0] + dx, base[0][1], base[0][2] + dz };
    const target = [3]f32{ base[1][0] + dx * 0.3, base[1][1], base[1][2] + dz * 0.3 };
    return camera.CameraPose.lookAt(eye, target, .{ 0, 1, 0 });
}

fn applyScenario(
    sc: Scenario,
    cam_pose: *camera.CameraPose,
    pp: *render_3d.pbr.PostProcessSettings,
    sun: *render_3d.pbr.DirectionalLight,
    fog: *render_3d.pbr.FogSettings,
    sky: ?*render_3d.pbr.SkyEnvironment,
) void {
    cam_pose.* = scenarioPose(sc.pose, 0, 0);
    fog.volumetric.temporal = sc.temporal;
    fog.volumetric.half_resolution = sc.vol_half;
    sun.shadow_normal_bias = sc.normal_bias;
    sun.direction = sc.sun_dir;
    sun.shadow_depth_bias = sc.sun_bias;
    pp.quality.shadows = .{
        .normal_offset = sc.shadow_normal_offset,
        .prioritize_local_lights = sc.shadow_prioritize,
        .static_cache = sc.shadow_cache,
        .adaptive_atlas = sc.shadow_adaptive,
        .pcss = sc.shadow_pcss,
        .depth_bias_floor_m = sc.bias_floor,
    };
    fog.enabled = sc.fog;
    fog.volumetric.enabled = sc.fog;
    pp.ssao.enabled = sc.ssao;
    pp.contact_shadows.enabled = sc.ssao;
    pp.bloom.enabled = sc.bloom;
    pp.anti_aliasing = if (sc.aa) .fxaa else .none;
    pp.quality.reuse_depth_prepass = sc.reuse_depth;
    pp.quality.ibl_rebuild_budget = if (sc.sliced_ibl) .sliced else .unlimited;
    sun.shadows_enabled = sc.shadows;
    if (sky) |s_env| applySkyPreset(s_env, sun, sc.sky_preset);
    if (sc.sun_lux > 0) sun.illuminance_lux = sc.sun_lux;
}

/// Advances the capture state machine by one frame. A capture requested in frame N is recorded while frame N
/// renders and is available at the start of frame N + 1.
fn stepCapture(
    ctx: *engine.SystemContext,
    st: *PbrDemoState,
    cam_pose: *camera.CameraPose,
    pp: *render_3d.pbr.PostProcessSettings,
    sun: *render_3d.pbr.DirectionalLight,
    fog: *render_3d.pbr.FogSettings,
) !void {
    const cr = &st.capture.?;
    if (cr.scenario >= SCENARIOS.len) {
        if (cr.final_rgb) |rgb| cr.allocator.free(rgb);
        cr.final_rgb = null;
        std.debug.print("[capture] done: {d} scenario(s), {d} failure(s)\n", .{ SCENARIOS.len, g_capture_failures });
        st.app.quit();
        return;
    }
    if (cr.filter) |f| {
        while (cr.scenario < SCENARIOS.len and std.mem.indexOf(u8, SCENARIOS[cr.scenario].name, f) == null) cr.scenario += 1;
        if (cr.scenario >= SCENARIOS.len) return;
    }
    const sc = SCENARIOS[cr.scenario];
    switch (cr.stage) {
        .warmup => {
            if (!cr.applied) {
                applyScenario(sc, cam_pose, pp, sun, fog, ctx.resources.get(render_3d.pbr.SkyEnvironment));
                resetFreeCamera(ctx, st);
                if (ctx.resources.get(render_3d.pbr.SkyEnvironment)) |sky_env| {
                    sky_env.hdri_pixels = if (sc.hdri_swap) st.hdri_alt else st.hdri_main;
                }
                if (ctx.world.get(st.nudge_entity, render_3d.Transform3D)) |tr| tr.position[0] = NUDGE_HOME_X;
                applyLocalLights(ctx, st, sc);
                cr.dt_sum = 0;
                cr.dt_max = 0;
                cr.dt_frames = 0;
                cr.applied = true;
                cr.frames = 0;
            }
            cr.frames += 1;
            // The first frame of a scenario absorbs the previous capture's GPU readback stall, so it is not sampled.
            if (cr.frames > 1) {
                cr.dt_sum += ctx.dt;
                cr.dt_max = @max(cr.dt_max, ctx.dt);
                cr.dt_frames += 1;
            }
            if (sc.nudge and cr.frames == NUDGE_FRAME) {
                if (ctx.world.get(st.nudge_entity, render_3d.Transform3D)) |tr| tr.position[0] = NUDGE_HOME_X + NUDGE_DISTANCE;
            }
            if (sc.cut) {
                // Odd frames use the scenario pose, even frames a bright pose 8 m away (a dark one would also swing the
                // auto exposure). The final frame is odd, so the captured frame follows a cut.
                cam_pose.* = if (cr.frames % 2 == 1) scenarioPose(sc.pose, 0, 0) else scenarioPose(.materials, 0, 0);
                resetFreeCamera(ctx, st);
            }
            if (sc.shake and cr.frames + SHAKE_SETTLE_FRAMES < WARMUP_FRAMES) {
                const t: f32 = @floatFromInt(cr.frames);
                cam_pose.* = scenarioPose(sc.pose, @sin(t * 0.5) * 0.9, @cos(t * 0.31) * 0.6);
                resetFreeCamera(ctx, st);
            } else if (sc.shake) {
                cam_pose.* = scenarioPose(sc.pose, 0, 0);
                resetFreeCamera(ctx, st);
            }
            if (cr.frames >= WARMUP_FRAMES) {
                _ = wgpu.requestCapture(st.app, .final);
                cr.stage = .wait_final;
                cr.frames = 0;
            }
        },
        .wait_final => {
            cr.frames += 1;
            var img = wgpu.takeCapture(st.app) orelse {
                if (cr.frames > WAIT_LIMIT_FRAMES) {
                    cr.fail(sc.name, "no final capture after {d} frames", .{WAIT_LIMIT_FRAMES});
                    cr.scenario += 1;
                    cr.stage = .warmup;
                    cr.applied = false;
                }
                return;
            };
            defer img.deinit(cr.allocator);
            try cr.handleFinal(sc, img);
            if (sc.cut) {
                // Hold the scenario pose for a few frames so the HDR capture that follows shows the same view.
                cam_pose.* = scenarioPose(sc.pose, 0, 0);
                resetFreeCamera(ctx, st);
                cr.stage = .hold;
                cr.frames = 0;
                return;
            }
            if (sc.stability) {
                _ = wgpu.requestCapture(st.app, .final);
                cr.stage = .wait_stable;
            } else {
                _ = wgpu.requestCapture(st.app, .hdr);
                cr.stage = .wait_hdr;
            }
            cr.frames = 0;
        },
        .hold => {
            cr.frames += 1;
            if (cr.frames >= 3) {
                _ = wgpu.requestCapture(st.app, .hdr);
                cr.stage = .wait_hdr;
                cr.frames = 0;
            }
        },
        .wait_stable => {
            cr.frames += 1;
            var img = wgpu.takeCapture(st.app) orelse {
                if (cr.frames > WAIT_LIMIT_FRAMES) {
                    cr.fail(sc.name, "no second capture after {d} frames", .{WAIT_LIMIT_FRAMES});
                    cr.scenario += 1;
                    cr.stage = .warmup;
                    cr.applied = false;
                }
                return;
            };
            defer img.deinit(cr.allocator);
            const second = try capture.displayToRgb8(cr.allocator, img);
            defer cr.allocator.free(second);
            if (cr.final_rgb) |first| {
                const diff = try capture.compareRgb8(first, second, PIXEL_THRESHOLD);
                const frac = diff.differingFraction();
                std.debug.print("[capture] {s}: frame-to-frame {d:.4}% pixels differ (max delta {d})\n", .{ sc.name, frac * 100.0, diff.max_delta });
                if (frac > MAX_FLICKER_FRACTION) {
                    cr.fail(sc.name, "{d:.3}% of pixels change between consecutive frames (limit {d:.3}%)", .{ frac * 100.0, MAX_FLICKER_FRACTION * 100.0 });
                }
            }
            _ = wgpu.requestCapture(st.app, .hdr);
            cr.stage = .wait_hdr;
            cr.frames = 0;
        },
        .wait_hdr => {
            cr.frames += 1;
            var img = wgpu.takeCapture(st.app) orelse {
                if (cr.frames > WAIT_LIMIT_FRAMES) {
                    cr.fail(sc.name, "no HDR capture after {d} frames", .{WAIT_LIMIT_FRAMES});
                    cr.scenario += 1;
                    cr.stage = .warmup;
                    cr.applied = false;
                }
                return;
            };
            defer img.deinit(cr.allocator);
            try cr.handleHdr(sc, img);
            try cr.writeTiming(sc);
            cr.scenario += 1;
            cr.stage = .warmup;
            cr.applied = false;
        },
    }
}

fn createUvSphere(allocator: std.mem.Allocator, radius: f32, stacks: u32, slices: u32) !render_3d.gltf.MeshData {
    var verts: std.ArrayList(render_3d.gltf.Vertex3D) = .empty;
    errdefer verts.deinit(allocator);
    var inds: std.ArrayList(u32) = .empty;
    errdefer inds.deinit(allocator);

    for (0..stacks + 1) |i| {
        const v_t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(stacks));
        const phi = v_t * std.math.pi;
        const sp = @sin(phi);
        const cp = @cos(phi);
        for (0..slices + 1) |j| {
            const u_t = @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(slices));
            const theta = u_t * 2.0 * std.math.pi;
            const nx = sp * @cos(theta);
            const ny = cp;
            const nz = sp * @sin(theta);
            try verts.append(allocator, .{
                .x = nx * radius,
                .y = ny * radius,
                .z = nz * radius,
                .nx = nx,
                .ny = ny,
                .nz = nz,
                .u = u_t,
                .v = v_t,
            });
        }
    }

    const row_stride = slices + 1;
    for (0..stacks) |i| {
        for (0..slices) |j| {
            const a: u32 = @intCast(i * row_stride + j);
            const b: u32 = @intCast((i + 1) * row_stride + j);
            const c_i: u32 = @intCast((i + 1) * row_stride + j + 1);
            const d: u32 = @intCast(i * row_stride + j + 1);
            try inds.appendSlice(allocator, &.{ a, d, b, d, c_i, b });
        }
    }

    return .{
        .allocator = allocator,
        .vertices = try verts.toOwnedSlice(allocator),
        .indices = try inds.toOwnedSlice(allocator),
        .bounds_center = .{ 0, 0, 0 },
        .bounds_radius = radius,
    };
}

fn updatePbrDemo(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(PbrDemoState) orelse return;
    const keys = ctx.resources.get(input.KeyInput) orelse return;
    const cam_pose = ctx.world.get(st.cam_entity, camera.CameraPose) orelse return;
    const pp = ctx.world.get(st.cam_entity, render_3d.pbr.PostProcessSettings) orelse return;
    const sun = ctx.world.get(st.sun_entity, render_3d.pbr.DirectionalLight) orelse return;
    const fog = ctx.resources.get(render_3d.pbr.FogSettings) orelse return;

    if (st.capture != null) {
        try stepCapture(ctx, st, cam_pose, pp, sun, fog);
        return;
    }

    if (keys.justPressed(.digit_1)) {
        pp.tonemap_mode = .agx;
        pp.tonemap_look = .base;
    } else if (keys.justPressed(.digit_2)) {
        pp.tonemap_mode = .agx;
        pp.tonemap_look = .punchy;
    } else if (keys.justPressed(.digit_3)) {
        pp.tonemap_mode = .aces;
    } else if (keys.justPressed(.digit_4)) {
        pp.tonemap_mode = .pbr_neutral;
    } else if (keys.justPressed(.digit_5)) {
        pp.tonemap_mode = .neutral;
    }

    if (keys.justPressed(.key_x)) pp.auto_exposure.enabled = !pp.auto_exposure.enabled;
    if (keys.justPressed(.key_b)) pp.bloom.enabled = !pp.bloom.enabled;
    if (keys.justPressed(.key_f)) {
        fog.enabled = !fog.enabled;
        fog.volumetric.enabled = fog.enabled;
    }
    if (keys.justPressed(.key_g)) sun.shadows_enabled = !sun.shadows_enabled;
    if (keys.justPressed(.key_o)) pp.ssao.enabled = !pp.ssao.enabled;
    if (keys.justPressed(.key_n)) {
        st.sky_preset = (st.sky_preset + 1) % 4;
        if (ctx.resources.get(render_3d.pbr.SkyEnvironment)) |sky| applySkyPreset(sky, sun, st.sky_preset);
    }
    if (keys.justPressed(.key_v)) pp.vignette.enabled = !pp.vignette.enabled;
    if (keys.justPressed(.key_r)) st.rotate_sun = !st.rotate_sun;
    if (keys.justPressed(.key_z)) st.show_gizmos = !st.show_gizmos;
    if (keys.justPressed(.key_t)) {
        st.in_vol_room = !st.in_vol_room;
        if (st.in_vol_room) {
            cam_pose.* = camera.CameraPose.lookAt(.{ 11.2, 2.1, 2.8 }, .{ 15.2, 2.3, -1.2 }, .{ 0, 1, 0 });
        } else {
            cam_pose.* = camera.CameraPose.lookAt(.{ 0, 2.6, 10.0 }, .{ 0, 2.6, 0 }, .{ 0, 1, 0 });
        }
    }

    if (st.rotate_sun) {
        st.sun_angle += ctx.dt * 0.35;
        sun.direction = .{ -@cos(st.sun_angle) * 0.6, -@max(@sin(st.sun_angle), 0.05), -0.45 };
    }

    const sky_label: []const u8 = switch (st.sky_preset) {
        0 => "HDRI",
        1 => "Day",
        2 => "Dusk",
        else => "Night",
    };
    const look_tag: []const u8 = if (pp.tonemap_mode == .agx and pp.tonemap_look == .punchy) " (Punchy)" else "";
    const h1 = std.fmt.bufPrint(
        &st.hud1,
        "Tonemap[1-5]: {s}{s} | AutoExp[X]: {any} | Bloom[B]: {any} | Shadows[G]: {any} | SSAO[O]: {any} | Sky[N]: {s}",
        .{ @tagName(pp.tonemap_mode), look_tag, pp.auto_exposure.enabled, pp.bloom.enabled, sun.shadows_enabled, pp.ssao.enabled, sky_label },
    ) catch "PBR Demo";
    st.hud1_len = h1.len;

    const h2 = std.fmt.bufPrint(
        &st.hud2,
        "WASD+RMB=Fly | T=VolRoom | Z=Gizmos({any}) | F=Fog({any}) | R=SunCycle({any}) | Pos:({d:.1},{d:.1},{d:.1})",
        .{ st.show_gizmos, fog.enabled, st.rotate_sun, cam_pose.position[0], cam_pose.position[1], cam_pose.position[2] },
    ) catch "";
    st.hud2_len = h2.len;

    if (st.show_gizmos) {
        if (ctx.resources.get(gizmos.GizmoService)) |giz| {
            giz.axes(.{ 0, 0.05, 0 }, 2.0);
            giz.grid(.{ 0, -0.36, 0 }, .{ 16, 16 }, .{ 2.0, 2.0 }, .{ 0.35, 0.45, 0.55, 0.45 });
            giz.cuboid(.{ 14.0, 2.6, 0.0 }, .{ 8.6, 6.0, 8.6 }, .{ 0.2, 0.9, 1.0, 0.75 });
            giz.sphere(.{ -4.5, 2.5, 3.0 }, 0.35, 16, .{ 0.25, 0.65, 1.0, 1.0 });
            giz.sphere(.{ 14.2, 2.4, 0.2 }, 0.35, 16, .{ 1.0, 0.2, 0.1, 1.0 });
            giz.arrow(.{ 11.4, 4.4, 2.2 }, .{ 1.65, -2.04, -1.44 }, .{ 1.0, 0.95, 0.4, 1.0 });
            giz.arrow(.{ 0, 7.5, 0 }, .{ sun.direction[0] * 3.0, sun.direction[1] * 3.0, sun.direction[2] * 3.0 }, .{ 1.0, 0.85, 0.2, 1.0 });
            giz.lineXray(.{ 0, 0.05, 0 }, .{ 14.2, 2.4, 0.2 }, .{ 1.0, 0.3, 0.3, 0.9 });
        }
    }
}

fn renderPbrOverlay(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(PbrDemoState) orelse return;
    const cam_svc = ctx.resources.get(camera.CameraService) orelse return;
    const px = window_sdl3.pixelSize(st.app);
    cam_svc.setPrimaryTargetSize(if (px) |p| p.width else 1280, if (px) |p| p.height else 720);

    try st.gfx.beginFrame(st.rt);
    try st.gfx.submitDrawCommands(st.rt, &.{
        .{ .text = .{ .x = 18, .y = 18, .content = st.hud1[0..st.hud1_len], .color = .{ .r = 0.96, .g = 0.98, .b = 1.0, .a = 1.0 } } },
        .{ .text = .{ .x = 18, .y = 42, .content = st.hud2[0..st.hud2_len], .color = .{ .r = 0.78, .g = 0.88, .b = 0.98, .a = 1.0 } } },
    });
    _ = try st.gfx.present(st.rt);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var app = engine.App.init(allocator, .{});
    defer app.deinit();

    try app.registerModule(window_sdl3.module());
    try app.registerModule(wgpu.module());
    try app.registerModule(draw_2d.module());
    try app.registerModule(gpu_3d.module());
    try app.registerModule(input.module());
    try app.registerModule(input_sdl3.module());
    try app.registerModule(camera.module());
    try app.registerModule(render_3d.module());
    try app.registerModule(gizmos.module());

    try app.resources.insert(window_sdl3.WindowConfig, .{
        .title = "Zengy — PBR Lighting, Shadows, Sky, AutoExposure & Tonemapping",
        .width = 1280,
        .height = 720,
        .resizable = true,
    });

    try app.addSystem(.{ .name = "pbr_demo.update", .stage = .update, .run = updatePbrDemo });
    try app.addSystem(.{ .name = "pbr_demo.overlay", .stage = .render_extract, .run = renderPbrOverlay });

    try app.initialize();

    const g_entry = try app.services.getService("engine.graphics.device", 1);
    const gfx: *graphics.GraphicsDeviceService = @ptrCast(@alignCast(@constCast(g_entry.api_ptr)));
    const mats = app.resources.get(render_3d.pbr.MaterialRegistry).?;

    var sphere = try createUvSphere(allocator, 0.55, 20, 32);
    defer sphere.deinit();
    const gpu_sphere = try gpu_3d.createMesh3D(&app, std.mem.sliceAsBytes(sphere.vertices), sphere.indices);

    var cube = try render_3d.gltf.createCubeMesh(allocator, 1.0);
    defer cube.deinit();
    const gpu_cube = try gpu_3d.createMesh3D(&app, std.mem.sliceAsBytes(cube.vertices), cube.indices);

    // Single-quad mesh in the XY plane facing +Z; unlike a thin cube it has no back face behind its holes.
    const quad_verts = [_]render_3d.gltf.Vertex3D{
        .{ .x = -0.5, .y = -0.5, .z = 0, .nx = 0, .ny = 0, .nz = 1, .u = 0, .v = 1 },
        .{ .x = 0.5, .y = -0.5, .z = 0, .nx = 0, .ny = 0, .nz = 1, .u = 1, .v = 1 },
        .{ .x = 0.5, .y = 0.5, .z = 0, .nx = 0, .ny = 0, .nz = 1, .u = 1, .v = 0 },
        .{ .x = -0.5, .y = 0.5, .z = 0, .nx = 0, .ny = 0, .nz = 1, .u = 0, .v = 0 },
    };
    const quad_indices = [_]u32{ 0, 1, 2, 0, 2, 3 };
    const gpu_quad = try gpu_3d.createMesh3D(&app, std.mem.sliceAsBytes(&quad_verts), &quad_indices);

    // Camera with FreeCamera + PostProcessSettings (AutoExposure + Bloom + AgX).
    const cam_e = try app.world.spawn();
    try app.world.set(cam_e, camera.Camera, .{ .order = 0 });
    try app.world.set(cam_e, camera.Projection, .{ .perspective = .{ .fov_rad = std.math.pi / 3.0, .near = 0.25, .far = 200.0 } });
    try app.world.set(cam_e, camera.CameraPose, camera.CameraPose.lookAt(.{ 0, 2.6, 10.0 }, .{ 0, 2.6, 0 }, .{ 0, 1, 0 }));
    try app.world.set(cam_e, camera.FreeCamera, .{ .walk_speed = 7.0, .run_speed = 16.0 });
    try app.world.set(cam_e, camera.FreeCameraState, .{});
    try app.world.set(cam_e, render_3d.pbr.PostProcessSettings, .{
        .auto_exposure = .{ .enabled = true, .min_ev100 = -2.0, .max_ev100 = 3.0, .speed_brighten = 1.5, .speed_darken = 3.0 },
        .bloom = .{ .enabled = true, .intensity = 0.25, .threshold = 1.2, .scatter = 0.7 },
        .ssao = .{ .enabled = true, .radius = 0.65, .intensity = 1.2, .bias = 0.03 },
        .contact_shadows = .{ .enabled = true, .length = 0.45, .thickness = 0.12, .opacity = 0.8 },
        .tonemap_mode = .agx,
        .tonemap_look = .base,
    });

    // Directional Sun Light + HDRI Sky Environment.
    var hdri = try render_3d.ibl.loadRadianceHdrFromMemory(allocator, SKY_HDR_BYTES);
    defer hdri.deinit();
    const hdri_alt = try allocator.dupe([4]f32, hdri.pixels);
    defer allocator.free(hdri_alt);
    try app.resources.insert(render_3d.pbr.SkyEnvironment, .{
        .kind = .hdri,
        .hdri_pixels = hdri.pixels,
        .hdri_width = hdri.width,
        .hdri_height = hdri.height,
        .hdri_exposure_ev = -0.6,
        .sky_tint = .{ 0.14, 0.38, 0.85 },
        .horizon_tint = .{ 0.52, 0.70, 0.92 },
        .ground_albedo = .{ 0.14, 0.14, 0.16 },
    });
    try app.resources.insert(render_3d.pbr.AmbientLight, .{
        .color = .{ 0.55, 0.68, 0.88 },
        .brightness = 0.04,
    });
    try app.resources.insert(render_3d.pbr.FogSettings, .{
        .enabled = true,
        .density = 0.014,
        .start_distance = 4.0,
        .volumetric = .{
            .enabled = true,
            .anisotropy = 0.68,
            .scattering = 0.22,
            .max_distance = 75.0,
        },
    });
    const sun_e = try app.world.spawn();
    try app.world.set(sun_e, render_3d.pbr.DirectionalLight, .{
        .color = .{ 1.0, 0.96, 0.90 },
        .illuminance_lux = 24000.0,
        .direction = .{ -0.45, -0.75, -0.45 },
        .shadows_enabled = true,
        .pcss_enabled = true,
    });

    // Screen/TV Area Light (RectLight) with dark metallic bezel & pedestal stand.
    const bezel_mat = try mats.add(.{ .base_color = .{ 0.08, 0.09, 0.11, 1.0 }, .metallic = 0.85, .roughness = 0.25 });
    const tv_bezel = try app.world.spawn();
    try app.world.set(tv_bezel, render_3d.Transform3D, .{ .position = .{ 0.0, 2.8, -4.68 }, .scale = .{ 4.0, 2.2, 0.10 } });
    try app.world.set(tv_bezel, render_3d.MeshRef, .{ .mesh_asset = @bitCast(gpu_cube), .material_handle = bezel_mat });

    const tv_stand = try app.world.spawn();
    try app.world.set(tv_stand, render_3d.Transform3D, .{ .position = .{ 0.0, 0.75, -4.78 }, .scale = .{ 0.45, 2.2, 0.20 } });
    try app.world.set(tv_stand, render_3d.MeshRef, .{ .mesh_asset = @bitCast(gpu_cube), .material_handle = bezel_mat });

    const tv_panel = try app.world.spawn();
    try app.world.set(tv_panel, render_3d.Transform3D, .{ .position = .{ 0.0, 2.8, -4.35 }, .scale = .{ 3.6, 1.8, 0.08 } });
    const tv_mat = try mats.add(.{
        .base_color = .{ 0.05, 0.08, 0.12, 1.0 },
        .emissive = .{ 0.7, 2.0, 3.8, 1.0 },
        .roughness = 0.12,
    });
    try app.world.set(tv_panel, render_3d.MeshRef, .{ .mesh_asset = @bitCast(gpu_cube), .material_handle = tv_mat });
    try app.world.set(tv_panel, render_3d.pbr.RectLight, .{
        .color = .{ 0.45, 0.82, 1.0 },
        .intensity_lumens = 2800.0,
        .width = 3.6,
        .height = 1.8,
        .range = 18.0,
    });

    // Architectural gallery columns casting crisp directional & spot shadows.
    const col_mat = try mats.add(.{ .base_color = .{ 0.72, 0.70, 0.66, 1.0 }, .metallic = 0.05, .roughness = 0.72 });
    const col_positions = [_][3]f32{
        .{ -6.2, 2.4, -4.0 },
        .{ 6.2, 2.4, -4.0 },
        .{ -6.2, 2.4, 4.5 },
    };
    for (col_positions) |cp| {
        const ce = try app.world.spawn();
        try app.world.set(ce, render_3d.Transform3D, .{ .position = cp, .scale = .{ 0.65, 5.6, 0.65 } });
        try app.world.set(ce, render_3d.MeshRef, .{ .mesh_asset = @bitCast(gpu_cube), .material_handle = col_mat });
    }

    // Shadowed SpotLight aimed across the dark volumetric room.
    const spot_e = try app.world.spawn();
    try app.world.set(spot_e, render_3d.Transform3D, .{ .position = .{ 11.4, 4.4, 2.2 } });
    try app.world.set(spot_e, render_3d.pbr.SpotLight, .{
        .color = .{ 0.92, 0.96, 1.0 },
        .intensity_lumens = 1200.0,
        .direction = .{ 0.55, -0.68, -0.48 },
        .range = 16.0,
        .inner_angle_rad = 0.22,
        .outer_angle_rad = 0.52,
        .shadows_enabled = true,
    });

    // Dark ReflectionProbe covering the enclosed volumetric room so the interior stays dark.
    const probe_e = try app.world.spawn();
    try app.world.set(probe_e, render_3d.Transform3D, .{ .position = .{ 14.0, 2.6, 0.0 } });
    try app.world.set(probe_e, render_3d.pbr.ReflectionProbe, .{
        .half_extents = .{ 4.3, 3.0, 4.3 },
        .blend_distance = 0.6,
        .intensity = 0.96,
        .sky_tint = .{ 0.008, 0.008, 0.012 },
        .ground_tint = .{ 0.004, 0.004, 0.006 },
    });

    // Two colored PointLights: blue near metallic grid, red inside the dark volumetric room.
    const pl1 = try app.world.spawn();
    try app.world.set(pl1, render_3d.Transform3D, .{ .position = .{ -4.5, 2.5, 3.0 } });
    try app.world.set(pl1, render_3d.pbr.PointLight, .{ .color = .{ 0.25, 0.65, 1.0 }, .intensity_lumens = 2500.0, .range = 16.0, .shadows_enabled = true });

    const pl2 = try app.world.spawn();
    try app.world.set(pl2, render_3d.Transform3D, .{ .position = .{ 14.2, 2.4, 0.2 } });
    try app.world.set(pl2, render_3d.pbr.PointLight, .{ .color = .{ 1.0, 0.12, 0.06 }, .intensity_lumens = 320.0, .range = 9.0, .shadows_enabled = true });

    // Procedural architectural tile floor texture (256x256).
    var floor_pixels: [256 * 256 * 4]u8 = undefined;
    for (0..256) |py| {
        for (0..256) |px_i| {
            const tile_x = (px_i / 32) % 2;
            const tile_y = (py / 32) % 2;
            const grout = (px_i % 32 < 2) or (py % 32 < 2);
            const checker = (tile_x ^ tile_y) == 0;
            const base_v: u8 = if (grout) 54 else if (checker) 168 else 124;
            const idx = (py * 256 + px_i) * 4;
            floor_pixels[idx + 0] = base_v;
            floor_pixels[idx + 1] = base_v + 4;
            floor_pixels[idx + 2] = base_v + 10;
            floor_pixels[idx + 3] = 255;
        }
    }
    const floor_tex = try graphics.createTextureSrgbRgba8(&app, 256, 256, &floor_pixels);

    // Ground plane.
    const floor_mat = try mats.add(.{
        .base_color = .{ 0.92, 0.94, 0.98, 1.0 },
        .base_color_tex = @bitCast(floor_tex),
        .metallic = 0.05,
        .roughness = 0.62,
    });
    const floor_e = try app.world.spawn();
    try app.world.set(floor_e, render_3d.Transform3D, .{ .position = .{ 0, -0.5, 0 }, .scale = .{ 36.0, 0.25, 36.0 } });
    try app.world.set(floor_e, render_3d.MeshRef, .{ .mesh_asset = @bitCast(gpu_cube), .material_handle = floor_mat });

    // 5x5 Metallic / Roughness sphere showcase grid with Gold, Chrome, Copper, and Emerald accents.
    const row_colors = [5][4]f32{
        .{ 0.85, 0.24, 0.20, 1.0 }, // Dielectric terracotta
        .{ 0.16, 0.72, 0.44, 1.0 }, // Satin emerald
        .{ 0.96, 0.64, 0.54, 1.0 }, // Copper
        .{ 1.00, 0.78, 0.34, 1.0 }, // Gold
        .{ 0.95, 0.96, 0.98, 1.0 }, // Chrome
    };
    for (0..5) |row| {
        for (0..5) |col| {
            const metallic = @as(f32, @floatFromInt(row)) / 4.0;
            const roughness = 0.06 + (@as(f32, @floatFromInt(col)) / 4.0) * 0.90;
            const mat = try mats.add(.{
                .base_color = row_colors[row],
                .metallic = metallic,
                .roughness = roughness,
            });
            const se = try app.world.spawn();
            const x = (@as(f32, @floatFromInt(col)) - 2.0) * 1.6;
            const y = 0.6 + @as(f32, @floatFromInt(row)) * 1.35;
            try app.world.set(se, render_3d.Transform3D, .{ .position = .{ x, y, 0.0 } });
            try app.world.set(se, render_3d.MeshRef, .{
                .mesh_asset = @bitCast(gpu_sphere),
                .material_handle = mat,
                .bounds_radius = sphere.bounds_radius,
            });
        }
    }

    // Emissive HDR beacon cubes (demonstrates Bloom).
    const em_mat = try mats.add(.{
        .base_color = .{ 0.1, 0.1, 0.1, 1.0 },
        .emissive = .{ 2.5, 5.5, 10.0, 1.0 },
        .roughness = 0.2,
    });
    const beacon = try app.world.spawn();
    try app.world.set(beacon, render_3d.Transform3D, .{ .position = .{ -5.5, 1.5, 0.0 }, .scale = .{ 0.7, 2.8, 0.7 } });
    try app.world.set(beacon, render_3d.MeshRef, .{ .mesh_asset = @bitCast(gpu_cube), .material_handle = em_mat });

    // Alpha-masked, double-sided "foliage" panel plus an alpha-blended glass pane, off to the left of the gallery.
    // They exercise the masked shadow pipeline, back-face lighting, and transparent ordering (see `materials_*`).
    var leaf_pixels: [64 * 64 * 4]u8 = undefined;
    for (0..64) |py| {
        for (0..64) |px_i| {
            const solid = ((px_i / 8) + (py / 8)) % 2 == 0;
            const idx = (py * 64 + px_i) * 4;
            leaf_pixels[idx + 0] = 60;
            leaf_pixels[idx + 1] = 150;
            leaf_pixels[idx + 2] = 70;
            leaf_pixels[idx + 3] = if (solid) 255 else 0;
        }
    }
    const leaf_tex = try graphics.createTextureSrgbRgba8(&app, 64, 64, &leaf_pixels);
    const leaf_mat = try mats.add(.{
        .base_color = .{ 1.0, 1.0, 1.0, 1.0 },
        .base_color_tex = @bitCast(leaf_tex),
        .alpha_mode = .mask,
        .alpha_cutoff = 0.5,
        .double_sided = true,
        .roughness = 0.7,
    });
    const leaf_e = try app.world.spawn();
    try app.world.set(leaf_e, render_3d.Transform3D, .{ .position = .{ -8.0, 1.6, 6.0 }, .scale = .{ 2.4, 2.4, 1.0 } });
    try app.world.set(leaf_e, render_3d.MeshRef, .{ .mesh_asset = @bitCast(gpu_quad), .material_handle = leaf_mat });

    const glass_mat = try mats.add(.{
        .base_color = .{ 0.55, 0.75, 0.95, 0.35 },
        .alpha_mode = .blend,
        .double_sided = true,
        .roughness = 0.05,
    });
    const glass_e = try app.world.spawn();
    try app.world.set(glass_e, render_3d.Transform3D, .{ .position = .{ -6.2, 1.4, 7.4 }, .scale = .{ 1.6, 2.0, 1.0 } });
    try app.world.set(glass_e, render_3d.MeshRef, .{ .mesh_asset = @bitCast(gpu_quad), .material_handle = glass_mat });

    // Enclosed dark volumetric room on the right (press T to jump inside) with a grated skylight window.
    const wall_mat = try mats.add(.{ .base_color = .{ 0.22, 0.23, 0.26, 1.0 }, .metallic = 0.0, .roughness = 0.9 });
    const alcove_parts = [_]struct { pos: [3]f32, scale: [3]f32 }{
        // Back (-Z), Front (+Z), Right (+X), and Left (-X with small doorway at z=2.6..4.0) walls
        .{ .pos = .{ 14.0, 2.5, -4.0 }, .scale = .{ 8.5, 5.5, 0.5 } },
        .{ .pos = .{ 14.0, 2.5, 4.0 }, .scale = .{ 8.5, 5.5, 0.5 } },
        .{ .pos = .{ 18.0, 2.5, 0.0 }, .scale = .{ 0.5, 5.5, 8.5 } },
        .{ .pos = .{ 10.0, 2.5, -0.9 }, .scale = .{ 0.5, 5.5, 6.2 } },
        .{ .pos = .{ 10.0, 3.8, 3.1 }, .scale = .{ 0.5, 2.9, 2.2 } },
        // Solid roof sections around the skylight opening (opening at x=14.6..17.4, z=-1.0..2.2)
        .{ .pos = .{ 12.3, 5.2, 0.0 }, .scale = .{ 4.8, 0.5, 8.5 } },
        .{ .pos = .{ 16.0, 5.2, -2.5 }, .scale = .{ 4.0, 0.5, 3.2 } },
        .{ .pos = .{ 16.0, 5.2, 3.1 }, .scale = .{ 4.0, 0.5, 2.0 } },
        .{ .pos = .{ 17.7, 5.2, 0.6 }, .scale = .{ 0.8, 0.5, 3.6 } },
        // Grated window bars across the skylight opening
        .{ .pos = .{ 15.5, 5.2, 0.6 }, .scale = .{ 0.24, 0.5, 3.4 } },
        .{ .pos = .{ 16.5, 5.2, 0.6 }, .scale = .{ 0.24, 0.5, 3.4 } },
        .{ .pos = .{ 16.0, 5.2, -0.1 }, .scale = .{ 3.2, 0.5, 0.24 } },
        .{ .pos = .{ 16.0, 5.2, 0.7 }, .scale = .{ 3.2, 0.5, 0.24 } },
        .{ .pos = .{ 16.0, 5.2, 1.5 }, .scale = .{ 3.2, 0.5, 0.24 } },
    };
    for (alcove_parts) |ap| {
        const we = try app.world.spawn();
        try app.world.set(we, render_3d.Transform3D, .{ .position = ap.pos, .scale = ap.scale });
        try app.world.set(we, render_3d.MeshRef, .{ .mesh_asset = @bitCast(gpu_cube), .material_handle = wall_mat });
    }

    var capture_runner: ?CaptureRunner = null;
    if (init.environ_map.get("ZENGY_CAPTURE_DIR")) |dir| {
        const golden = init.environ_map.get("ZENGY_CAPTURE_GOLDEN") orelse "tests/golden/visual-pbr";
        const update = if (init.environ_map.get("ZENGY_CAPTURE_UPDATE")) |v| std.mem.eql(u8, v, "1") else false;
        try std.Io.Dir.cwd().createDirPath(init.io, dir);
        if (update) try std.Io.Dir.cwd().createDirPath(init.io, golden);
        capture_runner = .{ .allocator = allocator, .io = init.io, .out_dir = dir, .golden_dir = golden, .update_goldens = update, .filter = init.environ_map.get("ZENGY_CAPTURE_FILTER") };
    }

    const px = window_sdl3.pixelSize(&app);
    const rt = try gfx.createSurface(1, if (px) |p| p.width else 1280, if (px) |p| p.height else 720);

    try app.resources.insert(PbrDemoState, .{
        .app = &app,
        .gfx = gfx,
        .rt = rt,
        .cam_entity = cam_e,
        .sun_entity = sun_e,
        .nudge_entity = leaf_e,
        .local_lights = .{ spot_e, pl1, pl2 },
        .local_light_lumens = .{
            (app.world.get(spot_e, render_3d.pbr.SpotLight) orelse unreachable).intensity_lumens,
            (app.world.get(pl1, render_3d.pbr.PointLight) orelse unreachable).intensity_lumens,
            (app.world.get(pl2, render_3d.pbr.PointLight) orelse unreachable).intensity_lumens,
        },
        .hdri_main = hdri.pixels,
        .hdri_alt = hdri_alt,
        .capture = capture_runner,
    });

    try window_sdl3.runVisualLoop(&app);
    if (g_capture_failures > 0) return error.CaptureFailures;
}
