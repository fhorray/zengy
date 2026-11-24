//! Visual PS5 DualSense / Gamepad & Haptics Test Scene (`examples/visual-gamepad/main.zig`).
//!
//! Connect a PS5 DualSense (or any SDL3-supported gamepad) via USB or Bluetooth:
//! - Left Stick / D-Pad: Move & tilt the 3D cube
//! - Right Stick: Rotate the 3D cube
//! - Cross (South): Trigger dual-motor rumble
//! - Square (West): Trigger L2/R2 trigger rumble
//! - Circle (East): Stop rumble
//! - Triangle (North): Reset cube pose
//! - L1 / R1: Cycle cube color
//! - L2 / R2: Scale cube & test analog trigger pressure
//!
//! Run with: `zig build run-visual-gamepad`

const std = @import("std");
const engine = @import("engine");
const window_sdl3 = @import("window_sdl3");
const graphics = @import("graphics");
const graphics_sdlgpu = @import("graphics_sdlgpu");
const input = @import("input");
const input_haptics = @import("input_haptics");
const input_sdl3 = @import("input_sdl3");
const camera = @import("camera");
const render_3d = @import("render_3d");

const PALETTE = [_][4]f32{
    .{ 0.25, 0.65, 0.98, 1.0 },
    .{ 0.35, 0.88, 0.58, 1.0 },
    .{ 0.96, 0.62, 0.22, 1.0 },
    .{ 0.88, 0.32, 0.45, 1.0 },
    .{ 0.72, 0.46, 0.95, 1.0 },
};

const GamepadDemoState = struct {
    app: *engine.App,
    gfx: *graphics.GraphicsDeviceService,
    rt: graphics.RenderTargetHandle,
    cube_mesh: graphics_sdlgpu.GpuMeshHandle,
    cam_entity: engine.EntityHandle,
    cube_entity: engine.EntityHandle,
    color_idx: usize = 0,
    rumble_status: []const u8 = "Idle (X=Rumble, Options/Touchpad=10s Show, O=Stop)",
    haptic_show_t: f32 = -1.0,
    hud_line1: [160]u8 = @splat(0),
    hud_line1_len: usize = 0,
    hud_line2: [160]u8 = @splat(0),
    hud_line2_len: usize = 0,
    hud_line3: [160]u8 = @splat(0),
    hud_line3_len: usize = 0,
};

