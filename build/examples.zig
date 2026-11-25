//! Example executables and their `run-*` steps (headless, C ABI plugin, playground, visual demos, capture harness).
//! Examples owned by an application (for example `apps/editor/examples/visual-inspector`) are registered here too.

const std = @import("std");
const Modules = @import("modules.zig").Modules;

/// Build pieces other build files depend on.
pub const Result = struct {
    install_c_plugin: *std.Build.Step.InstallArtifact,
    capture_check_step: *std.Build.Step,
};

/// Adds all examples. Returns the pieces the test suite depends on.
pub fn add(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, mods: Modules) Result {
    const engine_mod = mods.engine_mod;
    const window_mod = mods.window_mod;
    const graphics_mod = mods.graphics_mod;
    const ui_core_mod = mods.ui_core_mod;
    const ui_markup_mod = mods.ui_markup_mod;
    const ui_widgets_mod = mods.ui_widgets_mod;
    const ui_plume_mod = mods.ui_plume_mod;
    const scripting_host_mod = mods.scripting_host_mod;
    const assets_mod = mods.assets_mod;
    const scene_mod = mods.scene_mod;
    const editor_shell_mod = mods.editor_shell_mod;
    const testing_sdk_mod = mods.testing_sdk_mod;
    const scripting_python_mod = mods.scripting_python_mod;
    const input_mod = mods.input_mod;
    const input_haptics_mod = mods.input_haptics_mod;
    const camera_mod = mods.camera_mod;
    const state_mod = mods.state_mod;
    const audio_mod = mods.audio_mod;
    const render_3d_mod = mods.render_3d_mod;
    const gizmos_mod = mods.gizmos_mod;
    const shapes_mod = mods.shapes_mod;
    const dev_tools_mod = mods.dev_tools_mod;
    const picking_mod = mods.picking_mod;
    const remote_mod = mods.remote_mod;
    const log_mod = mods.log_mod;
    const editor_remote_adapter_mod = mods.editor_remote_adapter_mod;
    const window_sdl3_mod = mods.window_sdl3_mod;
    const input_sdl3_mod = mods.input_sdl3_mod;
    const audio_zaudio_mod = mods.audio_zaudio_mod;
    const render_2d_mod = mods.render_2d_mod;
    const prism_mod = mods.prism_mod;
    const helios_mod = mods.helios_mod;
    const draw_2d_mod = mods.draw_2d_mod;
    const gpu_3d_mod = mods.gpu_3d_mod;
    const wgpu_gpu_mod = mods.wgpu_gpu_mod;
    const graphics_wgpu_mod = mods.graphics_wgpu_mod;
    const wgpu_root = mods.wgpu_root;
    const wgpu_present = mods.wgpu_present;
    const wgpu_missing = mods.wgpu_missing;

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
    if (wgpu_missing) |fail| visual_hello_exe.step.dependOn(&fail.step) else b.installArtifact(visual_hello_exe);

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
    if (wgpu_missing) |fail| run_visual_hello.step.dependOn(&fail.step);
    const run_visual_hello_step = b.step("run-visual-hello", "Open the native SDL3 hello window (D1)");
    run_visual_hello_step.dependOn(&run_visual_hello.step);

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
    if (wgpu_missing) |fail| visual_gpu_exe.step.dependOn(&fail.step) else b.installArtifact(visual_gpu_exe);

    const run_visual_gpu = b.addSystemCommand(&.{"zig-out/bin/visual-gpu.exe"});
    run_visual_gpu.setCwd(b.path("."));
    run_visual_gpu.step.dependOn(b.getInstallStep());
    if (wgpu_missing) |fail| run_visual_gpu.step.dependOn(&fail.step);
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
    if (wgpu_missing) |fail| visual_2d_exe.step.dependOn(&fail.step) else b.installArtifact(visual_2d_exe);

    const run_visual_2d = b.addSystemCommand(&.{"zig-out/bin/visual-2d.exe"});
    run_visual_2d.setCwd(b.path("."));
    run_visual_2d.step.dependOn(b.getInstallStep());
    if (wgpu_missing) |fail| run_visual_2d.step.dependOn(&fail.step);
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
    if (wgpu_missing) |fail| visual_plume_exe.step.dependOn(&fail.step) else b.installArtifact(visual_plume_exe);

    const run_visual_plume = b.addSystemCommand(&.{"zig-out/bin/visual-plume.exe"});
    run_visual_plume.setCwd(b.path("."));
    run_visual_plume.step.dependOn(b.getInstallStep());
    if (wgpu_missing) |fail| run_visual_plume.step.dependOn(&fail.step);
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
    if (wgpu_missing) |fail| visual_ui_exe.step.dependOn(&fail.step) else b.installArtifact(visual_ui_exe);

    const run_visual_ui = b.addSystemCommand(&.{"zig-out/bin/visual-ui.exe"});
    run_visual_ui.setCwd(b.path("."));
    run_visual_ui.step.dependOn(b.getInstallStep());
    if (wgpu_missing) |fail| run_visual_ui.step.dependOn(&fail.step);
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
    if (wgpu_missing) |fail| visual_pg_exe.step.dependOn(&fail.step) else b.installArtifact(visual_pg_exe);

    const run_visual_pg = b.addSystemCommand(&.{"zig-out/bin/visual-playground.exe"});
    run_visual_pg.setCwd(b.path("."));
    run_visual_pg.step.dependOn(b.getInstallStep());
    if (wgpu_missing) |fail| run_visual_pg.step.dependOn(&fail.step);
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
    if (wgpu_missing) |fail| visual_py_exe.step.dependOn(&fail.step) else b.installArtifact(visual_py_exe);

    const run_visual_py = b.addSystemCommand(&.{"zig-out/bin/visual-python.exe"});
    run_visual_py.setCwd(b.path("."));
    run_visual_py.step.dependOn(b.getInstallStep());
    if (wgpu_missing) |fail| run_visual_py.step.dependOn(&fail.step);
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
    if (wgpu_missing) |fail| visual_3d_exe.step.dependOn(&fail.step) else b.installArtifact(visual_3d_exe);

    const run_visual_3d = b.addSystemCommand(&.{"zig-out/bin/visual-3d.exe"});
    run_visual_3d.setCwd(b.path("."));
    run_visual_3d.step.dependOn(b.getInstallStep());
    if (wgpu_missing) |fail| run_visual_3d.step.dependOn(&fail.step);
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
    if (wgpu_missing) |fail| visual_camera_exe.step.dependOn(&fail.step) else b.installArtifact(visual_camera_exe);

    const run_visual_camera = b.addSystemCommand(&.{"zig-out/bin/visual-camera.exe"});
    run_visual_camera.setCwd(b.path("."));
    run_visual_camera.step.dependOn(b.getInstallStep());
    if (wgpu_missing) |fail| run_visual_camera.step.dependOn(&fail.step);
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
    if (wgpu_missing) |fail| visual_gamepad_exe.step.dependOn(&fail.step) else b.installArtifact(visual_gamepad_exe);

    const run_visual_gamepad = b.addSystemCommand(&.{"zig-out/bin/visual-gamepad.exe"});
    run_visual_gamepad.setCwd(b.path("."));
    run_visual_gamepad.step.dependOn(b.getInstallStep());
    if (wgpu_missing) |fail| run_visual_gamepad.step.dependOn(&fail.step);
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
    if (wgpu_missing) |fail| visual_audio_exe.step.dependOn(&fail.step) else b.installArtifact(visual_audio_exe);

    const run_visual_audio = b.addSystemCommand(&.{"zig-out/bin/visual-audio.exe"});
    run_visual_audio.setCwd(b.path("."));
    run_visual_audio.step.dependOn(b.getInstallStep());
    if (wgpu_missing) |fail| run_visual_audio.step.dependOn(&fail.step);
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
    visual_pbr_mod.addImport("graphics_wgpu", graphics_wgpu_mod);
    visual_pbr_mod.addImport("draw_2d", draw_2d_mod);
    visual_pbr_mod.addImport("gpu_3d", gpu_3d_mod);
    visual_pbr_mod.addImport("input", input_mod);
    visual_pbr_mod.addImport("input_sdl3", input_sdl3_mod);
    visual_pbr_mod.addImport("camera", camera_mod);
    visual_pbr_mod.addImport("render_3d", render_3d_mod);
    visual_pbr_mod.addImport("gizmos", gizmos_mod);

    const visual_pbr_exe = b.addExecutable(.{
        .name = "visual-pbr",
        .root_module = visual_pbr_mod,
    });
    if (wgpu_missing) |fail| visual_pbr_exe.step.dependOn(&fail.step) else b.installArtifact(visual_pbr_exe);

    const run_visual_pbr = b.addSystemCommand(&.{"zig-out/bin/visual-pbr.exe"});
    run_visual_pbr.setCwd(b.path("."));
    run_visual_pbr.step.dependOn(b.getInstallStep());
    if (wgpu_missing) |fail| run_visual_pbr.step.dependOn(&fail.step);
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
    if (wgpu_missing) |fail| visual_gizmos_exe.step.dependOn(&fail.step) else b.installArtifact(visual_gizmos_exe);

    const run_visual_gizmos = b.addSystemCommand(&.{"zig-out/bin/visual-gizmos.exe"});
    run_visual_gizmos.setCwd(b.path("."));
    run_visual_gizmos.step.dependOn(b.getInstallStep());
    if (wgpu_missing) |fail| run_visual_gizmos.step.dependOn(&fail.step);
    const run_visual_gizmos_step = b.step("run-visual-gizmos", "Open the Visual 3D Gizmos Showcase");
    run_visual_gizmos_step.dependOn(&run_visual_gizmos.step);

    // Visual Shapes + Picking + Profiler + Remote Inspector Showcase. Run with `zig build run-visual-inspector`.
    const visual_inspector_mod = b.createModule(.{
        .root_source_file = b.path("apps/editor/examples/visual-inspector/main.zig"),
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
    visual_inspector_mod.addImport("remote_adapter", editor_remote_adapter_mod);

    const visual_inspector_exe = b.addExecutable(.{
        .name = "visual-inspector",
        .root_module = visual_inspector_mod,
    });
    if (wgpu_missing) |fail| visual_inspector_exe.step.dependOn(&fail.step) else b.installArtifact(visual_inspector_exe);

    const run_visual_inspector = b.addSystemCommand(&.{"zig-out/bin/visual-inspector.exe"});
    run_visual_inspector.setCwd(b.path("."));
    run_visual_inspector.step.dependOn(b.getInstallStep());
    if (wgpu_missing) |fail| run_visual_inspector.step.dependOn(&fail.step);
    const run_visual_inspector_step = b.step("run-visual-inspector", "Open the Visual Shapes, Picking & Profiler Showcase");
    run_visual_inspector_step.dependOn(&run_visual_inspector.step);

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
    visual_prism_mod.addImport("graphics_wgpu", graphics_wgpu_mod);
    visual_prism_mod.addImport("draw_2d", draw_2d_mod);
    visual_prism_mod.addImport("gpu_3d", gpu_3d_mod);
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
    if (wgpu_missing) |fail| visual_prism_exe.step.dependOn(&fail.step) else b.installArtifact(visual_prism_exe);

    const run_visual_prism = b.addSystemCommand(&.{"zig-out/bin/visual-prism.exe"});
    run_visual_prism.setCwd(b.path("."));
    run_visual_prism.step.dependOn(b.getInstallStep());
    if (wgpu_missing) |fail| run_visual_prism.step.dependOn(&fail.step);
    const run_visual_prism_step = b.step("run-visual-prism", "Open the Visual Prism Stage 01+02 Showcase");
    run_visual_prism_step.dependOn(&run_visual_prism.step);

    // Builds and installs only the examples already running on wgpu (plus runtime DLLs), without the SDL GPU ones.
    const wgpu_examples_step = b.step("build-wgpu-examples", "Install the examples that run on the wgpu stack");
    for ([_]*std.Build.Step.Compile{ visual_gpu_exe, visual_2d_exe, visual_plume_exe, visual_ui_exe, visual_pg_exe, visual_py_exe, visual_3d_exe, visual_camera_exe, visual_gamepad_exe, visual_audio_exe, visual_gizmos_exe, visual_inspector_exe, visual_pbr_exe, visual_prism_exe }) |exe| {
        wgpu_examples_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }
    if (wgpu_present and target.result.os.tag == .windows) {
        wgpu_examples_step.dependOn(&b.addInstallBinFile(.{ .cwd_relative = b.pathJoin(&.{ wgpu_root, "lib", "wgpu_native.dll" }) }, "wgpu_native.dll").step);
        if (b.lazyDependency("sdl3_win64", .{})) |sdl3_win64| {
            wgpu_examples_step.dependOn(&b.addInstallBinFile(sdl3_win64.path("SDL3.dll"), "SDL3.dll").step);
        }
    }

    // Render regression harness: renders the fixed scenarios of `visual-pbr` and compares them with
    // `tests/golden/visual-pbr` (`capture-check`) or rewrites those goldens (`capture-update`).
    // Needs a GPU and a window; see docs/roadmap/visual-risk-plan.md.
    const capture_exe_path = b.fmt("zig-out/bin/visual-pbr{s}", .{target.result.exeFileExt()});
    const capture_check = b.addSystemCommand(&.{capture_exe_path});
    capture_check.setCwd(b.path("."));
    capture_check.setEnvironmentVariable("ZENGY_CAPTURE_DIR", "zig-out/capture");
    capture_check.step.dependOn(b.getInstallStep());
    if (wgpu_missing) |fail| capture_check.step.dependOn(&fail.step);
    const capture_check_step = b.step("capture-check", "Render the visual-pbr scenarios and compare them with the golden images");
    capture_check_step.dependOn(&capture_check.step);

    const capture_update = b.addSystemCommand(&.{capture_exe_path});
    capture_update.setCwd(b.path("."));
    capture_update.setEnvironmentVariable("ZENGY_CAPTURE_DIR", "zig-out/capture");
    capture_update.setEnvironmentVariable("ZENGY_CAPTURE_UPDATE", "1");
    capture_update.step.dependOn(b.getInstallStep());
    if (wgpu_missing) |fail| capture_update.step.dependOn(&fail.step);
    const capture_update_step = b.step("capture-update", "Re-render the visual-pbr scenarios and overwrite the golden images");
    capture_update_step.dependOn(&capture_update.step);

    return .{
        .install_c_plugin = install_c_plugin,
        .capture_check_step = capture_check_step,
    };
}
