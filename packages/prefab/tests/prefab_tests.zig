//! Prefab package tests: batched atomic instantiation, migration, overrides, hierarchy hook.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const prefab = @import("prefab");

const Link = struct { child: engine.EntityHandle, parent: engine.EntityHandle };
var links: [8]Link = undefined;
var link_count: usize = 0;

fn recordLink(_: ?*anyopaque, _: *engine.World, child: engine.EntityHandle, parent: engine.EntityHandle) anyerror!void {
    links[link_count] = .{ .child = child, .parent = parent };
    link_count += 1;
}

fn failingLink(_: ?*anyopaque, _: *engine.World, _: engine.EntityHandle, _: engine.EntityHandle) anyerror!void {
    return error.LinkFailed;
}

fn statsV1ToV2(allocator: std.mem.Allocator, old: []const u8) anyerror![]u8 {
    const out = try allocator.alloc(u8, 8);
    @memcpy(out[0..4], old[0..4]);
    const armor: f32 = 1.5;
    @memcpy(out[4..8], std.mem.asBytes(&armor));
    return out;
}

test "instantiate builds entities, migrates old components, applies overrides, and links parents" {
    var types = engine.TypeRegistry.init(testing.allocator);
    defer types.deinit();
    const v1 = try types.registerSchema("game", "Stats", 1, .blittable, &.{.{ .name = "hp", .field_type = .i32_t }});
    const v2 = try types.registerSchema("game", "Stats", 2, .blittable, &.{
        .{ .name = "hp", .field_type = .i32_t },
        .{ .name = "armor", .field_type = .f32_t },
    });
    try types.registerMigration("game", "Stats", 1, statsV1ToV2);
    const tag = try types.registerSchema("game", "Name", 1, .blittable, &.{.{ .name = "id", .field_type = .u32_t }});

    // The prefab was authored when only Stats v1 existed.
    var pf = prefab.Prefab.init(testing.allocator);
    defer pf.deinit();
    try pf.addEntity("guard", null);
    try pf.addEntity("sword", "guard");
    var v1bytes: [4]u8 = undefined;
    try engine.TypeRegistry.setField(v1, &v1bytes, "hp", .{ .i32_t = 100 });
    try pf.addComponent("guard", v1, &v1bytes);
    var name_bytes: [4]u8 = undefined;
    try engine.TypeRegistry.setField(tag, &name_bytes, "id", .{ .u32_t = 7 });
    try pf.addComponent("sword", tag, &name_bytes);
    try testing.expectError(error.DuplicateLocalId, pf.addEntity("guard", null));
    try testing.expectError(error.UnknownParent, pf.addEntity("x", "missing"));

    var world = engine.World.init(testing.allocator, .{ .index = 0, .generation = 1 });
    defer world.deinit();
    link_count = 0;
    var inst = try prefab.instantiate(testing.allocator, &world, &types, &pf, .{
        .overrides = &.{.{ .local_id = "guard", .stable_id = v2.stable_id, .field = "hp", .value = .{ .i32_t = 250 } }},
        .link = recordLink,
    });
    defer inst.deinit();

    try testing.expectEqual(@as(usize, 2), world.entity_count);
    const guard = inst.find(&pf, "guard").?;
    const sword = inst.find(&pf, "sword").?;
    const stats_tid = engine.World.dynamicTypeId("game.Stats");
    const raw = world.getRaw(guard, stats_tid).?;
    try testing.expectEqual(@as(i32, 250), (try engine.TypeRegistry.getField(v2, raw, "hp")).i32_t); // override wins
    try testing.expectEqual(@as(f32, 1.5), (try engine.TypeRegistry.getField(v2, raw, "armor")).f32_t); // migrated default
    try testing.expectEqual(@as(usize, 1), link_count);
    try testing.expectEqual(sword, links[0].child);
    try testing.expectEqual(guard, links[0].parent);

    // Instantiating again yields independent entities (10k-style repeat use).
    var inst2 = try prefab.instantiate(testing.allocator, &world, &types, &pf, .{});
    defer inst2.deinit();
    try testing.expectEqual(@as(usize, 4), world.entity_count);
    try testing.expect(!std.meta.eql(inst2.find(&pf, "guard").?, guard));
}

