---
name: zengy-package-versioning
description: Semantic versioning rules for zengy packages, engine modules, zengy.toml manifests, and C ABI/capability compatibility. Use whenever adding, modifying, or releasing a package under packages/ or bumping engine versions.
---

# `zengy` Package & Module Versioning Rules

When modifying an existing official package under `packages/`, adding a new package, or bumping core engine contracts, always keep versions consistent across:
1. `engine.Module.descriptor.version` (e.g., `"0.1.0"`)
2. `packages/<name>/zengy.toml` (`version = "..."`, if present)
3. `provides_capabilities` / `required_capabilities` major version suffixes (e.g., `"engine.ui.tree/1"`)
4. `build.zig.zon` (for root `zengy` version bumps)

## Semantic Versioning (`MAJOR.MINOR.PATCH`)

- **PATCH (`0.1.x`)**:
  - Bug fixes, internal refactors, performance improvements, or documentation/comment updates with **no** public API or capability signature changes.
- **MINOR (`0.x.0`)**:
  - Backwards-compatible additions to a package: new widgets, new fields with defaults on existing config/descriptor structs, new optional `DrawCommand` variants, or new `zengy.toml` metadata.
  - Note: Upgrading `ui-core` with `SizeSpec`/`Layer`/new `UiNode` fields with defaults is a **MINOR** bump (`0.1.0` -> `0.2.0`) while keeping `"engine.ui.tree/1"`.
- **MAJOR (`x.0.0` or capability `/N` bump)**:
  - Breaking changes to public Zig APIs, removed/renamed symbols, changed `Service` struct memory layout without defaults, or breaking C ABI changes (`AE_ABI_MAJOR` in `include/engine_extension.h`).
  - Increment the capability major version suffix (e.g., `"engine.ui.tree/1"` -> `"engine.ui.tree/2"`) whenever a registered service struct layout or contract breaks binary/semantic compatibility for consumers.

## Engine Version & GitHub Release Tags (`build.zig.zon` & `v*` Tags)

Always derive the engine SemVer (`build.zig.zon` `.version`) and GitHub release tag (`vMAJOR.MINOR.PATCH`) from Conventional Commits since the last tag:

- **`fix:` / `perf:` / `refactor:` / `docs:`** -> Bump **PATCH** (`v0.1.8` -> `v0.1.9`).
- **`feat:`** -> Bump **MINOR** (`v0.1.9` -> `v0.2.0`, resetting PATCH to `0`).
- **`feat!:` / `fix!:` / `BREAKING CHANGE:`** -> Bump **MAJOR** (`v0.2.0` -> `v1.0.0`, resetting MINOR and PATCH to `0`).

### Commit vs. Push / Release Discipline

- **Local commits**: Make focused local commits without automatically pushing on every commit.
- **Pushing to `staging`, `main`, or release branches**:
  1. Ensure `.version` in `build.zig.zon` matches the accumulated commit types (`fix` -> PATCH, `feat` -> MINOR, breaking -> MAJOR).
  2. Verify `zig build test --summary all` and release builds pass before pushing.
  3. When cutting a GitHub release, create and push an annotated tag `v<MAJOR>.<MINOR>.<PATCH>` (e.g., `git tag -a v0.2.0 -m "Release v0.2.0"` + `git push origin v0.2.0`) so `.github/workflows/release.yml` publishes matching cross-platform archives.

## Checklist When Updating a Package

1. Bump `descriptor.version` in the package's `module()` function (`PATCH` for fixes, `MINOR` for additive features, `MAJOR` for breaking changes).
2. If the package has a `zengy.toml`, update its `version` field to match.
3. If `provides_capabilities` major version changed, update `required_capabilities` and `getService(..., major)` callers across dependent packages, examples, and tests.
4. Run `zig build test --summary all` and `zig build run-cli -Dcli-cmd=packages` to verify module graph resolution.
