//! Integrated Engine Playground (`examples/playground/main.zig`).
//!
//! End-to-end sandbox composing the minimal headless core with optional packages:
//! - `official.window` & `official.graphics` (surface, input, draw commands, present)
//! - `official.ui.core` + `official.ui.markup` (retained UI IR)
//! - `official.script.host` (runtime bridge + isolated event posting)
//! - `official.assets` (importer priority + caching)
//! - `official.scene` (2D transform hierarchy + snapshot)
//! - `app.editor.shell` (panel registry + schema inspector + undo/redo)
//! - `official.render.3d` (3D camera + mesh extraction)
//! - Dynamic C11 plugin (`zig-out/lib/libc_plugin.so`) via `PluginHost`
//!
//! Run with: `zig build run-playground`

const std = @import("std");
const engine = @import("engine");
const window = @import("window");
const graphics = @import("graphics");
const ui_core = @import("ui_core");
const ui_markup = @import("ui_markup");
const scripting_host = @import("scripting_host");
const assets = @import("assets");
const scene = @import("scene");
const editor_shell = @import("editor_shell");
const camera = @import("camera");
const render_3d = @import("render_3d");

fn playgroundTextImporter(allocator: std.mem.Allocator, _: []const u8, raw: []const u8) !assets.AssetArtifact {
    return .{
        .kind = try allocator.dupe(u8, "text/plain"),
        .bytes = try allocator.dupe(u8, raw),
    };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        const leak_status = gpa.deinit();
        if (leak_status == .leak) {
            std.debug.print("[playground] WARNING: memory leak detected!\n", .{});
        }
    }
    const allocator = gpa.allocator();

    var app = engine.App.init(allocator, .{
        .fixed_dt = 1.0 / 60.0,
        .max_frames = 3,
    });
    defer app.deinit();

    // 1. Register optional modules in arbitrary order (ModuleRegistry resolves topologically).
    try app.registerModule(camera.module());
    try app.registerModule(render_3d.module());
    try app.registerModule(editor_shell.module());
    try app.registerModule(ui_core.module());
    try app.registerModule(graphics.module());
    try app.registerModule(window.module());
    try app.registerModule(scripting_host.module());
    try app.registerModule(assets.module());
    try app.registerModule(scene.module());

    try app.initialize();

    // 2. Load the compiled C11 shared library plugin via the versioned C ABI.
    const plugin_path = switch (@import("builtin").os.tag) {
        .windows => "zig-out/bin/c_plugin.dll",
        .macos => "zig-out/lib/libc_plugin.dylib",
        else => "zig-out/lib/libc_plugin.so",
    };
    const plugin_host = try app.ensurePluginHost();
    const c_plugin_handle = try plugin_host.loadSharedLibrary(plugin_path);
    _ = plugin_host.startPlugin(c_plugin_handle);

    // 3. Create a window and graphics render target.
    const w_entry = try app.services.getService("engine.window", 1);
    const win: *window.WindowService = @ptrCast(@alignCast(@constCast(w_entry.api_ptr)));
    const g_entry = try app.services.getService("engine.graphics.device", 1);
    const gfx: *graphics.GraphicsDeviceService = @ptrCast(@alignCast(@constCast(g_entry.api_ptr)));

    const wh = try win.createWindow(.{ .title = "Zengy Playground", .width = 1280, .height = 720 });
    const rt = try gfx.createSurface(@bitCast(wh), 1280, 720);

    // 4. Populate UiTree using the HTML-like markup frontend and lay it out.
    const ui_tree = app.resources.get(ui_core.UiTree).?;
    try ui_markup.parseIntoTree(allocator,
        \\<ui-document>
        \\  <panel id="playground.hud">
        \\    <label id="title">Zengy Playground</label>
        \\    <button id="spawn_btn" action="playground.spawn">Spawn Entity</button>
        \\  </panel>
        \\</ui-document>
    , ui_tree);
    ui_tree.layoutTree(1280, 720);

    // 5. Load an asset via AssetService.
    const asset_svc = app.resources.get(assets.AssetService).?;
    try asset_svc.registerImporter(.{
        .id = "playground.txt",
        .extension = ".txt",
        .priority = 100,
        .import_fn = playgroundTextImporter,
    });
    const config_asset = try asset_svc.loadFromBytes("project://welcome.txt", "Hello from Zengy Playground!");

    // 6. Spawn 2D hierarchy + 3D camera & mesh entities.
    const root_2d = try app.world.spawn();
    try app.world.set(root_2d, scene.Transform2D, .{ .x = 100, .y = 200 });
    const child_2d = try app.world.spawn();
    try app.world.set(child_2d, scene.Transform2D, .{ .x = 50, .y = 25 });
    try app.world.set(child_2d, scene.Parent, .{ .entity = root_2d });

    const cam = try app.world.spawn();
    try app.world.set(cam, camera.Camera, .{});
    try app.world.set(cam, camera.Projection, .{ .perspective = .{ .fov_rad = std.math.pi / 3.0 } });
    try app.world.set(cam, camera.CameraPose, .{});
    const cube = try app.world.spawn();
    try app.world.set(cube, render_3d.Transform3D, .{ .position = .{ 0, 1, -5 } });
    try app.world.set(cube, render_3d.MeshRef, .{ .mesh_asset = @bitCast(config_asset), .material_id = 1 });

    // 7. Run 3 frames and render UI draw commands.
    var ui_cmds: std.ArrayList(graphics.DrawCommand) = .empty;
    defer ui_cmds.deinit(allocator);

    for (0..3) |_| {
        try app.tick(1.0 / 60.0);
        try gfx.beginFrame(rt);
        ui_cmds.clearRetainingCapacity();
        try ui_tree.paint(allocator, &ui_cmds);
        try gfx.submitDrawCommands(rt, ui_cmds.items);
        try gfx.present(rt);
    }

    const r3d = app.resources.get(render_3d.Render3DService).?;
    const child_t = app.world.getConst(child_2d, scene.Transform2D).?;
    const shell = app.resources.get(editor_shell.EditorShellService).?;

    std.debug.print(
        "Playground OK:\n" ++
            "  Frames: {d}, Entities: {d}\n" ++
            "  UI nodes (markup): {d}, Presented frames: {d}\n" ++
            "  2D child world pos: ({d:.1}, {d:.1})\n" ++
            "  3D extracted meshes: {d}\n" ++
            "  Editor panels: {d}\n" ++
            "  Asset content: {s}\n" ++
            "  Diagnostics logs: {d}\n",
        .{
            app.diagnostics.frame_count,
            app.world.entity_count,
            ui_tree.nodeCount(),
            gfx.presentedFrames(rt).?,
            child_t.world_x,
            child_t.world_y,
            r3d.drawCount(),
            shell.panelCount(),
            asset_svc.getBytes(config_asset).?,
            app.diagnostics.count(),
        },
    );

    _ = plugin_host.unloadPlugin(c_plugin_handle);
    app.shutdown();
}
