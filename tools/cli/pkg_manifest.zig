//! Package install manifest (`zengy.toml`) parsing and `build.zig` hook generation.
//!
//! Every package (official or community) may ship a `zengy.toml` that declares how `zengy add`
//! must provision it in the *user's* project, so no binaries ever need to live in the package repo:
//!
//! ```toml
//! name  = "sdl3"
//! entry = "include/SDL3/SDL.h"
//!
//! [[dependency]]            # fetched with `zig fetch --save` (hash verified by Zig)
//! name = "sdl3_win64"
//! url  = "https://github.com/libsdl-org/SDL/releases/download/release-3.4.20/SDL3-3.4.20-win32-x64.zip"
//! platforms = ["windows-x86_64"]
//!
//! [[install]]               # copied next to the executables (zig-out/bin)
//! dependency = "sdl3_win64"
//! path = "SDL3.dll"
//! platforms = ["windows-x86_64"]
//! ```
//!
//! Manifests from the community are untrusted input and end up as Zig code in the user's
//! `build.zig`, so every field is strictly validated before anything is generated.

const std = @import("std");
const builtin = @import("builtin");

/// Anchor line the generated hooks are inserted after (must live inside `build()` after `target`).
pub const ANCHOR = "// zengy:install-hooks";

pub const Dependency = struct {
    name: []const u8 = "",
    url: []const u8 = "",
    platforms: []const []const u8 = &.{},
};

pub const Install = struct {
    dependency: []const u8 = "",
    path: []const u8 = "",
    platforms: []const []const u8 = &.{},
};

pub const Manifest = struct {
    name: []const u8 = "",
    entry: []const u8 = "",
    dependencies: []const Dependency = &.{},
    installs: []const Install = &.{},
};

pub const Error = error{
    InvalidLine,
    InvalidValue,
    UnknownKey,
    UnknownSection,
    InvalidName,
    InvalidUrl,
    InvalidPath,
    InvalidPlatform,
    UnknownDependency,
    NoAnchor,
    UnterminatedBlock,
    OutOfMemory,
};

/// Platform string of the machine running the CLI, e.g. `windows-x86_64`.
pub const host_platform = @tagName(builtin.os.tag) ++ "-" ++ @tagName(builtin.cpu.arch);

pub fn platformMatches(platforms: []const []const u8, platform: []const u8) bool {
    if (platforms.len == 0) return true;
    for (platforms) |p| {
        if (std.mem.eql(u8, p, platform)) return true;
    }
    return false;
}

const Section = enum { top, dependency, install };

pub fn parse(arena: std.mem.Allocator, src: []const u8) Error!Manifest {
    var m: Manifest = .{};
    var deps: std.ArrayList(Dependency) = .empty;
    var installs: std.ArrayList(Install) = .empty;
    var section: Section = .top;

    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, stripComment(raw), " \t\r");
        if (line.len == 0) continue;

        if (line[0] == '[') {
            if (std.mem.eql(u8, line, "[[dependency]]")) {
                try deps.append(arena, .{});
                section = .dependency;
            } else if (std.mem.eql(u8, line, "[[install]]")) {
                try installs.append(arena, .{});
                section = .install;
            } else return error.UnknownSection;
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidLine;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");

        switch (section) {
            .top => {
                if (std.mem.eql(u8, key, "name")) {
                    m.name = try parseString(value);
                } else if (std.mem.eql(u8, key, "entry")) {
                    m.entry = try parseString(value);
                } else return error.UnknownKey;
            },
            .dependency => {
                const d = &deps.items[deps.items.len - 1];
                if (std.mem.eql(u8, key, "name")) {
                    d.name = try parseString(value);
                } else if (std.mem.eql(u8, key, "url")) {
                    d.url = try parseString(value);
                } else if (std.mem.eql(u8, key, "platforms")) {
                    d.platforms = try parseStringArray(arena, value);
                } else return error.UnknownKey;
            },
            .install => {
                const i = &installs.items[installs.items.len - 1];
                if (std.mem.eql(u8, key, "dependency")) {
                    i.dependency = try parseString(value);
                } else if (std.mem.eql(u8, key, "path")) {
                    i.path = try parseString(value);
                } else if (std.mem.eql(u8, key, "platforms")) {
                    i.platforms = try parseStringArray(arena, value);
                } else return error.UnknownKey;
            },
        }
    }

    m.dependencies = deps.items;
    m.installs = installs.items;
    try validate(m);
    return m;
}

fn stripComment(line: []const u8) []const u8 {
    var in_quote = false;
    for (line, 0..) |c, i| {
        if (c == '"') in_quote = !in_quote;
        if (c == '#' and !in_quote) return line[0..i];
    }
    return line;
}

fn parseString(value: []const u8) Error![]const u8 {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return error.InvalidValue;
    const inner = value[1 .. value.len - 1];
    // No escapes or embedded quotes: keeps generated code trivially safe.
    if (std.mem.indexOfAny(u8, inner, "\"\\") != null) return error.InvalidValue;
    return inner;
}

