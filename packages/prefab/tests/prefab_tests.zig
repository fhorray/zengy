//! Prefab package tests: batched atomic instantiation, migration, overrides, hierarchy hook.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const prefab = @import("prefab");
const toml_format = @import("toml_format");

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

test "TOML authoring files load through the JSON bridge" {
    var types = engine.TypeRegistry.init(testing.allocator);
    defer types.deinit();
    _ = try types.registerSchema("game", "Stats", 1, .blittable, &.{
        .{ .name = "hp", .field_type = .i32_t },
        .{ .name = "armor", .field_type = .f32_t },
    });
    _ = try types.registerSchema("game", "Pose", 1, .blittable, &.{
        .{ .name = "alive", .field_type = .bool_t },
        .{ .name = "pos", .field_type = .vec3_t },
    });

    const doc =
        \\[prefab]
        \\id = "enemy.guard"
        \\
        \\[[entities]]
        \\id = "guard"
        \\[entities.components."game.Stats"]
        \\hp = 150
        \\armor = 2.5
        \\
        \\[[entities]]
        \\id = "sword"
        \\parent = "guard"
        \\[entities.components."game.Pose"]
        \\alive = true
        \\pos = [0.0, 1.5, 0.0]
    ;
    const table = try toml_format.TomlService.parseTable(testing.allocator, doc);
    defer toml_format.TomlService.freeTable(testing.allocator, table);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const json_doc = try toml_format.tableToJsonValue(arena.allocator(), table);

    var pf = try prefab.json.parsePrefabValue(testing.allocator, &types, json_doc);
    defer pf.deinit();
    try testing.expectEqual(@as(usize, 2), pf.entities.items.len);
    var world = engine.World.init(testing.allocator, .{ .index = 0, .generation = 1 });
    defer world.deinit();
    var inst = try prefab.instantiate(testing.allocator, &world, &types, &pf, .{});
    defer inst.deinit();
    const stats = types.getLatest("game", "Stats").?;
    const raw = world.getRaw(inst.find(&pf, "guard").?, engine.World.dynamicTypeId("game.Stats")).?;
    try testing.expectEqual(@as(i32, 150), (try engine.TypeRegistry.getField(stats, raw, "hp")).i32_t);
    try testing.expectEqual(@as(f32, 2.5), (try engine.TypeRegistry.getField(stats, raw, "armor")).f32_t);

    // Date/time values have no JSON counterpart and are rejected, not silently dropped.
    const bad = try toml_format.TomlService.parseTable(testing.allocator, "when = 2026-11-24\n");
    defer toml_format.TomlService.freeTable(testing.allocator, bad);
    try testing.expectError(error.UnsupportedTomlValue, toml_format.tableToJsonValue(arena.allocator(), bad));
}

fn makeStatsTypes(types: *engine.TypeRegistry) !engine.ComponentSchema {
    return types.registerSchema("game", "Stats", 1, .blittable, &.{.{ .name = "hp", .field_type = .i32_t }});
}

fn addStatsEntity(pf: *prefab.Prefab, schema: engine.ComponentSchema, id: []const u8, parent: ?[]const u8, hp: i32) !void {
    try pf.addEntity(id, parent);
    var b: [4]u8 = undefined;
    try engine.TypeRegistry.setField(schema, &b, "hp", .{ .i32_t = hp });
    try pf.addComponent(id, schema, &b);
}

fn hpOf(world: *engine.World, schema: engine.ComponentSchema, e: engine.EntityHandle) !i32 {
    const raw = world.getRaw(e, engine.World.dynamicTypeId("game.Stats")).?;
    return (try engine.TypeRegistry.getField(schema, raw, "hp")).i32_t;
}

