//! `zengy-editor`: a minimal scene editor (MVP).
//!
//! A 3D viewport with a hierarchy panel (left) and an inspector panel (right):
//! - Click a shape in the viewport or a row in the hierarchy to select it (gizmo + highlight).
//! - Move/scale the selection from the keyboard; every change goes through `EditorDocument`
//!   so it is undoable.
//! - Add (`N`) and delete (`Delete`) cubes.
//! - Right-click drag + W/A/S/D flies the camera.
//!
//! The editor-specific state (entities, selection, history) lives in `document.zig` and is tested
//! headless; this file only composes the window, renderer, picking and the panel overlay.
//!
//! Run with: `zig build run-editor`

const std = @import("std");
const engine = @import("engine");
const window_sdl3 = @import("window_sdl3");
const graphics = @import("graphics");
const wgpu = @import("graphics_wgpu");
const draw_2d = @import("draw_2d");
const gpu_3d = @import("gpu_3d");
const input = @import("input");
const input_sdl3 = @import("input_sdl3");
const ui_core = @import("ui_core");
const camera = @import("camera");
const render_3d = @import("render_3d");
const gizmos = @import("gizmos");
const shapes = @import("shapes");
const dev_tools = @import("dev_tools");
const picking = @import("picking");
const document = @import("document");

const LEFT_W: f32 = 220;
const RIGHT_W: f32 = 270;
const HEADER_H: f32 = 52;
const FOOTER_H: f32 = 26;
const ROW_H: f32 = 22;
const LIST_TOP: f32 = HEADER_H + 34;

/// Translation step per key press; Shift uses `COARSE_STEP`.
const FINE_STEP: f32 = 0.25;
const COARSE_STEP: f32 = 1.0;

const white: graphics.Color = .{ .r = 0.95, .g = 0.97, .b = 1.0, .a = 1.0 };
const dim: graphics.Color = .{ .r = 0.62, .g = 0.67, .b = 0.76, .a = 1.0 };
const accent: graphics.Color = .{ .r = 0.45, .g = 0.78, .b = 1.0, .a = 1.0 };
const panel_bg: graphics.Color = .{ .r = 0.09, .g = 0.10, .b = 0.13, .a = 0.92 };
const header_bg: graphics.Color = .{ .r = 0.06, .g = 0.07, .b = 0.09, .a = 0.96 };
const row_selected: graphics.Color = .{ .r = 0.18, .g = 0.36, .b = 0.58, .a = 0.95 };

const EditorState = struct {
    app: *engine.App,
    gfx: *graphics.GraphicsDeviceService,
    rt: graphics.RenderTargetHandle,
    doc: *document.EditorDocument,
    cmds: *std.ArrayList(graphics.DrawCommand),
    cube_ref: render_3d.MeshRef,
    gizmo_mode: gizmos.TransformGizmoMode = .translate,
    next_cube: u32 = 1,
    status: [120]u8 = @splat(0),
    status_len: usize = 0,
    /// Per-frame text storage: draw commands borrow their strings until the frame is presented.
    text: [8192]u8 = undefined,
    text_len: usize = 0,

    fn setStatus(self: *EditorState, comptime format: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.status, format, args) catch self.status[0..0];
        self.status_len = s.len;
    }

    /// Formats into the per-frame buffer. Returns "..." when the buffer is full.
    fn fmt(self: *EditorState, comptime f: []const u8, args: anytype) []const u8 {
        const rest = self.text[self.text_len..];
        const s = std.fmt.bufPrint(rest, f, args) catch return "...";
        self.text_len += s.len;
        return s;
    }
};

fn windowSize(app: *engine.App) struct { w: f32, h: f32 } {
    if (window_sdl3.pixelSize(app)) |px| {
        const scale = if (px.dpi_scale > 0) px.dpi_scale else 1.0;
        return .{ .w = @as(f32, @floatFromInt(px.width)) / scale, .h = @as(f32, @floatFromInt(px.height)) / scale };
    }
    return .{ .w = 1280, .h = 720 };
}

fn overUi(pos: [2]f32, win: anytype) bool {
    return pos[0] < LEFT_W or pos[0] > win.w - RIGHT_W or pos[1] < HEADER_H or pos[1] > win.h - FOOTER_H;
}

fn spawnEntity(world: *engine.World, ref: render_3d.MeshRef, pos: [3]f32, half_ext: [3]f32) !engine.EntityHandle {
    const e = try world.spawn();
    errdefer _ = world.despawn(e) catch {};
    try world.set(e, render_3d.Transform3D, .{ .position = pos });
    try world.set(e, render_3d.MeshRef, ref);
    try world.set(e, picking.Pickable3D, .{ .half_extents = half_ext });
    return e;
}

