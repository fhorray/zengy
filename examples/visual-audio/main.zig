//! Visual 3D Spatial Audio, FreeCamera, State & Time Demo (`examples/visual-audio/main.zig`).
//!
//! Demonstrates `official.audio` + `official.audio.zaudio` (miniaudio) with
//! 3D distance attenuation & stereo L/R panning, `camera.FreeCamera`,
//! `official.state` (`StateMachine` + `inState`), and core `Time`/`Timer`.
//!
//! Controls:
//! - W / A / S / D (hold Shift to sprint) + Right-Click Drag: Fly 3D camera away from/around the emitter cube
//! - Q / E: Move camera down / up
//! - 1 / 2 / 3 / 4: Trigger SFX samples from `.tmp/Audio`
//! - Space: Toggle Playing / Paused state (pauses `Time` & audio)
//! - Up / Down: Adjust master volume
//!
//! Run with: `zig build run-visual-audio`

const std = @import("std");
const engine = @import("engine");
const window_sdl3 = @import("window_sdl3");
const graphics = @import("graphics");
const graphics_sdlgpu = @import("graphics_sdlgpu");
const input = @import("input");
const input_sdl3 = @import("input_sdl3");
const camera = @import("camera");
const render_3d = @import("render_3d");
const state = @import("state");
const audio = @import("audio");
const audio_zaudio = @import("audio_zaudio");

const DemoState = enum {
    playing,
    paused,
};

const MAX_AUDIO_DIST: f32 = 25.0;

const AudioDemoState = struct {
    app: *engine.App,
    gfx: *graphics.GraphicsDeviceService,
    rt: graphics.RenderTargetHandle,
    cube_mesh: graphics_sdlgpu.GpuMeshHandle,
    cam_entity: engine.EntityHandle,
    emitter_entity: engine.EntityHandle,
    landmarks: [6]engine.EntityHandle = @splat(.invalid),
    samples: [4]audio.AudioSourceHandle = @splat(.invalid),
    active_pb: ?audio.AudioPlaybackHandle = null,
    pulse_timer: engine.Timer = engine.Timer.init(0.5, .repeating),
    status_line: []const u8 = "BGM: Abandoned Research Facility.mp3 | WASD+RMB=Fly | 1-4=SFX | Space=Pause",
    hud1: [180]u8 = @splat(0),
    hud1_len: usize = 0,
    hud2: [180]u8 = @splat(0),
    hud2_len: usize = 0,
};

fn buildBeepWav(allocator: std.mem.Allocator, freq_hz: f32) ![]u8 {
    const sample_rate: u32 = 22050;
    const num_samples: u32 = sample_rate / 4;
    const data_len: u32 = num_samples * 2;
    const total_len: usize = 44 + data_len;
    const buf = try allocator.alloc(u8, total_len);
    @memcpy(buf[0..4], "RIFF");
    std.mem.writeInt(u32, buf[4..8], @intCast(total_len - 8), .little);
    @memcpy(buf[8..12], "WAVE");
    @memcpy(buf[12..16], "fmt ");
    std.mem.writeInt(u32, buf[16..20], 16, .little);
    std.mem.writeInt(u16, buf[20..22], 1, .little);
    std.mem.writeInt(u16, buf[22..24], 1, .little);
    std.mem.writeInt(u32, buf[24..28], sample_rate, .little);
    std.mem.writeInt(u32, buf[28..32], sample_rate * 2, .little);
    std.mem.writeInt(u16, buf[32..34], 2, .little);
    std.mem.writeInt(u16, buf[34..36], 16, .little);
    @memcpy(buf[36..40], "data");
    std.mem.writeInt(u32, buf[40..44], data_len, .little);

    for (0..num_samples) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sample_rate));
        const env = 1.0 - (@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(num_samples)));
        const s: i16 = @intFromFloat(@sin(t * freq_hz * 2.0 * std.math.pi) * 14000.0 * env);
        std.mem.writeInt(i16, buf[44 + i * 2 ..][0..2], s, .little);
    }
    return buf;
}

fn loadSampleOrBeep(svc: *audio.AudioService, allocator: std.mem.Allocator, io: std.Io, path: []const u8, fallback_hz: f32) !audio.AudioSourceHandle {
    return svc.loadFromFile(io, path) catch {
        const wav = try buildBeepWav(allocator, fallback_hz);
        defer allocator.free(wav);
        return svc.loadFromBytes(wav, .wav);
    };
}

