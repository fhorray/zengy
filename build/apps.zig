//! Applications: the manifest-driven `zengy-runtime` executable and the `zengy-editor` MVP editor.

const std = @import("std");
const Modules = @import("modules.zig").Modules;

/// Adds the `zengy-runtime` and `zengy-editor` executables.
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
    const graphics_wgpu_mod = mods.graphics_wgpu_mod;
    const draw_2d_mod = mods.draw_2d_mod;
    const wgpu_missing = mods.wgpu_missing;
    const gpu_3d_mod = mods.gpu_3d_mod;
    const input_mod = mods.input_mod;
    const input_sdl3_mod = mods.input_sdl3_mod;
    const camera_mod = mods.camera_mod;
    const render_3d_mod = mods.render_3d_mod;
    const gizmos_mod = mods.gizmos_mod;
    const shapes_mod = mods.shapes_mod;
    const dev_tools_mod = mods.dev_tools_mod;
    const picking_mod = mods.picking_mod;
    const editor_document_mod = mods.editor_document_mod;

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
    runtime_mod.addImport("graphics_wgpu", graphics_wgpu_mod);
    runtime_mod.addImport("draw_2d", draw_2d_mod);
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
    if (wgpu_missing) |fail| runtime_exe.step.dependOn(&fail.step) else b.installArtifact(runtime_exe);

    // Minimal scene editor (`apps/editor/src/main.zig`). Run with `zig build run-editor`.
    const editor_mod = b.createModule(.{
        .root_source_file = b.path("apps/editor/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    editor_mod.addImport("engine", engine_mod);
    editor_mod.addImport("window_sdl3", window_sdl3_mod);
    editor_mod.addImport("graphics", graphics_mod);
    editor_mod.addImport("graphics_wgpu", graphics_wgpu_mod);
    editor_mod.addImport("draw_2d", draw_2d_mod);
    editor_mod.addImport("gpu_3d", gpu_3d_mod);
    editor_mod.addImport("input", input_mod);
    editor_mod.addImport("input_sdl3", input_sdl3_mod);
    editor_mod.addImport("ui_core", ui_core_mod);
    editor_mod.addImport("camera", camera_mod);
    editor_mod.addImport("render_3d", render_3d_mod);
    editor_mod.addImport("gizmos", gizmos_mod);
    editor_mod.addImport("shapes", shapes_mod);
    editor_mod.addImport("dev_tools", dev_tools_mod);
    editor_mod.addImport("picking", picking_mod);
    editor_mod.addImport("document", editor_document_mod);

    const editor_exe = b.addExecutable(.{
        .name = "zengy-editor",
        .root_module = editor_mod,
    });
    if (wgpu_missing) |fail| editor_exe.step.dependOn(&fail.step) else b.installArtifact(editor_exe);

    // Run the installed binary so SDL3/wgpu DLLs beside zig-out/bin are found (cache copy fails on Windows).
    const editor_bin = if (target.result.os.tag == .windows) "zig-out/bin/zengy-editor.exe" else "zig-out/bin/zengy-editor";
    const run_editor = b.addSystemCommand(&.{editor_bin});
    run_editor.setCwd(b.path("."));
    run_editor.step.dependOn(b.getInstallStep());
    if (wgpu_missing) |fail| run_editor.step.dependOn(&fail.step);
    const run_editor_step = b.step("run-editor", "Open the zengy-editor MVP scene editor");
    run_editor_step.dependOn(&run_editor.step);
}
