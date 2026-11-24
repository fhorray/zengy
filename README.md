# Zig Modular Engine (`zengy`)

**`zengy` is a headless-first, modular 2D/3D engine written in Zig.**  
Start with a tiny, fast simulation core—then plug in only the capabilities your game, tool, or server actually needs.

---

## Why "Headless-First"?

Most game engines force every project to carry a window manager, GPU driver, UI toolkit, and scripting runtime—even when you just want to run a dedicated server, a simulation, or automated tests.

`zengy` flips that model:

1. **The Core is 100% Headless (`engine`)**  
   Out of the box, you get an Entity Component System (ECS), a deterministic frame/fixed-timestep loop, events, resources, and diagnostics—with **zero** dependencies on SDL, GPUs, UI, or scripting languages.
2. **Everything Else is Optional & Replaceable**  
   Want to open a window and draw 2D sprites or 3D meshes? Register the visual modules. Want to run the exact same game logic on a Linux server or in CI? Leave the visual modules out.
3. **No Lock-In**  
   Official packages (SDL3 windowing, SDL_GPU rendering, 2D/3D renderers, UI, Lua, PocketPy/Python) are just regular plugins. You can omit them, mix and match them, or write your own in Zig or via the C ABI (`include/engine_extension.h`).

---

## Quick Start

### Option A — Download Prebuilt Binaries
Check the **Releases** page on GitHub for prebuilt `Windows x64` and `Linux x64` bundles (see [Releasing & Distribution](docs/releasing.md)).

### Option B — Build from Source
Requires **Zig `0.17.1`**:

```bash
git clone https://github.com/fhorray/zigeng.git
cd zengy

# Verify everything works
zig build test

# Try a headless 1,000-entity simulation (no window/GPU required)
zig build run-headless

# Try the visual demos (Windows x64 SDL3 bundled; Linux/macOS require system SDL3)
zig build run-visual-2d          # 2D sprites, camera & mouse/WASD controls
zig build run-visual-ui          # UI panels, buttons, text input & scrolling
zig build run-visual-3d          # 3D meshes, depth buffer & camera movement
zig build run-visual-playground  # Combined 2D scene + interactive UI overlay
zig build run-visual-python      # Optional PocketPy (Python) script drawing on GPU
```

---

## Your First `zengy` App

A minimal headless simulation takes only a few lines of Zig:

```zig
const std = @import("std");
const engine = @import("engine");

const Position = struct { x: f32, y: f32 };
const Velocity = struct { dx: f32, dy: f32 };

fn moveSystem(ctx: *engine.SystemContext) !void {
    var q = try ctx.query(.{ .write = .{Position}, .read = .{Velocity} });
    defer q.deinit();

    while (q.next()) |row| {
        const pos = row.write(Position);
        const vel = row.read(Velocity);
        pos.x += vel.dx * ctx.dt;
        pos.y += vel.dy * ctx.dt;
    }
}

pub fn main() !void {
    var app = engine.App.init(std.heap.page_allocator, .{ .max_frames = 60 });
    defer app.deinit();

    _ = try app.registerComponent(Position);
    _ = try app.registerComponent(Velocity);
    try app.scheduler.addSystem(.{ .name = "move", .stage = .update, .run = moveSystem });

    const player = try app.world.spawn();
    try app.world.set(player, Position, .{ .x = 0, .y = 0 });
    try app.world.set(player, Velocity, .{ .dx = 10, .dy = 5 });

    try app.run(); // Runs 60 deterministic frames headlessly
}
```

When you are ready to add graphics, simply register the optional modules you want (for example `window_sdl3`, `graphics_sdlgpu`, `render_2d`, `render_3d`, or `ui_core`)—your `moveSystem` and components stay unchanged.

---

## Available Building Blocks (All Optional)

| What you want to add | Official Package(s) | Notes |
|---|---|---|
| **Native Window & Input** | `window-sdl3` (or `window` for headless) | Resizable window, DPI scaling, keyboard, mouse, text input |
| **GPU Rendering** | `graphics-sdlgpu` (or `graphics` for headless) | SDL_GPU (Vulkan/SPIR-V) with 2D batching, scissor clipping & 3D depth |
| **2D Scenes & Sprites** | `scene` + `render-2d` | `Transform2D`, `Camera2D`, `Sprite`, `Visibility`, layer sorting |
| **3D Scenes & glTF** | `render-3d` | `Transform3D`, `Camera3D`, `MeshRef`, glTF 2.0 loader, frustum culling |
| **UI & Text** | `ui-core`, `ui-markup`, `text` | Retained flex layout, HTML-like markup, clickable buttons, textboxes |
| **Scripting** | `scripting-host` + `scripting-lua` or `scripting-python` | Bring your own language, or opt into Lua 5.4 / PocketPy (Python) |
| **C / Native Plugins** | `include/engine_extension.h` | Load `.dll` / `.so` / `.dylib` plugins dynamically at runtime |
| **Automated Testing** | `testing` + `zengy` CLI | Deterministic TOML scenarios & offscreen framebuffer capture |

### Zero-Boilerplate Projects with `zengy` CLI

If you want to configure a project with an agnostic `game.toml` (without writing Zig boilerplate or forcing a specific scripting language or UI template), download a Release bundle and use the `zengy` CLI:

```bash
# Create a minimal agnostic project (game.toml)
zengy new my-game
cd my-game
zengy install
zengy run

# Or install individual official packages into ./packages/ for custom Zig builds
zengy list-official
zengy add physics
```

---

## Documentation & Next Steps

- **[Getting Started Guide](docs/getting-started.md)** — Setup, running demos, and composing headless vs visual apps
- **[Package Catalog](packages/README.md)** — Overview of every optional module
- **[Scripting with Python (PocketPy)](packages/scripting/python/README.md)** — Optional Python scripting guide
- **[Releasing & Distribution](docs/releasing.md)** — How CI builds and publishes releases
- **[Full Documentation Index](docs/README.md)** — API reference, architecture plan, and ADRs
