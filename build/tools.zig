//! Developer tools: the `zengy` CLI and the microbenchmark suite.

const std = @import("std");
const Modules = @import("modules.zig").Modules;

/// Adds the CLI (`cli`, `run-cli`) and benchmark (`run-bench`) targets.
pub fn add(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, mods: Modules) void {
    const engine_mod = mods.engine_mod;
    const window_mod = mods.window_mod;
    const graphics_mod = mods.graphics_mod;
    const ui_core_mod = mods.ui_core_mod;
    const scripting_host_mod = mods.scripting_host_mod;
    const assets_mod = mods.assets_mod;
    const scene_mod = mods.scene_mod;
    const toml_format_mod = mods.toml_format_mod;
    const json_format_mod = mods.json_format_mod;
    const testing_sdk_mod = mods.testing_sdk_mod;

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
}
