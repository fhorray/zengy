//! Package installation: official packages, plugin specs, `game.toml` installs and manifest provisioning.

const std = @import("std");
const builtin = @import("builtin");
const toml_format = @import("toml_format");
const pkg_manifest = @import("pkg_manifest.zig");
const OfficialPackageInfo = @import("catalog.zig").OfficialPackageInfo;
const findOfficialPackage = @import("catalog.zig").findOfficialPackage;
const packageDir = @import("catalog.zig").packageDir;
const runShell = @import("process.zig").runShell;
const hasCommand = @import("process.zig").hasCommand;
const fileExists = @import("process.zig").fileExists;
const runArgv = @import("process.zig").runArgv;
const cwdFileExists = @import("process.zig").cwdFileExists;
const runArgvIn = @import("process.zig").runArgvIn;
const writeFileRelative = @import("project.zig").writeFileRelative;

pub fn installOfficialPackage(allocator: std.mem.Allocator, io: std.Io, pkg: OfficialPackageInfo) !void {
    const dir = packageDir(pkg.name);
    // `mkdir -p` does not exist in cmd.exe (it creates a folder literally named "-p"), so the
    // directory creation is spelled per shell.
    const mk = if (builtin.os.tag == .windows) "(if not exist packages mkdir packages)" else "mkdir -p packages";
    const shell_cmd = if (pkg.third_party) |tp|
        try std.fmt.allocPrint(
            allocator,
            "{s} && curl -sL https://github.com/fhorray/zengy/archive/refs/heads/main.tar.gz | tar -xz --strip-components=1 -C . zengy-main/packages/{s} zengy-main/packages/{s}",
            .{ mk, dir, packageDir(tp) },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "{s} && curl -sL https://github.com/fhorray/zengy/archive/refs/heads/main.tar.gz | tar -xz --strip-components=1 -C . zengy-main/packages/{s}",
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

/// Runs the install flow declared by `<dir>/zengy.toml` (if any) inside the user's project:
/// `zig fetch --save` for each dependency of this platform, then a marker-delimited hook block
/// in `build.zig` (inserted after `// zengy:install-hooks`). Packages without a manifest are skipped.
/// Projects without `build.zig.zon` (plain `game.toml` projects) skip this: `zengy-runtime` ships
/// its runtime libraries.
pub fn provisionPackageDir(allocator: std.mem.Allocator, io: std.Io, dir: []const u8) !void {
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
pub var g_fork_path: ?[]const u8 = null;

pub fn isPluginLib(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".dll") or std.mem.endsWith(u8, name, ".so") or std.mem.endsWith(u8, name, ".dylib");
}

/// Copies shared libraries found under `src_dir` into `./.zengy/plugins/` (created on demand).
pub fn copyPluginLibs(allocator: std.mem.Allocator, io: std.Io, src_dir: []const u8, recursive: bool) !void {
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

pub fn compileAndInstallPluginDir(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8, label: []const u8) !void {
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
pub fn installPluginDirAndProvision(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8, label: []const u8) !void {
    const has_build = fileExists(allocator, io, dir_path, "build.zig") or fileExists(allocator, io, dir_path, "Cargo.toml");
    const has_manifest = fileExists(allocator, io, dir_path, "zengy.toml");
    if (has_build or !has_manifest) try compileAndInstallPluginDir(allocator, io, dir_path, label);
    try provisionPackageDir(allocator, io, dir_path);
}

pub fn installPluginSpec(allocator: std.mem.Allocator, io: std.Io, spec: []const u8) !void {
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

pub fn installFromGameToml(allocator: std.mem.Allocator, io: std.Io) !void {
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