fn updateEditor(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(EditorState) orelse return;
    const keys = ctx.resources.get(input.KeyInput) orelse return;
    const mouse = ctx.resources.get(input.MouseInput) orelse return;
    const motion = ctx.resources.get(input.AccumulatedMouseMotion) orelse return;
    const giz = ctx.resources.get(gizmos.GizmoService) orelse return;
    const pick = ctx.resources.get(picking.PickingService) orelse return;
    const focus = ctx.resources.get(picking.InputFocus) orelse return;
    const doc = st.doc;
    const win = windowSize(st.app);

    // Hierarchy row click.
    const pos = motion.position;
    const click = mouse.justPressed(.left);
    if (click and pos[0] < LEFT_W and pos[1] >= LIST_TOP) {
        const row: usize = @intFromFloat((pos[1] - LIST_TOP) / ROW_H);
        if (row < doc.entries.items.len) doc.select(doc.entries.items[row].entity);
    }

    // Viewport picking. Clicks on panels must not pick through them.
    var pick_pos = pos;
    if (window_sdl3.pixelSize(st.app)) |px| {
        pick_pos[0] *= px.dpi_scale;
        pick_pos[1] *= px.dpi_scale;
    }
    const in_viewport = !overUi(pos, win);
    _ = try pick.updatePointer(
        ctx.world,
        ctx.resources,
        ctx.events,
        pick_pos,
        motion.delta,
        mouse.pressed(.left) and in_viewport,
        click and in_viewport,
        mouse.justReleased(.left) and in_viewport,
    );
    if (click and in_viewport) doc.select(focus.focused_entity);
    focus.setFocus(doc.selected);

    const ctrl = keys.pressed(.control_left) or keys.pressed(.control_right);
    const shift = keys.pressed(.shift_left) or keys.pressed(.shift_right);

    // Undo / redo.
    if (ctrl and keys.justPressed(.key_z) and !shift) {
        st.setStatus("{s}", .{if (try doc.undo(ctx.world)) "Undo" else "Nothing to undo"});
    } else if (ctrl and (keys.justPressed(.key_y) or (shift and keys.justPressed(.key_z)))) {
        st.setStatus("{s}", .{if (try doc.redo(ctx.world)) "Redo" else "Nothing to redo"});
    }

    // Selection shortcuts.
    if (keys.justPressed(.tab)) {
        st.gizmo_mode = switch (st.gizmo_mode) {
            .translate => .rotate,
            .rotate => .scale,
            .scale => .translate,
        };
    }
    if (keys.justPressed(.escape)) doc.select(null);
    if (!ctrl and keys.justPressed(.key_j)) doc.selectRelative(1);
    if (!ctrl and keys.justPressed(.key_k)) doc.selectRelative(-1);

    // Add a cube next to the previous one.
    if (!ctrl and keys.justPressed(.key_n)) {
        const n = st.next_cube;
        st.next_cube += 1;
        const e = try spawnEntity(ctx.world, st.cube_ref, .{ -6.0 + 1.4 * @as(f32, @floatFromInt(n % 9)), 0.55, 3.0 - 1.4 * @as(f32, @floatFromInt(n / 9)) }, .{ 0.55, 0.55, 0.55 });
        var buf: [MAX_NAME]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "Cube {d}", .{n}) catch "Cube";
        doc.register(e, name) catch |err| {
            _ = ctx.world.despawn(e) catch {};
            return err;
        };
        doc.select(e);
        st.setStatus("Added {s}", .{name});
    }

    // Delete the selection. Not undoable in the MVP.
    if (keys.justPressed(.delete)) {
        if (doc.selected) |sel| {
            _ = doc.unregister(sel);
            _ = try ctx.world.despawn(sel);
            focus.setFocus(null);
            st.setStatus("Deleted (cannot be undone)", .{});
        }
    }

    // Move / scale the selection.
    if (doc.selected) |sel| {
        if (ctx.world.get(sel, render_3d.Transform3D)) |tf| {
            const step: f32 = if (shift) COARSE_STEP else FINE_STEP;
            var next = tf.*;
            var changed = false;
            if (keys.justPressed(.arrow_left)) {
                next.position[0] -= step;
                changed = true;
            }
            if (keys.justPressed(.arrow_right)) {
                next.position[0] += step;
                changed = true;
            }
            if (keys.justPressed(.arrow_up)) {
                next.position[2] -= step;
                changed = true;
            }
            if (keys.justPressed(.arrow_down)) {
                next.position[2] += step;
                changed = true;
            }
            if (keys.justPressed(.page_up)) {
                next.position[1] += step;
                changed = true;
            }
            if (keys.justPressed(.page_down)) {
                next.position[1] -= step;
                changed = true;
            }
            if (!ctrl and keys.justPressed(.key_r)) {
                for (&next.scale) |*s| s.* *= 1.1;
                changed = true;
            }
            if (!ctrl and keys.justPressed(.key_f)) {
                for (&next.scale) |*s| s.* = @max(0.05, s.* / 1.1);
                changed = true;
            }
            if (changed) try doc.setTransform(ctx.world, sel, next);
        }
    }

    // Studio grid, hover highlight and the selection gizmo.
    giz.grid(.{ 0, 0.005, 0 }, .{ 24, 24 }, .{ 1.5, 1.5 }, .{ 0.45, 0.48, 0.55, 0.35 });
    if (focus.hovered_entity) |hov| {
        if (ctx.world.get(hov, render_3d.Transform3D)) |tf| {
            giz.cuboid(tf.position, .{ tf.scale[0] + 0.12, tf.scale[1] + 0.12, tf.scale[2] + 0.12 }, .{ 1.0, 0.9, 0.25, 0.9 });
        }
    }
    if (doc.selected) |sel| {
        if (ctx.world.get(sel, render_3d.Transform3D)) |tf| {
            giz.transformGizmo(tf.position, st.gizmo_mode, 1.35, 0);
        }
    }
}

