---
name: zengy-architecture-and-packages
description: >-
  Architectural boundaries, module/capability/provider contracts, and package
  layout rules for zengy. Use when adding or modifying core modules, official
  packages under packages/, or capability interfaces.
---

# `zengy` Architecture & Package Layout

## Non-Negotiable Architectural Rules

1. **Unidirectional dependency**: `src/core/` (`@import("engine")`) **never** imports anything from `packages/`. All higher-level features (windowing, GPU, physics, UI, scripting, rendering, assets, formats) live in `packages/` as optional modules.
2. **Capabilities before implementations**: Core defines `App`, `World`, `Scheduler`, `EventBus`, `ResourceRegistry`, `ServiceRegistry`, and `ModuleGraph`. Contracts (`window`, `graphics`, `physics`, `scripting-host`, `ui-core`) define capabilities/vtables; concrete providers (`window-sdl3`, `graphics-sdlgpu`, `physics-jolt`, `physics-rapier`, `scripting-lua`, `scripting-python`) implement them without leaking backend types into core or game logic.
3. **Headless-first**: Any game or test must run deterministically without a window or GPU when visual modules are omitted.

## Package Directory Layout vs Public Names

Related packages are grouped under category subdirectories in `packages/`, while public CLI names remain flat and hyphenated:

- `physics`: `physics` (`packages/physics/core`), `physics-jolt` (`packages/physics/jolt`), `physics-rapier` (`packages/physics/rapier`)
- `window`: `window` (`packages/window/core`), `window-sdl3` (`packages/window/sdl3`)
- `graphics`: `graphics` (`packages/graphics/core`), `graphics-sdlgpu` (`packages/graphics/sdlgpu`)
- `render`: `render-2d` (`packages/render/2d`), `render-3d` (`packages/render/3d`), `text` (`packages/render/text`)
- `ui`: `ui-core` (`packages/ui/core`), `ui-markup` (`packages/ui/markup`)
- `scripting`: `scripting-host` (`packages/scripting/host`), `scripting-lua` (`packages/scripting/lua`), `scripting-python` (`packages/scripting/python`)
- `formats` / `tooling`: `formats/toml`, `formats/json`, `tooling/file-watcher`
- Flat: `assets`, `scene`, `editor-shell`, `testing`, `default-plugins`, `sdl3`

## Checklist When Adding a New Official Package

1. Create `packages/<category>/<name>/src/`, `tests/`, and `README.md`.
2. Register the module and its test suite in `build.zig` (`addModuleTest` in the `test` step).
3. Register its public name, entry file, and summary in `OFFICIAL_PACKAGES` and `packageDir()` inside `tools/cli/main.zig`.
4. Document the package and its capability ID in `packages/README.md`.
5. If the package requires external platform artifacts in a user's `build.zig` project, add a validated `zengy.toml` manifest (see `tools/cli/pkg_manifest.zig`).
