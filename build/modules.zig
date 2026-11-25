//! Module graph: every reusable SDK module, provider and application-local module, wired once.
//! Consumers (`examples.zig`, `tools.zig`, `apps.zig`, `tests.zig`) receive the result as `Modules`.

const std = @import("std");

/// Modules shared by the other build files. Field names match the local names used in `create`.
pub const Modules = struct {
    engine_mod: *std.Build.Module,
    c_abi_mod: *std.Build.Module,
    window_mod: *std.Build.Module,
    graphics_mod: *std.Build.Module,
    ui_core_mod: *std.Build.Module,
    ui_markup_mod: *std.Build.Module,
    ui_widgets_mod: *std.Build.Module,
    ui_plume_mod: *std.Build.Module,
    scripting_host_mod: *std.Build.Module,
    assets_mod: *std.Build.Module,
    scene_mod: *std.Build.Module,
    prefab_mod: *std.Build.Module,
    physics_mod: *std.Build.Module,
    editor_shell_mod: *std.Build.Module,
    toml_format_mod: *std.Build.Module,
    json_format_mod: *std.Build.Module,
    file_watcher_mod: *std.Build.Module,
    testing_sdk_mod: *std.Build.Module,
    scripting_lua_mod: *std.Build.Module,
    scripting_python_mod: *std.Build.Module,
    input_mod: *std.Build.Module,
    input_haptics_mod: *std.Build.Module,
    camera_mod: *std.Build.Module,
    state_mod: *std.Build.Module,
    audio_mod: *std.Build.Module,
    render_3d_mod: *std.Build.Module,
    gizmos_mod: *std.Build.Module,
    shapes_mod: *std.Build.Module,
    dev_tools_mod: *std.Build.Module,
    picking_mod: *std.Build.Module,
    remote_mod: *std.Build.Module,
    log_mod: *std.Build.Module,
    editor_remote_adapter_mod: *std.Build.Module,
    editor_document_mod: *std.Build.Module,
    window_sdl3_mod: *std.Build.Module,
    input_sdl3_mod: *std.Build.Module,
    zaudio_pkg_mod: *std.Build.Module,
    audio_zaudio_mod: *std.Build.Module,
    text_mod: *std.Build.Module,
    render_2d_mod: *std.Build.Module,
    prism_mod: *std.Build.Module,
    helios_mod: *std.Build.Module,
    draw_2d_mod: *std.Build.Module,
    gpu_3d_mod: *std.Build.Module,
    wgpu_gpu_mod: *std.Build.Module,
    graphics_wgpu_mod: *std.Build.Module,
    /// Resolved wgpu-native SDK root (`-Dwgpu-root`, default `.deps/wgpu-native`).
    wgpu_root: []const u8,
    /// Whether `webgpu.h` exists under `wgpu_root` at configure time.
    wgpu_present: bool,
    /// Fail step that steps needing the SDK depend on when it is missing.
    wgpu_missing: ?*std.Build.Step.Fail,
};

