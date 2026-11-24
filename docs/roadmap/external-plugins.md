# External Plugins & Local Compilation Workflow (`zengy`)

`zengy` keeps its core and contract packages (`src/core/`, `packages/physics/core/`, `packages/graphics/core/`, `packages/window/core/`, `packages/scripting/host/`) strictly agnostic. Concrete backends (physics solvers, scripting runtimes, audio backends, renderers) live as **external plugins** compiled on the user's machine by `zig`.

## 1. Design Principles

1. **No Prebuilt Binary Matrix Required:**
   - Community and official plugin authors only ship source code + a standard `build.zig` producing a shared library (`.dll`, `.so`, `.dylib`).
   - Because `zig` bundles Zig, C (`zig cc`), and C++ (`zig c++`) toolchains, `zengy` compiles plugins directly on the user's machine without requiring Visual Studio, GCC, or CMake.
2. **Versioned C ABI Boundary (`include/engine_extension.h`):**
   - Dynamic plugins export `ae_plugin_entry()` returning `AEPluginApi` (`AE_ABI_MAJOR = 1`).
   - Inside `load(host, out_state)`, plugins resolve engine services via `host->get_service(...)` (e.g., `"engine.physics"` v1) and attach their backend VTable.
3. **Project-Local Plugin Cache (`.zengy/`):**
   - Downloaded plugin sources live in `.zengy/cache/<plugin>/`.
   - Compiled shared libraries live in `.zengy/plugins/`.
   - User project folders remain clean (`game.toml`, `scripts/`, `ui/`, `assets/`).

---

## 2. Developer Workflow

### Adding a Plugin (`zengy add`)

`zengy add <spec>` supports three source formats:

1. **Official package name:**
   ```bash
   zengy add physics-jolt
   ```
2. **Community GitHub URL or `owner/repo[@tag]`:**
   ```bash
   zengy add https://github.com/user/zengy-audio@v0.2.0
   zengy add user/zengy-audio@v0.2.0
   ```
3. **Local plugin directory (for plugin authors):**
   ```bash
   zengy add ./packages/physics/jolt
   ```

When adding a shared-library plugin, `zengy`:
1. Clones or locates the plugin directory (`.zengy/cache/<name>` for remote repos).
2. If the plugin includes a `Cargo.toml` (e.g., `physics-rapier`), verifies that `cargo` and `rustc` are installed in `PATH` before running `cargo build --release` (failing with a clear install prompt if missing).
3. Runs `zig build -Doptimize=ReleaseSafe` inside that directory (when `build.zig` is present).
4. Copies the resulting `.dll` / `.so` / `.dylib` into `.zengy/plugins/`.

### Installing Existing Projects (`zengy install` / `zengy i`)

When cloning an existing `zengy` project that already declares `plugins = [...]` in `game.toml`:

```bash
zengy install
# or shorthand:
zengy i
```

This reads `game.toml`, fetches and compiles all declared plugins into `.zengy/plugins/`, and prepares the project for `zengy run`.

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

### Running Visual or Headless (`zengy-runtime`)

- **Visual mode:** `zengy run` starts `zengy-runtime`, initializes `App`, and loads any `.dll` / `.so` / `.dylib` from `.zengy/plugins/` (or explicit paths in `plugins = [...]`) via `PluginHost`.
- **Headless mode:** `zengy-runtime --headless --ticks 60` skips window/GPU initialization, runs 60 deterministic `.fixed_update` ticks, and exits cleanly for CI and automated testing.

---

## 3. Minimal Contract for Community Plugins

Any repository can act as a `zengy` plugin if it:
1. Provides a `build.zig` that installs a shared library (`.dll` / `.so` / `.dylib`) into `zig-out/lib` or `zig-out/bin`.
2. Exports `ae_plugin_entry` matching `include/engine_extension.h`.
3. Resolves capabilities via `AEHostApi.get_service` during `load()` and cleans up state in `unload()`.

---

## 4. Package Install Flow (`zengy.toml`)

Any package (official or community) can ship a `zengy.toml` at its root. `zengy add <pkg>` runs it **inside the user's project**, so no binaries need to live in the package repository:

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

- Projects with `build.zig.zon`: dependencies for the host platform are fetched and the hook block is written between `// zengy:begin <pkg>` / `// zengy:end <pkg>` right after the `// zengy:install-hooks` anchor (place it inside `build()` after `const target = ...`). Re-running replaces the block (idempotent). Without the anchor the CLI prints the block to paste.
- `game.toml` projects have no `build.zig.zon`, so nothing is edited: `zengy-runtime` already ships its runtime libraries.
- Manifests are untrusted input and become Zig code: only `https://` URLs, identifier-safe names, relative paths without `..`, and no quotes or backslashes are accepted (`tools/cli/pkg_manifest.zig`).

## 5. Plugin dependency on zengy (`--fork`)

Plugins that use engine modules (`physics/jolt`, `physics/rapier`) depend on `zengy` by pinned URL and hash in their `build.zig.zon`, so they build anywhere (including a user project that only received the plugin folder):

```zig
.zengy = .{
    .url = "git+https://github.com/fhorray/zigeng#<commit>",
    .hash = "zengy-<version>-...",   // `zig fetch <url>` prints it
},
```

- **Developing inside the zengy repository:** override the pin with the local checkout, no network needed: `zig build --fork=<zengy-root>` in the plugin directory, or `zengy add --fork=<zengy-root> <plugin>` (also `ZENGY_FORK`). `project.bat` does this for the sandbox projects.
- **Bumping the pin:** when `physics/core` or the plugin ABI (`cabi.ABI_VERSION`) changes, update `url`/`hash` in each plugin to a pushed commit or release tag. Plugins built against an older ABI are rejected at load time with a clear error instead of crashing.