fn updateGamepadDemo(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(GamepadDemoState) orelse return;
    const gps = ctx.resources.get(input.Gamepads) orelse return;
    const hap = ctx.resources.get(input_haptics.HapticService);
    const keys = ctx.resources.get(input.KeyInput);

    const t = ctx.world.get(st.cube_entity, render_3d.Transform3D) orelse return;
    const m = ctx.world.get(st.cube_entity, render_3d.MeshRef) orelse return;

    if (gps.firstConnected()) |gp| {
        const ls = gp.leftStick();
        const rs = gp.rightStick();
        const dp = gp.dpad();
        const l2 = gp.axis(.left_z);
        const r2 = gp.axis(.right_z);

        t.position[0] = std.math.clamp(t.position[0] + (ls[0] + dp[0] * 0.6) * 4.0 * ctx.dt, -4.0, 4.0);
        t.position[1] = std.math.clamp(t.position[1] + (ls[1] + dp[1] * 0.6) * 4.0 * ctx.dt, -2.5, 2.5);
        t.rotation_euler[1] += rs[0] * 3.0 * ctx.dt;
        t.rotation_euler[0] -= rs[1] * 3.0 * ctx.dt;

        const base_scale = 1.0 + r2 * 0.8 - l2 * 0.4;
        t.scale = .{ base_scale, base_scale, base_scale };

        if (gp.justPressed(.right_bumper) or gp.justPressed(.dpad_right)) {
            st.color_idx = (st.color_idx + 1) % PALETTE.len;
            m.color = PALETTE[st.color_idx];
        } else if (gp.justPressed(.left_bumper) or gp.justPressed(.dpad_left)) {
            st.color_idx = (st.color_idx + PALETTE.len - 1) % PALETTE.len;
            m.color = PALETTE[st.color_idx];
        }

        if (gp.justPressed(.left_thumb)) {
            t.position = .{ 0, 0, 0 };
            if (hap) |h| _ = h.playRumble(0, 0.45, 0.25, 120);
            st.rumble_status = "L3 Pressed: Center Position";
        }
        if (gp.justPressed(.right_thumb)) {
            t.rotation_euler = .{ 0, 0, 0 };
            if (hap) |h| _ = h.playRumble(0, 0.25, 0.45, 120);
            st.rumble_status = "R3 Pressed: Reset Rotation";
        }

        if (gp.justPressed(.north)) {
            t.position = .{ 0, 0, 0 };
            t.rotation_euler = .{ 0, 0, 0 };
            t.scale = .{ 1, 1, 1 };
        }

        if (hap) |h| {
            if (gp.justPressed(.start) or gp.justPressed(.touchpad)) {
                st.haptic_show_t = 0.0;
            } else if (gp.justPressed(.south)) {
                st.haptic_show_t = -1.0;
                const ok = h.playRumble(0, 0.75, 0.55, 350);
                st.rumble_status = if (ok) "Dual-Motor Rumble (350ms)" else "Rumble unsupported/failed";
            } else if (gp.justPressed(.west)) {
                st.haptic_show_t = -1.0;
                const trig_ok = h.setAdaptiveTrigger(0, .right, .{ .weapon = .{ .start_position = 0.25, .end_position = 0.65, .strength = 1.0 } });
                _ = h.setAdaptiveTrigger(0, .left, .{ .feedback = .{ .start_position = 0.2, .strength = 0.8 } });
                if (trig_ok) {
                    st.rumble_status = "PS5 Adaptive Triggers Active (R2=Weapon, L2=Feedback)";
                } else {
                    _ = h.playRumble(0, 0.35, 0.90, 250);
                    st.rumble_status = "Adaptive Triggers N/A -> High-Freq Pulse";
                }
            } else if (gp.justPressed(.east)) {
                st.haptic_show_t = -1.0;
                h.stop(0);
                st.rumble_status = "Stopped (Rumble + Triggers Off)";
            }

            // 10-second choreographed haptic + adaptive trigger showcase sequence.
            if (st.haptic_show_t >= 0.0) {
                st.haptic_show_t += ctx.dt;
                const s = st.haptic_show_t;
                if (s >= 10.0) {
                    st.haptic_show_t = -1.0;
                    h.stop(0);
                    st.rumble_status = "10s Haptic Show Complete!";
                } else if (s < 2.0) {
                    // Heartbeat double-thump + light L2/R2 resistance
                    const phase = @mod(s, 0.65);
                    const beat = (phase < 0.10) or (phase >= 0.18 and phase < 0.28);
                    _ = h.playRumble(0, if (beat) 0.95 else 0.0, if (beat) 0.15 else 0.0, 120);
                    _ = h.setAdaptiveTrigger(0, .both, .{ .feedback = .{ .start_position = 0.15, .strength = 0.7 } });
                    st.rumble_status = "10s Show [1/5]: Heartbeat + Trigger Pulse";
                } else if (s < 4.5) {
                    // Engine rev ramp-up + stiff R2 gas pedal
                    const u = (s - 2.0) / 2.5;
                    const lo = 0.15 + u * 0.80;
                    const hi = 0.10 + u * 0.75;
                    _ = h.playRumble(0, lo, hi, 120);
                    _ = h.setAdaptiveTrigger(0, .right, .{ .feedback = .{ .start_position = 0.1, .strength = 0.95 } });
                    t.rotation_euler[2] = @sin(s * 35.0) * (0.04 + u * 0.12);
                    st.rumble_status = "10s Show [2/5]: Engine Rev + R2 Resistance";
                } else if (s < 7.0) {
                    // Gravel / rain texture + rapid trigger vibration
                    const tick = @sin(s * 42.0) * 0.5 + 0.5;
                    _ = h.playRumble(0, 0.08, 0.25 + tick * 0.55, 120);
                    _ = h.setAdaptiveTrigger(0, .both, .{ .vibration = .{ .start_position = 0.1, .amplitude = 0.85, .frequency_hz = 28 } });
                    st.rumble_status = "10s Show [3/5]: Gravel + Trigger Vibration";
                } else if (s < 9.0) {
                    // Explosion + decaying aftershock + R2 weapon click wall
                    const u = 1.0 - (s - 7.0) / 2.0;
                    _ = h.playRumble(0, u * u, u * 0.85, 120);
                    _ = h.setAdaptiveTrigger(0, .right, .{ .weapon = .{ .start_position = 0.2, .end_position = 0.6, .strength = 1.0 } });
                    t.scale = .{ 1.0 + u * 0.45, 1.0 + u * 0.45, 1.0 + u * 0.45 };
                    st.rumble_status = "10s Show [4/5]: Impact + R2 Weapon Wall";
                } else {
                    // Gentle shimmer fade-out + release triggers
                    const u = 1.0 - (s - 9.0);
                    _ = h.playRumble(0, 0.05 * u, 0.35 * u, 120);
                    _ = h.setAdaptiveTrigger(0, .both, .off);
                    t.rotation_euler[2] = 0.0;
                    st.rumble_status = "10s Show [5/5]: Shimmer Fade-Out";
                }
            }
        }

        const l1 = std.fmt.bufPrint(&st.hud_line1, "Controller: {s} | {s}", .{ gp.name(), st.rumble_status }) catch "Controller";
        st.hud_line1_len = l1.len;
        const l2_str = std.fmt.bufPrint(
            &st.hud_line2,
            "L-Stick: ({d:.2}, {d:.2})  R-Stick: ({d:.2}, {d:.2})  L2:{d:.2} R2:{d:.2}",
            .{ ls[0], ls[1], rs[0], rs[1], l2, r2 },
        ) catch "";
        st.hud_line2_len = l2_str.len;
        const l3_str = std.fmt.bufPrint(
            &st.hud_line3,
            "DPad:[{s}{s}{s}{s}] Face:[{s}{s}{s}{s}] L1:{any} R1:{any} L3:{any} R3:{any} Touch:{any}",
            .{
                if (gp.pressed(.dpad_up)) "U" else ".",
                if (gp.pressed(.dpad_down)) "D" else ".",
                if (gp.pressed(.dpad_left)) "L" else ".",
                if (gp.pressed(.dpad_right)) "R" else ".",
                if (gp.pressed(.south)) "X" else ".",
                if (gp.pressed(.east)) "O" else ".",
                if (gp.pressed(.west)) "S" else ".",
                if (gp.pressed(.north)) "T" else ".",
                gp.pressed(.left_bumper),
                gp.pressed(.right_bumper),
                gp.pressed(.left_thumb),
                gp.pressed(.right_thumb),
                gp.pressed(.touchpad),
            },
        ) catch "";
        st.hud_line3_len = l3_str.len;
    } else {
        // Keyboard fallback when no controller is plugged in.
        if (keys) |k| {
            if (k.pressed(.arrow_left) or k.pressed(.key_a)) t.position[0] -= 3.0 * ctx.dt;
            if (k.pressed(.arrow_right) or k.pressed(.key_d)) t.position[0] += 3.0 * ctx.dt;
            if (k.pressed(.arrow_up) or k.pressed(.key_w)) t.position[1] += 3.0 * ctx.dt;
            if (k.pressed(.arrow_down) or k.pressed(.key_s)) t.position[1] -= 3.0 * ctx.dt;
        }
        const msg1 = "No gamepad detected — connect PS5 DualSense via USB/BT (or use WASD/Arrows)";
        @memcpy(st.hud_line1[0..msg1.len], msg1);
        st.hud_line1_len = msg1.len;
        st.hud_line2_len = 0;
        st.hud_line3_len = 0;
    }
}