test "instantiate is atomic: bad overrides and link failures leave the world untouched" {
    var types = engine.TypeRegistry.init(testing.allocator);
    defer types.deinit();
    const s = try types.registerSchema("game", "Stats", 1, .blittable, &.{.{ .name = "hp", .field_type = .i32_t }});
    var pf = prefab.Prefab.init(testing.allocator);
    defer pf.deinit();
    try pf.addEntity("a", null);
    try pf.addEntity("b", "a");
    var b4: [4]u8 = @splat(0);
    try pf.addComponent("a", s, &b4);
    try pf.addComponent("b", s, &b4);

    var world = engine.World.init(testing.allocator, .{ .index = 0, .generation = 1 });
    defer world.deinit();

    try testing.expectError(error.UnknownOverrideTarget, prefab.instantiate(testing.allocator, &world, &types, &pf, .{
        .overrides = &.{.{ .local_id = "ghost", .stable_id = s.stable_id, .field = "hp", .value = .{ .i32_t = 1 } }},
    }));
    try testing.expectError(error.FieldNotFound, prefab.instantiate(testing.allocator, &world, &types, &pf, .{
        .overrides = &.{.{ .local_id = "a", .stable_id = s.stable_id, .field = "nope", .value = .{ .i32_t = 1 } }},
    }));
    try testing.expectEqual(@as(usize, 0), world.entity_count);

    try testing.expectError(error.LinkFailed, prefab.instantiate(testing.allocator, &world, &types, &pf, .{ .link = failingLink }));
    try testing.expectEqual(@as(usize, 0), world.entity_count);

    // Unknown stored schema (e.g. plugin removed) is reported, not skipped.
    var other = engine.TypeRegistry.init(testing.allocator);
    defer other.deinit();
    try testing.expectError(error.UnknownSchema, prefab.instantiate(testing.allocator, &world, &other, &pf, .{}));
    try testing.expectEqual(@as(usize, 0), world.entity_count);
}

test "official.prefab module provides a PrefabLibrary resource and service" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();
    try app.registerModule(prefab.module());
    try app.initialize();
    const lib = app.resources.get(prefab.PrefabLibrary).?;
    var pf = prefab.Prefab.init(testing.allocator);
    try pf.addEntity("root", null);
    try lib.put("enemy", pf);
    var pf2 = prefab.Prefab.init(testing.allocator);
    try pf2.addEntity("replacement", null);
    try lib.put("enemy", pf2);
    try testing.expectEqualStrings("replacement", lib.get("enemy").?.entities.items[0].local_id);
    try testing.expect(lib.get("missing") == null);
}

