//! Deterministic plugin path planning for `zengy-runtime`.
//!
//! Pure helpers (no I/O, no engine imports) so ordering and de-duplication rules are unit tested:
//! explicit `game.toml` libraries load first in manifest order, then auto-discovered libraries
//! sorted by file name; a library is loaded once even when reachable through several paths.

const std = @import("std");

/// Returns true for platform shared-library file names.
pub fn isSharedLibName(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".so") or
        std.mem.endsWith(u8, name, ".dll") or
        std.mem.endsWith(u8, name, ".dylib");
}

/// Returns the last path component, accepting both `/` and `\` separators.
pub fn baseName(path: []const u8) []const u8 {
    const idx = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return path;
    return path[idx + 1 ..];
}

/// Returns true when the manifest entry requests the official physics module family:
/// exactly `physics` or an official `physics-<backend>` package name (not any substring match).
pub fn requestsPhysics(spec: []const u8) bool {
    return std.mem.eql(u8, spec, "physics") or std.mem.startsWith(u8, spec, "physics-");
}

fn lessThanName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Plans plugin load order. `explicit` are manifest entries (non-library entries are skipped),
/// `discovered` are file names found in the plugin directory (any order) and are resolved against
/// `discovered_dir`. Returned paths are owned by `arena`. Libraries with the same base name
/// (case-insensitive) load once, the first occurrence winning.
pub fn planLoadOrder(
    arena: std.mem.Allocator,
    explicit: []const []const u8,
    discovered_dir: []const u8,
    discovered: []const []const u8,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;

    for (explicit) |spec| {
        if (!isSharedLibName(spec)) continue;
        try addUnique(arena, &out, &seen, spec);
    }

    const sorted = try arena.dupe([]const u8, discovered);
    std.mem.sort([]const u8, sorted, {}, lessThanName);
    for (sorted) |name| {
        if (!isSharedLibName(name)) continue;
        const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ discovered_dir, name });
        try addUnique(arena, &out, &seen, full);
    }
    return out.items;
}

fn addUnique(
    arena: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    seen: *std.StringHashMapUnmanaged(void),
    path: []const u8,
) !void {
    const key = try std.ascii.allocLowerString(arena, baseName(path));
    const gop = try seen.getOrPut(arena, key);
    if (gop.found_existing) return;
    try out.append(arena, path);
}

test "planLoadOrder is deterministic, sorted, and de-duplicates by library name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const explicit = [_][]const u8{ "scene", "libs/zeta.so", "physics-jolt", "libs/Alpha.dll" };
    const discovered = [_][]const u8{ "zeta.so", "beta.so", "alpha.dll", "readme.txt" };
    const plan = try planLoadOrder(arena, &explicit, ".zengy/plugins", &discovered);

    try std.testing.expectEqual(@as(usize, 3), plan.len);
    try std.testing.expectEqualStrings("libs/zeta.so", plan[0]);
    try std.testing.expectEqualStrings("libs/Alpha.dll", plan[1]);
    try std.testing.expectEqualStrings(".zengy/plugins/beta.so", plan[2]);

    // Input order of the discovered directory never changes the plan.
    const shuffled = [_][]const u8{ "beta.so", "alpha.dll", "zeta.so" };
    const plan2 = try planLoadOrder(arena, &explicit, ".zengy/plugins", &shuffled);
    try std.testing.expectEqualDeep(plan, plan2);
}

test "requestsPhysics matches only the physics package family" {
    try std.testing.expect(requestsPhysics("physics"));
    try std.testing.expect(requestsPhysics("physics-jolt"));
    try std.testing.expect(!requestsPhysics("my-physics-tools.so"));
    try std.testing.expect(!requestsPhysics("metaphysics"));
}