/// Declares all modules and external dependency wiring for `target`/`optimize`.
pub fn create(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) Modules {
    // Public Zig SDK module ("engine")
    const engine_mod = b.addModule("engine", .{
        .root_source_file = b.path("src/engine.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Translate C ABI header for layout & compatibility tests
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("include/engine_extension.h"),
        .target = target,
        .optimize = optimize,
    });
    const c_abi_mod = translate_c.createModule();

    // Optional packages (Phases 5-13)
    const window_mod = b.addModule("window", .{
        .root_source_file = b.path("packages/window/core/src/window.zig"),
        .target = target,
        .optimize = optimize,
    });
    window_mod.addImport("engine", engine_mod);

    const graphics_mod = b.addModule("graphics", .{
        .root_source_file = b.path("packages/graphics/core/src/graphics.zig"),
        .target = target,
        .optimize = optimize,
    });
    graphics_mod.addImport("engine", engine_mod);

    const ui_core_mod = b.addModule("ui_core", .{
        .root_source_file = b.path("packages/ui/core/src/ui_core.zig"),
        .target = target,
        .optimize = optimize,
    });
    ui_core_mod.addImport("engine", engine_mod);
    ui_core_mod.addImport("graphics", graphics_mod);

    const ui_markup_mod = b.addModule("ui_markup", .{
        .root_source_file = b.path("packages/ui/markup/src/ui_markup.zig"),
        .target = target,
        .optimize = optimize,
    });
    ui_markup_mod.addImport("ui_core", ui_core_mod);

    const ui_widgets_mod = b.addModule("ui_widgets", .{
        .root_source_file = b.path("packages/ui/widgets/src/ui_widgets.zig"),
        .target = target,
        .optimize = optimize,
    });
    ui_widgets_mod.addImport("engine", engine_mod);
    ui_widgets_mod.addImport("window", window_mod);
    ui_widgets_mod.addImport("graphics", graphics_mod);
    ui_widgets_mod.addImport("ui_core", ui_core_mod);

    const ui_plume_mod = b.addModule("ui_plume", .{
        .root_source_file = b.path("packages/ui/plume/src/ui_plume.zig"),
        .target = target,
        .optimize = optimize,
    });
    ui_plume_mod.addImport("engine", engine_mod);
    ui_plume_mod.addImport("window", window_mod);
    ui_plume_mod.addImport("graphics", graphics_mod);
    ui_plume_mod.addImport("ui_core", ui_core_mod);
    ui_plume_mod.addImport("ui_widgets", ui_widgets_mod);

    const scripting_host_mod = b.addModule("scripting_host", .{
        .root_source_file = b.path("packages/scripting/host/src/scripting_host.zig"),
        .target = target,
        .optimize = optimize,
    });
    scripting_host_mod.addImport("engine", engine_mod);

    const assets_mod = b.addModule("assets", .{
        .root_source_file = b.path("packages/assets/src/assets.zig"),
        .target = target,
        .optimize = optimize,
    });
    assets_mod.addImport("engine", engine_mod);

    const scene_mod = b.addModule("scene", .{
        .root_source_file = b.path("packages/scene/src/scene.zig"),
        .target = target,
        .optimize = optimize,
    });
    scene_mod.addImport("engine", engine_mod);

    const prefab_mod = b.addModule("prefab", .{
        .root_source_file = b.path("packages/prefab/src/prefab.zig"),
        .target = target,
        .optimize = optimize,
    });
    prefab_mod.addImport("engine", engine_mod);

    const physics_mod = b.addModule("physics", .{
        .root_source_file = b.path("packages/physics/core/src/physics.zig"),
        .target = target,
        .optimize = optimize,
    });
    physics_mod.addImport("engine", engine_mod);

    // Application-local (not a public SDK module): the editor shell lives in `apps/editor`.
    const editor_shell_mod = b.createModule(.{
        .root_source_file = b.path("apps/editor/src/shell.zig"),
        .target = target,
        .optimize = optimize,
    });
    editor_shell_mod.addImport("engine", engine_mod);

    // External dependencies (validated for Zig 0.17.1)
    const z_toml_dep = b.dependency("z_toml", .{
        .target = target,
        .optimize = optimize,
    });
    const lookout_dep = b.dependency("lookout", .{
        .target = target,
        .optimize = optimize,
    });
    const yyjson_dep = b.dependency("yyjson", .{});

    const translate_yyjson = b.addTranslateC(.{
        .root_source_file = yyjson_dep.path("src/yyjson.h"),
        .target = target,
        .optimize = optimize,
    });
    const yyjson_c_mod = translate_yyjson.createModule();
    yyjson_c_mod.addIncludePath(yyjson_dep.path("src"));
    yyjson_c_mod.addCSourceFile(.{
        .file = yyjson_dep.path("src/yyjson.c"),
        .flags = &.{"-std=c11"},
    });

    const toml_format_mod = b.addModule("toml_format", .{
        .root_source_file = b.path("packages/formats/toml/src/toml_format.zig"),
        .target = target,
        .optimize = optimize,
    });
    toml_format_mod.addImport("engine", engine_mod);
    toml_format_mod.addImport("toml", z_toml_dep.module("toml"));

    const json_format_mod = b.addModule("json_format", .{
        .root_source_file = b.path("packages/formats/json/src/json_format.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    json_format_mod.addImport("engine", engine_mod);
    json_format_mod.addImport("yyjson_c", yyjson_c_mod);

    const file_watcher_mod = b.addModule("file_watcher", .{
        .root_source_file = b.path("packages/tooling/file-watcher/src/file_watcher.zig"),
        .target = target,
        .optimize = optimize,
    });
    file_watcher_mod.addImport("engine", engine_mod);
    file_watcher_mod.addImport("lookout", lookout_dep.module("lookout"));

    const testing_sdk_mod = b.addModule("testing_sdk", .{
        .root_source_file = b.path("packages/testing/src/testing_sdk.zig"),
        .target = target,
        .optimize = optimize,
    });
    testing_sdk_mod.addImport("engine", engine_mod);
    testing_sdk_mod.addImport("window", window_mod);
    testing_sdk_mod.addImport("graphics", graphics_mod);
    testing_sdk_mod.addImport("ui_core", ui_core_mod);
    testing_sdk_mod.addImport("toml_format", toml_format_mod);

    const lua_c_dep = b.dependency("lua_c", .{});
    const translate_lua = b.addTranslateC(.{
        .root_source_file = b.path("packages/scripting/lua/src/lua_bundle.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_lua.addIncludePath(lua_c_dep.path("."));
    const lua_c_mod = translate_lua.createModule();
    lua_c_mod.addIncludePath(lua_c_dep.path("."));
    lua_c_mod.addCSourceFiles(.{
        .root = lua_c_dep.path("."),
        .files = &.{
            "lapi.c",     "lauxlib.c", "lbaselib.c", "lcode.c",   "lcorolib.c",
            "lctype.c",   "ldblib.c",  "ldebug.c",   "ldo.c",     "ldump.c",
            "lfunc.c",    "lgc.c",     "linit.c",    "liolib.c",  "llex.c",
            "lmathlib.c", "lmem.c",    "loadlib.c",  "lobject.c", "lopcodes.c",
            "loslib.c",   "lparser.c", "lstate.c",   "lstring.c", "lstrlib.c",
            "ltable.c",   "ltablib.c", "ltm.c",      "lundump.c", "lutf8lib.c",
            "lvm.c",      "lzio.c",
        },
        .flags = &.{"-std=c99"},
    });

    const scripting_lua_mod = b.addModule("scripting_lua", .{
        .root_source_file = b.path("packages/scripting/lua/src/scripting_lua.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    scripting_lua_mod.addImport("engine", engine_mod);
    scripting_lua_mod.addImport("scripting_host", scripting_host_mod);
    scripting_lua_mod.addImport("lua_c", lua_c_mod);

    // PocketPy v2.2.0 (MIT) vendored inside packages/scripting/python/third_party/pocketpy.
    const pocketpy_c_mod = blk: {
        const translate_pocketpy = b.addTranslateC(.{
            .root_source_file = b.path("packages/scripting/python/src/pocketpy_bundle.h"),
            .target = target,
            .optimize = optimize,
        });
        translate_pocketpy.addIncludePath(b.path("packages/scripting/python/third_party/pocketpy"));
        const mod = translate_pocketpy.createModule();
        mod.addIncludePath(b.path("packages/scripting/python/third_party/pocketpy"));
        mod.addCSourceFile(.{
            .file = b.path("packages/scripting/python/third_party/pocketpy/pocketpy.c"),
            .flags = &.{ "-std=c11", "-DPK_ENABLE_OS=0" },
        });
        // PocketPy's `socket` module uses Winsock on Windows.
        if (target.result.os.tag == .windows) mod.linkSystemLibrary("ws2_32", .{});
        break :blk mod;
    };

    const scripting_python_mod = b.addModule("scripting_python", .{
        .root_source_file = b.path("packages/scripting/python/src/scripting_python.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    scripting_python_mod.addImport("engine", engine_mod);
    scripting_python_mod.addImport("scripting_host", scripting_host_mod);
    scripting_python_mod.addImport("pocketpy_c", pocketpy_c_mod);

    const default_plugins_mod = b.addModule("default_plugins", .{
        .root_source_file = b.path("packages/default-plugins/src/default_plugins.zig"),
        .target = target,
        .optimize = optimize,
    });
    default_plugins_mod.addImport("engine", engine_mod);
    default_plugins_mod.addImport("window", window_mod);
    default_plugins_mod.addImport("graphics", graphics_mod);
    default_plugins_mod.addImport("ui_core", ui_core_mod);
    default_plugins_mod.addImport("assets", assets_mod);
    default_plugins_mod.addImport("scene", scene_mod);
    default_plugins_mod.addImport("scripting_host", scripting_host_mod);
    default_plugins_mod.addImport("toml_format", toml_format_mod);
    default_plugins_mod.addImport("json_format", json_format_mod);

    const input_mod = b.addModule("input", .{
        .root_source_file = b.path("packages/input/core/src/input.zig"),
        .target = target,
        .optimize = optimize,
    });
    input_mod.addImport("engine", engine_mod);
    input_mod.addImport("window", window_mod);

    const input_haptics_mod = b.addModule("input_haptics", .{
        .root_source_file = b.path("packages/input/haptics/src/haptics.zig"),
        .target = target,
        .optimize = optimize,
    });
    input_haptics_mod.addImport("engine", engine_mod);

    const camera_mod = b.addModule("camera", .{
        .root_source_file = b.path("packages/camera/src/camera.zig"),
        .target = target,
        .optimize = optimize,
    });
    camera_mod.addImport("engine", engine_mod);

    const state_mod = b.addModule("state", .{
        .root_source_file = b.path("packages/state/src/state.zig"),
        .target = target,
        .optimize = optimize,
    });
    state_mod.addImport("engine", engine_mod);

    const audio_mod = b.addModule("audio", .{
        .root_source_file = b.path("packages/audio/core/src/audio.zig"),
        .target = target,
        .optimize = optimize,
    });
    audio_mod.addImport("engine", engine_mod);

    default_plugins_mod.addImport("camera", camera_mod);
    default_plugins_mod.addImport("input", input_mod);
    default_plugins_mod.addImport("input_haptics", input_haptics_mod);
    default_plugins_mod.addImport("state", state_mod);
    default_plugins_mod.addImport("audio", audio_mod);
    camera_mod.addImport("graphics", graphics_mod);
    camera_mod.addImport("input", input_mod);
    camera_mod.addImport("scene", scene_mod);

    const render_3d_mod = b.addModule("render_3d", .{
        .root_source_file = b.path("packages/render/3d/src/render_3d.zig"),
        .target = target,
        .optimize = optimize,
    });
    render_3d_mod.addImport("engine", engine_mod);
    render_3d_mod.addImport("camera", camera_mod);
    render_3d_mod.addImport("scene", scene_mod);

    const gizmos_mod = b.addModule("gizmos", .{
        .root_source_file = b.path("packages/gizmos/src/gizmos.zig"),
        .target = target,
        .optimize = optimize,
    });
    gizmos_mod.addImport("engine", engine_mod);
    gizmos_mod.addImport("camera", camera_mod);

    const shapes_mod = b.addModule("shapes", .{
        .root_source_file = b.path("packages/shapes/src/shapes.zig"),
        .target = target,
        .optimize = optimize,
    });
    shapes_mod.addImport("engine", engine_mod);
    shapes_mod.addImport("render_3d", render_3d_mod);

    const dev_tools_mod = b.addModule("dev_tools", .{
        .root_source_file = b.path("packages/dev-tools/src/dev_tools.zig"),
        .target = target,
        .optimize = optimize,
    });
    dev_tools_mod.addImport("engine", engine_mod);

    const picking_mod = b.addModule("picking", .{
        .root_source_file = b.path("packages/picking/src/picking.zig"),
        .target = target,
        .optimize = optimize,
    });
    picking_mod.addImport("engine", engine_mod);
    picking_mod.addImport("camera", camera_mod);
    picking_mod.addImport("input", input_mod);
    picking_mod.addImport("render_3d", render_3d_mod);

    const remote_mod = b.addModule("remote", .{
        .root_source_file = b.path("packages/remote/src/remote.zig"),
        .target = target,
        .optimize = optimize,
    });
    const log_mod = b.addModule("log", .{
        .root_source_file = b.path("packages/log/src/log.zig"),
        .target = target,
        .optimize = optimize,
    });
    log_mod.addImport("engine", engine_mod);

    const prism_mod = b.addModule("prism", .{
        .root_source_file = b.path("packages/render/prism/src/prism.zig"),
        .target = target,
        .optimize = optimize,
    });
    prism_mod.addImport("engine", engine_mod);

    const helios_mod = b.addModule("helios", .{
        .root_source_file = b.path("packages/render/helios/src/helios.zig"),
        .target = target,
        .optimize = optimize,
    });
    helios_mod.addImport("engine", engine_mod);
    helios_mod.addImport("prism", prism_mod);

    remote_mod.addImport("engine", engine_mod);
    remote_mod.addImport("dev_tools", dev_tools_mod);
    remote_mod.addImport("picking", picking_mod);
    remote_mod.addImport("log", log_mod);

    // Application-local bridge between `remote` and the editor shell (`apps/editor`).
    const editor_remote_adapter_mod = b.createModule(.{
        .root_source_file = b.path("apps/editor/src/remote_adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    editor_remote_adapter_mod.addImport("engine", engine_mod);
    editor_remote_adapter_mod.addImport("remote", remote_mod);
    editor_remote_adapter_mod.addImport("editor_shell", editor_shell_mod);

    // Editor document (entities, selection, transform history): plain data over the world, tested headless.
    const editor_document_mod = b.createModule(.{
        .root_source_file = b.path("apps/editor/src/document.zig"),
        .target = target,
        .optimize = optimize,
    });
    editor_document_mod.addImport("engine", engine_mod);
    editor_document_mod.addImport("render_3d", render_3d_mod);

    // SDL 3.4.20 (zlib) vendored in third_party/sdl3 (Windows x64 binaries).
    const sdl3_c_mod = blk: {
        const translate_sdl3 = b.addTranslateC(.{
            .root_source_file = b.path("packages/window/sdl3/src/sdl3_bundle.h"),
            .target = target,
            .optimize = optimize,
        });
        translate_sdl3.addIncludePath(b.path("third_party/sdl3/include"));
        const mod = translate_sdl3.createModule();
        mod.addIncludePath(b.path("third_party/sdl3/include"));
        mod.addLibraryPath(b.path("third_party/sdl3/lib/x64"));
        mod.linkSystemLibrary("SDL3", .{});
        break :blk mod;
    };

    const window_sdl3_mod = b.addModule("window_sdl3", .{
        .root_source_file = b.path("packages/window/sdl3/src/window_sdl3.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    window_sdl3_mod.addImport("engine", engine_mod);
    window_sdl3_mod.addImport("window", window_mod);
    window_sdl3_mod.addImport("sdl3_c", sdl3_c_mod);

    const input_sdl3_mod = b.addModule("input_sdl3", .{
        .root_source_file = b.path("packages/input/sdl3/src/input_sdl3.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    input_sdl3_mod.addImport("engine", engine_mod);
    input_sdl3_mod.addImport("input", input_mod);
    input_sdl3_mod.addImport("input_haptics", input_haptics_mod);
    input_sdl3_mod.addImport("sdl3_c", sdl3_c_mod);

    const audio_sdl3_mod = b.addModule("audio_sdl3", .{
        .root_source_file = b.path("packages/audio/sdl3/src/audio_sdl3.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    audio_sdl3_mod.addImport("engine", engine_mod);
    audio_sdl3_mod.addImport("audio", audio_mod);
    audio_sdl3_mod.addImport("sdl3_c", sdl3_c_mod);

    const zaudio_dep = b.dependency("zaudio", .{
        .target = target,
        .optimize = optimize,
    });
    const zaudio_pkg_mod = zaudio_dep.module("root");
    const miniaudio_lib = zaudio_dep.artifact("miniaudio");

    const audio_zaudio_mod = b.addModule("audio_zaudio", .{
        .root_source_file = b.path("packages/audio/zaudio/src/audio_zaudio.zig"),
        .target = target,
        .optimize = optimize,
    });
    audio_zaudio_mod.addImport("engine", engine_mod);
    audio_zaudio_mod.addImport("audio", audio_mod);
    audio_zaudio_mod.addImport("zaudio", zaudio_pkg_mod);
    audio_zaudio_mod.linkLibrary(miniaudio_lib);

    const text_mod = b.addModule("text", .{
        .root_source_file = b.path("packages/render/text/src/text.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    text_mod.addIncludePath(b.path("packages/render/text/src"));
    text_mod.addCSourceFile(.{
        .file = b.path("packages/render/text/src/ttf_impl.c"),
        .flags = &.{"-O2"},
    });
    text_mod.addImport("graphics", graphics_mod);

    const render_2d_mod = b.addModule("render_2d", .{
        .root_source_file = b.path("packages/render/2d/src/render_2d.zig"),
        .target = target,
        .optimize = optimize,
    });
    render_2d_mod.addImport("engine", engine_mod);
    render_2d_mod.addImport("graphics", graphics_mod);
    render_2d_mod.addImport("scene", scene_mod);
    render_2d_mod.addImport("camera", camera_mod);

    // GPU executor for draw commands and sprite quads. Needs only the neutral graphics contract + text atlases.
    // GPU renderer for unlit meshes and gizmos (neutral graphics contract only).
    const gpu_3d_mod = b.addModule("gpu_3d", .{
        .root_source_file = b.path("packages/render/3d/src/gpu/gpu_3d.zig"),
        .target = target,
        .optimize = optimize,
    });
    gpu_3d_mod.addImport("engine", engine_mod);
    gpu_3d_mod.addImport("graphics", graphics_mod);
    gpu_3d_mod.addImport("gizmos", gizmos_mod);
    gpu_3d_mod.addImport("render_3d", render_3d_mod);
    gpu_3d_mod.addImport("dev_tools", dev_tools_mod);
    gpu_3d_mod.addImport("prism", prism_mod);

    const draw_2d_mod = b.addModule("draw_2d", .{
        .root_source_file = b.path("packages/render/2d/src/draw_2d.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    draw_2d_mod.addImport("engine", engine_mod);
    draw_2d_mod.addImport("graphics", graphics_mod);
    draw_2d_mod.addImport("text", text_mod);

    // wgpu-native is the engine's graphics foundation. `tools/wgpu/install_wgpu.py` installs the pinned SDK into
    // `.deps/wgpu-native`; `-Dwgpu-root` points at another copy. Headless tests never need it.
    const wgpu_root: []const u8 = b.option([]const u8, "wgpu-root", "Absolute path to the wgpu-native v27.0.4.1 SDK (default: .deps/wgpu-native)") orelse ".deps/wgpu-native";
    const wgpu_present = if (std.Io.Dir.cwd().access(b.graph.io, b.pathJoin(&.{ wgpu_root, "include", "webgpu", "webgpu.h" }), .{})) |_| true else |_| false;
    // Steps that need the SDK depend on this so a missing SDK produces one clear message instead of a header error.
    const wgpu_missing: ?*std.Build.Step.Fail = if (wgpu_present) null else b.addFail("wgpu-native SDK not found. Run `python tools/wgpu/install_wgpu.py --output .deps/wgpu-native` (or pass -Dwgpu-root=<path>).");
    const wgpu_include: std.Build.LazyPath = .{ .cwd_relative = b.pathJoin(&.{ wgpu_root, "include" }) };
    const wgpu_lib: std.Build.LazyPath = .{ .cwd_relative = b.pathJoin(&.{ wgpu_root, "lib" }) };

    // Typed access to the pinned webgpu.h/wgpu.h for the Zig resource layer.
    const translate_wgpu = b.addTranslateC(.{
        .root_source_file = b.path("packages/graphics/wgpu/src/wgpu_c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_wgpu.addIncludePath(wgpu_include);
    const wgpu_c_mod = translate_wgpu.createModule();

    // Native device layer: the C bridge (surface/swapchain) plus the Zig implementation of
    // `graphics.gpu.GpuDevice`. Owns every wgpu-native call so renderers never see WGPU* types.
    const wgpu_gpu_mod = b.addModule("wgpu_gpu", .{
        .root_source_file = b.path("packages/graphics/wgpu/src/gpu_device.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    wgpu_gpu_mod.addImport("graphics", graphics_mod);
    wgpu_gpu_mod.addImport("wgpu_c", wgpu_c_mod);
    wgpu_gpu_mod.addIncludePath(b.path("third_party/sdl3/include"));
    wgpu_gpu_mod.addLibraryPath(b.path("third_party/sdl3/lib/x64"));
    wgpu_gpu_mod.linkSystemLibrary("SDL3", .{});
    wgpu_gpu_mod.addIncludePath(wgpu_include);
    wgpu_gpu_mod.addLibraryPath(wgpu_lib);
    wgpu_gpu_mod.addCSourceFiles(.{
        .files = &.{"packages/graphics/wgpu/src/bridge.c"},
        .flags = &.{"-std=c11"},
    });
    wgpu_gpu_mod.linkSystemLibrary("wgpu_native", .{ .preferred_link_mode = .dynamic });

    const graphics_wgpu_mod = b.addModule("graphics_wgpu", .{
        .root_source_file = b.path("packages/graphics/wgpu/src/graphics_wgpu.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    graphics_wgpu_mod.addImport("engine", engine_mod);
    graphics_wgpu_mod.addImport("graphics", graphics_mod);
    graphics_wgpu_mod.addImport("window_sdl3", window_sdl3_mod);
    graphics_wgpu_mod.addImport("wgpu_gpu", wgpu_gpu_mod);


    return .{
        .engine_mod = engine_mod,
        .c_abi_mod = c_abi_mod,
        .window_mod = window_mod,
        .graphics_mod = graphics_mod,
        .ui_core_mod = ui_core_mod,
        .ui_markup_mod = ui_markup_mod,
        .ui_widgets_mod = ui_widgets_mod,
        .ui_plume_mod = ui_plume_mod,
        .scripting_host_mod = scripting_host_mod,
        .assets_mod = assets_mod,
        .scene_mod = scene_mod,
        .prefab_mod = prefab_mod,
        .physics_mod = physics_mod,
        .editor_shell_mod = editor_shell_mod,
        .toml_format_mod = toml_format_mod,
        .json_format_mod = json_format_mod,
        .file_watcher_mod = file_watcher_mod,
        .testing_sdk_mod = testing_sdk_mod,
        .scripting_lua_mod = scripting_lua_mod,
        .scripting_python_mod = scripting_python_mod,
        .input_mod = input_mod,
        .input_haptics_mod = input_haptics_mod,
        .camera_mod = camera_mod,
        .state_mod = state_mod,
        .audio_mod = audio_mod,
        .render_3d_mod = render_3d_mod,
        .gizmos_mod = gizmos_mod,
        .shapes_mod = shapes_mod,
        .dev_tools_mod = dev_tools_mod,
        .picking_mod = picking_mod,
        .remote_mod = remote_mod,
        .log_mod = log_mod,
        .editor_remote_adapter_mod = editor_remote_adapter_mod,
        .editor_document_mod = editor_document_mod,
        .window_sdl3_mod = window_sdl3_mod,
        .input_sdl3_mod = input_sdl3_mod,
        .zaudio_pkg_mod = zaudio_pkg_mod,
        .audio_zaudio_mod = audio_zaudio_mod,
        .text_mod = text_mod,
        .render_2d_mod = render_2d_mod,
        .prism_mod = prism_mod,
        .helios_mod = helios_mod,
        .draw_2d_mod = draw_2d_mod,
        .gpu_3d_mod = gpu_3d_mod,
        .wgpu_gpu_mod = wgpu_gpu_mod,
        .graphics_wgpu_mod = graphics_wgpu_mod,
        .wgpu_root = wgpu_root,
        .wgpu_present = wgpu_present,
        .wgpu_missing = wgpu_missing,
    };
}
