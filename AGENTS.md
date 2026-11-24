# `zigeng` Agent Guidelines

`zigeng` is a headless-first, modular 2D/3D game engine written in **Zig `0.17.1`** (pinned in `build.zig.zon`).

## Core Architecture Rules

- **Strict unidirectional dependency**: `src/core/` (`@import("engine")`) **never** imports anything from `packages/`, SDL, GPU drivers, UI, or scripting VMs.
- **Capabilities before implementations**: Core defines `App`, `World`, `Scheduler`, `EventBus`, `ResourceRegistry`, `ServiceRegistry`, and `ModuleGraph`. Contracts (`window`, `graphics`, `physics`, `scripting-host`, `ui-core`) define interfaces/vtables; providers (`window-sdl3`, `graphics-sdlgpu`, `physics-jolt`, `physics-rapier`, `scripting-lua`, `scripting-python`) implement them without leaking backend internals.
- **Headless-first**: All core simulation and tests must run deterministically without a window or GPU.

## Toolchain & Verification

- Use **Zig `0.17.1`** for all builds and tests.
- Primary verification commands:
  - `zig build test --summary all` (and `-Doptimize=ReleaseSafe`)
  - `zig build run-headless`
  - `zig build run-cli`, `zig build run-cli -Dcli-cmd=packages`, `zig build run-cli -Dcli-cmd=test-scenario`
  - `zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe --summary all`
  - Sandbox CLI/plugin tests: `project.bat <project>` (Windows) or `sh project.sh <project>` (macOS/Linux) under `projects/`.

## Cross-Platform & Packaging Rules

- **No binaries in git**: Never commit `.dll`, `.dylib`, `.so`, or `.exe` binaries into the repository.
- **SDL3 provisioning**:
  - Windows x64 fetches `SDL3-3.4.20-win32-x64.zip` via `build.zig.zon` (`sdl3_win64`) and `packages/sdl3/zigeng.toml` (`zigeng add`).
  - macOS release archives (`.github/workflows/release.yml`) bundle `libSDL3.0.dylib` beside `zigeng-runtime`, rewrite its dependency to `@executable_path/libSDL3.0.dylib` via `install_name_tool`, and re-sign both binaries with `codesign --force --sign -`. Native `zig build` of visual targets on macOS/Linux links the system SDL3 (`brew install sdl3` on macOS) because upstream SDL3 distributes macOS binaries as a `.dmg` that `zig fetch` cannot unpack.
- **GitHub Actions runners**: `macos-14` was retired by GitHub on November 2, 2026. Always use `macos-15` (or newer) for macOS workflows.
- **Cross-platform CLI (`tools/cli/`)**: Prefer `std.process.run` with explicit `argv`; when shell commands are unavoidable, handle `cmd.exe` vs `sh -c` explicitly (e.g., never pass `mkdir -p` to `cmd.exe`).

## C ABI Boundary (`include/engine_extension.h`)

- Validate `struct_size` and `abi_major` (`AE_ABI_MAJOR` = 1) before reading extended fields.
- `AE_ABI_MINOR` updates must be append-only.
- `AEStringView` is not guaranteed to be NUL-terminated; always use `length`.
- Memory ownership never crosses the ABI implicitly; no C++ exceptions, Zig panics, or `longjmp` across plugin calls.

## Workspace Skills (`.agents/skills/`)

Load the relevant skill before making changes in these areas:
- `.agents/skills/sdl3-cross-platform/SKILL.md` — SDL3 linking, `packages/sdl3/zigeng.toml`, and macOS/Windows/Linux release bundling.
- `.agents/skills/zigeng-architecture-and-packages/SKILL.md` — Module boundaries, `packages/` layout, and adding new official packages.
- `.agents/skills/zigeng-cli-and-plugins/SKILL.md` — `zigeng` CLI (`game.toml` and `build.zig.zon` hooks), `--fork`, and sandbox tests.
- `.agents/skills/zigeng-c-abi-and-ffi/SKILL.md` — `include/engine_extension.h` contract and `c_plugin` verification.
- `.agents/skills/zigeng-build-ci-and-release/SKILL.md` — Build steps, CI workflows, and `v*` release tagging.