test "nested prefabs expand under an anchor, apply nested overrides, and reject cycles and depth" {
    var types = engine.TypeRegistry.init(testing.allocator);
    defer types.deinit();
    const stats = try makeStatsTypes(&types);

    var lib = prefab.PrefabLibrary.init(testing.allocator);
    defer lib.deinit();
    var weapon = prefab.Prefab.init(testing.allocator);
    try addStatsEntity(&weapon, stats, "blade", null, 10);
    try addStatsEntity(&weapon, stats, "gem", "blade", 1);
    try lib.put("weapon", weapon);

    var guard = prefab.Prefab.init(testing.allocator);
    defer guard.deinit();
    try addStatsEntity(&guard, stats, "body", null, 100);
    // The nested weapon's blade gets 99 HP; the gem keeps its authored 1.
    try guard.addNested("hand", "body", "weapon", &.{.{ .local_id = "blade", .stable_id = stats.stable_id, .field = "hp", .value = .{ .i32_t = 99 } }});

    var world = engine.World.init(testing.allocator, .{ .index = 0, .generation = 1 });
    defer world.deinit();
    Linked.reset();
    var inst = try prefab.instantiate(testing.allocator, &world, &types, &guard, .{ .resolver = lib.resolver(), .link = Linked.link });
    defer inst.deinit();

    // body, hand (anchor) + blade, gem from the nested prefab: 4 entities, top-level first.
    try testing.expectEqual(@as(usize, 4), inst.handles.len);
    try testing.expectEqual(@as(usize, 4), world.entity_count);
    try testing.expectEqual(@as(i32, 100), try hpOf(&world, stats, inst.find(&guard, "body").?));
    try testing.expectEqual(@as(i32, 99), try hpOf(&world, stats, inst.handles[2])); // blade
    try testing.expectEqual(@as(i32, 1), try hpOf(&world, stats, inst.handles[3])); // gem
    // hierarchy: hand -> body, blade -> hand, gem -> blade
    try testing.expectEqual(@as(usize, 3), Linked.count);
    try testing.expect(Linked.has(inst.handles[1], inst.handles[0]));
    try testing.expect(Linked.has(inst.handles[2], inst.handles[1]));
    try testing.expect(Linked.has(inst.handles[3], inst.handles[2]));

    // Without a resolver, nesting cannot be satisfied.
    try testing.expectError(error.UnknownPrefab, prefab.instantiate(testing.allocator, &world, &types, &guard, .{}));
    try testing.expectEqual(@as(usize, 4), world.entity_count); // nothing leaked from the failed call

    // Cycle: a -> b -> a.
    var pa = prefab.Prefab.init(testing.allocator);
    try pa.addNested("n", null, "b", &.{});
    try lib.put("a", pa);
    var pb = prefab.Prefab.init(testing.allocator);
    try pb.addNested("n", null, "a", &.{});
    try lib.put("b", pb);
    try testing.expectError(error.NestedPrefabCycle, prefab.instantiate(testing.allocator, &world, &types, lib.get("a").?, .{ .resolver = lib.resolver() }));

    // Override naming a nonexistent nested entity is rejected.
    var bad = prefab.Prefab.init(testing.allocator);
    defer bad.deinit();
    try bad.addNested("h", null, "weapon", &.{.{ .local_id = "nope", .stable_id = stats.stable_id, .field = "hp", .value = .{ .i32_t = 1 } }});
    try testing.expectError(error.UnknownOverrideTarget, prefab.instantiate(testing.allocator, &world, &types, &bad, .{ .resolver = lib.resolver() }));
}

const Linked = struct {
    var pairs: [16]struct { c: engine.EntityHandle, p: engine.EntityHandle } = undefined;
    var count: usize = 0;
    fn reset() void {
        count = 0;
    }
    fn link(_: ?*anyopaque, _: *engine.World, child: engine.EntityHandle, parent: engine.EntityHandle) anyerror!void {
        pairs[count] = .{ .c = child, .p = parent };
        count += 1;
    }
    fn has(c: engine.EntityHandle, p: engine.EntityHandle) bool {
        for (pairs[0..count]) |x| {
            if (std.meta.eql(x.c, c) and std.meta.eql(x.p, p)) return true;
        }
        return false;
    }
};

