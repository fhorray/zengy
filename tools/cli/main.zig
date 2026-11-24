//! Engine Diagnostic, Scenario Runner & Package Installer CLI (`tools/cli`).
//!
//! Commands:
//! - `doctor`: validates ABI version, module graph resolution, and service count.
//! - `packages`: prints resolved topological module order and registered providers.
//! - `test-scenario`: runs a deterministic TOML scenario and outputs a structured JSON report.
//! - `list-official`: lists all official packages available from `fhorray/zengy`.
//! - `new <name>`: scaffolds a game.toml + starter Python script + IDE typings project.
//! - `typings`: writes Python `.pyi` stubs (`typings/`) and `pyrightconfig.json` in CWD.
//! - `add <pkg>`: downloads an official package from GitHub into `./packages/<pkg>/`
//!   (and any required `third_party/` dependency such as `pocketpy` or `sdl3`).
//!
//! Usage:
//!   zig build run-cli
//!   zig build run-cli -Dcli-cmd=packages
//!   zig build run-cli -Dcli-cmd=list-official
//!   engine-cli add scripting-python

const std = @import("std");
const builtin = @import("builtin");
const engine = @import("engine");
const window = @import("window");
const graphics = @import("graphics");
const ui_core = @import("ui_core");
const scripting_host = @import("scripting_host");
const assets = @import("assets");
const testing_sdk = @import("testing_sdk");
const toml_format = @import("toml_format");
const pkg_manifest = @import("pkg_manifest.zig");

const OfficialPackageInfo = struct {
    name: []const u8,
    entry: []const u8,
    summary: []const u8,
    third_party: ?[]const u8 = null,
};

const OFFICIAL_PACKAGES = [_]OfficialPackageInfo{
    .{ .name = "window", .entry = "src/window.zig", .summary = "Headless window & input service" },
    .{ .name = "window-sdl3", .entry = "src/window_sdl3.zig", .summary = "Native SDL3 window & input", .third_party = "sdl3" },
    .{ .name = "graphics", .entry = "src/graphics.zig", .summary = "Headless graphics device & DrawCommand" },
    .{ .name = "graphics-sdlgpu", .entry = "src/graphics_sdlgpu.zig", .summary = "SDL_GPU (Vulkan/SPIR-V) 2D/3D backend", .third_party = "sdl3" },
    .{ .name = "scene", .entry = "src/scene.zig", .summary = "2D transform hierarchy & SceneSnapshot" },
    .{ .name = "prefab", .entry = "src/prefab.zig", .summary = "Portable prefab IR, overrides & atomic batch instantiation" },
    .{ .name = "physics", .entry = "src/physics.zig", .summary = "Agnostic ECS physics contract & PhysicsBackendVTable" },
    .{ .name = "physics-jolt", .entry = "src/physics_jolt.zig", .summary = "JoltPhysics v5.7.0 3D solver backend" },
    .{ .name = "physics-rapier", .entry = "src/physics_rapier.zig", .summary = "Rapier3D (Rust) solver backend (requires cargo/rustc)" },
    .{ .name = "render-2d", .entry = "src/render_2d.zig", .summary = "Sprite, Visibility & 2D batch extraction (uses camera)" },
    .{ .name = "render-3d", .entry = "src/render_3d.zig", .summary = "3D math, MeshRef, glTF 2.0 & frustum culling (uses camera)" },
    .{ .name = "gizmos", .entry = "src/gizmos.zig", .summary = "Immediate-mode 3D debug & editor gizmos (uses camera)" },
    .{ .name = "camera", .entry = "src/camera.zig", .summary = "Unified 2D/3D Camera, Projection, Viewport, RenderTarget & FreeCamera" },
    .{ .name = "input", .entry = "src/input.zig", .summary = "Bevy-style KeyCode, ButtonInput, Gamepad/D-Pad, mouse motion & scroll" },
    .{ .name = "input-haptics", .entry = "src/haptics.zig", .summary = "Agnostic controller rumble & trigger haptics contract" },
    .{ .name = "input-sdl3", .entry = "src/input_sdl3.zig", .summary = "SDL3 Gamepad & DualSense rumble provider", .third_party = "sdl3" },
    .{ .name = "text", .entry = "src/text.zig", .summary = "Embedded 8x8 ASCII bitmap font atlas" },
    .{ .name = "ui-core", .entry = "src/ui_core.zig", .summary = "Retained UiTree, flex layout & hit testing" },
    .{ .name = "ui-markup", .entry = "src/ui_markup.zig", .summary = "HTML-like UI markup parser" },
    .{ .name = "scripting-host", .entry = "src/scripting_host.zig", .summary = "Language-agnostic scripting host & bridge" },
    .{ .name = "scripting-lua", .entry = "src/scripting_lua.zig", .summary = "Embedded Lua 5.4 runtime" },
    .{ .name = "scripting-python", .entry = "src/scripting_python.zig", .summary = "Embedded PocketPy (Python) runtime" },
    .{ .name = "assets", .entry = "src/assets.zig", .summary = "URI-cached asset registry" },
    .{ .name = "editor-shell", .entry = "src/editor_shell.zig", .summary = "Dockable editor shell & undo/redo" },
    .{ .name = "testing", .entry = "src/testing_sdk.zig", .summary = "Deterministic TestDriver & CaptureService" },
    .{ .name = "default-plugins", .entry = "src/default_plugins.zig", .summary = "Curated bundle of official modules" },
};

