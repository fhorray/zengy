// Build script for the Modular Zengy Engine.
//
// Targets:
// - `engine`: Minimal headless core SDK module (`src/engine.zig`)
// - `headless-ecs`: Phase 1 standalone 1000-entity simulation (`zig build run-headless`)
// - `c_plugin`: Phase 3 pure C11 shared library plugin (`examples/c-plugin/plugin.c`)
// - Optional packages: `window`, `graphics`, `ui_core`, `ui_markup`,
//   `scripting_host`, `assets`, `scene`, `render_3d`
// - Applications: `zengy-runtime` (`apps/runtime/src/main.zig`); the editor shell is an app-local module (`apps/editor`)
// - `engine-cli`: Diagnostic CLI (`zig build run-cli`)
// - `test`: Per-module test suites organized inside each module's `tests/` directory
//
// Layout: `build/modules.zig` (module graph), `build/examples.zig`, `build/tools.zig`,
// `build/apps.zig`, `build/tests.zig`.

const std = @import("std");
const modules = @import("build/modules.zig");
const examples = @import("build/examples.zig");
const tools = @import("build/tools.zig");
const apps = @import("build/apps.zig");
const tests = @import("build/tests.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mods = modules.create(b, target, optimize);
    const example_steps = examples.add(b, target, optimize, mods);
    tools.add(b, target, optimize, mods);
    apps.add(b, target, optimize, mods);
    tests.add(b, target, optimize, mods, example_steps);
}