fn poseRight(pose: camera.CameraPose) [3]f32 {
    const f = pose.forward;
    const u = pose.up;
    const cx = f[1] * u[2] - f[2] * u[1];
    const cy = f[2] * u[0] - f[0] * u[2];
    const cz = f[0] * u[1] - f[1] * u[0];
    const len = @sqrt(cx * cx + cy * cy + cz * cz);
    if (len < 1e-6) return .{ 1, 0, 0 };
    return .{ cx / len, cy / len, cz / len };
}

fn updateSharedControls(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(AudioDemoState) orelse return;
    const keys = ctx.resources.get(input.KeyInput) orelse return;
    const sm = ctx.resources.get(state.StateMachine(DemoState)) orelse return;
    const time = ctx.resources.get(engine.Time) orelse return;
    const svc = ctx.resources.get(audio.AudioService) orelse return;

    if (keys.justPressed(.space)) {
        const next: DemoState = if (sm.is(.playing)) .paused else .playing;
        sm.set(next);
        time.paused = (next == .paused);
        if (st.active_pb) |pb| svc.setPaused(pb, next == .paused);
        if (ctx.world.get(st.emitter_entity, audio.AudioPlayer)) |ap| {
            ap.settings.paused = (next == .paused);
        }
    }

    if (keys.pressed(.arrow_up)) {
        svc.master_volume = std.math.clamp(svc.master_volume + 0.8 * time.raw_delta_s, 0.0, 1.5);
    }
    if (keys.pressed(.arrow_down)) {
        svc.master_volume = std.math.clamp(svc.master_volume - 0.8 * time.raw_delta_s, 0.0, 1.5);
    }

    const triggers = [_]struct { key: input.KeyCode, idx: usize, label: []const u8 }{
        .{ .key = .digit_1, .idx = 0, .label = "SFX: 8-Bit Jingle (jingles_NES00.ogg)" },
        .{ .key = .digit_2, .idx = 1, .label = "SFX: Hit Jingle (jingles_HIT00.ogg)" },
        .{ .key = .digit_3, .idx = 2, .label = "SFX: Sax Jingle (jingles_SAX00.ogg)" },
        .{ .key = .digit_4, .idx = 3, .label = "SFX: UI Click (click1.ogg)" },
    };
    for (triggers) |tr| {
        if (keys.justPressed(tr.key)) {
            if (st.active_pb) |pb| svc.stop(pb);
            st.active_pb = svc.play(st.samples[tr.idx], .{
                .mode = .once,
                .volume = 0.85,
                .paused = sm.is(.paused),
            }) catch null;
            st.status_line = tr.label;
        }
    }

    const h1 = std.fmt.bufPrint(
        &st.hud1,
        "State: {s} | Time: {d:.1}s | Vol: {d:.0}% | {s}",
        .{ @tagName(sm.current), time.elapsed_s, svc.master_volume * 100.0, st.status_line },
    ) catch "Audio Demo";
    st.hud1_len = h1.len;
}

fn updatePlayingOnly(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(AudioDemoState) orelse return;
    const keys = ctx.resources.get(input.KeyInput) orelse return;
    const time = ctx.resources.get(engine.Time) orelse return;

    const cam_pose = ctx.world.get(st.cam_entity, camera.CameraPose) orelse return;
    const listener = ctx.world.get(st.cam_entity, audio.SpatialListener) orelse return;
    const t = ctx.world.get(st.emitter_entity, render_3d.Transform3D) orelse return;

    // Q / E vertical flight complement to FreeCamera WASD+Shift.
    if (keys.pressed(.key_e)) cam_pose.position[1] += 6.0 * time.delta_s;
    if (keys.pressed(.key_q)) cam_pose.position[1] -= 6.0 * time.delta_s;

    // Sync SpatialListener with camera pose so flying away/around shifts distance + L/R pan!
    listener.position = cam_pose.position;
    listener.right = poseRight(cam_pose.*);

    t.rotation_euler[1] += 1.2 * time.delta_s;
    st.pulse_timer.tick(time.delta_s);
    const pulse = 1.0 + 0.14 * @sin(st.pulse_timer.fraction() * 2.0 * std.math.pi);
    t.scale = .{ pulse, pulse, pulse };

    const dx = t.position[0] - listener.position[0];
    const dy = t.position[1] - listener.position[1];
    const dz = t.position[2] - listener.position[2];
    const dist = @sqrt(dx * dx + dy * dy + dz * dz);
    const gain = std.math.clamp(1.0 - dist / MAX_AUDIO_DIST, 0.0, 1.0);
    const pan = if (dist > 0.001)
        std.math.clamp((dx * listener.right[0] + dy * listener.right[1] + dz * listener.right[2]) / dist, -1.0, 1.0)
    else
        0.0;
    const side: []const u8 = if (pan < -0.15) "LEFT" else if (pan > 0.15) "RIGHT" else "CENTER";

    const h2 = std.fmt.bufPrint(
        &st.hud2,
        "Cam: ({d:.1},{d:.1},{d:.1}) | Dist: {d:.1}m/{d:.0}m | Spatial Gain: {d:.0}% | Pan: {d:.2} ({s})",
        .{ cam_pose.position[0], cam_pose.position[1], cam_pose.position[2], dist, MAX_AUDIO_DIST, gain * 100.0, pan, side },
    ) catch "";
    st.hud2_len = h2.len;
}