fn findOfficialPackage(name: []const u8) ?OfficialPackageInfo {
    for (OFFICIAL_PACKAGES) |pkg| {
        if (std.mem.eql(u8, pkg.name, name)) return pkg;
    }
    return null;
}

/// Directory of an official package below `packages/`. Related packages are grouped by category
/// (`physics/jolt`, `ui/core`, ...); the public package name (`physics-jolt`) never changes.
fn packageDir(name: []const u8) []const u8 {
    const dirs = [_]struct { []const u8, []const u8 }{
        .{ "physics", "physics/core" },
        .{ "physics-jolt", "physics/jolt" },
        .{ "physics-rapier", "physics/rapier" },
        .{ "ui-core", "ui/core" },
        .{ "ui-markup", "ui/markup" },
        .{ "window", "window/core" },
        .{ "window-sdl3", "window/sdl3" },
        .{ "input", "input/core" },
        .{ "input-haptics", "input/haptics" },
        .{ "input-sdl3", "input/sdl3" },
        .{ "graphics", "graphics/core" },
        .{ "graphics-sdlgpu", "graphics/sdlgpu" },
        .{ "scripting-host", "scripting/host" },
        .{ "scripting-lua", "scripting/lua" },
        .{ "scripting-python", "scripting/python" },
        .{ "render-2d", "render/2d" },
        .{ "render-3d", "render/3d" },
        .{ "text", "render/text" },
        .{ "testing", "testing" },
    };
    for (dirs) |e| {
        if (std.mem.eql(u8, e[0], name)) return e[1];
    }
    return name;
}

fn installOfficialPackage(allocator: std.mem.Allocator, io: std.Io, pkg: OfficialPackageInfo) !void {
    const dir = packageDir(pkg.name);
    // `mkdir -p` does not exist in cmd.exe (it creates a folder literally named "-p"), so the
    // directory creation is spelled per shell.
    const mk = if (builtin.os.tag == .windows) "(if not exist packages mkdir packages)" else "mkdir -p packages";
    const shell_cmd = if (pkg.third_party) |tp|
        try std.fmt.allocPrint(
            allocator,
            "{s} && curl -sL https://github.com/fhorray/zigeng/archive/refs/heads/main.tar.gz | tar -xz --strip-components=1 -C . zigeng-main/packages/{s} zigeng-main/packages/{s}",
            .{ mk, dir, packageDir(tp) },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "{s} && curl -sL https://github.com/fhorray/zigeng/archive/refs/heads/main.tar.gz | tar -xz --strip-components=1 -C . zigeng-main/packages/{s}",
            .{ mk, dir },
        );
    defer allocator.free(shell_cmd);

    const argv = if (builtin.os.tag == .windows)
        [_][]const u8{ "cmd.exe", "/C", shell_cmd }
    else
        [_][]const u8{ "sh", "-c", shell_cmd };

    const res = try std.process.run(allocator, io, .{ .argv = &argv });
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);

    switch (res.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("Failed to download '{s}' (exit {d}):\n{s}\n", .{ pkg.name, code, res.stderr });
            return error.PackageDownloadFailed;
        },
        else => return error.PackageDownloadFailed,
    }

    std.debug.print("Installed official package into ./packages/{s}/\n", .{dir});
    if (pkg.third_party) |tp| {
        std.debug.print("Installed required dependency into ./packages/{s}/\n", .{packageDir(tp)});
        const tp_dir = try std.fmt.allocPrint(allocator, "packages/{s}", .{packageDir(tp)});
        defer allocator.free(tp_dir);
        try provisionPackageDir(allocator, io, tp_dir);
    }

    const pkg_dir = try std.fmt.allocPrint(allocator, "packages/{s}", .{dir});
    defer allocator.free(pkg_dir);
    if (fileExists(allocator, io, pkg_dir, "build.zig") or fileExists(allocator, io, pkg_dir, "Cargo.toml")) {
        try compileAndInstallPluginDir(allocator, io, pkg_dir, pkg.name);
    }
    try provisionPackageDir(allocator, io, pkg_dir);

    std.debug.print("\nAdd to your build.zig:\n  const pkg_mod = b.addModule(\"{s}\", .{{\n      .root_source_file = b.path(\"packages/{s}/{s}\"),\n      .target = target,\n      .optimize = optimize,\n  }});\n", .{
        pkg.name,
        dir,
        pkg.entry,
    });
}

