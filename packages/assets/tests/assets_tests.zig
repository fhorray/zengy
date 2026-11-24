//! Asset Service Package Tests (`packages/assets/tests/assets_tests.zig`).
//!
//! Validates Phase 11 `AssetService`: importer priority resolution, URI caching,
//! hot `reload()` version bumping, and stale `AssetHandle` rejection after unload.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const assets = @import("assets");

test "AssetService importer priority, caching, reload, and stale handle rejection" {
    const TextImporter = struct {
        fn importLow(allocator: std.mem.Allocator, _: []const u8, raw: []const u8) !assets.AssetArtifact {
            return .{
                .kind = try allocator.dupe(u8, "text/low"),
                .bytes = try allocator.dupe(u8, raw),
            };
        }
        fn importHigh(allocator: std.mem.Allocator, _: []const u8, raw: []const u8) !assets.AssetArtifact {
            const upper = try allocator.dupe(u8, raw);
            for (upper) |*c| c.* = std.ascii.toUpper(c.*);
            return .{
                .kind = try allocator.dupe(u8, "text/high"),
                .bytes = upper,
            };
        }
    };

    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(assets.module());
    try app.initialize();

    const svc = app.resources.get(assets.AssetService).?;
    try svc.registerImporter(.{ .id = "low", .extension = ".txt", .priority = 10, .import_fn = TextImporter.importLow });
    try svc.registerImporter(.{ .id = "high", .extension = ".txt", .priority = 200, .import_fn = TextImporter.importHigh });

    const h1 = try svc.loadFromBytes("project://hello.txt", "hello");
    const h2 = try svc.loadFromBytes("project://hello.txt", "ignored");
    try testing.expectEqual(h1, h2);
    try testing.expectEqualStrings("HELLO", svc.getBytes(h1).?);
    try testing.expectEqual(@as(?u32, 1), svc.getVersion(h1));

    try svc.reload(h1, "world");
    try testing.expectEqualStrings("WORLD", svc.getBytes(h1).?);
    try testing.expectEqual(@as(?u32, 2), svc.getVersion(h1));

    try testing.expect(svc.unload(h1));
    try testing.expect(svc.getBytes(h1) == null);
}

test "AssetService unregisters owned importers cleanly on module unload" {
    const DummyImp = struct {
        fn importFn(allocator: std.mem.Allocator, _: []const u8, raw: []const u8) !assets.AssetArtifact {
            return .{ .kind = try allocator.dupe(u8, "raw"), .bytes = try allocator.dupe(u8, raw) };
        }
    };

    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();
    try app.registerModule(assets.module());
    try app.initialize();

    const svc = app.resources.get(assets.AssetService).?;
    try svc.registerImporter(.{
        .id = "plugin.custom",
        .extension = ".custom",
        .owner_id = 777,
        .import_fn = DummyImp.importFn,
    });
    try testing.expect(svc.resolveImporter("project://a.custom") != null);

    try testing.expectEqual(@as(usize, 1), svc.unregisterImportersByOwner(777));
    try testing.expect(svc.resolveImporter("project://a.custom") == null);
}

test "AssetService reuses unloaded slots and keeps reloaded bytes alive until collectGarbage" {
    const RawImp = struct {
        fn importFn(allocator: std.mem.Allocator, _: []const u8, raw: []const u8) !assets.AssetArtifact {
            return .{ .kind = try allocator.dupe(u8, "raw"), .bytes = try allocator.dupe(u8, raw) };
        }
    };

    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();
    try app.registerModule(assets.module());
    try app.initialize();

    const svc = app.resources.get(assets.AssetService).?;
    try svc.registerImporter(.{ .id = "raw", .extension = ".bin", .import_fn = RawImp.importFn });

    const a = try svc.loadFromBytes("project://a.bin", "v1");
    const borrowed_v1 = svc.getBytes(a).?;
    try svc.reload(a, "v2");
    // Retired v1 slice stays valid until collectGarbage()
    try testing.expectEqualStrings("v1", borrowed_v1);
    try testing.expectEqualStrings("v2", svc.getBytes(a).?);
    svc.collectGarbage();

    try testing.expect(svc.unload(a));
    const b = try svc.loadFromBytes("project://b.bin", "new");
    try testing.expectEqual(a.index, b.index);
    try testing.expect(a.generation != b.generation);
}