const MAX_NAME = document.MAX_NAME_LEN;

fn text(st: *EditorState, x: f32, y: f32, content: []const u8, color: graphics.Color) !void {
    try st.cmds.append(st.app.allocator, .{ .text = .{ .x = x, .y = y, .content = content, .color = color } });
}

fn renderOverlay(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(EditorState) orelse return;
    const cam_svc = ctx.resources.get(camera.CameraService) orelse return;
    const prof = ctx.resources.get(dev_tools.FrameProfilerService) orelse return;
    const px = window_sdl3.pixelSize(st.app);
    cam_svc.setPrimaryTargetSize(if (px) |p| p.width else 1280, if (px) |p| p.height else 720);

    const win = windowSize(st.app);
    const doc = st.doc;
    st.cmds.clearRetainingCapacity();
    st.text_len = 0;

    // Header.
    try st.cmds.append(st.app.allocator, .{ .rect = .{ .x = 0, .y = 0, .width = win.w, .height = HEADER_H, .color = header_bg } });
    try text(st, 16, 8, "Zengy Editor", accent);
    try text(st, 16, 28, "[Click] select  [Arrows/PgUp/PgDn] move (Shift=coarse)  [R/F] scale  [N] add  [Del] delete  [Tab] gizmo  [Ctrl+Z/Y] undo/redo", dim);

    // Hierarchy panel.
    try st.cmds.append(st.app.allocator, .{ .rect = .{ .x = 0, .y = HEADER_H, .width = LEFT_W, .height = win.h - HEADER_H - FOOTER_H, .color = panel_bg } });
    try text(st, 12, HEADER_H + 8, st.fmt("Hierarchy ({d})", .{doc.entries.items.len}), accent);
    for (doc.entries.items, 0..) |*entry, i| {
        const y = LIST_TOP + ROW_H * @as(f32, @floatFromInt(i));
        if (y + ROW_H > win.h - FOOTER_H) break;
        const is_sel = if (doc.selected) |s| document.sameEntity(s, entry.entity) else false;
        if (is_sel) try st.cmds.append(st.app.allocator, .{ .rect = .{ .x = 4, .y = y, .width = LEFT_W - 8, .height = ROW_H - 2, .color = row_selected } });
        try text(st, 14, y + 3, entry.name(), if (is_sel) white else dim);
    }

    // Inspector panel.
    const rx = win.w - RIGHT_W;
    try st.cmds.append(st.app.allocator, .{ .rect = .{ .x = rx, .y = HEADER_H, .width = RIGHT_W, .height = win.h - HEADER_H - FOOTER_H, .color = panel_bg } });
    try text(st, rx + 12, HEADER_H + 8, "Inspector", accent);
    if (doc.selectedEntry()) |entry| {
        try text(st, rx + 12, LIST_TOP, entry.name(), white);
        if (ctx.world.get(entry.entity, render_3d.Transform3D)) |tf| {
            try text(st, rx + 12, LIST_TOP + 30, "Position", dim);
            try text(st, rx + 12, LIST_TOP + 50, st.fmt("x {d:.2}   y {d:.2}   z {d:.2}", .{ tf.position[0], tf.position[1], tf.position[2] }), white);
            try text(st, rx + 12, LIST_TOP + 80, "Scale", dim);
            try text(st, rx + 12, LIST_TOP + 100, st.fmt("x {d:.2}   y {d:.2}   z {d:.2}", .{ tf.scale[0], tf.scale[1], tf.scale[2] }), white);
        }
        try text(st, rx + 12, LIST_TOP + 140, st.fmt("History: {d} undo / {d} redo", .{ doc.undo_stack.items.len, doc.redo_stack.items.len }), dim);
        try text(st, rx + 12, LIST_TOP + 160, st.fmt("Gizmo: {s}", .{@tagName(st.gizmo_mode)}), dim);
    } else {
        try text(st, rx + 12, LIST_TOP, "Nothing selected", dim);
    }

    // Footer: status and frame time.
    try st.cmds.append(st.app.allocator, .{ .rect = .{ .x = 0, .y = win.h - FOOTER_H, .width = win.w, .height = FOOTER_H, .color = header_bg } });
    try text(st, 12, win.h - FOOTER_H + 5, st.status[0..st.status_len], white);
    try text(st, win.w - RIGHT_W + 12, win.h - FOOTER_H + 5, st.fmt("{d:.0} FPS ({d:.2} ms)", .{ prof.fps(), prof.totalFrameMs() }), dim);

    try st.gfx.beginFrame(st.rt);
    try st.gfx.submitDrawCommands(st.rt, st.cmds.items);
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
    try app.registerModule(ui_core.module());
    try app.registerModule(camera.module());
    try app.registerModule(render_3d.module());
    try app.registerModule(gizmos.module());
    try app.registerModule(shapes.module());
    try app.registerModule(dev_tools.module());
    try app.registerModule(picking.module());

    try app.resources.insert(window_sdl3.WindowConfig, .{
        .title = "Zengy Editor",
        .width = 1440,
        .height = 810,
        .resizable = true,
    });
    try app.resources.insert(wgpu.GpuConfig, .{
        .default_clear_color = .{ .r = 0.12, .g = 0.13, .b = 0.16, .a = 1.0 },
    });

    try app.addSystem(.{ .name = "editor.update", .stage = .update, .run = updateEditor });
    try app.addSystem(.{ .name = "editor.overlay", .stage = .render_extract, .run = renderOverlay });

    try app.initialize();
    if (app.resources.get(gizmos.GizmoService)) |giz| {
        giz.config.line.width = 2.0;
        giz.config.xray_alpha = 0.95;
    }

    const g_entry = try app.services.getService("engine.graphics.device", 1);
    const gfx: *graphics.GraphicsDeviceService = @ptrCast(@alignCast(@constCast(g_entry.api_ptr)));
    const mats = app.resources.get(render_3d.pbr.MaterialRegistry).?;

    var doc = document.EditorDocument.init(allocator);
    defer doc.deinit();
    var cmds: std.ArrayList(graphics.DrawCommand) = .empty;
    defer cmds.deinit(allocator);

    // Floor (not listed in the hierarchy, not pickable).
    var plane_m = try (shapes.Plane{ .size = .{ 24.0, 16.0 }, .subdivisions = .{ 4, 4 } }).mesh(allocator);
    defer plane_m.deinit();
    const floor_gpu = try gpu_3d.createMesh3D(&app, std.mem.sliceAsBytes(plane_m.vertices), plane_m.indices);
    const floor_mat = try mats.add(.{ .base_color = .{ 0.18, 0.20, 0.24, 1.0 }, .roughness = 0.85 });
    const floor_e = try app.world.spawn();
    try app.world.set(floor_e, render_3d.Transform3D, .{});
    try app.world.set(floor_e, render_3d.MeshRef, .{ .mesh_asset = @bitCast(floor_gpu), .material_handle = floor_mat });

    // Starter scene.
    var cuboid_m = try (shapes.Cuboid{ .size = .{ 1.1, 1.1, 1.1 } }).mesh(allocator);
    defer cuboid_m.deinit();
    var sphere_m = try (shapes.Sphere{ .radius = 0.65, .rings = 20, .sectors = 32 }).mesh(allocator);
    defer sphere_m.deinit();
    var cyl_m = try (shapes.Cylinder{ .radius = 0.5, .height = 1.2, .radial_segments = 28 }).mesh(allocator);
    defer cyl_m.deinit();
    var torus_m = try (shapes.Torus{ .major_radius = 0.58, .minor_radius = 0.22, .major_segments = 32, .minor_segments = 16 }).mesh(allocator);
    defer torus_m.deinit();

    const cube_gpu = try gpu_3d.createMesh3D(&app, std.mem.sliceAsBytes(cuboid_m.vertices), cuboid_m.indices);
    const cube_mat = try mats.add(.{ .base_color = .{ 0.85, 0.35, 0.25, 1.0 }, .roughness = 0.45 });
    const cube_ref: render_3d.MeshRef = .{ .mesh_asset = @bitCast(cube_gpu), .material_handle = cube_mat };

    const Starter = struct { name: []const u8, mesh: *shapes.ShapeMesh, pos: [3]f32, half: [3]f32, base: [4]f32, metallic: f32 };
    const starters = [_]Starter{
        .{ .name = "Cube", .mesh = &cuboid_m, .pos = .{ -3, 0.55, 0 }, .half = .{ 0.55, 0.55, 0.55 }, .base = .{ 0.85, 0.35, 0.25, 1 }, .metallic = 0.0 },
        .{ .name = "Sphere", .mesh = &sphere_m, .pos = .{ -1, 0.65, 0 }, .half = .{ 0.65, 0.65, 0.65 }, .base = .{ 0.95, 0.78, 0.28, 1 }, .metallic = 0.9 },
        .{ .name = "Cylinder", .mesh = &cyl_m, .pos = .{ 1, 0.6, 0 }, .half = .{ 0.5, 0.6, 0.5 }, .base = .{ 0.28, 0.52, 0.92, 1 }, .metallic = 0.0 },
        .{ .name = "Torus", .mesh = &torus_m, .pos = .{ 3, 0.55, 0 }, .half = .{ 0.8, 0.25, 0.8 }, .base = .{ 0.85, 0.5, 0.3, 1 }, .metallic = 0.85 },
    };
    var first: ?engine.EntityHandle = null;
    for (starters) |s| {
        const gpu_mesh = try gpu_3d.createMesh3D(&app, std.mem.sliceAsBytes(s.mesh.vertices), s.mesh.indices);
        const mat = try mats.add(.{ .base_color = s.base, .roughness = 0.4, .metallic = s.metallic });
        const e = try spawnEntity(&app.world, .{ .mesh_asset = @bitCast(gpu_mesh), .material_handle = mat }, s.pos, s.half);
        try doc.register(e, s.name);
        if (first == null) first = e;
    }
    doc.select(first);

    const sun_e = try app.world.spawn();
    try app.world.set(sun_e, render_3d.pbr.DirectionalLight, .{
        .color = .{ 1.0, 0.96, 0.90 },
        .illuminance_lux = 22000.0,
        .direction = .{ -0.45, -0.8, -0.35 },
    });

    const cam_e = try app.world.spawn();
    try app.world.set(cam_e, camera.Camera, .{ .order = 0 });
    try app.world.set(cam_e, camera.Projection, .{ .perspective = .{ .fov_rad = std.math.pi / 3.0, .near = 0.2, .far = 150.0 } });
    try app.world.set(cam_e, camera.CameraPose, camera.CameraPose.lookAt(.{ 0, 3.8, 9.5 }, .{ 0, 0.7, 0 }, .{ 0, 1, 0 }));
    try app.world.set(cam_e, camera.FreeCamera, .{ .walk_speed = 7.0, .run_speed = 14.0 });
    try app.world.set(cam_e, camera.FreeCameraState, .{});
    try app.world.set(cam_e, render_3d.pbr.PostProcessSettings, .{ .ssao = .{ .enabled = true }, .bloom = .{ .enabled = true } });

    const px = window_sdl3.pixelSize(&app);
    const rt = try gfx.createSurface(1, if (px) |p| p.width else 1440, if (px) |p| p.height else 810);
    try app.resources.insert(EditorState, .{
        .app = &app,
        .gfx = gfx,
        .rt = rt,
        .doc = &doc,
        .cmds = &cmds,
        .cube_ref = cube_ref,
    });
    if (app.resources.get(EditorState)) |st| st.setStatus("Ready", .{});

    try window_sdl3.runVisualLoop(&app);
}