fn renderGamepadDemo(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(GamepadDemoState) orelse return;
    const cam_svc = ctx.resources.get(camera.CameraService) orelse return;

    const px = window_sdl3.pixelSize(st.app);
    const px_w: u32 = if (px) |p| p.width else 1280;
    const px_h: u32 = if (px) |p| p.height else 720;
    cam_svc.setPrimaryTargetSize(px_w, px_h);

    const cam = ctx.world.get(st.cam_entity, camera.Camera) orelse return;

    try st.gfx.beginFrame(st.rt);
    try st.gfx.submitDrawCommands(st.rt, &.{
        .{ .clear = .{ .r = 0.06, .g = 0.07, .b = 0.10, .a = 1.0 } },
        .{ .text = .{
            .x = 20.0,
            .y = 20.0,
            .content = st.hud_line1[0..st.hud_line1_len],
            .color = .{ .r = 0.94, .g = 0.96, .b = 1.0, .a = 1.0 },
        } },
        .{ .text = .{
            .x = 20.0,
            .y = 44.0,
            .content = st.hud_line2[0..st.hud_line2_len],
            .color = .{ .r = 0.72, .g = 0.85, .b = 0.98, .a = 1.0 },
        } },
        .{ .text = .{
            .x = 20.0,
            .y = 68.0,
            .content = st.hud_line3[0..st.hud_line3_len],
            .color = .{ .r = 0.68, .g = 0.92, .b = 0.76, .a = 1.0 },
        } },
    });

    // Visual analog trigger bars (L2 & R2) at bottom-left.
    if (ctx.resources.get(input.Gamepads)) |gps| {
        if (gps.firstConnected()) |gp| {
            const l2 = gp.axis(.left_z);
            const r2 = gp.axis(.right_z);
            try st.gfx.submitDrawCommands(st.rt, &.{
                .{ .rect = .{ .x = 20, .y = @as(f32, @floatFromInt(px_h)) - 44, .width = 160, .height = 12, .color = .{ .r = 0.16, .g = 0.18, .b = 0.24, .a = 1.0 } } },
                .{ .rect = .{ .x = 20, .y = @as(f32, @floatFromInt(px_h)) - 44, .width = 160 * l2, .height = 12, .color = .{ .r = 0.30, .g = 0.65, .b = 0.98, .a = 1.0 } } },
                .{ .rect = .{ .x = 200, .y = @as(f32, @floatFromInt(px_h)) - 44, .width = 160, .height = 12, .color = .{ .r = 0.16, .g = 0.18, .b = 0.24, .a = 1.0 } } },
                .{ .rect = .{ .x = 200, .y = @as(f32, @floatFromInt(px_h)) - 44, .width = 160 * r2, .height = 12, .color = .{ .r = 0.96, .g = 0.56, .b = 0.22, .a = 1.0 } } },
            });
        }
    }

    const vp = render_3d.math3d.Mat4{ .m = cam.computed.clip_from_world };
    if (ctx.world.get(st.cube_entity, render_3d.Transform3D)) |t| {
        if (ctx.world.get(st.cube_entity, render_3d.MeshRef)) |m| {
            const mvp = render_3d.math3d.Mat4.mul(vp, t.toModelMatrix());
            try graphics_sdlgpu.queueMeshDraw(st.app, st.cube_mesh, mvp.m, m.color, null);
        }
    }

    try st.gfx.present(st.rt);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = engine.App.init(allocator, .{});
    defer app.deinit();

    try app.registerModule(window_sdl3.module());
    try app.registerModule(graphics_sdlgpu.module());
    try app.registerModule(input.module());
    try app.registerModule(input_haptics.module());
    try app.registerModule(input_sdl3.module());
    try app.registerModule(camera.module());

    try app.resources.insert(window_sdl3.WindowConfig, .{
        .title = "Zengy — PS5 DualSense & Haptics Visual Test",
        .width = 1280,
        .height = 720,
        .resizable = true,
    });

    try app.scheduler.addSystem(.{ .name = "gamepad_demo.update", .stage = .update, .run = updateGamepadDemo });
    try app.scheduler.addSystem(.{ .name = "gamepad_demo.render", .stage = .render_extract, .run = renderGamepadDemo });

    try app.initialize();

    const g_entry = try app.services.getService("engine.graphics.device", 1);
    const gfx: *graphics.GraphicsDeviceService = @ptrCast(@alignCast(@constCast(g_entry.api_ptr)));

    var cube = try render_3d.gltf.createCubeMesh(allocator, 0.9);
    defer cube.deinit();
    const gpu_cube = try graphics_sdlgpu.createMesh3D(&app, std.mem.sliceAsBytes(cube.vertices), cube.indices);

    const cam_e = try app.world.spawn();
    try app.world.set(cam_e, camera.Camera, .{ .order = 0 });
    try app.world.set(cam_e, camera.Projection, .{ .perspective = .{ .fov_rad = std.math.pi / 3.0 } });
    try app.world.set(cam_e, camera.CameraPose, camera.CameraPose.lookAt(.{ 0, 1.2, 6.0 }, .{ 0, 0, 0 }, .{ 0, 1, 0 }));

    const cube_e = try app.world.spawn();
    try app.world.set(cube_e, render_3d.Transform3D, .{ .position = .{ 0, 0, 0 } });
    try app.world.set(cube_e, render_3d.MeshRef, .{
        .mesh_asset = @bitCast(gpu_cube),
        .bounds_radius = cube.bounds_radius,
        .color = PALETTE[0],
    });

    const px = window_sdl3.pixelSize(&app);
    const px_w: u32 = if (px) |p| p.width else 1280;
    const px_h: u32 = if (px) |p| p.height else 720;
    const rt = try gfx.createSurface(1, px_w, px_h);

    try app.resources.insert(GamepadDemoState, .{
        .app = &app,
        .gfx = gfx,
        .rt = rt,
        .cube_mesh = gpu_cube,
        .cam_entity = cam_e,
        .cube_entity = cube_e,
    });

    try window_sdl3.runVisualLoop(&app);
}
