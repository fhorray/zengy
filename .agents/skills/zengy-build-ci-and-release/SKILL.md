---
name: zengy-build-ci-and-release
description: >-
  Build targets, local verification commands, GitHub Actions CI workflows, and
  release tagging procedures for zengy. Use when running tests, updating
  .github/workflows/, or preparing a release.
---

# `zengy` Build, CI & Release Runbook

## Toolchain

- **Build layout**: `build.zig` only wires the pieces; `build/modules.zig` declares every module and external dependency, `build/examples.zig` the examples, `build/tools.zig` the CLI and benchmarks, `build/apps.zig` the runtime, `build/tests.zig` the test roots. Keep local module aliases named identically across these files (`tools/ci/check_architecture.py` reads them together).
- **Zig `0.17.1`** is pinned in `build.zig.zon`. Do not use older or newer Zig versions when verifying builds or CI parity.
- **Rust (`cargo` / `rustc`)** is optional and only required when building `packages/physics/rapier`.

## Local Verification Commands

```bash
# Full per-module unit, integration, and C ABI test suites
zig build test --summary all
zig build test -Doptimize=ReleaseSafe --summary all

# Headless simulation & diagnostic CLI
zig build run-headless
zig build run-cli
zig build run-cli -Dcli-cmd=packages
zig build run-cli -Dcli-cmd=test-scenario

# Cross-compile all Windows x64 targets (matches CI)
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe --summary all

# Build only the CLI (no SDL3 required)
zig build cli -Doptimize=ReleaseSafe
```

## CI & Release Workflows

1. **CI (`.github/workflows/ci.yml`)**:
   - Triggers on push/PR to `main` and `staging`.
   - Runs `ubuntu-24.04` (`Debug` + `ReleaseSafe`), Windows x64 cross-compile from `ubuntu-24.04`, and `macos-15` (`Debug` + `ReleaseSafe`).
   - Extra jobs: `sanitize` (ThreadSanitizer over the parallel-scheduler tests; `-fsanitize-thread` must be passed per module), `bench` (`zig build run-bench` + `tools/ci/check_bench.sh` threshold guard), and `gpu-smoke` (builds SDL3 3.4.20 from source, then runs every native visual demo for 8 s under lavapipe with `SDL_VIDEODRIVER=offscreen`; `zig build` finds SDL3 via `--search-prefix`, not pkg-config).
   - `.github/workflows/fuzz.yml` runs the property/fuzz tests nightly at scale (`ZENGY_FUZZ_STEPS`, `ZENGY_FUZZ_ITER`, `ZENGY_FUZZ_SEED`).
   - Note: `macos-14` is retired by GitHub Actions — always keep macOS jobs on `macos-15` (or newer).
2. **Release (`.github/workflows/release.yml`)**:
   - Triggers on `v*` tags (e.g., `git tag v0.1.7 && git push origin v0.1.7`) or `workflow_dispatch`.
   - Produces:
     - `zengy-<tag>-x86_64-windows.zip` (`zengy.exe`, `zengy-runtime.exe`, `SDL3.dll`, `include/engine_extension.h`)
     - `zengy-<tag>-x86_64-linux.tar.gz` (`zengy` CLI, `include/engine_extension.h`)
     - `zengy-<tag>-arm64-macos.tar.gz` (`zengy`, `zengy-runtime`, `libSDL3.0.dylib` rewired with `@executable_path` + ad-hoc `codesign`, `include/engine_extension.h`)

## Before Tagging a Release

1. Ensure `ci.yml` is green on `main`.
2. Verify `project.bat` / `sh project.sh install-test` passes if CLI or plugin loading changed.
3. Push a `vX.Y.Z` tag and check all `release.yml` jobs succeed before sharing download links.