fn writeFileRelative(io: std.Io, path: []const u8, content: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

const PY_ZENGY_INIT_PYI = @embedFile("py_zengy_init_pyi");
const PY_ZENGY_INPUT_PYI = @embedFile("py_zengy_input_pyi");
const PY_ZENGY_KEY_PYI = @embedFile("py_zengy_key_pyi");

const PYRIGHT_CONFIG_JSON =
    \\{
    \\  "include": ["scripts"],
    \\  "extraPaths": ["typings"]
    \\}
    \\
;

const STARTER_MAIN_PY =
    \\import zengy
    \\from zengy import Key
    \\
    \\x = 600.0
    \\y = 320.0
    \\
    \\
    \\def start():
    \\    zengy.log("zengy game started!")
    \\
    \\
    \\def update(dt):
    \\    global x, y
    \\    speed = 300.0 * float(dt)
    \\    if zengy.input.is_key_down(Key.A) or zengy.input.is_key_down(Key.LEFT):
    \\        x -= speed
    \\    if zengy.input.is_key_down(Key.D) or zengy.input.is_key_down(Key.RIGHT):
    \\        x += speed
    \\    if zengy.input.is_key_down(Key.W) or zengy.input.is_key_down(Key.UP):
    \\        y -= speed
    \\    if zengy.input.is_key_down(Key.S) or zengy.input.is_key_down(Key.DOWN):
    \\        y += speed
    \\    zengy.draw_rect(x, y, 64.0, 64.0, 0.25, 0.75, 1.0, 1.0)
    \\
;

fn writePythonTypings(allocator: std.mem.Allocator, io: std.Io, base_dir: []const u8) !void {
    const typings_zengy_dir = try std.fmt.allocPrint(allocator, "{s}/typings/zengy", .{base_dir});
    defer allocator.free(typings_zengy_dir);
    try std.Io.Dir.cwd().createDirPath(io, typings_zengy_dir);

    const files = [_]struct { rel: []const u8, content: []const u8 }{
        .{ .rel = "typings/zengy/__init__.pyi", .content = PY_ZENGY_INIT_PYI },
        .{ .rel = "typings/zengy/input.pyi", .content = PY_ZENGY_INPUT_PYI },
        .{ .rel = "typings/zengy/Key.pyi", .content = PY_ZENGY_KEY_PYI },
        .{ .rel = "pyrightconfig.json", .content = PYRIGHT_CONFIG_JSON },
    };
    for (files) |f| {
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_dir, f.rel });
        defer allocator.free(path);
        try writeFileRelative(io, path, f.content);
    }
}

fn scaffoldProject(allocator: std.mem.Allocator, io: std.Io, name: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, name);

    const scripts_dir = try std.fmt.allocPrint(allocator, "{s}/scripts", .{name});
    defer allocator.free(scripts_dir);
    try std.Io.Dir.cwd().createDirPath(io, scripts_dir);

    const toml_path = try std.fmt.allocPrint(allocator, "{s}/game.toml", .{name});
    defer allocator.free(toml_path);
    const toml_src = try std.fmt.allocPrint(allocator,
        \\[game]
        \\title = "{s}"
        \\width = 1280
        \\height = 720
        \\mode = "2d"
        \\entry_script = "scripts/main.py"
        \\plugins = []
        \\
    , .{name});
    defer allocator.free(toml_src);
    try writeFileRelative(io, toml_path, toml_src);

    const main_py_path = try std.fmt.allocPrint(allocator, "{s}/scripts/main.py", .{name});
    defer allocator.free(main_py_path);
    try writeFileRelative(io, main_py_path, STARTER_MAIN_PY);

    try writePythonTypings(allocator, io, name);

    std.debug.print("Created zengy project '{s}/' (with scripts/main.py + Python typings):\n  cd {s}\n  zengy run\n", .{ name, name });
}