test "cooked binary round-trips prefabs (nested + overrides) and rejects corruption" {
    var types = engine.TypeRegistry.init(testing.allocator);
    defer types.deinit();
    const stats = try makeStatsTypes(&types);

    var pf = prefab.Prefab.init(testing.allocator);
    defer pf.deinit();
    try addStatsEntity(&pf, stats, "body", null, 100);
    try pf.addNested("hand", "body", "weapon", &.{
        .{ .local_id = "blade", .stable_id = stats.stable_id, .field = "hp", .value = .{ .i32_t = 99 } },
        .{ .local_id = "blade", .stable_id = stats.stable_id, .field = "pos", .value = .{ .vec3_t = .{ 1, 2, 3 } } },
    });

    const bytes = try prefab.cooked.cook(testing.allocator, &pf);
    defer testing.allocator.free(bytes);
    var back = try prefab.cooked.load(testing.allocator, bytes);
    defer back.deinit();

    try testing.expectEqual(@as(usize, 2), back.entities.items.len);
    try testing.expectEqualStrings("hand", back.entities.items[1].local_id);
    try testing.expectEqualStrings("body", back.entities.items[1].parent.?);
    const n = back.entities.items[1].nested.?;
    try testing.expectEqualStrings("weapon", n.prefab_name);
    try testing.expectEqual(@as(usize, 2), n.overrides.len);
    try testing.expectEqual(@as(i32, 99), n.overrides[0].value.i32_t);
    try testing.expectEqual([3]f32{ 1, 2, 3 }, n.overrides[1].value.vec3_t);
    // Re-cooking the loaded prefab is byte-identical (stable format).
    const bytes2 = try prefab.cooked.cook(testing.allocator, &back);
    defer testing.allocator.free(bytes2);
    try testing.expectEqualSlices(u8, bytes, bytes2);

    // Any single flipped bit is caught by the checksum.
    const mutated = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(mutated);
    for (0..mutated.len) |i| {
        mutated[i] ^= 0x10;
        try testing.expectError(error.CorruptPrefab, prefab.cooked.load(testing.allocator, mutated));
        mutated[i] ^= 0x10;
    }
    // Truncation and garbage never read out of bounds.
    for (0..bytes.len) |len| {
        if (prefab.cooked.load(testing.allocator, bytes[0..len])) |p| {
            var pp = p;
            pp.deinit();
            return error.TestUnexpectedResult;
        } else |_| {}
    }
    try testing.expectError(error.CorruptPrefab, prefab.cooked.load(testing.allocator, "not a prefab at all, definitely"));
}

test "streaming: budgeted commit, duplicate/cancel handling, atomic failure, unload" {
    var types = engine.TypeRegistry.init(testing.allocator);
    defer types.deinit();
    const stats = try makeStatsTypes(&types);
    var world = engine.World.init(testing.allocator, .{ .index = 0, .generation = 1 });
    defer world.deinit();

    var cell = prefab.Prefab.init(testing.allocator);
    defer cell.deinit();
    try addStatsEntity(&cell, stats, "a", null, 1);
    try addStatsEntity(&cell, stats, "b", "a", 2);
    try addStatsEntity(&cell, stats, "c", "a", 3);

    var st = prefab.streaming.CellStreamer.init(testing.allocator);
    defer st.deinit();

    // Prepare off to the side (no world access), then queue three cells.
    try st.request("north", try prefab.prepare(testing.allocator, &types, &cell, .{}), .{});
    try st.request("south", try prefab.prepare(testing.allocator, &types, &cell, .{}), .{});
    try st.request("east", try prefab.prepare(testing.allocator, &types, &cell, .{}), .{});
    try testing.expectError(error.CellAlreadyQueued, st.request("north", try prefab.prepare(testing.allocator, &types, &cell, .{}), .{}));
    try testing.expect(st.cancel("east"));
    try testing.expect(!st.cancel("east"));

    // Budget of 4 entities: "north" (3) loads, "south" (3) would exceed it and waits.
    try testing.expectEqual(@as(usize, 3), try st.update(&world, 4));
    try testing.expect(st.isLoaded("north") and st.isQueued("south"));
    try testing.expectEqual(@as(usize, 3), world.entity_count);
    // A budget smaller than any cell still makes progress (one cell per call).
    try testing.expectEqual(@as(usize, 3), try st.update(&world, 1));
    try testing.expectEqual(@as(usize, 6), world.entity_count);
    try testing.expectEqual(@as(usize, 0), try st.update(&world, 100));
    try testing.expectError(error.CellAlreadyLoaded, st.request("north", try prefab.prepare(testing.allocator, &types, &cell, .{}), .{}));

    // Unloading removes exactly that cell's entities.
    try testing.expect(st.unload(&world, "north"));
    try testing.expect(!st.unload(&world, "north"));
    try testing.expectEqual(@as(usize, 3), world.entity_count);

    // A failing commit (link error) is atomic and does not wedge the queue.
    const failing = struct {
        fn link(_: ?*anyopaque, _: *engine.World, _: engine.EntityHandle, _: engine.EntityHandle) anyerror!void {
            return error.LinkFailed;
        }
    }.link;
    try st.request("bad", try prefab.prepare(testing.allocator, &types, &cell, .{}), .{ .link = failing });
    try testing.expectError(error.LinkFailed, st.update(&world, 100));
    try testing.expectEqual(@as(usize, 3), world.entity_count);
    try testing.expect(!st.isQueued("bad") and !st.isLoaded("bad"));
}
