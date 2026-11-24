---
name: zengy-cli-and-plugins
description: >-
  Guides development and testing of the zengy CLI (tools/cli), zengy-runtime
  (tools/runtime), game.toml projects, zengy.toml manifests, and sandbox project
  tests. Use when modifying tools/cli/, tools/runtime/, or plugin installation.
---

# `zengy` CLI, Runtime & Plugin Workflows

`zengy` supports two distinct user project modes without requiring a clone of the engine repo.

## 1. Manifesto-Driven `game.toml` Projects

- Commands:
  - `zengy new <name>` — scaffolds a minimal `game.toml` project.
  - `zengy add <spec>` — installs an official package name, GitHub URL/`owner/repo[@tag]`, or local path; compiles native plugins (Zig or Rust+Zig) into `.zengy/plugins/` (`.dll` / `.so` / `.dylib`).
  - `zengy install` (`zengy i`) — reads `plugins = [...]` from `game.toml` and installs/builds them.
  - `zengy run` / `zengy-runtime [--headless --ticks N]` — runs `game.toml` visually or headlessly.
- **No `build.zig.zon` hook edits**: `game.toml` projects skip `zengy.toml` `build.zig` provisioning because `zengy-runtime` ships runtime libraries.

## 2. Native Zig Projects (`build.zig` + `build.zig.zon`)

- Users add the engine via `zig fetch --save git+https://github.com/fhorray/zigeng#<tag>`.
- When running `zengy add <pkg>` in a directory with `build.zig.zon`, `tools/cli/main.zig` runs `provisionPackageDir()`:
  - Reads `<pkg>/zengy.toml` via `tools/cli/pkg_manifest.zig`.
  - Runs `zig fetch --save=<name> <url>` for matching `host_platform` (`<os>-<arch>`).
  - Inserts or idempotently replaces `// zengy:begin <pkg>` ... `// zengy:end <pkg>` right after `// zengy:install-hooks` in `build.zig`.

## 3. Local Sandbox Testing (`--fork` / `ZENGY_FORK`)

External plugins (e.g., `packages/physics/jolt`, `packages/physics/rapier`) pin `zengy` in their `build.zig.zon`. When developing inside the engine repo, override the pin with `--fork=<zengy-root>` or `ZENGY_FORK`:

- Windows: `project.bat <project> [ticks]` (e.g., `install-test`, `jolt-test`, `rapier-test` under `projects/`)
- POSIX (macOS/Linux): `sh project.sh <project> [ticks]`

## 4. Cross-Platform CLI Rules (`tools/cli/main.zig`)

- Prefer `std.process.run` with explicit `argv` (`runArgv` / `runArgvIn`) over shell invocation so paths with spaces or separators work on Windows and POSIX.
- Whenever shell commands are unavoidable, branch explicitly for Windows (`cmd.exe /C`) vs POSIX (`sh -c`) — never pass `mkdir -p` to `cmd.exe` (it creates a literal `-p` directory).
- Keep `pkg_manifest.zig` validation strict (HTTPS URLs only, safe relative paths, identifier-only names) because generated snippets are written into user `build.zig` files.