fn runShell(allocator: std.mem.Allocator, io: std.Io, shell_cmd: []const u8) !void {
    const argv = if (builtin.os.tag == .windows)
        [_][]const u8{ "cmd.exe", "/C", shell_cmd }
    else
        [_][]const u8{ "sh", "-c", shell_cmd };

    const res = try std.process.run(allocator, io, .{ .argv = &argv });
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);
    if (res.stdout.len > 0) std.debug.print("{s}", .{res.stdout});
    if (res.stderr.len > 0) std.debug.print("{s}", .{res.stderr});

    switch (res.term) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

fn hasCommand(allocator: std.mem.Allocator, io: std.Io, check_cmd: []const u8) bool {
    const argv = if (builtin.os.tag == .windows)
        [_][]const u8{ "cmd.exe", "/C", check_cmd }
    else
        [_][]const u8{ "sh", "-c", check_cmd };
    const res = std.process.run(allocator, io, .{ .argv = &argv }) catch return false;
    allocator.free(res.stdout);
    allocator.free(res.stderr);
    return switch (res.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn fileExists(allocator: std.mem.Allocator, io: std.Io, base_dir: []const u8, rel: []const u8) bool {
    const full = std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_dir, rel }) catch return false;
    defer allocator.free(full);
    std.Io.Dir.cwd().access(io, full, .{}) catch return false;
    return true;
}

fn runArgv(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const res = try std.process.run(allocator, io, .{ .argv = argv });
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);
    if (res.stdout.len > 0) std.debug.print("{s}", .{res.stdout});
    if (res.stderr.len > 0) std.debug.print("{s}", .{res.stderr});
    switch (res.term) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

fn cwdFileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Runs the install flow declared by `<dir>/zengy.toml` (if any) inside the user's project:
/// `zig fetch --save` for each dependency of this platform, then a marker-delimited hook block
/// in `build.zig` (inserted after `// zengy:install-hooks`). Packages without a manifest are skipped.
/// Projects without `build.zig.zon` (plain `game.toml` projects) skip this: `zengy-runtime` ships
/// its runtime libraries.
fn provisionPackageDir(allocator: std.mem.Allocator, io: std.Io, dir: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const manifest_path = try std.fmt.allocPrint(arena, "{s}/zengy.toml", .{dir});
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, arena, .limited(256 * 1024)) catch return;

    const manifest = pkg_manifest.parse(arena, bytes) catch |err| {
        std.debug.print("[zengy] Invalid {s}: {s}. Skipping package provisioning.\n", .{ manifest_path, @errorName(err) });
        return error.InvalidPackageManifest;
    };
    if (manifest.dependencies.len == 0 and manifest.installs.len == 0) return;
    const pkg_name = if (manifest.name.len != 0) manifest.name else std.fs.path.basename(dir);

    if (!cwdFileExists(io, "build.zig.zon")) {
        std.debug.print("[zengy] '{s}': no build.zig.zon here (game.toml project); runtime libraries come with zengy-runtime.\n", .{pkg_name});
        return;
    }

    for (manifest.dependencies) |d| {
        if (!pkg_manifest.platformMatches(d.platforms, pkg_manifest.host_platform)) continue;
        std.debug.print("[zengy] Fetching '{s}' for '{s}' (hash verified by zig)...\n", .{ d.name, pkg_name });
        const save_flag = try std.fmt.allocPrint(arena, "--save={s}", .{d.name});
        try runArgv(allocator, io, &.{ "zig", "fetch", save_flag, d.url });
    }

    if (manifest.installs.len == 0) return;
    if (!cwdFileExists(io, "build.zig")) {
        std.debug.print("[zengy] '{s}': no build.zig found; cannot install runtime files.\n", .{pkg_name});
        return;
    }
    const block = try pkg_manifest.renderBlock(arena, pkg_name, manifest);
    const build_src = try std.Io.Dir.cwd().readFileAlloc(io, "build.zig", arena, .limited(4 * 1024 * 1024));
    const updated = pkg_manifest.applyBlock(arena, build_src, pkg_name, block) catch |err| switch (err) {
        error.NoAnchor => {
            std.debug.print(
                "[zengy] build.zig has no '{s}' anchor. Add that line inside build() after `const target = ...`, then re-run, or paste this block manually:\n\n{s}\n",
                .{ pkg_manifest.ANCHOR, block },
            );
            return;
        },
        else => return err,
    };
    if (!std.mem.eql(u8, build_src, updated)) {
        try writeFileRelative(io, "build.zig", updated);
        std.debug.print("[zengy] Updated build.zig hooks for '{s}' (zig-out/bin install of runtime files).\n", .{pkg_name});
    }
}

