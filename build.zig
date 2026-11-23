// Build script for the Modular Zig Engine (`zigeng`).
//
// Targets:
// - `engine`: Minimal headless core SDK module (`src/engine.zig`)
// - `headless-ecs`: Phase 1 standalone 1000-entity simulation (`zig build run-headless`)
// - `c_plugin`: Phase 3 pure C11 shared library plugin (`examples/c-plugin/plugin.c`)
// - Optional packages: `window`, `graphics`, `ui_core`, `ui_markup`, `ui_novaui`,
//   `ui_immediate`, `scripting_host`, `assets`, `scene`, `editor_shell`, `render_3d`
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
        .root_source_file = b.path("packages/window/src/window.zig"),
        .target = target,
        .optimize = optimize,
    });
    window_mod.addImport("engine", engine_mod);

    const graphics_mod = b.addModule("graphics", .{
        .root_source_file = b.path("packages/graphics/src/graphics.zig"),
        .target = target,
        .optimize = optimize,
    });
    graphics_mod.addImport("engine", engine_mod);

    const ui_core_mod = b.addModule("ui_core", .{
        .root_source_file = b.path("packages/ui-core/src/ui_core.zig"),
        .target = target,
        .optimize = optimize,
    });
    ui_core_mod.addImport("engine", engine_mod);
    ui_core_mod.addImport("graphics", graphics_mod);

    const ui_markup_mod = b.addModule("ui_markup", .{
        .root_source_file = b.path("packages/ui-markup/src/ui_markup.zig"),
        .target = target,
        .optimize = optimize,
    });
    ui_markup_mod.addImport("ui_core", ui_core_mod);

    const ui_novaui_mod = b.addModule("ui_novaui", .{
        .root_source_file = b.path("packages/ui-novaui/src/novaui.zig"),
        .target = target,
        .optimize = optimize,
    });
    ui_novaui_mod.addImport("ui_core", ui_core_mod);

    const ui_immediate_mod = b.addModule("ui_immediate", .{
        .root_source_file = b.path("packages/ui-immediate/src/ui_immediate.zig"),
        .target = target,
        .optimize = optimize,
    });
    ui_immediate_mod.addImport("engine", engine_mod);
    ui_immediate_mod.addImport("window", window_mod);
    ui_immediate_mod.addImport("graphics", graphics_mod);

    const scripting_host_mod = b.addModule("scripting_host", .{
        .root_source_file = b.path("packages/scripting-host/src/scripting_host.zig"),
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

    const render_3d_mod = b.addModule("render_3d", .{
        .root_source_file = b.path("packages/render-3d/src/render_3d.zig"),
        .target = target,
        .optimize = optimize,
    });
    render_3d_mod.addImport("engine", engine_mod);

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

    const cli_exe = b.addExecutable(.{
        .name = "engine-cli",
        .root_module = cli_mod,
    });
    b.installArtifact(cli_exe);

    const run_cli = b.addRunArtifact(cli_exe);
    const cli_cmd = b.option([]const u8, "cli-cmd", "CLI subcommand (doctor, packages)") orelse "doctor";
    run_cli.addArg(cli_cmd);
    const run_cli_step = b.step("run-cli", "Run the engine diagnostic CLI (doctor, packages)");
    run_cli_step.dependOn(&run_cli.step);

    // Integrated Playground project (`projects/playground`)
    const playground_mod = b.createModule(.{
        .root_source_file = b.path("projects/playground/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    playground_mod.addImport("engine", engine_mod);
    playground_mod.addImport("window", window_mod);
    playground_mod.addImport("graphics", graphics_mod);
    playground_mod.addImport("ui_core", ui_core_mod);
    playground_mod.addImport("ui_markup", ui_markup_mod);
    playground_mod.addImport("ui_novaui", ui_novaui_mod);
    playground_mod.addImport("scripting_host", scripting_host_mod);
    playground_mod.addImport("assets", assets_mod);
    playground_mod.addImport("scene", scene_mod);
    playground_mod.addImport("editor_shell", editor_shell_mod);
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
        .name = "zigeng-bench",
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

    addModuleTest(b, test_step, "src/core/tests/core_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
    }, null);

    addModuleTest(b, test_step, "src/core/tests/abi_tests.zig", target, optimize, true, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "c_abi", .mod = c_abi_mod },
    }, &install_c_plugin.step);

    addModuleTest(b, test_step, "packages/window/tests/window_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "window", .mod = window_mod },
    }, null);

    addModuleTest(b, test_step, "packages/graphics/tests/graphics_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "window", .mod = window_mod },
        .{ .name = "graphics", .mod = graphics_mod },
    }, null);

    addModuleTest(b, test_step, "packages/ui-core/tests/ui_core_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "window", .mod = window_mod },
        .{ .name = "graphics", .mod = graphics_mod },
        .{ .name = "ui_core", .mod = ui_core_mod },
    }, null);

    addModuleTest(b, test_step, "packages/ui-markup/tests/ui_frontends_tests.zig", target, optimize, false, &.{
        .{ .name = "ui_core", .mod = ui_core_mod },
        .{ .name = "ui_markup", .mod = ui_markup_mod },
        .{ .name = "ui_novaui", .mod = ui_novaui_mod },
    }, null);

    addModuleTest(b, test_step, "packages/ui-immediate/tests/ui_immediate_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "window", .mod = window_mod },
        .{ .name = "graphics", .mod = graphics_mod },
        .{ .name = "ui_immediate", .mod = ui_immediate_mod },
    }, null);

    addModuleTest(b, test_step, "packages/scripting-host/tests/scripting_host_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "scripting_host", .mod = scripting_host_mod },
    }, null);

    addModuleTest(b, test_step, "packages/assets/tests/assets_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "assets", .mod = assets_mod },
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

    addModuleTest(b, test_step, "packages/render-3d/tests/render_3d_tests.zig", target, optimize, false, &.{
        .{ .name = "engine", .mod = engine_mod },
        .{ .name = "window", .mod = window_mod },
        .{ .name = "graphics", .mod = graphics_mod },
        .{ .name = "render_3d", .mod = render_3d_mod },
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
}
