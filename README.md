# Zig Modular Engine (`zigeng`)

A modular, extensible 2D/3D game & application engine written in Zig (`0.17.1`) with a **minimal headless core**, capability-based `ModuleRegistry` & `ServiceRegistry`, generational ECS facade, deterministic `Scheduler`, runtime reflection, C11 ABI (`include/engine_extension.h`), embedded **Lua 5.4** & **PocketPy (Python)** scripting, and a native **SDL3 + SDL_GPU** visual runtime.

> **Documentation Hub:** See [docs/README.md](docs/README.md) · **Getting Started:** [docs/getting-started.md](docs/getting-started.md) · **Releasing & CI:** [docs/releasing.md](docs/releasing.md)

## Architecture Highlights

- **Minimal Headless Core (`src/core/`)**: `App`, `World` (generational `EntityHandle`, `EntityGuid`), `Scheduler` (stages, topological ordering, conflict/cycle detection, `fixed_update` accumulator), `CommandBuffer`, `EventBus`, `ResourceRegistry`, `Diagnostics`, `TypeRegistry`, and `abi.zig` — **zero** dependencies on SDL, GPU, UI, or scripting VMs.
- **Optional Modular Packages (`packages/`)**: Opt-in capabilities resolved by `ModuleRegistry` and `ServiceRegistry`:
  - **Window & Input**: `window` (headless) and `window-sdl3` (native SDL3 window, DPI scaling, keyboard/mouse/text events).
  - **Graphics**: `graphics` (headless `DrawCommand` device) and `graphics-sdlgpu` (SDL_GPU Vulkan/SPIR-V backend, 2D textured batching, scissor clipping, 3D unlit depth pass).
  - **2D & 3D Rendering**: `scene` (`Transform2D`, `Parent`), `render-2d` (`Camera2D`, `Sprite`, `Visibility`), and `render-3d` (`Transform3D`, `Camera3D`, `MeshRef`, `math3d`, glTF 2.0 importer, 6-plane frustum culling).
  - **Text & UI**: `text` (embedded 8x8 ASCII bitmap font atlas), `ui-core` (retained `UiTree`, flex layout, focus, scroll/clipping), `ui-markup`, `ui-novaui`, `ui-immediate`.
  - **Scripting**: `scripting-host`, `scripting-lua` (Lua 5.4), `scripting-python` (PocketPy v2.2.0 with `engine.draw_rect`).
  - **Tooling & Testing**: `assets`, `formats/toml`, `formats/json`, `file-watcher`, `editor-shell`, `testing` (deterministic `TestDriver` + offscreen `CaptureService`), and `tools/cli` (`engine-cli`).

## Quick Start

Requires **Zig `0.17.1`**.

```bash
# Run all unit, integration, and C ABI tests
zig build test --summary all

# Headless ECS & integrated playground
zig build run-headless
zig build run-playground

# Diagnostic CLI (doctor, packages, test-scenario)
zig build run-cli
zig build run-cli -Dcli-cmd=packages

# Visual SDL3 + SDL_GPU demos (Windows x64 vendored in third_party/sdl3)
zig build run-visual-hello       # Native SDL3 window + DPI + input
zig build run-visual-gpu         # SDL_GPU clear, triangle & rect
zig build run-visual-2d          # 2D sprites, Camera2D, mouse/WASD
zig build run-visual-ui          # Markup UI, text atlas, textbox, clipping
zig build run-visual-playground  # Integrated 2D scene + UI panel + spawn/log
zig build run-visual-python      # PocketPy script driving SDL_GPU rectangles
zig build run-visual-3d          # Phase E 3D cubes, depth buffer & frustum culling
```

## Repository Layout

```text
.
├── build.zig / build.zig.zon
├── include/engine_extension.h   # Stable C11 ABI boundary for native plugins
├── src/                         # Minimal headless core (zero UI/GPU/VM deps)
├── packages/                    # Optional capability packages (see packages/README.md)
├── examples/                    # Headless, C plugin, playground & visual demos
├── tools/cli/                   # engine-cli (doctor, packages, test-scenario)
├── third_party/                 # Vendored PocketPy v2.2.0 and SDL 3.4.20 (Win x64)
├── docs/                        # Guides, API reference, architecture & ADRs
└── .github/workflows/           # CI tests/cross-build & GitHub Release pipeline
```