/// Runs `argv` inside `cwd` without a shell (no quoting or path-separator pitfalls) and echoes its output.
/// Optional local zengy checkout (`--fork=<path>` or `ZENGY_FORK`) forwarded to plugin builds.
var g_fork_path: ?[]const u8 = null;

fn runArgvIn(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: []const u8) !void {
    const res = try std.process.run(allocator, io, .{ .argv = argv, .cwd = .{ .path = cwd } });
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);
    if (res.stdout.len > 0) std.debug.print("{s}", .{res.stdout});
    if (res.stderr.len > 0) std.debug.print("{s}", .{res.stderr});
    switch (res.term) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

fn isPluginLib(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".dll") or std.mem.endsWith(u8, name, ".so") or std.mem.endsWith(u8, name, ".dylib");
}

/// Copies shared libraries found under `src_dir` into `./.zengy/plugins/` (created on demand).
fn copyPluginLibs(allocator: std.mem.Allocator, io: std.Io, src_dir: []const u8, recursive: bool) !void {
    try std.Io.Dir.cwd().createDirPath(io, ".zengy/plugins");
    var plugins = try std.Io.Dir.cwd().openDir(io, ".zengy/plugins", .{});
    defer plugins.close(io);
    var src = std.Io.Dir.cwd().openDir(io, src_dir, .{ .iterate = true }) catch return error.PluginBuildOutputMissing;
    defer src.close(io);

    var walker = try src.walk(allocator);
    defer walker.deinit();
    var copied: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !isPluginLib(entry.basename)) continue;
        if (!recursive and std.mem.indexOfAny(u8, entry.path, "/\\") != null) continue;
        try entry.dir.copyFile(entry.basename, plugins, entry.basename, io, .{});
        std.debug.print("[zengy] Copied {s} -> .zengy/plugins/\n", .{entry.basename});
        copied += 1;
    }
    if (copied == 0) {
        std.debug.print("[zengy] No shared library (.dll/.so/.dylib) found under '{s}'.\n", .{src_dir});
        return error.PluginBuildOutputMissing;
    }
}

fn compileAndInstallPluginDir(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8, label: []const u8) !void {
    const has_cargo = fileExists(allocator, io, dir_path, "Cargo.toml");
    const has_zig = fileExists(allocator, io, dir_path, "build.zig");

    if (has_cargo) {
        const cargo_ok = hasCommand(allocator, io, if (builtin.os.tag == .windows) "where cargo >nul 2>nul && where rustc >nul 2>nul" else "command -v cargo >/dev/null 2>&1 && command -v rustc >/dev/null 2>&1");
        if (!cargo_ok) {
            std.debug.print("[zengy] Error: plugin '{s}' requires Rust ('cargo' and 'rustc' not found in PATH).\n", .{label});
            std.debug.print("[zengy] Install Rust from https://rustup.rs and run the command again.\n", .{});
            return error.MissingRustToolchain;
        }
        std.debug.print("[zengy] Building Rust dependency for '{s}' (cargo build --release)...\n", .{label});
        try runArgvIn(allocator, io, &.{ "cargo", "build", "--release" }, dir_path);
    }

    if (has_zig) {
        std.debug.print("[zengy] Building plugin '{s}' locally with zig...\n", .{label});
        if (g_fork_path) |fork| {
            // Local zengy checkout overrides the pinned `zengy` dependency of the plugin
            // (`zig build --fork`); used when developing inside the zengy repository.
            const abs_fork = try std.Io.Dir.cwd().realPathFileAlloc(io, fork, allocator);
            defer allocator.free(abs_fork);
            const fork_arg = try std.fmt.allocPrint(allocator, "--fork={s}", .{abs_fork});
            defer allocator.free(fork_arg);
            try runArgvIn(allocator, io, &.{ "zig", "build", "-Doptimize=ReleaseSafe", fork_arg }, dir_path);
        } else {
            try runArgvIn(allocator, io, &.{ "zig", "build", "-Doptimize=ReleaseSafe" }, dir_path);
        }
        const out_dir = try std.fmt.allocPrint(allocator, "{s}/zig-out", .{dir_path});
        defer allocator.free(out_dir);
        try copyPluginLibs(allocator, io, out_dir, true);
    } else if (has_cargo) {
        const out_dir = try std.fmt.allocPrint(allocator, "{s}/target/release", .{dir_path});
        defer allocator.free(out_dir);
        try copyPluginLibs(allocator, io, out_dir, false);
    } else {
        std.debug.print("[zengy] Error: plugin '{s}' has neither build.zig nor Cargo.toml.\n", .{label});
        return error.InvalidPluginDirectory;
    }

    std.debug.print("[zengy] Installed compiled plugin '{s}' into .zengy/plugins/\n", .{label});
}

