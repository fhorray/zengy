# Getting Started with `zengy`

This guide walks you through setting up `zengy`, running the built-in examples, composing your own headless or visual application, and using `engine-cli`.

## 1. Prerequisites

- **Zig `0.17.1`** (pinned in [`build.zig.zon`](../build.zig.zon)).
- **Visual demos on Windows x64**: SDL 3.4.20 headers and `SDL3.lib` are vendored in `packages/sdl3/`. Place `SDL3.dll` in `packages/sdl3/bin/x64/SDL3.dll` (or next to the `.exe` in `zig-out/bin/`). A Vulkan-capable GPU driver is required for the SPIR-V `SDL_GPU` backend.
- **Linux / macOS**: Headless builds and `zig build test` work out of the box. Native visual builds on Linux/macOS require installing SDL3 system libraries.

## 2. Verify Your Environment

```bash
# Run all 50+ test steps (core, C ABI, packages, scripting, 2D/3D, text)
zig build test --summary all

# Cross-compile all Windows visual executables from Linux/macOS
zig build -Dtarget=x86_64-windows --summary all

# Run the diagnostic CLI
zig build run-cli
zig build run-cli -Dcli-cmd=packages
zig build run-cli -Dcli-cmd=test-scenario
```

## 3. Composing an Application

### Minimal Headless App (no SDL / GPU)

```zig
const std = @import("std");
const engine = @import("engine");

const Velocity = struct { dx: f32, dy: f32 };

fn moveSystem(ctx: *engine.SystemContext) !void {
    var q = try ctx.query(.{ .read = .{Velocity} });
    defer q.deinit();
    while (q.next()) |row| {
        const v = row.read(Velocity);
        _ = v;
    }
}

pub fn main() !void {
    var app = engine.App.init(std.heap.page_allocator, .{ .max_frames = 10 });
    defer app.deinit();

    _ = try app.registerComponent(Velocity);
    try app.scheduler.addSystem(.{ .name = "move", .stage = .update, .run = moveSystem });

    const e = try app.world.spawn();
    try app.world.set(e, Velocity, .{ .dx = 1.0, .dy = 0.0 });

    try app.run();
}
```

### Visual 2D / UI / 3D App

Register `window_sdl3.module()` and `graphics_sdlgpu.module()` instead of their headless counterparts, then hand the OS loop to `window_sdl3.runVisualLoop(&app)`:

```zig
try app.registerModule(window_sdl3.module());
try app.registerModule(graphics_sdlgpu.module());
try app.registerModule(scene.module());
try app.registerModule(render_2d.module());
try app.registerModule(ui_core.module());

try app.resources.insert(window_sdl3.WindowConfig, .{
    .title = "My Zengy Game",
    .width = 1280,
    .height = 720,
    .resizable = true,
});

try app.initialize();
try window_sdl3.runVisualLoop(&app);
```

## 4. Next Reading

- [Package Catalog](../packages/README.md)
- [PocketPy Python Scripting]( ../packages/scripting/python/README.md)
- [SDL_GPU Backend](../packages/graphics/sdlgpu/README.md)
- [2D Renderer](../packages/render/2d/README.md) & [3D Renderer](../packages/render/3d/README.md)
- [Releasing & Distribution Guide](releasing.md)
