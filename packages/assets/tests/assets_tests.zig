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