/// Community/local package flow: compile it when it has build files, then run its `zengy.toml` install flow.
/// A package that only declares a `zengy.toml` (nothing to compile) is valid.
fn installPluginDirAndProvision(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8, label: []const u8) !void {
    const has_build = fileExists(allocator, io, dir_path, "build.zig") or fileExists(allocator, io, dir_path, "Cargo.toml");
    const has_manifest = fileExists(allocator, io, dir_path, "zengy.toml");
    if (has_build or !has_manifest) try compileAndInstallPluginDir(allocator, io, dir_path, label);
    try provisionPackageDir(allocator, io, dir_path);
}

fn installPluginSpec(allocator: std.mem.Allocator, io: std.Io, spec: []const u8) !void {
    if (std.mem.eql(u8, spec, "scene") or std.mem.eql(u8, spec, "physics")) {
        std.debug.print("[zengy] '{s}' is a built-in engine contract.\n", .{spec});
        return;
    }

    // 1. Local directory path (e.g. ./my-plugin or ../my-plugin)
    if (std.mem.startsWith(u8, spec, "./") or std.mem.startsWith(u8, spec, "../") or std.mem.startsWith(u8, spec, "/")) {
        try installPluginDirAndProvision(allocator, io, spec, spec);
        return;
    }

    // 2. GitHub URL or owner/repo[@tag]
    const is_url = std.mem.startsWith(u8, spec, "https://") or std.mem.startsWith(u8, spec, "http://");
    const has_slash = std.mem.indexOfScalar(u8, spec, '/') != null;
    if (is_url or has_slash) {
        var repo_part = spec;
        var tag: ?[]const u8 = null;
        if (std.mem.lastIndexOfScalar(u8, spec, '@')) |at_idx| {
            repo_part = spec[0..at_idx];
            tag = spec[at_idx + 1 ..];
        }
        const clone_url = if (is_url)
            try allocator.dupe(u8, repo_part)
        else
            try std.fmt.allocPrint(allocator, "https://github.com/{s}.git", .{repo_part});
        defer allocator.free(clone_url);

        const last_slash = std.mem.lastIndexOfScalar(u8, repo_part, '/') orelse 0;
        var repo_name = if (last_slash + 1 < repo_part.len) repo_part[last_slash + 1 ..] else "plugin";
        if (std.mem.endsWith(u8, repo_name, ".git")) repo_name = repo_name[0 .. repo_name.len - 4];

        const cache_dir = try std.fmt.allocPrint(allocator, ".zengy/cache/{s}", .{repo_name});
        defer allocator.free(cache_dir);

        const branch_flag = if (tag) |t|
            try std.fmt.allocPrint(allocator, "--branch \"{s}\" ", .{t})
        else
            try allocator.dupe(u8, "");
        defer allocator.free(branch_flag);

        const clone_cmd = if (builtin.os.tag == .windows)
            try std.fmt.allocPrint(
                allocator,
                "mkdir .zengy\\cache 2>nul & if not exist \"{s}\" (git clone --depth 1 {s}\"{s}\" \"{s}\") else (git -C \"{s}\" pull --ff-only)",
                .{ cache_dir, branch_flag, clone_url, cache_dir, cache_dir },
            )
        else
            try std.fmt.allocPrint(
                allocator,
                "mkdir -p .zengy/cache && if [ ! -d \"{s}\" ]; then git clone --depth 1 {s}\"{s}\" \"{s}\"; else git -C \"{s}\" pull --ff-only || true; fi",
                .{ cache_dir, branch_flag, clone_url, cache_dir, cache_dir },
            );
        defer allocator.free(clone_cmd);
        try runShell(allocator, io, clone_cmd);
        try installPluginDirAndProvision(allocator, io, cache_dir, repo_name);
        return;
    }

    // 3. Official package catalog fallback
    const pkg = findOfficialPackage(spec) orelse {
        std.debug.print("Unknown package or plugin '{s}'. Use an official name, owner/repo[@tag], GitHub URL, or ./local-path.\n", .{spec});
        return error.UnknownPackage;
    };
    try installOfficialPackage(allocator, io, pkg);
}

