// Build script for the Modular Zig Engine (`zigeng`).
//
// Targets:
// - `engine`: Minimal headless core SDK module (`src/engine.zig`)
// - `headless-ecs`: Phase 1 standalone 1000-entity simulation (`zig build run-headless`)
// - `c_plugin`: Phase 3 pure C11 shared library plugin (`examples/c-plugin/plugin.c`)
// - Optional packages: `window`, `graphics`, `ui_core`, `ui_markup`, `ui_novaui`,
//   `ui_immediate`, `scripting_host`, `assets`, and CLI tools.
// - `test`: Full unit, integration, and C ABI layout test suite (`zig build test`)

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

    // Unit, integration, and ABI compatibility tests
    const test_mod = b.createModule(.{
        .root_source_file = b.path("tests/core_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport("engine", engine_mod);
    test_mod.addImport("c_abi", c_abi_mod);

    const tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(tests);
    run_tests.step.dependOn(&install_c_plugin.step);

    // Optional packages (Phases 5, 6, 7, 9, 10)
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

    const pkg_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/packages_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    pkg_test_mod.addImport("engine", engine_mod);
    pkg_test_mod.addImport("window", window_mod);
    pkg_test_mod.addImport("graphics", graphics_mod);
    pkg_test_mod.addImport("ui_core", ui_core_mod);
    pkg_test_mod.addImport("ui_markup", ui_markup_mod);
    pkg_test_mod.addImport("ui_novaui", ui_novaui_mod);
    pkg_test_mod.addImport("ui_immediate", ui_immediate_mod);
    pkg_test_mod.addImport("scripting_host", scripting_host_mod);
    pkg_test_mod.addImport("assets", assets_mod);

    const pkg_tests = b.addTest(.{
        .root_module = pkg_test_mod,
    });
    const run_pkg_tests = b.addRunArtifact(pkg_tests);

    const test_step = b.step("test", "Run all unit, integration, and C ABI tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_pkg_tests.step);
}
