//! Visual Shapes, Picking, Profiler & Remote Inspector Showcase (`apps/editor/examples/visual-inspector/main.zig`).
//!
//! Combines `official.shapes`, `official.picking`, `official.gizmos`,
//! `official.dev_tools`, `app.editor.shell`, and `official.remote`:
//! - Procedural PBR shapes (`Plane`, `Cuboid`, `Sphere`, `Capsule`, `Cylinder`, `Torus`, `Cone`)
//! - 3D raycast picking + `InputFocus` selection + `GizmoService` highlight
//! - Live per-pass profiler HUD (`Shadow`, `SSAO`, `Forward+`, `Volumetric`, `Bloom`, `PostFX`)
//! - Live `RemoteInspectorService` JSON-RPC query on the focused entity
//!
//! Controls:
//! - Left-Click on any shape: Select & focus entity (`Pickable3D` + `InputFocus`)
//! - Tab: Cycle transform gizmo mode (`.translate`, `.rotate`, `.scale`)
//! - 1 / 2 / 3: Toggle SSAO / Volumetric Fog / Bloom passes
//! - R: Query `RemoteInspectorService` (`zengy/get_entity`) for focused entity
//! - W/A/S/D (+Shift sprint, Q/E down/up) + Right-Click Drag: Fly FreeCamera
//!
//! Run with: `zig build run-visual-inspector`

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
const editor_shell = @import("editor_shell");
const picking = @import("picking");
const remote = @import("remote");
const remote_adapter = @import("remote_adapter");

const InspectorState = struct {
    app: *engine.App,
    gfx: *graphics.GraphicsDeviceService,
    rt: graphics.RenderTargetHandle,
    cam_entity: engine.EntityHandle,
    hud_line1: [240]u8 = @splat(0),
    hud_line1_len: usize = 0,
    hud_line2: [240]u8 = @splat(0),
    hud_line2_len: usize = 0,
    hud_line3: [240]u8 = @splat(0),
    hud_line3_len: usize = 0,
    gizmo_mode: gizmos.TransformGizmoMode = .translate,
    remote_preview: [140]u8 = @splat(0),
    remote_preview_len: usize = 0,
};

fn queryFocusedRemote(st: *InspectorState, focus: *const picking.InputFocus, rem: *remote.RemoteInspectorService) void {
    const ent = focus.focused_entity orelse {
        const msg = "Focused: none (Left-click a shape)";
        @memcpy(st.remote_preview[0..msg.len], msg);
        st.remote_preview_len = msg.len;
        return;
    };
    var req_buf: [160]u8 = undefined;
    const req = std.fmt.bufPrint(
        &req_buf,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"zengy/get_entity\",\"params\":{{\"index\":{d},\"generation\":{d}}}}}",
        .{ ent.index, ent.generation },
    ) catch return;
    const res = rem.handleRequest(st.app, req, st.app.allocator) catch return;
    defer st.app.allocator.free(res);
    const n = @min(res.len, st.remote_preview.len);
    @memcpy(st.remote_preview[0..n], res[0..n]);
    st.remote_preview_len = n;
}

