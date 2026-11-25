# `zengy` Agent Guidelines

`zengy` is a headless-first, modular 2D/3D game engine written in **Zig `0.17.1`** (pinned in `build.zig.zon`).

## Core Architecture Rules

- **Strict unidirectional dependency**: `src/core/` (`@import("engine")`) **never** imports anything from `packages/`, SDL, GPU drivers, UI, or scripting VMs.
- **Capabilities before implementations**: Core defines `App`, `World`, `Scheduler`, `EventBus`, `ResourceRegistry`, `ServiceRegistry`, and `ModuleGraph`. Contracts (`window`, `graphics`, `physics`, `scripting-host`, `ui-core`) define interfaces/vtables; providers (`window-sdl3`, `graphics-sdlgpu`, `physics-jolt`, `physics-rapier`, `scripting-lua`, `scripting-python`) implement them without leaking backend internals.
- **Agnostic & community-extensible by design**: Every new feature must be designed as an open, extensible contract (capability/vtable, service/resource registry, or C ABI hook) rather than a closed monolith—just like `scripting-host` lets the community plug in any scripting language or `ui-core`/`ui-widgets` lets them build custom UI frontends—so third-party packages can extend, replace, and compose features without modifying core or official providers.
- **Reference ecosystem (`zig-gamedev`)**: When implementing specific Zig gamedev systems, math, audio, physics, or native bindings, consult [`zig-gamedev`](https://github.com/zig-gamedev) packages as a reference before reinventing low-level bindings, while wrapping any chosen dependency behind `zengy`'s agnostic capability contracts.
- **Headless-first**: All core simulation and tests must run deterministically without a window or GPU.

## Repository Layers

- `src/core/` core SDK; `packages/` reusable optional capabilities and providers; `apps/` complete applications (`apps/runtime`, `apps/editor`); `tools/` developer automation (`cli`, `ci`); `examples/`, `projects/`, `benchmarks/`, `tests/` demos, integration sandboxes, perf and fixtures. See `docs/adr/ADR-008-application-package-boundaries.md`.
- **Forbidden reverse dependencies**: core never imports packages; packages never import `apps/`, `tools/`, `examples/` or tests; apps and tools never import each other's sources (launching an executable is fine). Application-specific UI, documents, selection and workflow stay in the application until a concrete reuse need exists; do not create a package just to split a file.
- Run `python3 tools/ci/check_architecture.py` after moving files or changing module wiring in `build.zig`.

## Code & Documentation Style

- **English only**: Keep all repository code, comments, docstrings, documentation, skills, and commit messages in English.
- **Doc comments on public declarations**: Add concise `///` doc comments above `pub const` types, constants, and public functions (brief by default, expanding when contracts, ownership, or invariants warrant detail), plus short inline comments for non-obvious _why_ decisions.

## Code & Documentation Style

- **English only**: Keep all repository code, comments, docstrings, documentation, skills, and commit messages in English.
- **Doc comments on public declarations**: Add concise `///` doc comments above `pub const` types, constants, and public functions (brief by default, expanding when contracts, ownership, or invariants warrant detail), plus short inline comments for non-obvious *why* decisions.

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
  - Windows x64 fetches `SDL3-3.4.20-win32-x64.zip` via `build.zig.zon` (`sdl3_win64`) and `packages/sdl3/zengy.toml` (`zengy add`).
  - macOS release archives (`.github/workflows/release.yml`) bundle `libSDL3.0.dylib` beside `zengy-runtime`, rewrite its dependency to `@executable_path/libSDL3.0.dylib` via `install_name_tool`, and re-sign both binaries with `codesign --force --sign -`. Native `zig build` of visual targets on macOS/Linux links the system SDL3 (`brew install sdl3` on macOS) because upstream SDL3 distributes macOS binaries as a `.dmg` that `zig fetch` cannot unpack.
- **GitHub Actions runners**: `macos-14` was retired by GitHub on November 2, 2026. Always use `macos-15` (or newer) for macOS workflows.
- **Cross-platform CLI (`tools/cli/`)**: Prefer `std.process.run` with explicit `argv`; when shell commands are unavoidable, handle `cmd.exe` vs `sh -c` explicitly (e.g., never pass `mkdir -p` to `cmd.exe`).

## C ABI Boundary (`include/engine_extension.h`)

- Validate `struct_size` and `abi_major` (`AE_ABI_MAJOR` = 1) before reading extended fields.
- `AE_ABI_MINOR` updates must be append-only.
- `AEStringView` is not guaranteed to be NUL-terminated; always use `length`.
- Memory ownership never crosses the ABI implicitly; no C++ exceptions, Zig panics, or `longjmp` across plugin calls.

## Workspace Skills (`.agents/skills/`)

Load the relevant skill before making changes in these areas:

- `.agents/skills/sdl3-cross-platform/SKILL.md` — SDL3 linking, `packages/sdl3/zengy.toml`, and macOS/Windows/Linux release bundling.
- `.agents/skills/zengy-architecture-and-packages/SKILL.md` — Module boundaries, `packages/` layout, and adding new official packages.
- `.agents/skills/zengy-cli-and-plugins/SKILL.md` — `zengy` CLI (`game.toml` and `build.zig.zon` hooks), `--fork`, and sandbox tests.
- `.agents/skills/zengy-c-abi-and-ffi/SKILL.md` — `include/engine_extension.h` contract and `c_plugin` verification.
- `.agents/skills/zengy-build-ci-and-release/SKILL.md` — Build steps, CI workflows, and `v*` release tagging.
- `.agents/skills/zengy-package-versioning/SKILL.md` — SemVer rules for `engine.Module` versions, `zengy.toml`, and capability `/N` bumps.
