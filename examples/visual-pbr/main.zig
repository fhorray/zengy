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
const graphics_sdlgpu = @import("graphics_sdlgpu");
const input = @import("input");
const input_sdl3 = @import("input_sdl3");
const camera = @import("camera");
const render_3d = @import("render_3d");

const capture = graphics_sdlgpu.capture;

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
    /// Present only in capture mode (`ZENGY_CAPTURE_DIR`); drives the scenarios instead of the keyboard.
    capture: ?CaptureRunner = null,
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
};

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
};

const CaptureStage = enum { warmup, wait_final, wait_hdr };

const CaptureRunner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    out_dir: []const u8,
    golden_dir: []const u8,
    update_goldens: bool,
    scenario: usize = 0,
    stage: CaptureStage = .warmup,
    applied: bool = false,
    frames: u32 = 0,
    /// Final-frame RGB8 of the running scenario, kept until its HDR capture completes.
    final_rgb: ?[]u8 = null,
    final_w: u32 = 0,
    final_h: u32 = 0,
    speckle: u64 = 0,
    contrast: f32 = 0,

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
        if (self.final_rgb) |old| self.allocator.free(old);
        self.final_rgb = rgb;
        self.final_w = img.width;
        self.final_h = img.height;
        if (self.update_goldens) return;

        const golden_bytes = self.readFile(self.golden_dir, sc.name, ".png") orelse {
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
        if (frac > MAX_DIFF_FRACTION) {
            self.fail(sc.name, "{d:.3}% of pixels differ from the golden (limit {d:.3}%)", .{ frac * 100.0, MAX_DIFF_FRACTION * 100.0 });
            const diff_img = try capture.diffImageRgb8(self.allocator, rgb, golden.rgb, PIXEL_THRESHOLD);
            defer self.allocator.free(diff_img);
            try self.writePng(self.out_dir, sc.name, ".diff.png", img.width, img.height, diff_img);
        }
    }

    /// Measures the HDR frame, writes the stats file, and checks it against the golden stats.
    fn handleHdr(self: *CaptureRunner, sc: Scenario, img: capture.Image) !void {
        const stats = try capture.hdrStats(self.allocator, img);
        const preview = try capture.hdrPreviewRgb8(self.allocator, img);
        defer self.allocator.free(preview);
        try self.writePng(self.out_dir, sc.name, ".hdr.png", img.width, img.height, preview);

        const text = try std.fmt.allocPrint(
            self.allocator,
            "name={s}\nwidth={d}\nheight={d}\nnan={d}\ninf={d}\nmean_luma={d:.4}\np50_luma={d:.4}\np95_luma={d:.4}\nspeckle={d}\ncontrast={d:.2}\n",
            .{ sc.name, img.width, img.height, stats.nan_count, stats.inf_count, stats.mean_luma, stats.p50_luma, stats.p95_luma, self.speckle, self.contrast },
        );
        defer self.allocator.free(text);
        try self.writeFile(self.out_dir, sc.name, ".stats.txt", text);
        std.debug.print("[capture] {s}: nan={d} inf={d} mean_luma={d:.3} speckle={d} contrast={d:.1}\n", .{ sc.name, stats.nan_count, stats.inf_count, stats.mean_luma, self.speckle, self.contrast });

        if (stats.nan_count > 0 or stats.inf_count > 0) {
            self.fail(sc.name, "HDR frame has {d} NaN and {d} Inf pixels", .{ stats.nan_count, stats.inf_count });
        }

        if (self.update_goldens) {
            if (self.final_rgb) |rgb| try self.writePng(self.golden_dir, sc.name, ".png", self.final_w, self.final_h, rgb);
            try self.writeFile(self.golden_dir, sc.name, ".stats.txt", text);
            return;
        }

        const golden_text = self.readFile(self.golden_dir, sc.name, ".stats.txt") orelse return;
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

fn applyScenario(
    sc: Scenario,
    cam_pose: *camera.CameraPose,
    pp: *render_3d.pbr.PostProcessSettings,
    sun: *render_3d.pbr.DirectionalLight,
    fog: *render_3d.pbr.FogSettings,
    sky: ?*render_3d.pbr.SkyEnvironment,
) void {
    cam_pose.* = switch (sc.pose) {
        .gallery => camera.CameraPose.lookAt(.{ 0, 2.6, 10.0 }, .{ 0, 2.6, 0 }, .{ 0, 1, 0 }),
        .vol_room => camera.CameraPose.lookAt(.{ 11.2, 2.1, 2.8 }, .{ 15.2, 2.3, -1.2 }, .{ 0, 1, 0 }),
        .closeup => camera.CameraPose.lookAt(.{ 0.5, 2.4, 5.5 }, .{ 0, 2.0, 0 }, .{ 0, 1, 0 }),
        .materials => camera.CameraPose.lookAt(.{ -8.0, 1.9, 10.0 }, .{ -8.0, 1.2, 6.0 }, .{ 0, 1, 0 }),
    };
    fog.enabled = sc.fog;
    fog.volumetric.enabled = sc.fog;
    pp.ssao.enabled = sc.ssao;
    pp.contact_shadows.enabled = sc.ssao;
    pp.bloom.enabled = sc.bloom;
    pp.anti_aliasing = if (sc.aa) .fxaa else .none;
    sun.shadows_enabled = sc.shadows;
    if (sky) |s_env| applySkyPreset(s_env, sun, sc.sky_preset);
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
    const sc = SCENARIOS[cr.scenario];
    switch (cr.stage) {
        .warmup => {
            if (!cr.applied) {
                applyScenario(sc, cam_pose, pp, sun, fog, ctx.resources.get(render_3d.pbr.SkyEnvironment));
                cr.applied = true;
                cr.frames = 0;
            }
            cr.frames += 1;
            if (cr.frames >= WARMUP_FRAMES) {
                graphics_sdlgpu.requestCapture(st.app, .final);
                cr.stage = .wait_final;
                cr.frames = 0;
            }
        },
        .wait_final => {
            cr.frames += 1;
            var img = graphics_sdlgpu.takeCapture(st.app) orelse {
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
            graphics_sdlgpu.requestCapture(st.app, .hdr);
            cr.stage = .wait_hdr;
            cr.frames = 0;
        },
        .wait_hdr => {
            cr.frames += 1;
            var img = graphics_sdlgpu.takeCapture(st.app) orelse {
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
        "WASD+RMB=Fly | T=VolRoom | F=Fog({any}) | R=SunCycle({any}) | V=Vignette({any}) | Pos:({d:.1},{d:.1},{d:.1})",
        .{ fog.enabled, st.rotate_sun, pp.vignette.enabled, cam_pose.position[0], cam_pose.position[1], cam_pose.position[2] },
    ) catch "";
    st.hud2_len = h2.len;
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
    try st.gfx.present(st.rt);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var app = engine.App.init(allocator, .{});
    defer app.deinit();

    try app.registerModule(window_sdl3.module());
    try app.registerModule(graphics_sdlgpu.module());
    try app.registerModule(input.module());
    try app.registerModule(input_sdl3.module());
    try app.registerModule(camera.module());
    try app.registerModule(render_3d.module());

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
    const gpu_sphere = try graphics_sdlgpu.createMesh3D(&app, std.mem.sliceAsBytes(sphere.vertices), sphere.indices);

    var cube = try render_3d.gltf.createCubeMesh(allocator, 1.0);
    defer cube.deinit();
    const gpu_cube = try graphics_sdlgpu.createMesh3D(&app, std.mem.sliceAsBytes(cube.vertices), cube.indices);

    // Single-quad mesh in the XY plane facing +Z; unlike a thin cube it has no back face behind its holes.
    const quad_verts = [_]render_3d.gltf.Vertex3D{
        .{ .x = -0.5, .y = -0.5, .z = 0, .nx = 0, .ny = 0, .nz = 1, .u = 0, .v = 1 },
        .{ .x = 0.5, .y = -0.5, .z = 0, .nx = 0, .ny = 0, .nz = 1, .u = 1, .v = 1 },
        .{ .x = 0.5, .y = 0.5, .z = 0, .nx = 0, .ny = 0, .nz = 1, .u = 1, .v = 0 },
        .{ .x = -0.5, .y = 0.5, .z = 0, .nx = 0, .ny = 0, .nz = 1, .u = 0, .v = 0 },
    };
    const quad_indices = [_]u32{ 0, 1, 2, 0, 2, 3 };
    const gpu_quad = try graphics_sdlgpu.createMesh3D(&app, std.mem.sliceAsBytes(&quad_verts), &quad_indices);

    // Camera with FreeCamera + PostProcessSettings (AutoExposure + Bloom + AgX).
    const cam_e = try app.world.spawn();
    try app.world.set(cam_e, camera.Camera, .{ .order = 0 });
    try app.world.set(cam_e, camera.Projection, .{ .perspective = .{ .fov_rad = std.math.pi / 3.0, .near = 0.25, .far = 200.0 } });
    try app.world.set(cam_e, camera.CameraPose, camera.CameraPose.lookAt(.{ 0, 2.6, 10.0 }, .{ 0, 2.6, 0 }, .{ 0, 1, 0 }));
    try app.world.set(cam_e, camera.FreeCamera, .{ .walk_speed = 7.0, .run_speed = 16.0 });
    try app.world.set(cam_e, camera.FreeCameraState, .{});
    try app.world.set(cam_e, render_3d.pbr.PostProcessSettings, .{
        .auto_exposure = .{ .enabled = true, .min_ev100 = -2.0, .max_ev100 = 3.0, .speed_brighten = 3.0, .speed_darken = 1.5 },
        .bloom = .{ .enabled = true, .intensity = 0.25, .threshold = 1.2, .scatter = 0.7 },
        .ssao = .{ .enabled = true, .radius = 0.65, .intensity = 1.2, .bias = 0.03 },
        .contact_shadows = .{ .enabled = true, .length = 0.45, .thickness = 0.12, .opacity = 0.8 },
        .tonemap_mode = .agx,
        .tonemap_look = .base,
    });

    // Directional Sun Light + HDRI Sky Environment.
    var hdri = try render_3d.ibl.loadRadianceHdrFromMemory(allocator, SKY_HDR_BYTES);
    defer hdri.deinit();
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
    const floor_tex = try graphics_sdlgpu.createTextureSrgbRgba8(&app, 256, 256, &floor_pixels);

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
    const leaf_tex = try graphics_sdlgpu.createTextureSrgbRgba8(&app, 64, 64, &leaf_pixels);
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
        capture_runner = .{ .allocator = allocator, .io = init.io, .out_dir = dir, .golden_dir = golden, .update_goldens = update };
    }

    const px = window_sdl3.pixelSize(&app);
    const rt = try gfx.createSurface(1, if (px) |p| p.width else 1280, if (px) |p| p.height else 720);

    try app.resources.insert(PbrDemoState, .{
        .app = &app,
        .gfx = gfx,
        .rt = rt,
        .cam_entity = cam_e,
        .sun_entity = sun_e,
        .capture = capture_runner,
    });

    try window_sdl3.runVisualLoop(&app);
    if (g_capture_failures > 0) return error.CaptureFailures;
}