test "JSON loader builds a prefab and overrides from authoring text, strictly" {
    var types = engine.TypeRegistry.init(testing.allocator);
    defer types.deinit();
    _ = try types.registerSchema("game", "Stats", 2, .blittable, &.{
        .{ .name = "hp", .field_type = .i32_t },
        .{ .name = "armor", .field_type = .f32_t },
    });
    const pose = try types.registerSchema("game", "Pose", 1, .blittable, &.{
        .{ .name = "alive", .field_type = .bool_t },
        .{ .name = "pos", .field_type = .vec3_t },
    });
    const stats = types.getLatest("game", "Stats").?;

    const doc =
        \\{ "prefab": { "id": "enemy.guard" },
        \\  "entities": [
        \\    { "id": "guard", "components": { "game.Stats": { "hp": 150, "armor": 2.5 } } },
        \\    { "id": "sword", "parent": "guard", "components": { "game.Pose": { "alive": true, "pos": [0, 1.5, 0] } } } ] }
    ;
    var pf = try prefab.json.parsePrefab(testing.allocator, &types, doc);
    defer pf.deinit();
    try testing.expectEqual(@as(usize, 2), pf.entities.items.len);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ovs = try prefab.json.parseOverrides(arena.allocator(), &types,
        \\[ { "entity": "guard", "component": "game.Stats", "field": "hp", "value": 999 } ]
    );
    var world = engine.World.init(testing.allocator, .{ .index = 0, .generation = 1 });
    defer world.deinit();
    var inst = try prefab.instantiate(testing.allocator, &world, &types, &pf, .{ .overrides = ovs });
    defer inst.deinit();

    const guard = inst.find(&pf, "guard").?;
    const sg = world.getRaw(guard, engine.World.dynamicTypeId("game.Stats")).?;
    try testing.expectEqual(@as(i32, 999), (try engine.TypeRegistry.getField(stats, sg, "hp")).i32_t);
    try testing.expectEqual(@as(f32, 2.5), (try engine.TypeRegistry.getField(stats, sg, "armor")).f32_t);
    const sw = world.getRaw(inst.find(&pf, "sword").?, engine.World.dynamicTypeId("game.Pose")).?;
    try testing.expectEqual([3]f32{ 0, 1.5, 0 }, (try engine.TypeRegistry.getField(pose, sw, "pos")).vec3_t);
    try testing.expect((try engine.TypeRegistry.getField(pose, sw, "alive")).bool_t);

    // Strictness: each of these must fail loudly.
    const bad = [_]struct { text: []const u8, err: anyerror }{
        .{ .text = "{\"entities\":[{\"id\":\"a\",\"components\":{\"game.Nope\":{}}}]}", .err = error.UnknownComponentType },
        .{ .text = "{\"entities\":[{\"id\":\"a\",\"components\":{\"game.Stats\":{\"mana\":1}}}]}", .err = error.UnknownField },
        .{ .text = "{\"entities\":[{\"id\":\"a\",\"components\":{\"game.Stats\":{\"hp\":\"many\"}}}]}", .err = error.InvalidFieldValue },
        .{ .text = "{\"entities\":[{\"id\":\"a\",\"components\":{\"game.Stats\":{\"hp\":99999999999}}}]}", .err = error.InvalidFieldValue },
        .{ .text = "{\"entities\":[{\"id\":\"a\",\"components\":{\"game.Pose\":{\"pos\":[1,2]}}}]}", .err = error.InvalidFieldValue },
        .{ .text = "{\"entities\":[{\"id\":\"a\"},{\"id\":\"a\"}]}", .err = error.DuplicateLocalId },
        .{ .text = "{\"entities\":[{\"id\":\"a\",\"parent\":\"zzz\"}]}", .err = error.UnknownParent },
        .{ .text = "{\"nothing\":1}", .err = error.InvalidDocument },
    };
    for (bad) |b| try testing.expectError(b.err, prefab.json.parsePrefab(testing.allocator, &types, b.text));
}

test "reinstantiate swaps instances atomically and keeps the old one on failure" {
    var types = engine.TypeRegistry.init(testing.allocator);
    defer types.deinit();
    const s = try types.registerSchema("game", "Stats", 1, .blittable, &.{.{ .name = "hp", .field_type = .i32_t }});
    var pf = prefab.Prefab.init(testing.allocator);
    defer pf.deinit();
    try pf.addEntity("a", null);
    var b4: [4]u8 = @splat(0);
    try pf.addComponent("a", s, &b4);

    var world = engine.World.init(testing.allocator, .{ .index = 0, .generation = 1 });
    defer world.deinit();
    var inst = try prefab.instantiate(testing.allocator, &world, &types, &pf, .{});
    const old_handle = inst.handles[0];

    // Failing reload (bad override target) keeps the running instance.
    try testing.expectError(error.UnknownOverrideTarget, prefab.reinstantiate(testing.allocator, &world, &types, &pf, &inst, .{
        .overrides = &.{.{ .local_id = "zzz", .stable_id = s.stable_id, .field = "hp", .value = .{ .i32_t = 1 } }},
    }));
    try testing.expect(world.isAlive(old_handle));
    try testing.expectEqual(@as(usize, 1), world.entity_count);

    var fresh = try prefab.reinstantiate(testing.allocator, &world, &types, &pf, &inst, .{});
    defer fresh.deinit();
    try testing.expect(!world.isAlive(old_handle));
    try testing.expect(world.isAlive(fresh.handles[0]));
    try testing.expectEqual(@as(usize, 1), world.entity_count);
}
