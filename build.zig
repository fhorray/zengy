// Build script for the Modular Zengy Engine.
//
// Targets:
// - `engine`: Minimal headless core SDK module (`src/engine.zig`)
// - `headless-ecs`: Phase 1 standalone 1000-entity simulation (`zig build run-headless`)
// - `c_plugin`: Phase 3 pure C11 shared library plugin (`examples/c-plugin/plugin.c`)
// - Optional packages: `window`, `graphics`, `ui_core`, `ui_markup`,
//   `scripting_host`, `assets`, `scene`, `editor_shell`, `render_3d`
// - `engine-cli`: Diagnostic CLI (`zig build run-cli`)
// - `test`: Per-module test suites organized inside each module's `tests/` directory

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Public Zig SDK module ("engine")
    const engine_mod = b.addModule("engine", .{
        .root_source_file = b.path("src/engine.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Headless ECS example (Phase 1 gate)
    const headless_mod = b.createModule(.{
        .root_source_file = b.path("examples/headless-ecs/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    headless_mod.addImport("engine", engine_mod);

    const headless_exe = b.addExecutable(.{
        .name = "headless-ecs",
        .root_module = headless_mod,
    });
    b.installArtifact(headless_exe);

    const run_headless = b.addRunArtifact(headless_exe);
    const run_headless_step = b.step("run-headless", "Run the headless ECS example (1000 entities)");
    run_headless_step.dependOn(&run_headless.step);

    // Pure C ABI example plugin (Phase 3 gate)
    const c_plugin_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_plugin_mod.addIncludePath(b.path("include"));
    c_plugin_mod.addCSourceFile(.{
        .file = b.path("examples/c-plugin/plugin.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });

    const c_plugin = b.addLibrary(.{
        .name = "c_plugin",
        .linkage = .dynamic,
        .root_module = c_plugin_mod,
    });
    const install_c_plugin = b.addInstallArtifact(c_plugin, .{});

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

    const editor_shell_mod = b.addModule("editor_shell", .{
        .root_source_file = b.path("packages/editor-shell/src/editor_shell.zig"),
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
    remote_mod.addImport("editor_shell", editor_shell_mod);
    remote_mod.addImport("picking", picking_mod);
    remote_mod.addImport("log", log_mod);

    // Diagnostic CLI tool (`tools/cli`)
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("tools/cli/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_mod.addImport("engine", engine_mod);
    cli_mod.addImport("window", window_mod);
    cli_mod.addImport("graphics", graphics_mod);
    cli_mod.addImport("ui_core", ui_core_mod);
    cli_mod.addImport("scripting_host", scripting_host_mod);
    cli_mod.addImport("assets", assets_mod);
    cli_mod.addImport("testing_sdk", testing_sdk_mod);
    cli_mod.addImport("toml_format", toml_format_mod);
    cli_mod.addAnonymousImport("py_zengy_init_pyi", .{
        .root_source_file = b.path("packages/scripting/python/typings/zengy/__init__.pyi"),
    });
    cli_mod.addAnonymousImport("py_zengy_input_pyi", .{
        .root_source_file = b.path("packages/scripting/python/typings/zengy/input.pyi"),
    });
    cli_mod.addAnonymousImport("py_zengy_key_pyi", .{
        .root_source_file = b.path("packages/scripting/python/typings/zengy/Key.pyi"),
    });
    cli_mod.addAnonymousImport("py_zengy_init_pyi", .{
        .root_source_file = b.path("packages/scripting/python/typings/zengy/__init__.pyi"),
    });
    cli_mod.addAnonymousImport("py_zengy_input_pyi", .{
        .root_source_file = b.path("packages/scripting/python/typings/zengy/input.pyi"),
    });
    cli_mod.addAnonymousImport("py_zengy_key_pyi", .{
        .root_source_file = b.path("packages/scripting/python/typings/zengy/Key.pyi"),
    });

    const cli_exe = b.addExecutable(.{
        .name = "zengy",
        .root_module = cli_mod,
    });
    b.installArtifact(cli_exe);

    // CLI-only step: builds and installs `zengy` without linking SDL3 (used by the Linux release).
    const cli_step = b.step("cli", "Build and install only the zengy CLI (no SDL3 needed)");
    cli_step.dependOn(&b.addInstallArtifact(cli_exe, .{}).step);

    const run_cli = b.addRunArtifact(cli_exe);
    const cli_cmd = b.option([]const u8, "cli-cmd", "CLI subcommand (doctor, packages, list-official, new, run, add)") orelse "doctor";
    run_cli.addArg(cli_cmd);
    if (b.option([]const u8, "cli-arg", "Optional argument for CLI subcommand")) |arg| {
        run_cli.addArg(arg);
    }
    const run_cli_step = b.step("run-cli", "Run the zengy CLI (doctor, packages, list-official, new, run, add)");
    run_cli_step.dependOn(&run_cli.step);

    // Integrated Playground example (`examples/playground`)
    const playground_mod = b.createModule(.{
        .root_source_file = b.path("examples/playground/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    playground_mod.addImport("engine", engine_mod);
    playground_mod.addImport("window", window_mod);
    playground_mod.addImport("graphics", graphics_mod);
    playground_mod.addImport("ui_core", ui_core_mod);
    playground_mod.addImport("ui_markup", ui_markup_mod);
    playground_mod.addImport("scripting_host", scripting_host_mod);
    playground_mod.addImport("assets", assets_mod);
    playground_mod.addImport("scene", scene_mod);
    playground_mod.addImport("editor_shell", editor_shell_mod);
    playground_mod.addImport("camera", camera_mod);
    playground_mod.addImport("render_3d", render_3d_mod);

    const playground_exe = b.addExecutable(.{
        .name = "playground",
        .root_module = playground_mod,
    });
    b.installArtifact(playground_exe);

    const run_playground = b.addRunArtifact(playground_exe);
    run_playground.step.dependOn(&install_c_plugin.step);
    const run_playground_step = b.step("run-playground", "Run the integrated engine playground");
    run_playground_step.dependOn(&run_playground.step);

    // SDL 3.4.20 (zlib) vendored in packages/sdl3 (Windows x64 binaries).
    const sdl3_c_mod = blk: {
        const translate_sdl3 = b.addTranslateC(.{
            .root_source_file = b.path("packages/window/sdl3/src/sdl3_bundle.h"),
            .target = target,
            .optimize = optimize,
        });
        translate_sdl3.addIncludePath(b.path("packages/sdl3/include"));
        const mod = translate_sdl3.createModule();
        mod.addIncludePath(b.path("packages/sdl3/include"));
        mod.addLibraryPath(b.path("packages/sdl3/lib/x64"));
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

    // Visual hello (D1): native SDL3 window, input and DPI. Run with `zig build run-visual-hello`.
    const visual_hello_mod = b.createModule(.{
        .root_source_file = b.path("examples/visual-hello/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    visual_hello_mod.addImport("engine", engine_mod);
    visual_hello_mod.addImport("window_sdl3", window_sdl3_mod);

    const visual_hello_exe = b.addExecutable(.{
        .name = "visual-hello",
        .root_module = visual_hello_mod,
    });
    b.installArtifact(visual_hello_exe);

    // The SDL3 runtime DLL must sit next to the executable in zig-out/bin when present.
    // Windows x64: the SDL3 runtime DLL comes from the pinned official release (`sdl3_win64` in build.zig.zon),
    // fetched on demand and installed next to the executables. Other targets link the system SDL3.
    if (target.result.os.tag == .windows and target.result.cpu.arch == .x86_64) {
        if (b.lazyDependency("sdl3_win64", .{})) |sdl3_win64| {
            const install_sdl3_dll = b.addInstallBinFile(sdl3_win64.path("SDL3.dll"), "SDL3.dll");
            b.getInstallStep().dependOn(&install_sdl3_dll.step);
        }
    }
    // Run the installed copy: the cache copy has no SDL3.dll beside it (Windows exit 0xC0000135).
    const run_visual_hello = b.addSystemCommand(&.{"zig-out/bin/visual-hello.exe"});
    run_visual_hello.setCwd(b.path("."));
    run_visual_hello.step.dependOn(b.getInstallStep());
    const run_visual_hello_step = b.step("run-visual-hello", "Open the native SDL3 hello window (D1)");
    run_visual_hello_step.dependOn(&run_visual_hello.step);

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

    const draw_2d_mod = b.addModule("draw_2d", .{
        .root_source_file = b.path("packages/render/2d/src/draw_2d.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    draw_2d_mod.addImport("engine", engine_mod);
    draw_2d_mod.addImport("graphics", graphics_mod);
    draw_2d_mod.addImport("text", text_mod);

    const gpu_resources_mod = b.addModule("gpu_resources", .{
        .root_source_file = b.path("packages/graphics/sdlgpu/src/gpu_resources.zig"),
        .target = target,
        .optimize = optimize,
    });
    gpu_resources_mod.addImport("graphics", graphics_mod);

    const graphics_sdlgpu_mod = b.addModule("graphics_sdlgpu", .{
        .root_source_file = b.path("packages/graphics/sdlgpu/src/graphics_sdlgpu.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    graphics_sdlgpu_mod.addImport("engine", engine_mod);
    graphics_sdlgpu_mod.addImport("graphics", graphics_mod);
    graphics_sdlgpu_mod.addImport("window_sdl3", window_sdl3_mod);
    graphics_sdlgpu_mod.addImport("text", text_mod);
    graphics_sdlgpu_mod.addImport("render_3d", render_3d_mod);
    graphics_sdlgpu_mod.addImport("gizmos", gizmos_mod);
    graphics_sdlgpu_mod.addImport("dev_tools", dev_tools_mod);
    graphics_sdlgpu_mod.addImport("prism", prism_mod);
    graphics_sdlgpu_mod.addImport("sdl3_c", sdl3_c_mod);

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
    wgpu_gpu_mod.addIncludePath(b.path("packages/sdl3/include"));
    wgpu_gpu_mod.addLibraryPath(b.path("packages/sdl3/lib/x64"));
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

    // Real-GPU conformance tests. Kept out of the default `test` step, which must run without a GPU.
    const gpu_test_mod = b.createModule(.{
        .root_source_file = b.path("packages/graphics/wgpu/tests/all_gpu_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    gpu_test_mod.addImport("graphics", graphics_mod);
    gpu_test_mod.addImport("wgpu_gpu", wgpu_gpu_mod);
    gpu_test_mod.addImport("draw_2d", draw_2d_mod);
    gpu_test_mod.addImport("gpu_3d", gpu_3d_mod);
    gpu_test_mod.addImport("gizmos", gizmos_mod);
    gpu_test_mod.addImport("render_3d", render_3d_mod);
    gpu_test_mod.addImport("engine", engine_mod);
    gpu_test_mod.addImport("window_sdl3", window_sdl3_mod);
    gpu_test_mod.addImport("graphics_wgpu", graphics_wgpu_mod);
    const gpu_tests = b.addTest(.{ .root_module = gpu_test_mod });
    const gpu_test_step = b.step("test-wgpu-gpu", "Run wgpu GpuDevice conformance tests on a real adapter");
    // On Windows the loader needs SDL3.dll and wgpu_native.dll beside the executable, so run an
    // installed copy (the cache copy fails with 0xC0000135 / exit 53), like `run-visual-hello`.
    const wgpu_dll = b.addInstallBinFile(.{ .cwd_relative = b.pathJoin(&.{ wgpu_root, "lib", "wgpu_native.dll" }) }, "wgpu_native.dll");
    if (wgpu_present and target.result.os.tag == .windows) b.getInstallStep().dependOn(&wgpu_dll.step);
    if (target.result.os.tag == .windows) {
        const install_gpu_tests = b.addInstallArtifact(gpu_tests, .{ .dest_sub_path = "wgpu-gpu-tests.exe" });
        const run_gpu_tests = b.addSystemCommand(&.{"zig-out/bin/wgpu-gpu-tests.exe"});
        run_gpu_tests.setCwd(b.path("."));
        run_gpu_tests.step.dependOn(&install_gpu_tests.step);
        run_gpu_tests.step.dependOn(&wgpu_dll.step);
        if (b.lazyDependency("sdl3_win64", .{})) |sdl3_win64| {
            const install_sdl = b.addInstallBinFile(sdl3_win64.path("SDL3.dll"), "SDL3.dll");
            run_gpu_tests.step.dependOn(&install_sdl.step);
        }
        gpu_test_step.dependOn(&run_gpu_tests.step);
    } else {
        gpu_test_step.dependOn(&b.addRunArtifact(gpu_tests).step);
    }

    const visual_wgpu_mod = b.createModule(.{
        .root_source_file = b.path("examples/visual-wgpu/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    visual_wgpu_mod.addImport("engine", engine_mod);
    visual_wgpu_mod.addImport("window_sdl3", window_sdl3_mod);
    visual_wgpu_mod.addImport("graphics", graphics_mod);
    visual_wgpu_mod.addImport("graphics_wgpu", graphics_wgpu_mod);
    visual_wgpu_mod.addImport("draw_2d", draw_2d_mod);
    const visual_wgpu_exe = b.addExecutable(.{ .name = "visual-wgpu", .root_module = visual_wgpu_mod });
    const install_wgpu = b.addInstallArtifact(visual_wgpu_exe, .{});
    const build_wgpu_step = b.step("build-visual-wgpu", "Build the native wgpu migration demo");
    build_wgpu_step.dependOn(&install_wgpu.step);
    const run_wgpu_step = b.step("run-visual-wgpu", "Run the native wgpu migration demo");
    if (target.result.os.tag == .windows) {
        // Same loader constraint as the GPU tests: run the installed copy with its DLLs beside it.
        const run_wgpu = b.addSystemCommand(&.{"zig-out/bin/visual-wgpu.exe"});
        run_wgpu.setCwd(b.path("."));
        run_wgpu.step.dependOn(&install_wgpu.step);
        run_wgpu.step.dependOn(&wgpu_dll.step);
        if (b.lazyDependency("sdl3_win64", .{})) |sdl3_win64| {
            const install_sdl = b.addInstallBinFile(sdl3_win64.path("SDL3.dll"), "SDL3.dll");
            run_wgpu.step.dependOn(&install_sdl.step);
        }
        run_wgpu_step.dependOn(&run_wgpu.step);
    } else {
        run_wgpu_step.dependOn(&b.addRunArtifact(visual_wgpu_exe).step);
    }

    // Visual GPU hello (D2): SDL3 window + SDL_GPU triangle & rect. Run with `zig build run-visual-gpu`.
    const visual_gpu_mod = b.createModule(.{
        .root_source_file = b.path("examples/visual-gpu/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    visual_gpu_mod.addImport("engine", engine_mod);
    visual_gpu_mod.addImport("window", window_mod);
    visual_gpu_mod.addImport("window_sdl3", window_sdl3_mod);
    visual_gpu_mod.addImport("graphics", graphics_mod);
    visual_gpu_mod.addImport("graphics_wgpu", graphics_wgpu_mod);
    visual_gpu_mod.addImport("draw_2d", draw_2d_mod);

    const visual_gpu_exe = b.addExecutable(.{
        .name = "visual-gpu",
        .root_module = visual_gpu_mod,
    });
    b.installArtifact(visual_gpu_exe);
    if (wgpu_missing) |fail| visual_gpu_exe.step.dependOn(&fail.step);

    const run_visual_gpu = b.addSystemCommand(&.{"zig-out/bin/visual-gpu.exe"});
    run_visual_gpu.setCwd(b.path("."));
    run_visual_gpu.step.dependOn(b.getInstallStep());
    const run_visual_gpu_step = b.step("run-visual-gpu", "Open the native SDL3 + SDL_GPU hello window (D2)");
    run_visual_gpu_step.dependOn(&run_visual_gpu.step);

    // Visual 2D hello (D3): Camera2D, Sprite, Transform2D, and batched textures. Run with `zig build run-visual-2d`.
    const visual_2d_mod = b.createModule(.{
        .root_source_file = b.path("examples/visual-2d/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    visual_2d_mod.addImport("engine", engine_mod);
    visual_2d_mod.addImport("window", window_mod);
    visual_2d_mod.addImport("window_sdl3", window_sdl3_mod);
    visual_2d_mod.addImport("graphics", graphics_mod);
    visual_2d_mod.addImport("graphics_wgpu", graphics_wgpu_mod);
    visual_2d_mod.addImport("draw_2d", draw_2d_mod);
    visual_2d_mod.addImport("scene", scene_mod);
    visual_2d_mod.addImport("camera", camera_mod);
    visual_2d_mod.addImport("render_2d", render_2d_mod);

    const visual_2d_exe = b.addExecutable(.{
        .name = "visual-2d",
        .root_module = visual_2d_mod,
    });
    b.installArtifact(visual_2d_exe);
    if (wgpu_missing) |fail| visual_2d_exe.step.dependOn(&fail.step);

    const run_visual_2d = b.addSystemCommand(&.{"zig-out/bin/visual-2d.exe"});
    run_visual_2d.setCwd(b.path("."));
    run_visual_2d.step.dependOn(b.getInstallStep());
    const run_visual_2d_step = b.step("run-visual-2d", "Open the native SDL3 2D sprites & Camera2D demo (D3)");
    run_visual_2d_step.dependOn(&run_visual_2d.step);

    // Visual Plume Widget Gallery: full ui-widgets + ui-plume showcase. Run with `zig build run-visual-plume`.
    const visual_plume_mod = b.createModule(.{
        .root_source_file = b.path("examples/visual-plume/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    visual_plume_mod.addImport("engine", engine_mod);
    visual_plume_mod.addImport("window", window_mod);
    visual_plume_mod.addImport("window_sdl3", window_sdl3_mod);
    visual_plume_mod.addImport("graphics", graphics_mod);
    visual_plume_mod.addImport("graphics_wgpu", graphics_wgpu_mod);
    visual_plume_mod.addImport("draw_2d", draw_2d_mod);
    visual_plume_mod.addImport("ui_core", ui_core_mod);
    visual_plume_mod.addImport("ui_widgets", ui_widgets_mod);
    visual_plume_mod.addImport("ui_plume", ui_plume_mod);

    const visual_plume_exe = b.addExecutable(.{
        .name = "visual-plume",
        .root_module = visual_plume_mod,
    });
    b.installArtifact(visual_plume_exe);
    if (wgpu_missing) |fail| visual_plume_exe.step.dependOn(&fail.step);

    const run_visual_plume = b.addSystemCommand(&.{"zig-out/bin/visual-plume.exe"});
    run_visual_plume.setCwd(b.path("."));
    run_visual_plume.step.dependOn(b.getInstallStep());
    const run_visual_plume_step = b.step("run-visual-plume", "Open the native SDL3 Plume Widget Gallery demo");
    run_visual_plume_step.dependOn(&run_visual_plume.step);

    // Visual UI hello (D4): UiTree, ui_markup, font atlas text, click, textbox & clipping. Run with `zig build run-visual-ui`.
    const visual_ui_mod = b.createModule(.{
        .root_source_file = b.path("examples/visual-ui/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    visual_ui_mod.addImport("engine", engine_mod);
    visual_ui_mod.addImport("window", window_mod);
    visual_ui_mod.addImport("window_sdl3", window_sdl3_mod);
    visual_ui_mod.addImport("graphics", graphics_mod);
    visual_ui_mod.addImport("graphics_wgpu", graphics_wgpu_mod);
    visual_ui_mod.addImport("draw_2d", draw_2d_mod);
    visual_ui_mod.addImport("ui_core", ui_core_mod);
    visual_ui_mod.addImport("ui_markup", ui_markup_mod);

    const visual_ui_exe = b.addExecutable(.{
        .name = "visual-ui",
        .root_module = visual_ui_mod,
    });
    b.installArtifact(visual_ui_exe);
    if (wgpu_missing) |fail| visual_ui_exe.step.dependOn(&fail.step);

    const run_visual_ui = b.addSystemCommand(&.{"zig-out/bin/visual-ui.exe"});
    run_visual_ui.setCwd(b.path("."));
    run_visual_ui.step.dependOn(b.getInstallStep());
    const run_visual_ui_step = b.step("run-visual-ui", "Open the native SDL3 UI & text demo (D4)");
    run_visual_ui_step.dependOn(&run_visual_ui.step);

    // Visual Playground (D5): integrated 2D scene + UI panel (FPS, Spawn, Log). Run with `zig build run-visual-playground`.
    const visual_pg_mod = b.createModule(.{
        .root_source_file = b.path("examples/visual-playground/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    visual_pg_mod.addImport("engine", engine_mod);
    visual_pg_mod.addImport("window", window_mod);
    visual_pg_mod.addImport("window_sdl3", window_sdl3_mod);
    visual_pg_mod.addImport("graphics", graphics_mod);
    visual_pg_mod.addImport("graphics_wgpu", graphics_wgpu_mod);
    visual_pg_mod.addImport("draw_2d", draw_2d_mod);
    visual_pg_mod.addImport("scene", scene_mod);
    visual_pg_mod.addImport("camera", camera_mod);
    visual_pg_mod.addImport("render_2d", render_2d_mod);
    visual_pg_mod.addImport("ui_core", ui_core_mod);
    visual_pg_mod.addImport("ui_markup", ui_markup_mod);

    const visual_pg_exe = b.addExecutable(.{
        .name = "visual-playground",
        .root_module = visual_pg_mod,
    });
    b.installArtifact(visual_pg_exe);
    if (wgpu_missing) |fail| visual_pg_exe.step.dependOn(&fail.step);

    const run_visual_pg = b.addSystemCommand(&.{"zig-out/bin/visual-playground.exe"});
    run_visual_pg.setCwd(b.path("."));
    run_visual_pg.step.dependOn(b.getInstallStep());
    const run_visual_pg_step = b.step("run-visual-playground", "Open the integrated 2D + UI Visual Playground (D5)");
    run_visual_pg_step.dependOn(&run_visual_pg.step);

    // Visual Python (PocketPy + SDL_GPU): Python script driving `engine.draw_rect`. Run with `zig build run-visual-python`.
    const visual_py_mod = b.createModule(.{
        .root_source_file = b.path("examples/visual-python/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    visual_py_mod.addImport("engine", engine_mod);
    visual_py_mod.addImport("window_sdl3", window_sdl3_mod);
    visual_py_mod.addImport("graphics", graphics_mod);
    visual_py_mod.addImport("graphics_wgpu", graphics_wgpu_mod);
    visual_py_mod.addImport("draw_2d", draw_2d_mod);
    visual_py_mod.addImport("scripting_host", scripting_host_mod);
    visual_py_mod.addImport("scripting_python", scripting_python_mod);

    const visual_py_exe = b.addExecutable(.{
        .name = "visual-python",
        .root_module = visual_py_mod,
    });
    b.installArtifact(visual_py_exe);
    if (wgpu_missing) |fail| visual_py_exe.step.dependOn(&fail.step);

    const run_visual_py = b.addSystemCommand(&.{"zig-out/bin/visual-python.exe"});
    run_visual_py.setCwd(b.path("."));
    run_visual_py.step.dependOn(b.getInstallStep());
    const run_visual_py_step = b.step("run-visual-python", "Open the PocketPy + SDL_GPU visual demo");
    run_visual_py_step.dependOn(&run_visual_py.step);

    // Visual 3D (Phase E): 3D unlit meshes, depth buffer, Camera3D & frustum culling. Run with `zig build run-visual-3d`.
    const visual_3d_mod = b.createModule(.{
        .root_source_file = b.path("examples/visual-3d/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    visual_3d_mod.addImport("engine", engine_mod);
    visual_3d_mod.addImport("window", window_mod);
    visual_3d_mod.addImport("window_sdl3", window_sdl3_mod);
    visual_3d_mod.addImport("graphics", graphics_mod);
    visual_3d_mod.addImport("graphics_wgpu", graphics_wgpu_mod);
    visual_3d_mod.addImport("draw_2d", draw_2d_mod);
    visual_3d_mod.addImport("gpu_3d", gpu_3d_mod);
    visual_3d_mod.addImport("camera", camera_mod);
    visual_3d_mod.addImport("render_3d", render_3d_mod);

    const visual_3d_exe = b.addExecutable(.{
        .name = "visual-3d",
        .root_module = visual_3d_mod,
    });
    b.installArtifact(visual_3d_exe);
    if (wgpu_missing) |fail| visual_3d_exe.step.dependOn(&fail.step);

    const run_visual_3d = b.addSystemCommand(&.{"zig-out/bin/visual-3d.exe"});
    run_visual_3d.setCwd(b.path("."));
    run_visual_3d.step.dependOn(b.getInstallStep());
    const run_visual_3d_step = b.step("run-visual-3d", "Open the Phase E 3D Foundation demo");
    run_visual_3d_step.dependOn(&run_visual_3d.step);

    // Headless Camera & Projection example. Run with `zig build run-camera`.
    const camera_example_mod = b.createModule(.{
        .root_source_file = b.path("examples/camera/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    camera_example_mod.addImport("engine", engine_mod);
    camera_example_mod.addImport("camera", camera_mod);

    const camera_example_exe = b.addExecutable(.{
        .name = "camera-example",
        .root_module = camera_example_mod,
    });
    b.installArtifact(camera_example_exe);

    const run_camera = b.addRunArtifact(camera_example_exe);
    const run_camera_step = b.step("run-camera", "Run the headless Camera & Projection example");
    run_camera_step.dependOn(&run_camera.step);

    // Visual Camera & Bevy-style Input demo. Run with `zig build run-visual-camera`.
    const visual_camera_mod = b.createModule(.{
        .root_source_file = b.path("examples/visual-camera/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    visual_camera_mod.addImport("engine", engine_mod);
    visual_camera_mod.addImport("window", window_mod);
    visual_camera_mod.addImport("window_sdl3", window_sdl3_mod);
    visual_camera_mod.addImport("graphics", graphics_mod);
    visual_camera_mod.addImport("graphics_wgpu", graphics_wgpu_mod);
    visual_camera_mod.addImport("draw_2d", draw_2d_mod);
    visual_camera_mod.addImport("gpu_3d", gpu_3d_mod);
    visual_camera_mod.addImport("input", input_mod);
    visual_camera_mod.addImport("camera", camera_mod);
    visual_camera_mod.addImport("render_3d", render_3d_mod);

    const visual_camera_exe = b.addExecutable(.{
        .name = "visual-camera",
        .root_module = visual_camera_mod,
    });
    b.installArtifact(visual_camera_exe);
    if (wgpu_missing) |fail| visual_camera_exe.step.dependOn(&fail.step);

    const run_visual_camera = b.addSystemCommand(&.{"zig-out/bin/visual-camera.exe"});
    run_visual_camera.setCwd(b.path("."));
    run_visual_camera.step.dependOn(b.getInstallStep());
    const run_visual_camera_step = b.step("run-visual-camera", "Open the Visual Camera & Input demo");
    run_visual_camera_step.dependOn(&run_visual_camera.step);

    // Visual PS5 DualSense / Gamepad & Haptics demo. Run with `zig build run-visual-gamepad`.
    const visual_gamepad_mod = b.createModule(.{
        .root_source_file = b.path("examples/visual-gamepad/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    visual_gamepad_mod.addImport("engine", engine_mod);
    visual_gamepad_mod.addImport("window_sdl3", window_sdl3_mod);
    visual_gamepad_mod.addImport("graphics", graphics_mod);
    visual_gamepad_mod.addImport("graphics_wgpu", graphics_wgpu_mod);
    visual_gamepad_mod.addImport("draw_2d", draw_2d_mod);
    visual_gamepad_mod.addImport("gpu_3d", gpu_3d_mod);
    visual_gamepad_mod.addImport("input", input_mod);
    visual_gamepad_mod.addImport("input_haptics", input_haptics_mod);
    visual_gamepad_mod.addImport("input_sdl3", input_sdl3_mod);
    visual_gamepad_mod.addImport("camera", camera_mod);
    visual_gamepad_mod.addImport("render_3d", render_3d_mod);

    const visual_gamepad_exe = b.addExecutable(.{
        .name = "visual-gamepad",
        .root_module = visual_gamepad_mod,
    });
    b.installArtifact(visual_gamepad_exe);
    if (wgpu_missing) |fail| visual_gamepad_exe.step.dependOn(&fail.step);

    const run_visual_gamepad = b.addSystemCommand(&.{"zig-out/bin/visual-gamepad.exe"});
    run_visual_gamepad.setCwd(b.path("."));
    run_visual_gamepad.step.dependOn(b.getInstallStep());
    const run_visual_gamepad_step = b.step("run-visual-gamepad", "Open the Visual PS5 DualSense & Haptics demo");
    run_visual_gamepad_step.dependOn(&run_visual_gamepad.step);

    // Visual Audio, State & Time demo. Run with `zig build run-visual-audio`.
    const visual_audio_mod = b.createModule(.{
        .root_source_file = b.path("examples/visual-audio/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    visual_audio_mod.addImport("engine", engine_mod);
    visual_audio_mod.addImport("window_sdl3", window_sdl3_mod);
    visual_audio_mod.addImport("graphics", graphics_mod);
    visual_audio_mod.addImport("graphics_wgpu", graphics_wgpu_mod);
    visual_audio_mod.addImport("draw_2d", draw_2d_mod);
    visual_audio_mod.addImport("gpu_3d", gpu_3d_mod);
    visual_audio_mod.addImport("input", input_mod);
    visual_audio_mod.addImport("input_sdl3", input_sdl3_mod);
    visual_audio_mod.addImport("camera", camera_mod);
    visual_audio_mod.addImport("render_3d", render_3d_mod);
    visual_audio_mod.addImport("state", state_mod);
    visual_audio_mod.addImport("audio", audio_mod);
    visual_audio_mod.addImport("audio_zaudio", audio_zaudio_mod);

    const visual_audio_exe = b.addExecutable(.{
        .name = "visual-audio",
        .root_module = visual_audio_mod,
    });
    b.installArtifact(visual_audio_exe);
    if (wgpu_missing) |fail| visual_audio_exe.step.dependOn(&fail.step);

    const run_visual_audio = b.addSystemCommand(&.{"zig-out/bin/visual-audio.exe"});
    run_visual_audio.setCwd(b.path("."));
    run_visual_audio.step.dependOn(b.getInstallStep());
    const run_visual_audio_step = b.step("run-visual-audio", "Open the Visual Audio, State & Time demo");
    run_visual_audio_step.dependOn(&run_visual_audio.step);

    // Visual PBR, Shadows, Sky, AutoExposure & Tonemapping demo. Run with `zig build run-visual-pbr`.
    const visual_pbr_mod = b.createModule(.{
        .root_source_file = b.path("examples/visual-pbr/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    visual_pbr_mod.addImport("engine", engine_mod);
    visual_pbr_mod.addImport("window_sdl3", window_sdl3_mod);
    visual_pbr_mod.addImport("graphics", graphics_mod);
    visual_pbr_mod.addImport("testing_sdk", testing_sdk_mod);
    visual_pbr_mod.addImport("graphics_sdlgpu", graphics_sdlgpu_mod);
    visual_pbr_mod.addImport("input", input_mod);
    visual_pbr_mod.addImport("input_sdl3", input_sdl3_mod);
    visual_pbr_mod.addImport("camera", camera_mod);
    visual_pbr_mod.addImport("render_3d", render_3d_mod);
    visual_pbr_mod.addImport("gizmos", gizmos_mod);

    const visual_pbr_exe = b.addExecutable(.{
        .name = "visual-pbr",
        .root_module = visual_pbr_mod,
    });
    b.installArtifact(visual_pbr_exe);

    const run_visual_pbr = b.addSystemCommand(&.{"zig-out/bin/visual-pbr.exe"});
    run_visual_pbr.setCwd(b.path("."));
    run_visual_pbr.step.dependOn(b.getInstallStep());
    const run_visual_pbr_step = b.step("run-visual-pbr", "Open the Visual PBR, Shadows, AutoExposure & Tonemapping demo");
    run_visual_pbr_step.dependOn(&run_visual_pbr.step);

    // Visual 3D Gizmos Showcase. Run with `zig build run-visual-gizmos`.
    const visual_gizmos_mod = b.createModule(.{
        .root_source_file = b.path("examples/visual-gizmos/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    visual_gizmos_mod.addImport("engine", engine_mod);
    visual_gizmos_mod.addImport("window_sdl3", window_sdl3_mod);
    visual_gizmos_mod.addImport("graphics", graphics_mod);
    visual_gizmos_mod.addImport("graphics_wgpu", graphics_wgpu_mod);
    visual_gizmos_mod.addImport("draw_2d", draw_2d_mod);
    visual_gizmos_mod.addImport("gpu_3d", gpu_3d_mod);
    visual_gizmos_mod.addImport("input", input_mod);
    visual_gizmos_mod.addImport("input_sdl3", input_sdl3_mod);
    visual_gizmos_mod.addImport("camera", camera_mod);
    visual_gizmos_mod.addImport("render_3d", render_3d_mod);
    visual_gizmos_mod.addImport("gizmos", gizmos_mod);

    const visual_gizmos_exe = b.addExecutable(.{
        .name = "visual-gizmos",
        .root_module = visual_gizmos_mod,
    });
    b.installArtifact(visual_gizmos_exe);
    if (wgpu_missing) |fail| visual_gizmos_exe.step.dependOn(&fail.step);

    const run_visual_gizmos = b.addSystemCommand(&.{"zig-out/bin/visual-gizmos.exe"});
    run_visual_gizmos.setCwd(b.path("."));
    run_visual_gizmos.step.dependOn(b.getInstallStep());
    const run_visual_gizmos_step = b.step("run-visual-gizmos", "Open the Visual 3D Gizmos Showcase");
    run_visual_gizmos_step.dependOn(&run_visual_gizmos.step);

    // Visual Shapes + Picking + Profiler + Remote Inspector Showcase. Run with `zig build run-visual-inspector`.
    const visual_inspector_mod = b.createModule(.{
        .root_source_file = b.path("examples/visual-inspector/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    visual_inspector_mod.addImport("engine", engine_mod);
    visual_inspector_mod.addImport("window_sdl3", window_sdl3_mod);
    visual_inspector_mod.addImport("graphics", graphics_mod);
    visual_inspector_mod.addImport("graphics_wgpu", graphics_wgpu_mod);
    visual_inspector_mod.addImport("draw_2d", draw_2d_mod);
    visual_inspector_mod.addImport("gpu_3d", gpu_3d_mod);
    visual_inspector_mod.addImport("input", input_mod);
    visual_inspector_mod.addImport("input_sdl3", input_sdl3_mod);
    visual_inspector_mod.addImport("ui_core", ui_core_mod);
    visual_inspector_mod.addImport("camera", camera_mod);
    visual_inspector_mod.addImport("render_3d", render_3d_mod);
    visual_inspector_mod.addImport("gizmos", gizmos_mod);
    visual_inspector_mod.addImport("shapes", shapes_mod);
    visual_inspector_mod.addImport("dev_tools", dev_tools_mod);
    visual_inspector_mod.addImport("editor_shell", editor_shell_mod);
    visual_inspector_mod.addImport("picking", picking_mod);
    visual_inspector_mod.addImport("log", log_mod);
    visual_inspector_mod.addImport("remote", remote_mod);

    const visual_inspector_exe = b.addExecutable(.{
        .name = "visual-inspector",
        .root_module = visual_inspector_mod,
    });
    b.installArtifact(visual_inspector_exe);
    if (wgpu_missing) |fail| visual_inspector_exe.step.dependOn(&fail.step);

    const run_visual_inspector = b.addSystemCommand(&.{"zig-out/bin/visual-inspector.exe"});
    run_visual_inspector.setCwd(b.path("."));
    run_visual_inspector.step.dependOn(b.getInstallStep());
    const run_visual_inspector_step = b.step("run-visual-inspector", "Open the Visual Shapes, Picking & Profiler Showcase");
    run_visual_inspector_step.dependOn(&run_visual_inspector.step);

    // Builds and installs only the examples already running on wgpu (plus runtime DLLs), without the SDL GPU ones.
    const wgpu_examples_step = b.step("build-wgpu-examples", "Install the examples that run on the wgpu stack");
    for ([_]*std.Build.Step.Compile{ visual_gpu_exe, visual_2d_exe, visual_plume_exe, visual_ui_exe, visual_pg_exe, visual_py_exe, visual_3d_exe, visual_camera_exe, visual_gamepad_exe, visual_audio_exe, visual_gizmos_exe, visual_inspector_exe }) |exe| {
        wgpu_examples_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }
    if (wgpu_present and target.result.os.tag == .windows) {
        wgpu_examples_step.dependOn(&b.addInstallBinFile(.{ .cwd_relative = b.pathJoin(&.{ wgpu_root, "lib", "wgpu_native.dll" }) }, "wgpu_native.dll").step);
        if (b.lazyDependency("sdl3_win64", .{})) |sdl3_win64| {
            wgpu_examples_step.dependOn(&b.addInstallBinFile(sdl3_win64.path("SDL3.dll"), "SDL3.dll").step);
        }
    }

    // Visual Prism Stage 01+02 Showcase. Run with `zig build run-visual-prism`.
    const visual_prism_mod = b.createModule(.{
        .root_source_file = b.path("examples/visual-prism/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    visual_prism_mod.addImport("engine", engine_mod);
    visual_prism_mod.addImport("window_sdl3", window_sdl3_mod);
    visual_prism_mod.addImport("graphics", graphics_mod);
    visual_prism_mod.addImport("graphics_sdlgpu", graphics_sdlgpu_mod);
    visual_prism_mod.addImport("testing_sdk", testing_sdk_mod);
    visual_prism_mod.addAnonymousImport("sky_hdr", .{
        .root_source_file = b.path("examples/visual-pbr/assets/sky.hdr"),
    });
    visual_prism_mod.addImport("input", input_mod);
    visual_prism_mod.addImport("input_sdl3", input_sdl3_mod);
    visual_prism_mod.addImport("camera", camera_mod);
    visual_prism_mod.addImport("render_3d", render_3d_mod);
    visual_prism_mod.addImport("gizmos", gizmos_mod);
    visual_prism_mod.addImport("shapes", shapes_mod);
    visual_prism_mod.addImport("dev_tools", dev_tools_mod);
    visual_prism_mod.addImport("prism", prism_mod);
    visual_prism_mod.addImport("helios", helios_mod);

    const visual_prism_exe = b.addExecutable(.{
        .name = "visual-prism",
        .root_module = visual_prism_mod,
    });
    b.installArtifact(visual_prism_exe);

    const run_visual_prism = b.addSystemCommand(&.{"zig-out/bin/visual-prism.exe"});
    run_visual_prism.setCwd(b.path("."));
    run_visual_prism.step.dependOn(b.getInstallStep());
    const run_visual_prism_step = b.step("run-visual-prism", "Open the Visual Prism Stage 01+02 Showcase");
    run_visual_prism_step.dependOn(&run_visual_prism.step);

    // Render regression harness: renders the fixed scenarios of `visual-pbr` and compares them with
    // `tests/golden/visual-pbr` (`capture-check`) or rewrites those goldens (`capture-update`).
    // Needs a GPU and a window; see docs/roadmap/visual-risk-plan.md.
    const capture_exe_path = b.fmt("zig-out/bin/visual-pbr{s}", .{target.result.exeFileExt()});
    const capture_check = b.addSystemCommand(&.{capture_exe_path});
    capture_check.setCwd(b.path("."));
    capture_check.setEnvironmentVariable("ZENGY_CAPTURE_DIR", "zig-out/capture");
    capture_check.step.dependOn(b.getInstallStep());
    const capture_check_step = b.step("capture-check", "Render the visual-pbr scenarios and compare them with the golden images");
    capture_check_step.dependOn(&capture_check.step);

    const capture_update = b.addSystemCommand(&.{capture_exe_path});
    capture_update.setCwd(b.path("."));
    capture_update.setEnvironmentVariable("ZENGY_CAPTURE_DIR", "zig-out/capture");
    capture_update.setEnvironmentVariable("ZENGY_CAPTURE_UPDATE", "1");
    capture_update.step.dependOn(b.getInstallStep());
    const capture_update_step = b.step("capture-update", "Re-render the visual-pbr scenarios and overwrite the golden images");
    capture_update_step.dependOn(&capture_update.step);

    // Manifesto-driven visual runtime (`tools/runtime/main.zig`): reads game.toml in CWD.
    const runtime_mod = b.createModule(.{
        .root_source_file = b.path("tools/runtime/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    runtime_mod.addImport("engine", engine_mod);
    runtime_mod.addImport("window", window_mod);
    runtime_mod.addImport("window_sdl3", window_sdl3_mod);
    runtime_mod.addImport("graphics", graphics_mod);
    runtime_mod.addImport("graphics_sdlgpu", graphics_sdlgpu_mod);
    runtime_mod.addImport("ui_core", ui_core_mod);
    runtime_mod.addImport("ui_markup", ui_markup_mod);
    runtime_mod.addImport("scripting_host", scripting_host_mod);
    runtime_mod.addImport("scripting_python", scripting_python_mod);
    runtime_mod.addImport("scripting_lua", scripting_lua_mod);
    runtime_mod.addImport("toml_format", toml_format_mod);
    runtime_mod.addImport("scene", scene_mod);
    runtime_mod.addImport("physics", physics_mod);

    const runtime_exe = b.addExecutable(.{
        .name = "zengy-runtime",
        .root_module = runtime_mod,
    });
    b.installArtifact(runtime_exe);

    // Microbenchmark suite (`benchmarks/main.zig`)
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("benchmarks/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    bench_mod.addImport("engine", engine_mod);
    bench_mod.addImport("graphics", graphics_mod);
    bench_mod.addImport("ui_core", ui_core_mod);
    bench_mod.addImport("scene", scene_mod);
    bench_mod.addImport("json_format", json_format_mod);

    const bench_exe = b.addExecutable(.{
        .name = "zengy-bench",
        .root_module = bench_mod,
    });
    b.installArtifact(bench_exe);
    const run_bench = b.addRunArtifact(bench_exe);
    const run_bench_step = b.step("run-bench", "Run the engine microbenchmark suite");
    run_bench_step.dependOn(&run_bench.step);

    // Per-module test suites
    const test_step = b.step("test", "Run all per-module unit, integration, and C ABI tests");

    const addModuleTest = struct {
        fn add(
            builder: *std.Build,
            step: *std.Build.Step,
            path: []const u8,
            tgt: std.Build.ResolvedTarget,
            opt: std.builtin.OptimizeMode,
            link_c: bool,
            imports: []const struct { name: []const u8, mod: *std.Build.Module },
            dep_step: ?*std.Build.Step,
        ) void {
            const m = builder.createModule(.{
                .root_source_file = builder.path(path),
                .target = tgt,
                .optimize = opt,
                .link_libc = link_c,
            });
            for (imports) |imp| {
                m.addImport(imp.name, imp.mod);
            }
            const t = builder.addTest(.{ .root_module = m });
            const r = builder.addRunArtifact(t);
            if (dep_step) |ds| r.step.dependOn(ds);
            step.dependOn(&r.step);
        }
    }.add;

    const pkg_manifest_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/cli/pkg_manifest.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(pkg_manifest_tests).step);

    const plugin_path_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/runtime/plugin_paths.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(plugin_path_tests).step);

    // The render regression suite needs a GPU and a window, so it joins `zig build test` only on request.
    const capture_in_test = b.option(bool, "capture", "Also run the GPU render regression suite (capture-check) as part of `zig build test`") orelse false;
    if (capture_in_test) test_step.dependOn(capture_check_step);

    const hook_tracker_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/runtime/hook_tracker.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(hook_tracker_tests).step);

    addModuleTest(b, test_step, "src/core/tests/core_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
    }, null);

    addModuleTest(b, test_step, "src/core/tests/abi_tests.zig", target, optimize, true, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "c_abi", .mod = c_abi_mod },
    }, &install_c_plugin.step);

    addModuleTest(b, test_step, "packages/window/core/tests/window_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "window", .mod = window_mod },
    }, null);

    // Backend-neutral GPU contract: handle pools, command recorder and format helpers.
    addModuleTest(b, test_step, "packages/graphics/core/src/gpu.zig", target, optimize, false, &.{}, null);
    addModuleTest(b, test_step, "packages/graphics/core/src/frame.zig", target, optimize, false, &.{}, null);

    addModuleTest(b, test_step, "packages/graphics/core/tests/graphics_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "window", .mod = window_mod },
        .{ .name = "graphics", .mod = graphics_mod },
    }, null);

    addModuleTest(b, test_step, "packages/ui/core/tests/ui_core_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "window", .mod = window_mod },
        .{ .name = "graphics", .mod = graphics_mod },
        .{ .name = "ui_core", .mod = ui_core_mod },
    }, null);

    addModuleTest(b, test_step, "packages/ui/markup/tests/ui_frontends_tests.zig", target, optimize, false, &.{
        .{ .name = "ui_core", .mod = ui_core_mod },
        .{ .name = "ui_markup", .mod = ui_markup_mod },
    }, null);

    addModuleTest(b, test_step, "packages/ui/widgets/tests/ui_widgets_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "window", .mod = window_mod },
        .{ .name = "graphics", .mod = graphics_mod },
        .{ .name = "ui_core", .mod = ui_core_mod },
        .{ .name = "ui_widgets", .mod = ui_widgets_mod },
    }, null);

    addModuleTest(b, test_step, "packages/ui/plume/tests/ui_plume_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "window", .mod = window_mod },
        .{ .name = "graphics", .mod = graphics_mod },
        .{ .name = "ui_core", .mod = ui_core_mod },
        .{ .name = "ui_widgets", .mod = ui_widgets_mod },
        .{ .name = "ui_plume", .mod = ui_plume_mod },
        .{ .name = "testing_sdk", .mod = testing_sdk_mod },
    }, null);

    addModuleTest(b, test_step, "packages/scripting/host/tests/scripting_host_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "scripting_host", .mod = scripting_host_mod },
    }, null);

    addModuleTest(b, test_step, "packages/assets/tests/assets_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "assets", .mod = assets_mod },
    }, null);

    addModuleTest(b, test_step, "packages/prefab/tests/prefab_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "prefab", .mod = prefab_mod },
        .{ .name = "toml_format", .mod = toml_format_mod },
    }, null);

    addModuleTest(b, test_step, "packages/scene/tests/scene_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "scene", .mod = scene_mod },
    }, null);

    addModuleTest(b, test_step, "packages/editor-shell/tests/editor_shell_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "window", .mod = window_mod },
        .{ .name = "graphics", .mod = graphics_mod },
        .{ .name = "ui_core", .mod = ui_core_mod },
        .{ .name = "editor_shell", .mod = editor_shell_mod },
    }, null);

    addModuleTest(b, test_step, "packages/render/3d/tests/render_3d_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "window", .mod = window_mod },
        .{ .name = "graphics", .mod = graphics_mod },
        .{ .name = "scene", .mod = scene_mod },
        .{ .name = "camera", .mod = camera_mod },
        .{ .name = "render_3d", .mod = render_3d_mod },
    }, null);

    addModuleTest(b, test_step, "packages/gizmos/tests/gizmos_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "camera", .mod = camera_mod },
        .{ .name = "gizmos", .mod = gizmos_mod },
    }, null);

    addModuleTest(b, test_step, "packages/shapes/tests/shapes_tests.zig", target, optimize, false, &.{
        .{ .name = "shapes", .mod = shapes_mod },
    }, null);

    addModuleTest(b, test_step, "packages/dev-tools/tests/dev_tools_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "dev_tools", .mod = dev_tools_mod },
    }, null);

    addModuleTest(b, test_step, "packages/picking/tests/picking_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "window", .mod = window_mod },
        .{ .name = "graphics", .mod = graphics_mod },
        .{ .name = "input", .mod = input_mod },
        .{ .name = "scene", .mod = scene_mod },
        .{ .name = "camera", .mod = camera_mod },
        .{ .name = "render_3d", .mod = render_3d_mod },
        .{ .name = "picking", .mod = picking_mod },
    }, null);

    addModuleTest(b, test_step, "packages/remote/tests/remote_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "window", .mod = window_mod },
        .{ .name = "graphics", .mod = graphics_mod },
        .{ .name = "ui_core", .mod = ui_core_mod },
        .{ .name = "dev_tools", .mod = dev_tools_mod },
        .{ .name = "editor_shell", .mod = editor_shell_mod },
        .{ .name = "picking", .mod = picking_mod },
        .{ .name = "log", .mod = log_mod },
        .{ .name = "remote", .mod = remote_mod },
    }, null);

    addModuleTest(b, test_step, "packages/log/tests/log_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "log", .mod = log_mod },
    }, null);

    addModuleTest(b, test_step, "packages/render/prism/tests/prism_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "prism", .mod = prism_mod },
    }, null);

    addModuleTest(b, test_step, "packages/render/helios/tests/helios_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "prism", .mod = prism_mod },
        .{ .name = "helios", .mod = helios_mod },
    }, null);

    addModuleTest(b, test_step, "packages/formats/toml/tests/toml_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "toml_format", .mod = toml_format_mod },
    }, null);

    addModuleTest(b, test_step, "packages/formats/json/tests/json_tests.zig", target, optimize, true, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "json_format", .mod = json_format_mod },
    }, null);

    addModuleTest(b, test_step, "packages/tooling/file-watcher/tests/file_watcher_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "file_watcher", .mod = file_watcher_mod },
    }, null);

    addModuleTest(b, test_step, "packages/testing/tests/testing_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "window", .mod = window_mod },
        .{ .name = "graphics", .mod = graphics_mod },
        .{ .name = "ui_core", .mod = ui_core_mod },
        .{ .name = "testing_sdk", .mod = testing_sdk_mod },
    }, null);

    addModuleTest(b, test_step, "packages/scripting/lua/tests/scripting_lua_tests.zig", target, optimize, true, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "scripting_host", .mod = scripting_host_mod },
        .{ .name = "scripting_lua", .mod = scripting_lua_mod },
    }, null);

    addModuleTest(b, test_step, "packages/scripting/python/tests/scripting_python_tests.zig", target, optimize, true, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "scripting_host", .mod = scripting_host_mod },
        .{ .name = "scripting_lua", .mod = scripting_lua_mod },
        .{ .name = "scripting_python", .mod = scripting_python_mod },
    }, null);

    addModuleTest(b, test_step, "packages/graphics/sdlgpu/tests/graphics_sdlgpu_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "graphics", .mod = graphics_mod },
        .{ .name = "gpu_resources", .mod = gpu_resources_mod },
    }, null);

    // Pure volumetric light ranking; no SDL or engine imports, so it runs headless.
    addModuleTest(b, test_step, "packages/graphics/sdlgpu/src/volumetric_lights.zig", target, optimize, false, &.{}, null);
    addModuleTest(b, test_step, "packages/graphics/sdlgpu/src/shadow_cull.zig", target, optimize, false, &.{}, null);
    addModuleTest(b, test_step, "packages/graphics/sdlgpu/src/shadow_plan.zig", target, optimize, false, &.{}, null);
    addModuleTest(b, test_step, "packages/testing/src/render_regression.zig", target, optimize, false, &.{
        .{ .name = "graphics", .mod = graphics_mod },
    }, null);

    addModuleTest(b, test_step, "packages/render/text/tests/text_tests.zig", target, optimize, false, &.{
        .{ .name = "text", .mod = text_mod },
    }, null);

    addModuleTest(b, test_step, "packages/render/2d/src/draw_2d.zig", target, optimize, true, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "graphics", .mod = graphics_mod },
        .{ .name = "text", .mod = text_mod },
    }, null);

    addModuleTest(b, test_step, "packages/render/3d/src/gpu/gpu_3d.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "graphics", .mod = graphics_mod },
        .{ .name = "gizmos", .mod = gizmos_mod },
    }, null);

    addModuleTest(b, test_step, "packages/render/2d/tests/render_2d_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "window", .mod = window_mod },
        .{ .name = "graphics", .mod = graphics_mod },
        .{ .name = "scene", .mod = scene_mod },
        .{ .name = "camera", .mod = camera_mod },
        .{ .name = "render_2d", .mod = render_2d_mod },
    }, null);

    addModuleTest(b, test_step, "packages/physics/core/tests/physics_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "physics", .mod = physics_mod },
    }, null);

    addModuleTest(b, test_step, "packages/camera/tests/camera_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "graphics", .mod = graphics_mod },
        .{ .name = "input", .mod = input_mod },
        .{ .name = "scene", .mod = scene_mod },
        .{ .name = "camera", .mod = camera_mod },
    }, null);

    addModuleTest(b, test_step, "packages/input/core/tests/input_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "window", .mod = window_mod },
        .{ .name = "input", .mod = input_mod },
    }, null);

    addModuleTest(b, test_step, "packages/input/haptics/tests/haptics_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "input_haptics", .mod = input_haptics_mod },
    }, null);
    addModuleTest(b, test_step, "packages/state/tests/state_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "state", .mod = state_mod },
    }, null);
    addModuleTest(b, test_step, "packages/audio/core/tests/audio_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "audio", .mod = audio_mod },
    }, null);
    addModuleTest(b, test_step, "packages/audio/zaudio/tests/zaudio_tests.zig", target, optimize, true, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "audio", .mod = audio_mod },
        .{ .name = "zaudio", .mod = zaudio_pkg_mod },
        .{ .name = "audio_zaudio", .mod = audio_zaudio_mod },
    }, null);
}