fn renderAudioDemo(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(AudioDemoState) orelse return;
    const cam_svc = ctx.resources.get(camera.CameraService) orelse return;

    const px = window_sdl3.pixelSize(st.app);
    const px_w: u32 = if (px) |p| p.width else 1280;
    const px_h: u32 = if (px) |p| p.height else 720;
    cam_svc.setPrimaryTargetSize(px_w, px_h);

    const cam = ctx.world.get(st.cam_entity, camera.Camera) orelse return;

    try st.gfx.beginFrame(st.rt);
    try st.gfx.submitDrawCommands(st.rt, &.{
        .{ .clear = .{ .r = 0.05, .g = 0.06, .b = 0.10, .a = 1.0 } },
        .{ .text = .{ .x = 20, .y = 20, .content = st.hud1[0..st.hud1_len], .color = .{ .r = 0.94, .g = 0.96, .b = 1.0, .a = 1.0 } } },
        .{ .text = .{ .x = 20, .y = 44, .content = st.hud2[0..st.hud2_len], .color = .{ .r = 0.70, .g = 0.88, .b = 0.98, .a = 1.0 } } },
    });

    const vp = render_3d.math3d.Mat4{ .m = cam.computed.clip_from_world };
    const draw_list = [_]engine.EntityHandle{
        st.emitter_entity,
        st.landmarks[0],
        st.landmarks[1],
        st.landmarks[2],
        st.landmarks[3],
        st.landmarks[4],
        st.landmarks[5],
    };
    for (draw_list) |e| {
        if (ctx.world.get(e, render_3d.Transform3D)) |t| {
            if (ctx.world.get(e, render_3d.MeshRef)) |m| {
                const mvp = render_3d.math3d.Mat4.mul(vp, t.toModelMatrix());
                try graphics_sdlgpu.queueMeshDraw(st.app, st.cube_mesh, mvp.m, m.color, null);
            }
        }
    }

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
    try app.registerModule(state.module());
    try app.registerModule(audio.module());
    try app.registerModule(audio_zaudio.module());

    try state.registerState(&app, DemoState, .playing);

    try app.resources.insert(window_sdl3.WindowConfig, .{
        .title = "Zengy — 3D Spatial Audio (zaudio), FreeCamera, State & Time Demo",
        .width = 1280,
        .height = 720,
        .resizable = true,
    });

    try app.addSystem(.{ .name = "audio_demo.controls", .stage = .update, .run = updateSharedControls });
    try app.addSystem(.{
        .name = "audio_demo.playing",
        .stage = .update,
        .run = updatePlayingOnly,
        .run_if = state.inState(DemoState, .playing),
    });
    try app.addSystem(.{ .name = "audio_demo.render", .stage = .render_extract, .run = renderAudioDemo });

    try app.initialize();

    const svc = app.resources.get(audio.AudioService).?;
    const bgm = try loadSampleOrBeep(svc, allocator, init.io, ".tmp/Abandoned Research Facility.mp3", 220.0);
    const s0 = try loadSampleOrBeep(svc, allocator, init.io, ".tmp/Audio/8-Bit jingles/jingles_NES00.ogg", 440.0);
    const s1 = try loadSampleOrBeep(svc, allocator, init.io, ".tmp/Audio/Hit jingles/jingles_HIT00.ogg", 330.0);
    const s2 = try loadSampleOrBeep(svc, allocator, init.io, ".tmp/Audio/Sax jingles/jingles_SAX00.ogg", 554.0);
    const s3 = try loadSampleOrBeep(svc, allocator, init.io, ".tmp/Audio/UI/click1.ogg", 880.0);

    const g_entry = try app.services.getService("engine.graphics.device", 1);
    const gfx: *graphics.GraphicsDeviceService = @ptrCast(@alignCast(@constCast(g_entry.api_ptr)));

    var cube = try render_3d.gltf.createCubeMesh(allocator, 0.85);
    defer cube.deinit();
    const gpu_cube = try graphics_sdlgpu.createMesh3D(&app, std.mem.sliceAsBytes(cube.vertices), cube.indices);

    // Camera also acts as the 3D SpatialListener + FreeCamera.
    const cam_e = try app.world.spawn();
    try app.world.set(cam_e, camera.Camera, .{ .order = 0 });
    try app.world.set(cam_e, camera.Projection, .{ .perspective = .{ .fov_rad = std.math.pi / 3.0, .far = 160.0 } });
    try app.world.set(cam_e, camera.CameraPose, camera.CameraPose.lookAt(.{ 0, 1.5, 5.5 }, .{ 0, 0, 0 }, .{ 0, 1, 0 }));
    try app.world.set(cam_e, camera.FreeCamera, .{ .walk_speed = 8.0, .run_speed = 18.0 });
    try app.world.set(cam_e, camera.FreeCameraState, .{});
    try app.world.set(cam_e, audio.SpatialListener, .{ .position = .{ 0, 1.5, 5.5 } });

    // Glowing green emitter cube at world origin.
    const emitter_e = try app.world.spawn();
    try app.world.set(emitter_e, render_3d.Transform3D, .{ .position = .{ 0, 0, 0 } });
    try app.world.set(emitter_e, render_3d.MeshRef, .{
        .mesh_asset = @bitCast(gpu_cube),
        .bounds_radius = cube.bounds_radius,
        .color = .{ 0.30, 0.90, 0.62, 1.0 },
    });
    try app.world.set(emitter_e, audio.AudioPlayer, .{
        .source = bgm,
        .auto_play = true,
        .settings = .{ .mode = .loop, .volume = 0.9, .spatial = true, .max_distance = MAX_AUDIO_DIST },
    });

    // Reference pillars/markers at 6m, 12m, 20m so distance perception is obvious while flying.
    const marker_specs = [_]struct { pos: [3]f32, scale: [3]f32, col: [4]f32 }{
        .{ .pos = .{ -6, -0.8, 0 }, .scale = .{ 0.4, 0.4, 0.4 }, .col = .{ 0.35, 0.45, 0.65, 1.0 } },
        .{ .pos = .{ 6, -0.8, 0 }, .scale = .{ 0.4, 0.4, 0.4 }, .col = .{ 0.35, 0.45, 0.65, 1.0 } },
        .{ .pos = .{ 0, -0.8, 12 }, .scale = .{ 0.5, 0.5, 0.5 }, .col = .{ 0.75, 0.55, 0.25, 1.0 } },
        .{ .pos = .{ 0, -0.8, -12 }, .scale = .{ 0.5, 0.5, 0.5 }, .col = .{ 0.75, 0.55, 0.25, 1.0 } },
        .{ .pos = .{ -12, -0.8, 12 }, .scale = .{ 0.6, 0.6, 0.6 }, .col = .{ 0.65, 0.30, 0.35, 1.0 } },
        .{ .pos = .{ 12, -0.8, 12 }, .scale = .{ 0.6, 0.6, 0.6 }, .col = .{ 0.65, 0.30, 0.35, 1.0 } },
    };
    var landmarks: [6]engine.EntityHandle = undefined;
    for (marker_specs, 0..) |ms, idx| {
        const le = try app.world.spawn();
        try app.world.set(le, render_3d.Transform3D, .{ .position = ms.pos, .scale = ms.scale });
        try app.world.set(le, render_3d.MeshRef, .{
            .mesh_asset = @bitCast(gpu_cube),
            .bounds_radius = cube.bounds_radius,
            .color = ms.col,
        });
        landmarks[idx] = le;
    }

    const px = window_sdl3.pixelSize(&app);
    const px_w: u32 = if (px) |p| p.width else 1280;
    const px_h: u32 = if (px) |p| p.height else 720;
    const rt = try gfx.createSurface(1, px_w, px_h);

    try app.resources.insert(AudioDemoState, .{
        .app = &app,
        .gfx = gfx,
        .rt = rt,
        .cube_mesh = gpu_cube,
        .cam_entity = cam_e,
        .emitter_entity = emitter_e,
        .landmarks = landmarks,
        .samples = .{ s0, s1, s2, s3 },
    });

    try window_sdl3.runVisualLoop(&app);
}
