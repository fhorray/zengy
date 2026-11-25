//! Official package catalog (`zengy add <name>` / `list-official`): public names, entry files and directories.

const std = @import("std");

pub const OfficialPackageInfo = struct {
    name: []const u8,
    entry: []const u8,
    summary: []const u8,
    third_party: ?[]const u8 = null,
};

pub const OFFICIAL_PACKAGES = [_]OfficialPackageInfo{
    .{ .name = "window", .entry = "src/window.zig", .summary = "Headless window & input service" },
    .{ .name = "window-sdl3", .entry = "src/window_sdl3.zig", .summary = "Native SDL3 window & input", .third_party = "sdl3" },
    .{ .name = "graphics", .entry = "src/graphics.zig", .summary = "Headless graphics device & DrawCommand" },
    .{ .name = "graphics-sdlgpu", .entry = "src/graphics_sdlgpu.zig", .summary = "SDL_GPU (Vulkan/SPIR-V) 2D/3D backend", .third_party = "sdl3" },
    .{ .name = "scene", .entry = "src/scene.zig", .summary = "2D transform hierarchy & SceneSnapshot" },
    .{ .name = "prefab", .entry = "src/prefab.zig", .summary = "Portable prefab IR, overrides & atomic batch instantiation" },
    .{ .name = "physics", .entry = "src/physics.zig", .summary = "Agnostic ECS physics contract & PhysicsBackendVTable" },
    .{ .name = "physics-jolt", .entry = "src/physics_jolt.zig", .summary = "JoltPhysics v5.7.0 3D solver backend" },
    .{ .name = "physics-rapier", .entry = "src/physics_rapier.zig", .summary = "Rapier3D (Rust) solver backend (requires cargo/rustc)" },
    .{ .name = "render-2d", .entry = "src/render_2d.zig", .summary = "Sprite, Visibility & 2D batch extraction (uses camera)" },
    .{ .name = "render-3d", .entry = "src/render_3d.zig", .summary = "3D math, MeshRef, glTF 2.0 & frustum culling (uses camera)" },
    .{ .name = "gizmos", .entry = "src/gizmos.zig", .summary = "Immediate-mode 3D debug & editor gizmos (uses camera)" },
    .{ .name = "shapes", .entry = "src/shapes.zig", .summary = "Procedural 3D primitives (Plane, Cuboid, Sphere, Capsule, Cylinder, Torus, Cone) with UVs & tangents" },
    .{ .name = "dev-tools", .entry = "src/dev_tools.zig", .summary = "Per-pass frame profiler and developer telemetry" },
    .{ .name = "picking", .entry = "src/picking.zig", .summary = "Unified UI/2D/3D pointer picking & InputFocus" },
    .{ .name = "remote", .entry = "src/remote.zig", .summary = "JSON-RPC 2.0 remote ECS & profiler inspector" },
    .{ .name = "log", .entry = "src/log.zig", .summary = "Configurable subsystem log filtering & pluggable sinks" },
    .{ .name = "camera", .entry = "src/camera.zig", .summary = "Unified 2D/3D Camera, Projection, Viewport, RenderTarget & FreeCamera" },
    .{ .name = "input", .entry = "src/input.zig", .summary = "Bevy-style KeyCode, ButtonInput, Gamepad/D-Pad, mouse motion & scroll" },
    .{ .name = "input-haptics", .entry = "src/haptics.zig", .summary = "Agnostic controller rumble & trigger haptics contract" },
    .{ .name = "input-sdl3", .entry = "src/input_sdl3.zig", .summary = "SDL3 Gamepad & DualSense rumble provider", .third_party = "sdl3" },
    .{ .name = "text", .entry = "src/text.zig", .summary = "Embedded 8x8 ASCII bitmap font atlas" },
    .{ .name = "ui-core", .entry = "src/ui_core.zig", .summary = "Retained UiTree, flex layout & hit testing" },
    .{ .name = "ui-markup", .entry = "src/ui_markup.zig", .summary = "HTML-like UI markup parser" },
    .{ .name = "ui-widgets", .entry = "src/ui_widgets.zig", .summary = "Visual-agnostic widget runtime (uses ui-core)" },
    .{ .name = "ui-plume", .entry = "src/ui_plume.zig", .summary = "Plume widget kit & theme (uses ui-widgets)" },
    .{ .name = "scripting-host", .entry = "src/scripting_host.zig", .summary = "Language-agnostic scripting host & bridge" },
    .{ .name = "scripting-lua", .entry = "src/scripting_lua.zig", .summary = "Embedded Lua 5.4 runtime" },
    .{ .name = "scripting-python", .entry = "src/scripting_python.zig", .summary = "Embedded PocketPy (Python) runtime" },
    .{ .name = "assets", .entry = "src/assets.zig", .summary = "URI-cached asset registry" },
    .{ .name = "testing", .entry = "src/testing_sdk.zig", .summary = "Deterministic TestDriver & CaptureService" },
    .{ .name = "default-plugins", .entry = "src/default_plugins.zig", .summary = "Curated bundle of official modules" },
};

pub fn findOfficialPackage(name: []const u8) ?OfficialPackageInfo {
    for (OFFICIAL_PACKAGES) |pkg| {
        if (std.mem.eql(u8, pkg.name, name)) return pkg;
    }
    return null;
}

/// Directory of an official package below `packages/`. Related packages are grouped by category
/// (`physics/jolt`, `ui/core`, ...); the public package name (`physics-jolt`) never changes.
pub fn packageDir(name: []const u8) []const u8 {
    const dirs = [_]struct { []const u8, []const u8 }{
        .{ "physics", "physics/core" },
        .{ "physics-jolt", "physics/jolt" },
        .{ "physics-rapier", "physics/rapier" },
        .{ "ui-core", "ui/core" },
        .{ "ui-markup", "ui/markup" },
        .{ "ui-widgets", "ui/widgets" },
        .{ "ui-plume", "ui/plume" },
        .{ "window", "window/core" },
        .{ "window-sdl3", "window/sdl3" },
        .{ "input", "input/core" },
        .{ "input-haptics", "input/haptics" },
        .{ "input-sdl3", "input/sdl3" },
        .{ "graphics", "graphics/core" },
        .{ "graphics-sdlgpu", "graphics/sdlgpu" },
        .{ "scripting-host", "scripting/host" },
        .{ "scripting-lua", "scripting/lua" },
        .{ "scripting-python", "scripting/python" },
        .{ "render-2d", "render/2d" },
        .{ "render-3d", "render/3d" },
        .{ "text", "render/text" },
        .{ "testing", "testing" },
    };
    for (dirs) |e| {
        if (std.mem.eql(u8, e[0], name)) return e[1];
    }
    return name;
}
