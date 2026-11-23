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

    const test_step = b.step("test", "Run all unit, integration, and C ABI tests");
    test_step.dependOn(&run_tests.step);
}
