# Releasing, CI/CD & Distribution (`zengy`)

## 1. Current `engine-cli` Scope

`engine-cli` (`tools/cli/main.zig`) is a **developer diagnostic & scenario runner CLI**:
- `engine-cli doctor` — verifies ABI version, module graph resolution, and service registry health.
- `engine-cli packages` — prints topological module resolution order and registered providers.
- `engine-cli test-scenario` — runs a deterministic headless TOML UI scenario and outputs JSON telemetry.

> Note: `engine-cli` does **not** upload or publish builds to users. Distribution is handled via **GitHub Actions + GitHub Releases** (`.github/workflows/release.yml`).

## 2. CI Workflow (`.github/workflows/ci.yml`)

Every push to `main`, `feat/**`, `fix/**` and every Pull Request to `main` automatically verifies:
1. `zig build test` in `Debug` and `ReleaseSafe`
2. `zig build run-headless` and `zig build run-cli`
3. `zig build -Dtarget=x86_64-windows` cross-compilation of all visual & headless binaries

## 3. Merging to `main` & Publishing a Release

### Step 1 — Merge your feature branch into `main`

Using GitHub CLI (`gh`):

```bash
gh pr create --base main --head feat/default-plugins-and-scripting --title "feat: visual runtime (D1-D5), PocketPy, and Phase E 3D" --fill
gh pr merge --merge
```

Or locally with Git:

```bash
git checkout main
git pull origin main
git merge --no-ff feat/default-plugins-and-scripting
git push origin main
```

### Step 2 — Trigger a Release Build

Push a semantic version tag (`v*`), which triggers [`.github/workflows/release.yml`](../.github/workflows/release.yml):

```bash
git tag v0.1.0
git push origin v0.1.0
```

Or trigger manually from GitHub Actions (`Run workflow`) / `gh workflow run release.yml -f tag=v0.1.0`.

The release workflow builds `ReleaseSafe` archives for:
- `zengy-<tag>-x86_64-windows.zip` (all visual `.exe`s, `playground.exe`, `engine-cli.exe`, `include/engine_extension.h`)
- `zengy-<tag>-x86_64-linux.tar.gz` (`headless-ecs`, `playground`, `engine-cli`, `c_plugin`, `include/engine_extension.h`)

and publishes them to **GitHub Releases**, where end users can download and extract the archive directly.