fn parseStringArray(arena: std.mem.Allocator, value: []const u8) Error![]const []const u8 {
    if (value.len < 2 or value[0] != '[' or value[value.len - 1] != ']') return error.InvalidValue;
    const inner = std.mem.trim(u8, value[1 .. value.len - 1], " \t");
    var out: std.ArrayList([]const u8) = .empty;
    if (inner.len == 0) return out.items;
    var parts = std.mem.splitScalar(u8, inner, ',');
    while (parts.next()) |part| {
        try out.append(arena, try parseString(std.mem.trim(u8, part, " \t")));
    }
    return out.items;
}

fn isIdent(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

fn isPackageName(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    return true;
}

fn isSafePath(s: []const u8) bool {
    if (s.len == 0 or s[0] == '/') return false;
    for (s) |c| if (c < 0x20 or c == 0x7f or c == '"' or c == '\\' or c == ':') return false;
    var segs = std.mem.splitScalar(u8, s, '/');
    while (segs.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, "..") or std.mem.eql(u8, seg, ".")) return false;
    }
    return true;
}

fn isPlatform(s: []const u8) bool {
    const dash = std.mem.indexOfScalar(u8, s, '-') orelse return false;
    return isIdent(s[0..dash]) and isIdent(s[dash + 1 ..]);
}

fn validate(m: Manifest) Error!void {
    if (m.name.len != 0 and !isPackageName(m.name)) return error.InvalidName;
    if (m.entry.len != 0 and !isSafePath(m.entry)) return error.InvalidPath;

    for (m.dependencies) |d| {
        if (!isIdent(d.name)) return error.InvalidName;
        if (!std.mem.startsWith(u8, d.url, "https://")) return error.InvalidUrl;
        for (d.url) |c| if (c <= 0x20 or c == 0x7f or c == '"' or c == '\\' or c == '\'') return error.InvalidUrl;
        for (d.platforms) |p| if (!isPlatform(p)) return error.InvalidPlatform;
    }
    for (m.installs) |i| {
        if (!isSafePath(i.path)) return error.InvalidPath;
        for (i.platforms) |p| if (!isPlatform(p)) return error.InvalidPlatform;
        var known = false;
        for (m.dependencies) |d| {
            if (std.mem.eql(u8, d.name, i.dependency)) known = true;
        }
        if (!known) return error.UnknownDependency;
    }
}

fn basename(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

fn beginMarker(arena: std.mem.Allocator, pkg: []const u8) Error![]u8 {
    return std.fmt.allocPrint(arena, "// zengy:begin {s}", .{pkg});
}

fn endMarker(arena: std.mem.Allocator, pkg: []const u8) Error![]u8 {
    return std.fmt.allocPrint(arena, "// zengy:end {s}", .{pkg});
}

/// Renders the marker-delimited hook block (no trailing newline). Requires `b` and `target`
/// in scope at the anchor; platform gating happens at build time so cross-compiling works.
pub fn renderBlock(arena: std.mem.Allocator, pkg: []const u8, m: Manifest) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, try std.fmt.allocPrint(arena, "    {s}\n", .{try beginMarker(arena, pkg)}));
    for (m.installs) |i| {
        var cond: std.ArrayList(u8) = .empty;
        for (i.platforms, 0..) |p, idx| {
            const dash = std.mem.indexOfScalar(u8, p, '-').?;
            if (idx != 0) try cond.appendSlice(arena, " or ");
            try cond.appendSlice(arena, try std.fmt.allocPrint(
                arena,
                "(target.result.os.tag == .{s} and target.result.cpu.arch == .{s})",
                .{ p[0..dash], p[dash + 1 ..] },
            ));
        }
        if (cond.items.len == 0) try cond.appendSlice(arena, "true");
        try out.appendSlice(arena, try std.fmt.allocPrint(
            arena,
            \\    if ({s}) {{
            \\        if (b.lazyDependency("{s}", .{{}})) |zengy_dep| {{
            \\            b.getInstallStep().dependOn(&b.addInstallBinFile(zengy_dep.path("{s}"), "{s}").step);
            \\        }}
            \\    }}
            \\
        ,
            .{ cond.items, i.dependency, i.path, basename(i.path) },
        ));
    }
    try out.appendSlice(arena, try std.fmt.allocPrint(arena, "    {s}", .{try endMarker(arena, pkg)}));
    return out.items;
}

