# External Plugins & Local Compilation Workflow (`zigeng`)

`zigeng` keeps its core and contract packages (`src/core/`, `packages/physics/`, `packages/graphics/`, `packages/window/`, `packages/scripting-host/`) strictly agnostic. Concrete backends (physics solvers, scripting runtimes, audio backends, renderers) live as **external plugins** compiled on the user's machine by `zig`.

## 1. Design Principles

1. **No Prebuilt Binary Matrix Required:**
   - Community and official plugin authors only ship source code + a standard `build.zig` producing a shared library (`.dll`, `.so`, `.dylib`).
   - Because `zig` bundles Zig, C (`zig cc`), and C++ (`zig c++`) toolchains, `zigeng` compiles plugins directly on the user's machine without requiring Visual Studio, GCC, or CMake.
2. **Versioned C ABI Boundary (`include/engine_extension.h`):**
   - Dynamic plugins export `ae_plugin_entry()` returning `AEPluginApi` (`AE_ABI_MAJOR = 1`).
   - Inside `load(host, out_state)`, plugins resolve engine services via `host->get_service(...)` (e.g., `"engine.physics"` v1) and attach their backend VTable.
3. **Project-Local Plugin Cache (`.zigeng/`):**
   - Downloaded plugin sources live in `.zigeng/cache/<plugin>/`.
   - Compiled shared libraries live in `.zigeng/plugins/`.
   - User project folders remain clean (`game.toml`, `scripts/`, `ui/`, `assets/`).

---

## 2. Developer Workflow

### Adding a Plugin (`zigeng add`)

`zigeng add <spec>` supports three source formats:

1. **Official package name:**
   ```bash
   zigeng add physics-jolt
   ```
2. **Community GitHub URL or `owner/repo[@tag]`:**
   ```bash
   zigeng add https://github.com/user/zigeng-audio@v0.2.0
   zigeng add user/zigeng-audio@v0.2.0
   ```
3. **Local plugin directory (for plugin authors):**
   ```bash
   zigeng add ./packages/physics-jolt
   ```

When adding a shared-library plugin, `zigeng`:
1. Clones or locates the plugin directory (`.zigeng/cache/<name>` for remote repos).
2. If the plugin includes a `Cargo.toml` (e.g., `physics-rapier`), verifies that `cargo` and `rustc` are installed in `PATH` before running `cargo build --release` (failing with a clear install prompt if missing).
3. Runs `zig build -Doptimize=ReleaseSafe` inside that directory (when `build.zig` is present).
4. Copies the resulting `.dll` / `.so` / `.dylib` into `.zigeng/plugins/`.

### Installing Existing Projects (`zigeng install` / `zigeng i`)

When cloning an existing `zigeng` project that already declares `plugins = [...]` in `game.toml`:

```bash
zigeng install
# or shorthand:
zigeng i
```

This reads `game.toml`, fetches and compiles all declared plugins into `.zigeng/plugins/`, and prepares the project for `zigeng run`.

### Declaring Plugins in `game.toml`

```toml
[game]
title = "My Game"
width = 1280
height = 720
mode = "2d"
entry_script = "scripts/main.py"
ui = "ui/hud.html"
plugins = ["scene", "physics", "physics-jolt"]
```

### Running Visual or Headless (`zigeng-runtime`)

- **Visual mode:** `zigeng run` starts `zigeng-runtime`, initializes `App`, and loads any `.dll` / `.so` / `.dylib` from `.zigeng/plugins/` (or explicit paths in `plugins = [...]`) via `PluginHost`.
- **Headless mode:** `zigeng-runtime --headless --ticks 60` skips window/GPU initialization, runs 60 deterministic `.fixed_update` ticks, and exits cleanly for CI and automated testing.

---

## 3. Minimal Contract for Community Plugins

Any repository can act as a `zigeng` plugin if it:
1. Provides a `build.zig` that installs a shared library (`.dll` / `.so` / `.dylib`) into `zig-out/lib` or `zig-out/bin`.
2. Exports `ae_plugin_entry` matching `include/engine_extension.h`.
3. Resolves capabilities via `AEHostApi.get_service` during `load()` and cleans up state in `unload()`.

---

## 4. Package Install Flow (`zigeng.toml`)

Any package (official or community) can ship a `zigeng.toml` at its root. `zigeng add <pkg>` runs it **inside the user's project**, so no binaries need to live in the package repository:

```toml
name = "sdl3"

[[dependency]]                 # `zig fetch --save=<name> <url>` (hash verified by Zig)
name = "sdl3_win64"
url  = "https://github.com/libsdl-org/SDL/releases/download/release-3.4.20/SDL3-3.4.20-win32-x64.zip"
platforms = ["windows-x86_64"] # optional; `<os>-<arch>`; omitted = all

[[install]]                    # file copied to zig-out/bin through a hook block in build.zig
dependency = "sdl3_win64"
path = "SDL3.dll"
platforms = ["windows-x86_64"]
```

- Projects with `build.zig.zon`: dependencies for the host platform are fetched and the hook block is written between `// zigeng:begin <pkg>` / `// zigeng:end <pkg>` right after the `// zigeng:install-hooks` anchor (place it inside `build()` after `const target = ...`). Re-running replaces the block (idempotent). Without the anchor the CLI prints the block to paste.
- `game.toml` projects have no `build.zig.zon`, so nothing is edited: `zigeng-runtime` already ships its runtime libraries.
- Manifests are untrusted input and become Zig code: only `https://` URLs, identifier-safe names, relative paths without `..`, and no quotes or backslashes are accepted (`tools/cli/pkg_manifest.zig`).