test "AssetService survives allocation failures at every point without leaks, double-frees, or lost slots" {
    const RawImp = struct {
        fn importFn(allocator: std.mem.Allocator, _: []const u8, raw: []const u8) !assets.AssetArtifact {
            const kind = try allocator.dupe(u8, "raw");
            errdefer allocator.free(kind);
            return .{ .kind = kind, .bytes = try allocator.dupe(u8, raw) };
        }
    };

    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var svc = assets.AssetService.init(failing.allocator());
        defer svc.deinit();
        svc.registerImporter(.{ .id = "raw", .extension = ".raw", .import_fn = RawImp.importFn }) catch continue;

        for (0..3) |round| {
            const h = svc.loadFromBytes("project://a.raw", "one") catch continue;
            const before = svc.getBytes(h).?;
            const version_before = svc.getVersion(h).?;
            svc.reload(h, "two") catch {
                // A failed reload must keep the previous payload and version intact.
                try testing.expectEqualStrings(before, svc.getBytes(h).?);
                try testing.expectEqual(version_before, svc.getVersion(h).?);
            };
            if (!svc.unload(h)) {
                // Bookkeeping could not be reserved: asset must remain loaded and valid.
                try testing.expect(svc.getBytes(h) != null);
                _ = svc.unload(h);
            }
            if (round == 1) svc.collectGarbage();
        }
        // No slot may be permanently lost: slots == live + free list.
        var live: usize = 0;
        for (svc.assets.items) |s| {
            if (s.alive) live += 1;
        }
        try testing.expectEqual(svc.assets.items.len, live + svc.free_indices.items.len);
    }
}

test "AssetService dependency graph: cycles rejected, dependents invalidated on reload, shared assets protected" {
    const RawImp = struct {
        fn importFn(allocator: std.mem.Allocator, _: []const u8, raw: []const u8) !assets.AssetArtifact {
            return .{ .kind = try allocator.dupe(u8, "raw"), .bytes = try allocator.dupe(u8, raw) };
        }
    };
    var svc = assets.AssetService.init(testing.allocator);
    defer svc.deinit();
    try svc.registerImporter(.{ .id = "raw", .extension = ".raw", .import_fn = RawImp.importFn });

    const tex = try svc.loadFromBytes("project://tex.raw", "t");
    const mat = try svc.loadFromBytes("project://mat.raw", "m");
    const mesh = try svc.loadFromBytes("project://mesh.raw", "x");
    try svc.addDependency(mat, tex);
    try svc.addDependency(mesh, mat);
    try svc.addDependency(mesh, mat); // duplicate is a no-op
    try testing.expectEqual(@as(usize, 1), svc.dependenciesOf(mesh).len);

    try testing.expectError(error.DependencyCycle, svc.addDependency(tex, mesh)); // would close a loop
    try testing.expectError(error.DependencyCycle, svc.addDependency(mat, mat));

    const users = try svc.dependentsOf(testing.allocator, tex);
    defer testing.allocator.free(users);
    try testing.expectEqual(@as(usize, 2), users.len); // mat and (transitively) mesh

    const before = svc.getVersion(mesh).?;
    try testing.expectEqual(@as(usize, 2), try svc.reloadAndInvalidate(tex, "t2"));
    try testing.expectEqual(before + 1, svc.getVersion(mesh).?);

    try testing.expect(!svc.unloadIfUnreferenced(tex)); // mat still uses it
    try testing.expect(svc.unloadIfUnreferenced(mesh));
    try testing.expect(svc.unloadIfUnreferenced(mat));
    try testing.expect(svc.unloadIfUnreferenced(tex));
    // A reused slot starts with no stale dependencies.
    const again = try svc.loadFromBytes("project://again.raw", "a");
    try testing.expectEqual(@as(usize, 0), svc.dependenciesOf(again).len);
}