/// Replaces the package's existing hook block, or inserts `block` right after `ANCHOR`.
/// Idempotent: applying the same block twice yields identical output.
pub fn applyBlock(arena: std.mem.Allocator, build_zig: []const u8, pkg: []const u8, block: []const u8) Error![]u8 {
    const begin = try beginMarker(arena, pkg);
    const end = try endMarker(arena, pkg);

    var out: std.ArrayList(u8) = .empty;
    var first = true;
    var in_block = false;
    var done = false;

    // An existing block is replaced in place; the anchor is only used for the first insertion.
    var has_block = false;
    var scan = std.mem.splitScalar(u8, build_zig, '\n');
    while (scan.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), begin)) has_block = true;
    }

    var lines = std.mem.splitScalar(u8, build_zig, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (in_block) {
            if (std.mem.eql(u8, t, end)) in_block = false;
            continue;
        }
        if (!done and std.mem.eql(u8, t, begin)) {
            if (!first) try out.append(arena, '\n');
            try out.appendSlice(arena, block);
            first = false;
            in_block = true;
            done = true;
            continue;
        }
        if (!first) try out.append(arena, '\n');
        try out.appendSlice(arena, line);
        first = false;
        if (!has_block and !done and std.mem.eql(u8, t, ANCHOR)) {
            try out.append(arena, '\n');
            try out.appendSlice(arena, block);
            done = true;
        }
    }
    if (in_block) return error.UnterminatedBlock;
    if (!done) return error.NoAnchor;
    return out.items;
}

test "parse sdl3-style manifest" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const m = try parse(arena_state.allocator(),
        \\# comment
        \\name = "sdl3"
        \\
        \\[[dependency]]
        \\name = "sdl3_win64"
        \\url = "https://github.com/libsdl-org/SDL/releases/download/release-3.4.20/SDL3-3.4.20-win32-x64.zip" # trailing
        \\platforms = ["windows-x86_64"]
        \\
        \\[[install]]
        \\dependency = "sdl3_win64"
        \\path = "SDL3.dll"
        \\platforms = ["windows-x86_64"]
    );
    try std.testing.expectEqualStrings("sdl3", m.name);
    try std.testing.expectEqual(@as(usize, 1), m.dependencies.len);
    try std.testing.expectEqualStrings("sdl3_win64", m.dependencies[0].name);
    try std.testing.expect(platformMatches(m.dependencies[0].platforms, "windows-x86_64"));
    try std.testing.expect(!platformMatches(m.dependencies[0].platforms, "linux-x86_64"));
    try std.testing.expectEqualStrings("SDL3.dll", m.installs[0].path);
}

test "parse rejects unsafe manifests" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const dep = "[[dependency]]\nname = \"x\"\nurl = \"https://e.com/x.zip\"\n";
    try std.testing.expectError(error.InvalidUrl, parse(a, "[[dependency]]\nname = \"x\"\nurl = \"http://e.com/x.zip\"\n"));
    try std.testing.expectError(error.InvalidPath, parse(a, dep ++ "[[install]]\ndependency = \"x\"\npath = \"../evil.dll\"\n"));
    try std.testing.expectError(error.InvalidValue, parse(a, dep ++ "[[install]]\ndependency = \"x\"\npath = \"a\\\\b.dll\"\n"));
    try std.testing.expectError(error.InvalidPath, parse(a, dep ++ "[[install]]\ndependency = \"x\"\npath = \"/abs/x.dll\"\n"));
    try std.testing.expectError(error.UnknownDependency, parse(a, dep ++ "[[install]]\ndependency = \"y\"\npath = \"a.dll\"\n"));
    try std.testing.expectError(error.InvalidName, parse(a, "[[dependency]]\nname = \"a b\"\nurl = \"https://e.com/x\"\n"));
    try std.testing.expectError(error.InvalidPlatform, parse(a, "[[dependency]]\nname = \"x\"\nurl = \"https://e.com/x\"\nplatforms = [\"win\"]\n"));
    try std.testing.expectError(error.UnknownKey, parse(a, "evil = \"1\"\n"));
    try std.testing.expectError(error.UnknownSection, parse(a, "[run]\n"));
}

test "block render and idempotent apply" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const m = try parse(a,
        \\[[dependency]]
        \\name = "sdl3_win64"
        \\url = "https://e.com/x.zip"
        \\[[install]]
        \\dependency = "sdl3_win64"
        \\path = "bin/SDL3.dll"
        \\platforms = ["windows-x86_64"]
    );
    const block = try renderBlock(a, "sdl3", m);
    try std.testing.expect(std.mem.indexOf(u8, block, "target.result.os.tag == .windows") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "zengy_dep.path(\"bin/SDL3.dll\"), \"SDL3.dll\"") != null);

    const src = "pub fn build(b: *std.Build) void {\n    const target = b.standardTargetOptions(.{});\n    // zengy:install-hooks\n}\n";
    const once = try applyBlock(a, src, "sdl3", block);
    try std.testing.expect(std.mem.indexOf(u8, once, "zengy:begin sdl3") != null);
    try std.testing.expect(std.mem.endsWith(u8, once, "\n}\n"));
    const twice = try applyBlock(a, once, "sdl3", block);
    try std.testing.expectEqualStrings(once, twice);

    const changed = try applyBlock(a, once, "sdl3", "    // zengy:begin sdl3\n    // zengy:end sdl3");
    try std.testing.expect(std.mem.indexOf(u8, changed, "lazyDependency") == null);

    try std.testing.expectError(error.NoAnchor, applyBlock(a, "pub fn build() void {}\n", "sdl3", block));
    try std.testing.expectError(error.UnterminatedBlock, applyBlock(a, "// zengy:begin sdl3\n", "sdl3", block));
}
