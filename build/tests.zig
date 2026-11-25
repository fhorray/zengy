//! Test suites: per-module unit, integration and C ABI tests behind the `test` step.

const std = @import("std");
const Modules = @import("modules.zig").Modules;

/// Registers every test root. `examples` supplies the C plugin install and capture check steps.
pub fn add(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, mods: Modules, examples: @import("examples.zig").Result) void {
    const engine_mod = mods.engine_mod;
    const c_abi_mod = mods.c_abi_mod;
    const window_mod = mods.window_mod;
    const graphics_mod = mods.graphics_mod;
    const ui_core_mod = mods.ui_core_mod;
    const ui_markup_mod = mods.ui_markup_mod;
    const ui_widgets_mod = mods.ui_widgets_mod;
    const ui_plume_mod = mods.ui_plume_mod;
    const scripting_host_mod = mods.scripting_host_mod;
    const assets_mod = mods.assets_mod;
    const scene_mod = mods.scene_mod;
    const prefab_mod = mods.prefab_mod;
    const physics_mod = mods.physics_mod;
    const editor_shell_mod = mods.editor_shell_mod;
    const toml_format_mod = mods.toml_format_mod;
    const json_format_mod = mods.json_format_mod;
    const file_watcher_mod = mods.file_watcher_mod;
    const testing_sdk_mod = mods.testing_sdk_mod;
    const scripting_lua_mod = mods.scripting_lua_mod;
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
    const zaudio_pkg_mod = mods.zaudio_pkg_mod;
    const audio_zaudio_mod = mods.audio_zaudio_mod;
    const text_mod = mods.text_mod;
    const render_2d_mod = mods.render_2d_mod;
    const prism_mod = mods.prism_mod;
    const helios_mod = mods.helios_mod;

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
            .root_source_file = b.path("apps/runtime/src/plugin_paths.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(plugin_path_tests).step);

    // The render regression suite needs a GPU and a window, so it joins `zig build test` only on request.
    const capture_in_test = b.option(bool, "capture", "Also run the GPU render regression suite (capture-check) as part of `zig build test`") orelse false;
    if (capture_in_test) test_step.dependOn(examples.capture_check_step);

    const hook_tracker_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/runtime/src/hook_tracker.zig"),
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
    }, &examples.install_c_plugin.step);

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

    addModuleTest(b, test_step, "apps/editor/tests/document_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "render_3d", .mod = render_3d_mod },
        .{ .name = "scene", .mod = scene_mod },
        .{ .name = "document", .mod = mods.editor_document_mod },
    }, null);

    addModuleTest(b, test_step, "apps/editor/tests/shell_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "window", .mod = window_mod },
        .{ .name = "graphics", .mod = graphics_mod },
        .{ .name = "ui_core", .mod = ui_core_mod },
        .{ .name = "editor_shell", .mod = editor_shell_mod },
        .{ .name = "document", .mod = mods.editor_document_mod },
        .{ .name = "render_3d", .mod = render_3d_mod },
        .{ .name = "scene", .mod = scene_mod },
    }, null);

    addModuleTest(b, test_step, "apps/editor/tests/panels_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "window", .mod = window_mod },
        .{ .name = "graphics", .mod = graphics_mod },
        .{ .name = "ui_core", .mod = ui_core_mod },
        .{ .name = "ui_widgets", .mod = ui_widgets_mod },
        .{ .name = "ui_plume", .mod = ui_plume_mod },
        .{ .name = "document", .mod = mods.editor_document_mod },
        .{ .name = "panels", .mod = mods.editor_panels_mod },
        .{ .name = "render_3d", .mod = render_3d_mod },
        .{ .name = "scene", .mod = scene_mod },
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
        .{ .name = "picking", .mod = picking_mod },
        .{ .name = "log", .mod = log_mod },
        .{ .name = "remote", .mod = remote_mod },
    }, null);

    addModuleTest(b, test_step, "apps/editor/tests/remote_adapter_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "window", .mod = window_mod },
        .{ .name = "graphics", .mod = graphics_mod },
        .{ .name = "ui_core", .mod = ui_core_mod },
        .{ .name = "dev_tools", .mod = dev_tools_mod },
        .{ .name = "picking", .mod = picking_mod },
        .{ .name = "remote", .mod = remote_mod },
        .{ .name = "editor_shell", .mod = editor_shell_mod },
        .{ .name = "remote_adapter", .mod = editor_remote_adapter_mod },
        .{ .name = "document", .mod = mods.editor_document_mod },
        .{ .name = "render_3d", .mod = render_3d_mod },
        .{ .name = "scene", .mod = scene_mod },
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

    // Pure-logic parts of the PBR renderer (no GPU needed).
    for ([_][]const u8{
        "packages/render/3d/src/gpu/pbr/volumetric_lights.zig",
        "packages/render/3d/src/gpu/pbr/shadow_cull.zig",
        "packages/render/3d/src/gpu/pbr/shadow_plan.zig",
        "packages/render/3d/src/gpu/pbr/screen_transport.zig",
    }) |path| addModuleTest(b, test_step, path, target, optimize, false, &.{}, null);
    addModuleTest(b, test_step, "packages/render/3d/src/gpu/pbr/gpu_timing.zig", target, optimize, false, &.{
        .{ .name = "graphics", .mod = graphics_mod },
    }, null);
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
        .{ .name = "render_3d", .mod = render_3d_mod },
        .{ .name = "dev_tools", .mod = dev_tools_mod },
        .{ .name = "prism", .mod = prism_mod },
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