fn updateInspector(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(InspectorState) orelse return;
    const keys = ctx.resources.get(input.KeyInput) orelse return;
    const mouse = ctx.resources.get(input.MouseInput) orelse return;
    const motion = ctx.resources.get(input.AccumulatedMouseMotion) orelse return;
    const giz = ctx.resources.get(gizmos.GizmoService) orelse return;
    const prof = ctx.resources.get(dev_tools.FrameProfilerService) orelse return;
    const pick = ctx.resources.get(picking.PickingService) orelse return;
    const focus = ctx.resources.get(picking.InputFocus) orelse return;
    const rem = ctx.resources.get(remote.RemoteInspectorService) orelse return;

    if (keys.justPressed(.tab)) {
        st.gizmo_mode = switch (st.gizmo_mode) {
            .translate => .rotate,
            .rotate => .scale,
            .scale => .translate,
        };
    }
    if (keys.justPressed(.digit_1)) {
        if (ctx.world.get(st.cam_entity, render_3d.pbr.PostProcessSettings)) |pp| pp.ssao.enabled = !pp.ssao.enabled;
    }
    if (keys.justPressed(.digit_2)) {
        if (ctx.world.get(st.cam_entity, render_3d.pbr.FogSettings)) |fg| fg.volumetric.enabled = !fg.volumetric.enabled;
    }
    if (keys.justPressed(.digit_3)) {
        if (ctx.world.get(st.cam_entity, render_3d.pbr.PostProcessSettings)) |pp| pp.bloom.enabled = !pp.bloom.enabled;
    }

    // DPI-aware picking update so HiDPI screens match camera viewport coordinates.
    var pick_pos = motion.position;
    if (window_sdl3.pixelSize(st.app)) |px| {
        pick_pos[0] *= px.dpi_scale;
        pick_pos[1] *= px.dpi_scale;
    }
    _ = try pick.updatePointer(
        ctx.world,
        ctx.resources,
        ctx.events,
        pick_pos,
        motion.delta,
        mouse.pressed(.left),
        mouse.justPressed(.left),
        mouse.justReleased(.left),
    );

    if (keys.justPressed(.key_r) or mouse.justPressed(.left)) {
        queryFocusedRemote(st, focus, rem);
    }

    // Draw subtle studio grid + highlight hovered/focused shape with gizmos.
    giz.grid(.{ 0, 0.005, 0 }, .{ 24, 24 }, .{ 1.5, 1.5 }, .{ 0.45, 0.48, 0.55, 0.35 });
    if (focus.hovered_entity) |hov| {
        if (ctx.world.get(hov, render_3d.Transform3D)) |tf| {
            giz.cuboid(tf.position, .{ tf.scale[0] + 0.12, tf.scale[1] + 0.12, tf.scale[2] + 0.12 }, .{ 1.0, 0.9, 0.25, 0.9 });
        }
    }
    if (focus.focused_entity) |foc| {
        if (ctx.world.get(foc, render_3d.Transform3D)) |tf| {
            giz.transformGizmo(tf.position, st.gizmo_mode, 1.35, 0);
        }
    }

    const l1 = std.fmt.bufPrint(
        &st.hud_line1,
        "FPS:{d:.0} ({d:.2}ms) | Shadow:{d:.2}ms SSAO:{d:.2}ms Fwd+:{d:.2}ms Vol:{d:.2}ms Bloom:{d:.2}ms PostFX:{d:.2}ms",
        .{
            prof.fps(),
            prof.totalFrameMs(),
            prof.passMs(.shadow),
            prof.passMs(.ssao),
            prof.passMs(.forward_plus),
            prof.passMs(.volumetric),
            prof.passMs(.bloom),
            prof.passMs(.postfx),
        },
    ) catch "Profiler";
    st.hud_line1_len = l1.len;

    const l2 = std.fmt.bufPrint(
        &st.hud_line2,
        "[LClick]Pick [Tab]Gizmo:{s} [1]SSAO [2]Volumetric [3]Bloom [R]RemoteInspect",
        .{@tagName(st.gizmo_mode)},
    ) catch "Controls";
    st.hud_line2_len = l2.len;

    const l3 = std.fmt.bufPrint(&st.hud_line3, "Remote: {s}", .{st.remote_preview[0..st.remote_preview_len]}) catch "Remote";
    st.hud_line3_len = l3.len;
}

fn renderOverlay(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(InspectorState) orelse return;
    const cam_svc = ctx.resources.get(camera.CameraService) orelse return;
    const px = window_sdl3.pixelSize(st.app);
    cam_svc.setPrimaryTargetSize(if (px) |p| p.width else 1280, if (px) |p| p.height else 720);

    try st.gfx.beginFrame(st.rt);
    try st.gfx.submitDrawCommands(st.rt, &.{
        .{ .text = .{ .x = 16, .y = 16, .content = st.hud_line1[0..st.hud_line1_len], .color = .{ .r = 0.55, .g = 0.95, .b = 0.70, .a = 1.0 } } },
        .{ .text = .{ .x = 16, .y = 38, .content = st.hud_line2[0..st.hud_line2_len], .color = .{ .r = 0.95, .g = 0.97, .b = 1.0, .a = 1.0 } } },
        .{ .text = .{ .x = 16, .y = 60, .content = st.hud_line3[0..st.remote_preview_len + 8], .color = .{ .r = 0.85, .g = 0.90, .b = 1.0, .a = 0.95 } } },
    });
    _ = try st.gfx.present(st.rt);
}

