---
name: zigeng-cli-and-plugins
description: >-
  Guides development and testing of the zigeng CLI (tools/cli), zigeng-runtime
  (tools/runtime), game.toml projects, zigeng.toml manifests, and sandbox project
  tests. Use when modifying tools/cli/, tools/runtime/, or plugin installation.
---

# `zigeng` CLI, Runtime & Plugin Workflows

`zigeng` supports two distinct user project modes without requiring a clone of the engine repo.

## 1. Manifesto-Driven `game.toml` Projects

- Commands:
  - `zigeng new <name>` — scaffolds a minimal `game.toml` project.
  - `zigeng add <spec>` — installs an official package name, GitHub URL/`owner/repo[@tag]`, or local path; compiles native plugins (Zig or Rust+Zig) into `.zigeng/plugins/` (`.dll` / `.so` / `.dylib`).
  - `zigeng install` (`zigeng i`) — reads `plugins = [...]` from `game.toml` and installs/builds them.
  - `zigeng run` / `zigeng-runtime [--headless --ticks N]` — runs `game.toml` visually or headlessly.
- **No `build.zig.zon` hook edits**: `game.toml` projects skip `zigeng.toml` `build.zig` provisioning because `zigeng-runtime` ships runtime libraries.

## 2. Native Zig Projects (`build.zig` + `build.zig.zon`)

- Users add the engine via `zig fetch --save git+https://github.com/fhorray/zigeng#<tag>`.
- When running `zigeng add <pkg>` in a directory with `build.zig.zon`, `tools/cli/main.zig` runs `provisionPackageDir()`:
  - Reads `<pkg>/zigeng.toml` via `tools/cli/pkg_manifest.zig`.
  - Runs `zig fetch --save=<name> <url>` for matching `host_platform` (`<os>-<arch>`).
  - Inserts or idempotently replaces `// zigeng:begin <pkg>` ... `// zigeng:end <pkg>` right after `// zigeng:install-hooks` in `build.zig`.

## 3. Local Sandbox Testing (`--fork` / `ZIGENG_FORK`)

External plugins (e.g., `packages/physics/jolt`, `packages/physics/rapier`) pin `zigeng` in their `build.zig.zon`. When developing inside the engine repo, override the pin with `--fork=<zigeng-root>` or `ZIGENG_FORK`:

- Windows: `project.bat <project> [ticks]` (e.g., `install-test`, `jolt-test`, `rapier-test` under `projects/`)
- POSIX (macOS/Linux): `sh project.sh <project> [ticks]`

## 4. Cross-Platform CLI Rules (`tools/cli/main.zig`)

- Prefer `std.process.run` with explicit `argv` (`runArgv` / `runArgvIn`) over shell invocation so paths with spaces or separators work on Windows and POSIX.
- Whenever shell commands are unavoidable, branch explicitly for Windows (`cmd.exe /C`) vs POSIX (`sh -c`) — never pass `mkdir -p` to `cmd.exe` (it creates a literal `-p` directory).
- Keep `pkg_manifest.zig` validation strict (HTTPS URLs only, safe relative paths, identifier-only names) because generated snippets are written into user `build.zig` files.
