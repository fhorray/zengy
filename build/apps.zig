//! Applications: the manifest-driven `zengy-runtime` executable.

const std = @import("std");
const Modules = @import("modules.zig").Modules;

/// Adds the `zengy-runtime` executable.
pub fn add(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, mods: Modules) void {
    const engine_mod = mods.engine_mod;
    const window_mod = mods.window_mod;
    const graphics_mod = mods.graphics_mod;
    const ui_core_mod = mods.ui_core_mod;
    const ui_markup_mod = mods.ui_markup_mod;
    const scripting_host_mod = mods.scripting_host_mod;
    const scene_mod = mods.scene_mod;
    const physics_mod = mods.physics_mod;
    const toml_format_mod = mods.toml_format_mod;
    const scripting_lua_mod = mods.scripting_lua_mod;
    const scripting_python_mod = mods.scripting_python_mod;
    const window_sdl3_mod = mods.window_sdl3_mod;
    const graphics_sdlgpu_mod = mods.graphics_sdlgpu_mod;

    // Manifesto-driven visual runtime (`apps/runtime/src/main.zig`): reads game.toml in CWD.
    const runtime_mod = b.createModule(.{
        .root_source_file = b.path("apps/runtime/src/main.zig"),
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
}