fn spawnShape(
    app: *engine.App,
    allocator: std.mem.Allocator,
    shape_mesh: *shapes.ShapeMesh,
    pos: [3]f32,
    mat: render_3d.pbr.MaterialHandle,
    half_ext: [3]f32,
    schema: engine.reflection.ComponentSchema,
    kind_id: u32,
) !engine.EntityHandle {
    const gpu_mesh = try gpu_3d.createMesh3D(app, std.mem.sliceAsBytes(shape_mesh.vertices), shape_mesh.indices);
    const e = try app.world.spawn();
    try app.world.set(e, render_3d.Transform3D, .{ .position = pos });
    try app.world.set(e, render_3d.MeshRef, .{ .mesh_asset = @bitCast(gpu_mesh), .material_handle = mat });
    try app.world.set(e, picking.Pickable3D, .{ .half_extents = half_ext });

    const bytes = try allocator.alloc(u8, schema.byte_size);
    defer allocator.free(bytes);
    @memset(bytes, 0);
    try engine.TypeRegistry.setField(schema, bytes, "kind_id", .{ .u32_t = kind_id });
    try engine.TypeRegistry.setField(schema, bytes, "pos_y", .{ .f32_t = pos[1] });
    try app.world.setRaw(e, schema.component_type_id, bytes);
    return e;
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
    try app.registerModule(editor_shell.module());
    try app.registerModule(picking.module());
    try app.registerModule(remote.module());

    try app.resources.insert(window_sdl3.WindowConfig, .{
        .title = "Zengy — Shapes, Picking, Profiler & Remote Inspector",
        .width = 1280,
        .height = 720,
        .resizable = true,
    });
    try app.resources.insert(wgpu.GpuConfig, .{
        .default_clear_color = .{ .r = 0.12, .g = 0.13, .b = 0.16, .a = 1.0 },
    });

    try app.addSystem(.{ .name = "inspector.update", .stage = .update, .run = updateInspector });
    try app.addSystem(.{ .name = "inspector.overlay", .stage = .render_extract, .run = renderOverlay });

    try app.initialize();
    // Route remote edits through the editor shell history and expose its panels.
    try remote_adapter.attach(&app);
    if (app.resources.get(gizmos.GizmoService)) |giz| {
        giz.config.line.width = 2.0;
        giz.config.xray_alpha = 0.95;
    }

    const g_entry = try app.services.getService("engine.graphics.device", 1);
    const gfx: *graphics.GraphicsDeviceService = @ptrCast(@alignCast(@constCast(g_entry.api_ptr)));
    const mats = app.resources.get(render_3d.pbr.MaterialRegistry).?;

    // Reflected schema so RemoteInspectorService can inspect every shape live.
    const schema = try app.types.registerSchema("demo", "ShapeInfo", 1, .blittable, &.{
        .{ .name = "kind_id", .field_type = .u32_t },
        .{ .name = "pos_y", .field_type = .f32_t },
    });
    _ = try app.world.registerDynamicComponent("demo.ShapeInfo", schema.byte_size);

    // 1. Procedural Plane floor
    var plane_m = try (shapes.Plane{ .size = .{ 20.0, 14.0 }, .subdivisions = .{ 4, 4 } }).mesh(allocator);
    defer plane_m.deinit();
    const floor_gpu = try gpu_3d.createMesh3D(&app, std.mem.sliceAsBytes(plane_m.vertices), plane_m.indices);
    const floor_mat = try mats.add(.{ .base_color = .{ 0.18, 0.20, 0.24, 1.0 }, .roughness = 0.85 });
    const floor_e = try app.world.spawn();
    try app.world.set(floor_e, render_3d.Transform3D, .{ .position = .{ 0, 0, 0 } });
    try app.world.set(floor_e, render_3d.MeshRef, .{ .mesh_asset = @bitCast(floor_gpu), .material_handle = floor_mat });

    // 2. All 6 standing procedural shapes
    var cuboid_m = try (shapes.Cuboid{ .size = .{ 1.1, 1.1, 1.1 } }).mesh(allocator);
    defer cuboid_m.deinit();
    var sphere_m = try (shapes.Sphere{ .radius = 0.65, .rings = 20, .sectors = 32 }).mesh(allocator);
    defer sphere_m.deinit();
    var capsule_m = try (shapes.Capsule{ .radius = 0.38, .half_length = 0.45, .rings = 10, .sectors = 24 }).mesh(allocator);
    defer capsule_m.deinit();
    var cyl_m = try (shapes.Cylinder{ .radius = 0.5, .height = 1.2, .radial_segments = 28 }).mesh(allocator);
    defer cyl_m.deinit();
    var torus_m = try (shapes.Torus{ .major_radius = 0.58, .minor_radius = 0.22, .major_segments = 32, .minor_segments = 16 }).mesh(allocator);
    defer torus_m.deinit();
    var cone_m = try (shapes.Cone{ .radius = 0.58, .height = 1.25, .radial_segments = 28 }).mesh(allocator);
    defer cone_m.deinit();

    const first_e = try spawnShape(&app, allocator, &cuboid_m, .{ -5.0, 0.55, 0 }, try mats.add(.{ .base_color = .{ 0.85, 0.35, 0.25, 1.0 }, .roughness = 0.45 }), .{ 0.55, 0.55, 0.55 }, schema, 1);
    _ = try spawnShape(&app, allocator, &sphere_m, .{ -3.0, 0.65, 0 }, try mats.add(.{ .base_color = .{ 0.95, 0.78, 0.28, 1.0 }, .roughness = 0.2, .metallic = 0.9 }), .{ 0.65, 0.65, 0.65 }, schema, 2);
    _ = try spawnShape(&app, allocator, &capsule_m, .{ -1.0, 0.83, 0 }, try mats.add(.{ .base_color = .{ 0.22, 0.78, 0.72, 1.0 }, .roughness = 0.35 }), .{ 0.4, 0.85, 0.4 }, schema, 3);
    _ = try spawnShape(&app, allocator, &cyl_m, .{ 1.0, 0.60, 0 }, try mats.add(.{ .base_color = .{ 0.28, 0.52, 0.92, 1.0 }, .roughness = 0.4 }), .{ 0.5, 0.6, 0.5 }, schema, 4);
    _ = try spawnShape(&app, allocator, &torus_m, .{ 3.0, 0.55, 0 }, try mats.add(.{ .base_color = .{ 0.85, 0.50, 0.30, 1.0 }, .roughness = 0.25, .metallic = 0.85 }), .{ 0.8, 0.25, 0.8 }, schema, 5);
    _ = try spawnShape(&app, allocator, &cone_m, .{ 5.0, 0.625, 0 }, try mats.add(.{ .base_color = .{ 0.28, 0.82, 0.40, 1.0 }, .roughness = 0.5 }), .{ 0.58, 0.625, 0.58 }, schema, 6);

    if (app.resources.get(picking.InputFocus)) |focus| {
        focus.setFocus(first_e);
    }

    const sun_e = try app.world.spawn();
    try app.world.set(sun_e, render_3d.pbr.DirectionalLight, .{
        .color = .{ 1.0, 0.96, 0.90 },
        .illuminance_lux = 22000.0,
        .direction = .{ -0.45, -0.8, -0.35 },
    });

    const cam_e = try app.world.spawn();
    try app.world.set(cam_e, camera.Camera, .{ .order = 0 });
    try app.world.set(cam_e, camera.Projection, .{ .perspective = .{ .fov_rad = std.math.pi / 3.0, .near = 0.2, .far = 150.0 } });
    try app.world.set(cam_e, camera.CameraPose, camera.CameraPose.lookAt(.{ 0, 3.6, 8.8 }, .{ 0, 0.7, 0 }, .{ 0, 1, 0 }));
    try app.world.set(cam_e, camera.FreeCamera, .{ .walk_speed = 7.0, .run_speed = 14.0 });
    try app.world.set(cam_e, camera.FreeCameraState, .{});
    try app.world.set(cam_e, render_3d.pbr.PostProcessSettings, .{
        .ssao = .{ .enabled = true },
        .bloom = .{ .enabled = true },
    });
    try app.world.set(cam_e, render_3d.pbr.FogSettings, .{
        .enabled = true,
        .density = 0.008,
        .volumetric = .{ .enabled = true },
    });

    const px = window_sdl3.pixelSize(&app);
    const rt = try gfx.createSurface(1, if (px) |p| p.width else 1280, if (px) |p| p.height else 720);
    try app.resources.insert(InspectorState, .{
        .app = &app,
        .gfx = gfx,
        .rt = rt,
        .cam_entity = cam_e,
    });
    if (app.resources.get(InspectorState)) |st| {
        const focus = app.resources.get(picking.InputFocus).?;
        const rem = app.resources.get(remote.RemoteInspectorService).?;
        queryFocusedRemote(st, focus, rem);
    }

    try window_sdl3.runVisualLoop(&app);
}