fn installFromGameToml(allocator: std.mem.Allocator, io: std.Io) !void {
    const manifest_bytes = std.Io.Dir.cwd().readFileAlloc(io, "game.toml", allocator, .limited(4 * 1024 * 1024)) catch |err| {
        std.debug.print("[zengy] Could not read 'game.toml' in current directory: {}\n", .{err});
        return err;
    };
    defer allocator.free(manifest_bytes);

    var manifest = try toml_format.TomlService.parseGameManifest(allocator, manifest_bytes);
    defer manifest.deinit(allocator);

    if (manifest.plugins.len == 0) {
        std.debug.print("[zengy] No plugins listed in game.toml.\n", .{});
        return;
    }

    std.debug.print("[zengy] Installing {d} plugin(s) from game.toml...\n", .{manifest.plugins.len});
    for (manifest.plugins) |p| {
        try installPluginSpec(allocator, io, p);
    }
    std.debug.print("[zengy] All plugins installed.\n", .{});
}

fn runProject(allocator: std.mem.Allocator, io: std.Io, args_it: anytype) !void {
    const runtime_bin = if (builtin.os.tag == .windows) "zengy-runtime.exe" else "zengy-runtime";
    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(allocator);
    try argv_list.append(allocator, runtime_bin);
    while (args_it.next()) |arg| {
        try argv_list.append(allocator, arg);
    }

    var child = try std.process.spawn(io, .{ .argv = argv_list.items });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.RuntimeExitedWithError,
        else => return error.RuntimeExitedWithError,
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args_it = try init.minimal.args.iterateAllocator(allocator);
    defer args_it.deinit();
    _ = args_it.next(); // skip executable name
    const cmd = args_it.next() orelse "doctor";

    if (std.mem.eql(u8, cmd, "new")) {
        const proj_name = args_it.next() orelse {
            std.debug.print("Usage: zengy new <project-name>\n", .{});
            return;
        };
        try scaffoldProject(allocator, init.io, proj_name);
        return;
    }

    if (std.mem.eql(u8, cmd, "typings")) {
        try writePythonTypings(allocator, init.io, ".");
        std.debug.print("Generated Python typings in ./typings/ and ./pyrightconfig.json.\n", .{});
        return;
    }

    if (std.mem.eql(u8, cmd, "run")) {
        try runProject(allocator, init.io, &args_it);
        return;
    }

    if (std.mem.eql(u8, cmd, "install") or std.mem.eql(u8, cmd, "i")) {
        g_fork_path = init.environ_map.get("ZENGY_FORK");
        while (args_it.next()) |a| {
            if (std.mem.startsWith(u8, a, "--fork=")) g_fork_path = a["--fork=".len..];
        }
        try installFromGameToml(allocator, init.io);
        return;
    }

    if (std.mem.eql(u8, cmd, "list-official")) {
        std.debug.print("Official zengy packages (install with: zengy add <name>):\n", .{});
        for (OFFICIAL_PACKAGES) |pkg| {
            std.debug.print("  - {s:<18} {s}\n", .{ pkg.name, pkg.summary });
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "add")) {
        g_fork_path = init.environ_map.get("ZENGY_FORK");
        var pkg_spec: ?[]const u8 = null;
        while (args_it.next()) |a| {
            if (std.mem.startsWith(u8, a, "--fork=")) {
                g_fork_path = a["--fork=".len..];
            } else if (pkg_spec == null) {
                pkg_spec = a;
            }
        }
        const spec = pkg_spec orelse {
            std.debug.print("Usage: zengy add [--fork=<zengy-checkout>] <package | owner/repo[@tag] | github-url | ./local-path>\n", .{});
            return;
        };
        try installPluginSpec(allocator, init.io, spec);
        return;
    }

    if (std.mem.eql(u8, cmd, "test-scenario")) {
        var scen_app = engine.App.init(allocator, .{ .fixed_dt = 1.0 / 60.0 });
        defer scen_app.deinit();

        try scen_app.registerModule(window.module());
        try scen_app.registerModule(graphics.module());
        try scen_app.registerModule(ui_core.module());
        try scen_app.registerModule(testing_sdk.module());
        try scen_app.initialize();

        const tree = scen_app.resources.get(ui_core.UiTree).?;
        const panel = try tree.createNode(null, .{ .id = "root", .kind = .panel });
        _ = try tree.createNode(panel, .{ .id = "btn", .kind = .button, .text = "Play", .action = "game.play" });
        tree.layoutTree(128, 128);

        const sample_toml =
            \\[scenario]
            \\name = "cli_smoke"
            \\ticks = 10
            \\
            \\[[actions]]
            \\at_tick = 2
            \\type = "ui_click"
            \\target = "btn"
        ;

        var scen = try testing_sdk.TestDriver.parseScenarioToml(allocator, sample_toml);
        defer scen.deinit();

        const i_entry = try scen_app.services.getService("engine.input", 1);
        const input: *window.InputService = @ptrCast(@alignCast(@constCast(i_entry.api_ptr)));
        const drv = scen_app.resources.get(testing_sdk.TestDriver).?;
        try drv.runScenario(&scen, &scen_app, input, tree);

        var cmds: std.ArrayList(graphics.DrawCommand) = .empty;
        defer cmds.deinit(allocator);
        try cmds.append(allocator, .{ .clear = .{ .r = 0.05, .g = 0.05, .b = 0.08 } });
        try tree.paint(allocator, &cmds);

        const cap = scen_app.resources.get(testing_sdk.CaptureService).?;
        cap.rasterize(cmds.items);

        std.debug.print(
            "{{\"scenario\":\"{s}\",\"zig_version\":\"{s}\",\"ticks\":{d},\"entities\":{d},\"framebuffer_hash\":{d},\"status\":\"ok\"}}\n",
            .{
                scen.name,
                builtin.zig_version_string,
                drv.current_tick,
                scen_app.world.entity_count,
                cap.computeHash(),
            },
        );
        return;
    }

    // Compose a representative application graph to inspect resolution & ABI health.
    var app = engine.App.init(allocator, .{});
    defer app.deinit();

    try app.registerModule(window.module());
    try app.registerModule(graphics.module());
    try app.registerModule(ui_core.module());
    try app.registerModule(scripting_host.module());
    try app.registerModule(assets.module());
    try app.initialize();

    if (std.mem.eql(u8, cmd, "doctor")) {
        std.debug.print(
            "zengy doctor:\n  ABI version: {d}.{d}\n  App state: {s}\n  Modules resolved: {d}\n  Services registered: {d}\n  Status: OK\n",
            .{
                engine.abi.ABI_MAJOR,
                engine.abi.ABI_MINOR,
                @tagName(app.state),
                app.modules.modules.items.len,
                app.services.count(),
            },
        );
    } else if (std.mem.eql(u8, cmd, "packages")) {
        std.debug.print("Resolved Module Topological Order:\n", .{});
        for (app.modules.resolved_order.items, 0..) |mod_idx, step| {
            const mod = app.modules.modules.items[mod_idx].module;
            std.debug.print("  {d}. {s} ({s})\n", .{
                step + 1,
                mod.descriptor.id,
                mod.descriptor.version,
            });
        }
        std.debug.print("Registered Service Providers:\n", .{});
        for (app.services.services.items) |svc| {
            std.debug.print("  - {s}/{d} -> {s} (exclusive={})\n", .{
                svc.capability,
                svc.major_version,
                svc.provider_id,
                svc.exclusive,
            });
        }
    } else {
        std.debug.print("Unknown command '{s}'. Available: doctor, packages, test-scenario, list-official, add <pkg>\n", .{cmd});
    }
}
