//! Visual 3D Gizmos Showcase (`examples/visual-gizmos/main.zig`).
//!
//! Demonstrates immediate-mode 3D debug & editor gizmos (`official.gizmos`)
//! combined with `camera.Camera.viewportToWorld` ray picking:
//! - Ground grid, RGB coordinate axes, wireframe cuboids, spheres, circles,
//!   directional arrows, and X-ray (always-on-top) overlays.
//! - Left-Click & Drag on the center cube (or its RGB axis handles) to move it!
//!
//! Controls:
//! - Left-Click + Drag on Cube / Axis: Select & Move Cube (hold Shift for Y-axis)
//! - W/A/S/D (+Shift sprint, Q/E down/up) + Right-Click Drag: Fly FreeCamera
//! - G: Toggle Gizmos
//! - X: Toggle X-Ray overlay lines
//!
//! Run with: `zig build run-visual-gizmos`

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

const DragAxis = enum {
    none,
    xz_plane,
    axis_x,
    axis_y,
    axis_z,
};

const GizmoShowcaseState = struct {
    app: *engine.App,
    gfx: *graphics.GraphicsDeviceService,
    rt: graphics.RenderTargetHandle,
    cam_entity: engine.EntityHandle,
    box_entity: engine.EntityHandle,
    time: f32 = 0.0,
    show_xray: bool = true,
    selected: bool = true,
    gizmo_mode: gizmos.TransformGizmoMode = .translate,
    hovered_axis: DragAxis = .none,
    hovered_hit: [3]f32 = .{ 0, 0, 0 },
    drag_axis: DragAxis = .none,
    drag_hit: [3]f32 = .{ 0, 0, 0 },
    drag_offset: [3]f32 = .{ 0, 0, 0 },
    drag_plane_y: f32 = 1.0,
    hud: [220]u8 = @splat(0),
    hud_len: usize = 0,
};

fn intersectRayAabb(origin: [3]f32, dir: [3]f32, min_b: [3]f32, max_b: [3]f32) ?f32 {
    var tmin: f32 = 0.0;
    var tmax: f32 = 1e6;
    inline for (0..3) |i| {
        if (@abs(dir[i]) < 1e-6) {
            if (origin[i] < min_b[i] or origin[i] > max_b[i]) return null;
        } else {
            const inv = 1.0 / dir[i];
            var t1 = (min_b[i] - origin[i]) * inv;
            var t2 = (max_b[i] - origin[i]) * inv;
            if (t1 > t2) {
                const tmp = t1;
                t1 = t2;
                t2 = tmp;
            }
            tmin = @max(tmin, t1);
            tmax = @min(tmax, t2);
            if (tmin > tmax) return null;
        }
    }
    return tmin;
}

fn intersectRayPlaneY(origin: [3]f32, dir: [3]f32, plane_y: f32) ?[3]f32 {
    if (@abs(dir[1]) < 1e-5) return null;
    const t = (plane_y - origin[1]) / dir[1];
    if (t < 0.0 or t > 200.0) return null;
    return .{
        origin[0] + dir[0] * t,
        plane_y,
        origin[2] + dir[2] * t,
    };
}

fn closestPointOnAxis(ray_o: [3]f32, ray_d: [3]f32, axis_o: [3]f32, axis_d: [3]f32) f32 {
    const w0 = [3]f32{ axis_o[0] - ray_o[0], axis_o[1] - ray_o[1], axis_o[2] - ray_o[2] };
    const a = axis_d[0] * axis_d[0] + axis_d[1] * axis_d[1] + axis_d[2] * axis_d[2];
    const b = axis_d[0] * ray_d[0] + axis_d[1] * ray_d[1] + axis_d[2] * ray_d[2];
    const c = ray_d[0] * ray_d[0] + ray_d[1] * ray_d[1] + ray_d[2] * ray_d[2];
    const d = axis_d[0] * w0[0] + axis_d[1] * w0[1] + axis_d[2] * w0[2];
    const e = ray_d[0] * w0[0] + ray_d[1] * w0[1] + ray_d[2] * w0[2];
    const denom = a * c - b * b;
    if (@abs(denom) < 1e-5) return 0.0;
    return (b * e - c * d) / denom;
}

fn updateShowcase(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(GizmoShowcaseState) orelse return;
    const keys = ctx.resources.get(input.KeyInput) orelse return;
    const mouse = ctx.resources.get(input.MouseInput) orelse return;
    const motion = ctx.resources.get(input.AccumulatedMouseMotion) orelse return;
    const giz = ctx.resources.get(gizmos.GizmoService) orelse return;
    const cam = ctx.world.get(st.cam_entity, camera.Camera) orelse return;
    const box_tf = ctx.world.get(st.box_entity, render_3d.Transform3D) orelse return;

    st.time += ctx.dt;
    if (keys.justPressed(.key_g)) giz.config.enabled = !giz.config.enabled;
    if (keys.justPressed(.key_x)) st.show_xray = !st.show_xray;
    if (keys.justPressed(.digit_1)) giz.config.line.style = .solid;
    if (keys.justPressed(.digit_2)) giz.config.line.style = .{ .dashed = .{ .gap_scale = 1.5, .line_scale = 2.5 } };
    if (keys.justPressed(.digit_3)) giz.config.line.style = .dotted;
    if (keys.justPressed(.digit_4)) giz.config.arrow.style = .chevron;
    if (keys.justPressed(.digit_5)) giz.config.arrow.style = .cone;
    if (keys.justPressed(.digit_6)) giz.config.arrow.style = .diamond;
    if (keys.justPressed(.arrow_down)) giz.config.line.width = @max(1.0, giz.config.line.width - 0.5);
    if (keys.justPressed(.arrow_up)) giz.config.line.width = @min(10.0, giz.config.line.width + 0.5);
    if (keys.justPressed(.digit_7)) st.gizmo_mode = .translate;
    if (keys.justPressed(.digit_8)) st.gizmo_mode = .rotate;
    if (keys.justPressed(.digit_9)) st.gizmo_mode = .scale;
    if (keys.justPressed(.tab)) {
        st.gizmo_mode = switch (st.gizmo_mode) {
            .translate => .rotate,
            .rotate => .scale,
            .scale => .translate,
        };
    }

    // Interactive 3D ray picking & gizmo dragging with Left Mouse Button (DPI-aware).
    const pos = box_tf.position;
    const half = [3]f32{ box_tf.scale[0] * 0.5, box_tf.scale[1] * 0.5, box_tf.scale[2] * 0.5 };
    var pick_pos = motion.position;
    if (window_sdl3.pixelSize(st.app)) |px| {
        pick_pos[0] *= px.dpi_scale;
        pick_pos[1] *= px.dpi_scale;
    }
    const maybe_ray = cam.viewportToWorld(pick_pos);

    if (st.drag_axis == .none) {
        st.hovered_axis = .none;
        if (maybe_ray) |r| {
            var best_t: f32 = 1e6;
            if (st.selected) {
                if (st.gizmo_mode == .rotate) {
                    const ring_r: f32 = 1.6 * 0.85;
                    const ring_tol: f32 = 0.22;
                    const planes = [3]struct { axis: DragAxis, norm: [3]f32 }{
                        .{ .axis = .axis_x, .norm = .{ 1, 0, 0 } },
                        .{ .axis = .axis_y, .norm = .{ 0, 1, 0 } },
                        .{ .axis = .axis_z, .norm = .{ 0, 0, 1 } },
                    };
                    for (planes) |pl| {
                        const denom = r.direction[0] * pl.norm[0] + r.direction[1] * pl.norm[1] + r.direction[2] * pl.norm[2];
                        if (@abs(denom) > 0.08) {
                            const diff = [3]f32{ pos[0] - r.origin[0], pos[1] - r.origin[1], pos[2] - r.origin[2] };
                            const t = (diff[0] * pl.norm[0] + diff[1] * pl.norm[1] + diff[2] * pl.norm[2]) / denom;
                            if (t > 0.0 and t < best_t) {
                                const hit = [3]f32{ r.origin[0] + r.direction[0] * t, r.origin[1] + r.direction[1] * t, r.origin[2] + r.direction[2] * t };
                                const dx = hit[0] - pos[0];
                                const dy = hit[1] - pos[1];
                                const dz = hit[2] - pos[2];
                                const dist = @sqrt(dx * dx + dy * dy + dz * dz);
                                if (@abs(dist - ring_r) < ring_tol) {
                                    best_t = t;
                                    st.hovered_axis = pl.axis;
                                    st.hovered_hit = hit;
                                }
                            }
                        }
                    }
                } else {
                    const axis_len: f32 = 1.6;
                    const pad: f32 = 0.22;
                    if (intersectRayAabb(r.origin, r.direction, .{ pos[0] + 0.5, pos[1] - pad, pos[2] - pad }, .{ pos[0] + axis_len, pos[1] + pad, pos[2] + pad })) |t| {
                        if (t < best_t) {
                            best_t = t;
                            st.hovered_axis = .axis_x;
                        }
                    }
                    if (intersectRayAabb(r.origin, r.direction, .{ pos[0] - pad, pos[1] + 0.5, pos[2] - pad }, .{ pos[0] + pad, pos[1] + axis_len, pos[2] + pad })) |t| {
                        if (t < best_t) {
                            best_t = t;
                            st.hovered_axis = .axis_y;
                        }
                    }
                    if (intersectRayAabb(r.origin, r.direction, .{ pos[0] - pad, pos[1] - pad, pos[2] + 0.5 }, .{ pos[0] + pad, pos[1] + pad, pos[2] + axis_len })) |t| {
                        if (t < best_t) {
                            best_t = t;
                            st.hovered_axis = .axis_z;
                        }
                    }
                }
            }
            if (st.hovered_axis == .none) {
                if (intersectRayAabb(r.origin, r.direction, .{ pos[0] - half[0], pos[1] - half[1], pos[2] - half[2] }, .{ pos[0] + half[0], pos[1] + half[1], pos[2] + half[2] }) != null) {
                    st.hovered_axis = .xz_plane;
                }
            }

            if (mouse.justPressed(.left)) {
                if (st.hovered_axis != .none) {
                    st.selected = true;
                    st.drag_axis = st.hovered_axis;
                    st.drag_hit = st.hovered_hit;
                    st.drag_plane_y = pos[1];
                    switch (st.drag_axis) {
                        .xz_plane => {
                            if (intersectRayPlaneY(r.origin, r.direction, st.drag_plane_y)) |hit| {
                                st.drag_offset = .{ pos[0] - hit[0], 0.0, pos[2] - hit[2] };
                            } else {
                                st.drag_offset = .{ 0, 0, 0 };
                            }
                        },
                        .axis_x => st.drag_offset[0] = closestPointOnAxis(r.origin, r.direction, pos, .{ 1, 0, 0 }),
                        .axis_y => st.drag_offset[1] = closestPointOnAxis(r.origin, r.direction, pos, .{ 0, 1, 0 }),
                        .axis_z => st.drag_offset[2] = closestPointOnAxis(r.origin, r.direction, pos, .{ 0, 0, 1 }),
                        .none => {},
                    }
                } else {
                    st.selected = false;
                }
            }
        }
    } else {
        if (mouse.justReleased(.left) or !mouse.pressed(.left)) {
            st.drag_axis = .none;
        } else if (maybe_ray) |r| {
            const shift = keys.pressed(.shift_left) or keys.pressed(.shift_right);
            if (st.gizmo_mode == .translate) {
                if (st.drag_axis == .xz_plane and !shift) {
                    if (intersectRayPlaneY(r.origin, r.direction, st.drag_plane_y)) |hit| {
                        box_tf.position[0] = hit[0] + st.drag_offset[0];
                        box_tf.position[2] = hit[2] + st.drag_offset[2];
                    }
                } else if (st.drag_axis == .axis_x) {
                    const delta = closestPointOnAxis(r.origin, r.direction, pos, .{ 1, 0, 0 }) - st.drag_offset[0];
                    box_tf.position[0] += delta;
                } else if (st.drag_axis == .axis_y or (st.drag_axis == .xz_plane and shift)) {
                    const delta = closestPointOnAxis(r.origin, r.direction, pos, .{ 0, 1, 0 }) - st.drag_offset[1];
                    box_tf.position[1] = @max(half[1], pos[1] + delta);
                    st.drag_plane_y = box_tf.position[1];
                } else if (st.drag_axis == .axis_z) {
                    const delta = closestPointOnAxis(r.origin, r.direction, pos, .{ 0, 0, 1 }) - st.drag_offset[2];
                    box_tf.position[2] += delta;
                }
            } else if (st.gizmo_mode == .rotate) {
                const rot_idx: usize = switch (st.drag_axis) {
                    .axis_x => 0,
                    .axis_y, .xz_plane => 1,
                    .axis_z => 2,
                    .none => 1,
                };
                const axis_vec: [3]f32 = switch (rot_idx) {
                    0 => .{ 1, 0, 0 },
                    1 => .{ 0, 1, 0 },
                    else => .{ 0, 0, 1 },
                };
                var r_vec = [3]f32{
                    st.drag_hit[0] - pos[0],
                    st.drag_hit[1] - pos[1],
                    st.drag_hit[2] - pos[2],
                };
                const r_len = @sqrt(r_vec[0] * r_vec[0] + r_vec[1] * r_vec[1] + r_vec[2] * r_vec[2]);
                if (st.drag_axis == .xz_plane or r_len < 1e-4) {
                    r_vec = .{ 0, 0, 1 };
                } else {
                    r_vec = .{ r_vec[0] / r_len, r_vec[1] / r_len, r_vec[2] / r_len };
                }
                const tan3 = [3]f32{
                    axis_vec[1] * r_vec[2] - axis_vec[2] * r_vec[1],
                    axis_vec[2] * r_vec[0] - axis_vec[0] * r_vec[2],
                    axis_vec[0] * r_vec[1] - axis_vec[1] * r_vec[0],
                };
                const anchor = [3]f32{ pos[0] + r_vec[0], pos[1] + r_vec[1], pos[2] + r_vec[2] };
                const tip = [3]f32{ anchor[0] + tan3[0] * 0.5, anchor[1] + tan3[1] * 0.5, anchor[2] + tan3[2] * 0.5 };
                var angle_delta = motion.delta[0] * 0.01;
                if (cam.worldToViewport(anchor)) |p0| {
                    if (cam.worldToViewport(tip)) |p1| {
                        const tx = p1[0] - p0[0];
                        const ty = p1[1] - p0[1];
                        const tlen = @sqrt(tx * tx + ty * ty);
                        if (tlen > 1e-3) {
                            angle_delta = ((motion.delta[0] * tx + motion.delta[1] * ty) / tlen) * 0.012;
                        }
                    }
                }
                box_tf.rotation_euler[rot_idx] += angle_delta;
            } else if (st.gizmo_mode == .scale) {
                if (st.drag_axis == .axis_x) {
                    const d = closestPointOnAxis(r.origin, r.direction, pos, .{ 1, 0, 0 }) - st.drag_offset[0];
                    box_tf.scale[0] = @max(0.25, box_tf.scale[0] + d);
                    st.drag_offset[0] = closestPointOnAxis(r.origin, r.direction, pos, .{ 1, 0, 0 });
                } else if (st.drag_axis == .axis_y) {
                    const d = closestPointOnAxis(r.origin, r.direction, pos, .{ 0, 1, 0 }) - st.drag_offset[1];
                    box_tf.scale[1] = @max(0.25, box_tf.scale[1] + d);
                    st.drag_offset[1] = closestPointOnAxis(r.origin, r.direction, pos, .{ 0, 1, 0 });
                } else if (st.drag_axis == .axis_z) {
                    const d = closestPointOnAxis(r.origin, r.direction, pos, .{ 0, 0, 1 }) - st.drag_offset[2];
                    box_tf.scale[2] = @max(0.25, box_tf.scale[2] + d);
                    st.drag_offset[2] = closestPointOnAxis(r.origin, r.direction, pos, .{ 0, 0, 1 });
                } else if (st.drag_axis == .xz_plane) {
                    const d = closestPointOnAxis(r.origin, r.direction, pos, .{ 0, 1, 0 }) - st.drag_offset[1];
                    box_tf.scale[0] = @max(0.25, box_tf.scale[0] + d);
                    box_tf.scale[1] = @max(0.25, box_tf.scale[1] + d);
                    box_tf.scale[2] = @max(0.25, box_tf.scale[2] + d);
                    st.drag_offset[1] = closestPointOnAxis(r.origin, r.direction, pos, .{ 0, 1, 0 });
                }
            }
        }
    }

    const cur = box_tf.position;
    const ls_tag: []const u8 = switch (giz.config.line.style) {
        .solid => "Solid",
        .dotted => "Dotted",
        .dashed => "Dashed",
    };
    const h = std.fmt.bufPrint(
        &st.hud,
        "[Tab/7-9]Mode:{s} | [1-3]Line:{s} [4-6]Arrow:{s} [Up/Dn]Width:{d:.1}px | G=On({any})",
        .{ @tagName(st.gizmo_mode), ls_tag, @tagName(giz.config.arrow.style), giz.config.line.width, giz.config.enabled },
    ) catch "Gizmos Showcase";
    st.hud_len = h.len;

    // Large ground grid + world origin axes.
    giz.grid(.{ 0, 0, 0 }, .{ 28, 28 }, .{ 1.5, 1.5 }, .{ 0.55, 0.58, 0.62, 0.45 });
    giz.axes(.{ -6.5, 0.02, 4.0 }, 1.0);

    // Directional Light Gizmo (sun disc + parallel rays, back-left).
    const sun_pos = [3]f32{ -4.2, 3.0, -3.5 };
    const sun_dir = [3]f32{ 0.45, -0.75, 0.45 };
    giz.circle(sun_pos, sun_dir, 0.42, 20, .{ 1.0, 0.92, 0.45, 0.95 });
    for (0..8) |ri| {
        const ang = @as(f32, @floatFromInt(ri)) * (2.0 * std.math.pi / 8.0);
        const rx = sun_pos[0] + @cos(ang) * 0.36;
        const rz = sun_pos[2] + @sin(ang) * 0.36;
        giz.ray(.{ rx, sun_pos[1], rz }, .{ sun_dir[0] * 1.4, sun_dir[1] * 1.4, sun_dir[2] * 1.4 }, .{ 1.0, 0.92, 0.45, 0.8 });
    }

    // Tilted green grid + red frames in the background.
    giz.gridOriented(.{ 8.0, 2.2, -5.0 }, .{ -0.35, 0.35, 0.85 }, .{ 6, 6 }, .{ 0.45, 0.45 }, .{ 0.15, 0.85, 0.25, 0.9 });
    giz.arrow(.{ 8.0, 2.2, -5.0 }, .{ -1.1, 0.2, 0.5 }, .{ 0.15, 0.85, 0.25, 1.0 });
    giz.rect(.{ 5.8, 1.2, -2.5 }, .{ 0.0, 0.0, 1.0 }, .{ 1.8, 1.8 }, .{ 0.95, 0.2, 0.2, 0.9 });

    // Red sphere + red rect + downward orange drop-arrow (right).
    const red_pos = [3]f32{ 4.5, 1.8, -0.2 };
    giz.rect(red_pos, .{ 0.0, 0.0, 1.0 }, .{ 1.8, 1.8 }, .{ 0.95, 0.2, 0.2, 0.9 });
    giz.sphere(red_pos, 0.6, 20, .{ 0.95, 0.15, 0.2, 0.95 });
    giz.arrow(red_pos, .{ 0.0, -red_pos[1], 0.0 }, .{ 1.0, 0.45, 0.1, 1.0 });

    // Rounded cuboid showcase on front-right.
    giz.roundedCuboid(.{ 4.5, 0.85, 3.6 }, .{ 1.5, 1.5, 1.5 }, 0.28, .{ 0.3, 0.9, 1.0, 0.9 });

    // Spiraling cyan-to-magenta circles + orbiting spheres on the left (clear of the center cube).
    for (0..14) |ci| {
        const t: f32 = @as(f32, @floatFromInt(ci)) / 13.0;
        const c_pos = [3]f32{
            -5.0 + t * 1.4 + 0.15 * @cos(st.time * 2.0 + t * 4.0),
            1.4 + 0.25 * @sin(t * std.math.pi),
            1.8 - t * 2.4,
        };
        const r_col = [4]f32{ 0.2 + 0.75 * t, 0.85 - 0.45 * t, 0.95, 0.8 };
        giz.circle(c_pos, .{ 0.35, 0.15, 0.9 }, 0.6 + 0.25 * (1.0 - t), 22, r_col);
    }
    for (0..3) |si| {
        const phase = st.time * 1.5 + @as(f32, @floatFromInt(si)) * 2.1;
        giz.sphere(.{ -4.8 + 0.4 * @cos(phase), 0.7 + 0.2 * @sin(phase), 2.4 - @as(f32, @floatFromInt(si)) * 0.45 }, 0.36, 14, .{ 0.75, 0.95, 0.2, 0.85 });
    }

    // Clean Unity-style selection wireframe + sleek interactive RGB transform gizmo on the center cube.
    if (st.selected or st.hovered_axis != .none) {
        const box_col: [4]f32 = if (st.drag_axis != .none)
            .{ 1.0, 0.92, 0.25, 1.0 }
        else if (st.hovered_axis != .none)
            .{ 0.4, 1.0, 0.85, 1.0 }
        else
            .{ 1.0, 0.86, 0.22, 0.9 };
        giz.cuboid(cur, .{ box_tf.scale[0] + 0.08, box_tf.scale[1] + 0.08, box_tf.scale[2] + 0.08 }, box_col);

        if (st.selected) {
            const active_ax: u8 = switch (if (st.drag_axis != .none) st.drag_axis else st.hovered_axis) {
                .axis_x => 1,
                .axis_y => 2,
                .axis_z => 3,
                else => 0,
            };
            giz.transformGizmo(cur, st.gizmo_mode, 1.6, active_ax);
        }
    }

    // Subtle X-ray cross at the cube pivot when X-ray toggle is active.
    if (st.show_xray) {
        giz.lineXray(.{ cur[0] - 0.18, cur[1], cur[2] }, .{ cur[0] + 0.18, cur[1], cur[2] }, .{ 1.0, 1.0, 1.0, 0.65 });
        giz.lineXray(.{ cur[0], cur[1] - 0.18, cur[2] }, .{ cur[0], cur[1] + 0.18, cur[2] }, .{ 1.0, 1.0, 1.0, 0.65 });
    }
}

fn renderOverlay(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(GizmoShowcaseState) orelse return;
    const cam_svc = ctx.resources.get(camera.CameraService) orelse return;
    const px = window_sdl3.pixelSize(st.app);
    cam_svc.setPrimaryTargetSize(if (px) |p| p.width else 1280, if (px) |p| p.height else 720);

    try st.gfx.beginFrame(st.rt);
    try st.gfx.submitDrawCommands(st.rt, &.{
        .{ .text = .{ .x = 18, .y = 18, .content = st.hud[0..st.hud_len], .color = .{ .r = 0.95, .g = 0.98, .b = 1.0, .a = 1.0 } } },
    });
    try st.gfx.present(st.rt);
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
        .title = "Zengy — 3D Gizmos Showcase",
        .width = 1280,
        .height = 720,
        .resizable = true,
    });
    try app.resources.insert(wgpu.GpuConfig, .{
        .default_clear_color = .{ .r = 0.14, .g = 0.15, .b = 0.18, .a = 1.0 },
    });

    try app.addSystem(.{ .name = "gizmos_showcase.update", .stage = .update, .run = updateShowcase });
    try app.addSystem(.{ .name = "gizmos_showcase.overlay", .stage = .render_extract, .run = renderOverlay });

    try app.initialize();
    if (app.resources.get(gizmos.GizmoService)) |giz| {
        giz.config.line.width = 2.0;
        giz.config.xray_alpha = 0.95;
    }

    const g_entry = try app.services.getService("engine.graphics.device", 1);
    const gfx: *graphics.GraphicsDeviceService = @ptrCast(@alignCast(@constCast(g_entry.api_ptr)));
    const mats = app.resources.get(render_3d.pbr.MaterialRegistry).?;

    var cube = try render_3d.gltf.createCubeMesh(allocator, 1.0);
    defer cube.deinit();
    const gpu_cube = try gpu_3d.createMesh3D(&app, std.mem.sliceAsBytes(cube.vertices), cube.indices);

    // Dark matte slate floor pad under the interactive cube.
    const pad_mat = try mats.add(.{ .base_color = .{ 0.18, 0.21, 0.24, 1.0 }, .roughness = 0.88 });
    const pad_e = try app.world.spawn();
    try app.world.set(pad_e, render_3d.Transform3D, .{ .position = .{ 0, -0.04, 0 }, .scale = .{ 5.5, 0.06, 5.5 } });
    try app.world.set(pad_e, render_3d.MeshRef, .{ .mesh_asset = @bitCast(gpu_cube), .material_handle = pad_mat });

    // Solid interactive cube with transform gizmo.
    const mat = try mats.add(.{ .base_color = .{ 0.62, 0.64, 0.68, 1.0 }, .roughness = 0.45, .metallic = 0.15 });
    const box_e = try app.world.spawn();
    try app.world.set(box_e, render_3d.Transform3D, .{ .position = .{ 0, 0.75, 0 }, .scale = .{ 1.4, 1.5, 1.4 } });
    try app.world.set(box_e, render_3d.MeshRef, .{ .mesh_asset = @bitCast(gpu_cube), .material_handle = mat });

    const sun_e = try app.world.spawn();
    try app.world.set(sun_e, render_3d.pbr.DirectionalLight, .{
        .color = .{ 1.0, 0.96, 0.90 },
        .illuminance_lux = 18000.0,
        .direction = .{ -0.4, -0.8, -0.4 },
    });

    const cam_e = try app.world.spawn();
    try app.world.set(cam_e, camera.Camera, .{ .order = 0 });
    try app.world.set(cam_e, camera.Projection, .{ .perspective = .{ .fov_rad = std.math.pi / 3.0, .near = 0.2, .far = 150.0 } });
    try app.world.set(cam_e, camera.CameraPose, camera.CameraPose.lookAt(.{ 0, 4.5, 9.5 }, .{ 0, 1.0, 0 }, .{ 0, 1, 0 }));
    try app.world.set(cam_e, camera.FreeCamera, .{ .walk_speed = 7.0, .run_speed = 14.0 });
    try app.world.set(cam_e, camera.FreeCameraState, .{});

    const px = window_sdl3.pixelSize(&app);
    const rt = try gfx.createSurface(1, if (px) |p| p.width else 1280, if (px) |p| p.height else 720);
    try app.resources.insert(GizmoShowcaseState, .{
        .app = &app,
        .gfx = gfx,
        .rt = rt,
        .cam_entity = cam_e,
        .box_entity = box_e,
    });

    try window_sdl3.runVisualLoop(&app);
}
