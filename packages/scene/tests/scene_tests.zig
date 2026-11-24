//! 2D Scene & Transform Graph Tests (`packages/scene/tests/scene_tests.zig`).
//!
//! Validates Phase 11 `official.scene`: parent-child `Transform2D` propagation
//! during `.post_update` and headless `SceneSnapshot` capture/restore across Worlds.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const scene = @import("scene");

test "Transform2D parent-child propagation and SceneSnapshot restore" {
    var app = engine.App.init(testing.allocator, .{ .max_frames = 1 });
    defer app.deinit();

    try app.registerModule(scene.module());

    const parent = try app.world.spawn();
    try app.world.set(parent, scene.Transform2D, .{ .x = 100, .y = 50 });

    const child = try app.world.spawn();
    try app.world.set(child, scene.Transform2D, .{ .x = 25, .y = -10 });
    try app.world.set(child, scene.Parent, .{ .entity = parent });

    try app.run();

    const ct = app.world.getConst(child, scene.Transform2D).?;
    try testing.expectApproxEqAbs(@as(f32, 125.0), ct.world_x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 40.0), ct.world_y, 0.001);

    // Capture and restore into an independent World without editor dependencies.
    var snap = try scene.SceneSnapshot.capture(testing.allocator, &app.world);
    defer snap.deinit();
    try testing.expectEqual(@as(usize, 2), snap.records.items.len);

    var restored_world = engine.World.init(testing.allocator, .{ .index = 1, .generation = 1 });
    defer restored_world.deinit();
    const count = try snap.restore(&restored_world);
    try testing.expectEqual(@as(usize, 2), count);

    // Verify restored hierarchy & persistent GUIDs
    var rq = try restored_world.query(.{ .read = .{scene.Transform2D} });
    var found_parent_link = false;
    const parent_guid_orig = app.world.getGuid(parent).?;
    const child_guid_orig = app.world.getGuid(child).?;
    while (rq.next()) |row| {
        const g = restored_world.getGuid(row.entity).?;
        if (g == child_guid_orig) {
            const p_comp = restored_world.getConst(row.entity, scene.Parent).?;
            try testing.expectEqual(parent_guid_orig, restored_world.getGuid(p_comp.entity).?);
            found_parent_link = true;
        }
    }
    rq.deinit();
    try testing.expect(found_parent_link);
}

test "Transform2D propagates parent rotation + scale and breaks Parent cycles safely" {
    var app = engine.App.init(testing.allocator, .{ .max_frames = 1 });
    defer app.deinit();

    try app.registerModule(scene.module());

    // Parent at (10, 0) rotated +90 deg with scale 2x
    const p = try app.world.spawn();
    try app.world.set(p, scene.Transform2D, .{
        .x = 10,
        .y = 0,
        .rotation_rad = std.math.pi / 2.0,
        .scale_x = 2.0,
        .scale_y = 2.0,
    });
    // Child at local (5, 0) -> scaled (10, 0) -> rotated 90 deg (0, 10) -> world (10, 10)
    const c = try app.world.spawn();
    try app.world.set(c, scene.Transform2D, .{ .x = 5, .y = 0 });
    try app.world.set(c, scene.Parent, .{ .entity = p });

    // Cycle pair A <-> B must not explode coordinates
    const a = try app.world.spawn();
    const b = try app.world.spawn();
    try app.world.set(a, scene.Transform2D, .{ .x = 3, .y = 4 });
    try app.world.set(b, scene.Transform2D, .{ .x = 7, .y = 8 });
    try app.world.set(a, scene.Parent, .{ .entity = b });
    try app.world.set(b, scene.Parent, .{ .entity = a });

    try app.run();

    const ct = app.world.getConst(c, scene.Transform2D).?;
    try testing.expectApproxEqAbs(@as(f32, 10.0), ct.world_x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 10.0), ct.world_y, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 2.0), ct.world_scale_x, 0.001);

    const at = app.world.getConst(a, scene.Transform2D).?;
    try testing.expectApproxEqAbs(@as(f32, 3.0), at.world_x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 4.0), at.world_y, 0.001);
}

test "Transform2D propagation resolves deep chains once and keeps cycle descendants local" {
    var app = engine.App.init(testing.allocator, .{ .max_frames = 1 });
    defer app.deinit();
    try app.registerModule(scene.module());

    var prev = try app.world.spawn();
    try app.world.set(prev, scene.Transform2D, .{ .x = 1 });
    const depth = 3000;
    for (1..depth) |_| {
        const e = try app.world.spawn();
        try app.world.set(e, scene.Transform2D, .{ .x = 1 });
        try app.world.set(e, scene.Parent, .{ .entity = prev });
        prev = e;
    }

    // A two-node cycle plus a child hanging off it: all fall back to local values.
    const a = try app.world.spawn();
    const b = try app.world.spawn();
    const c = try app.world.spawn();
    try app.world.set(a, scene.Transform2D, .{ .x = 10 });
    try app.world.set(b, scene.Transform2D, .{ .x = 20 });
    try app.world.set(c, scene.Transform2D, .{ .x = 30 });
    try app.world.set(a, scene.Parent, .{ .entity = b });
    try app.world.set(b, scene.Parent, .{ .entity = a });
    try app.world.set(c, scene.Parent, .{ .entity = a });

    try app.run();

    try testing.expectApproxEqAbs(@as(f32, depth), app.world.getConst(prev, scene.Transform2D).?.world_x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 10), app.world.getConst(a, scene.Transform2D).?.world_x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 20), app.world.getConst(b, scene.Transform2D).?.world_x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 30), app.world.getConst(c, scene.Transform2D).?.world_x, 0.001);
}

const graph = scene.graph;

fn spawnNode(world: *engine.World, x: f32) !engine.EntityHandle {
    const e = try world.spawn();
    try world.set(e, scene.Transform2D, .{ .x = x });
    return e;
}

test "SceneGraph reparent maintains child lists, rejects cycles, and preserves world transform" {
    var app = engine.App.init(testing.allocator, .{ .max_frames = 1 });
    defer app.deinit();
    try app.registerModule(scene.module());
    const w = &app.world;

    const root = try spawnNode(w, 100);
    const a = try spawnNode(w, 1);
    const b = try spawnNode(w, 2);
    const c = try spawnNode(w, 3);
    try graph.reparent(w, a, root, .{});
    try graph.reparent(w, b, root, .{});
    try graph.reparent(w, c, a, .{});
    try testing.expectEqual(@as(usize, 2), graph.childCount(w, root));
    try testing.expectEqual(@as(usize, 1), graph.childCount(w, a));

    try testing.expectError(error.HierarchyCycle, graph.reparent(w, root, c, .{}));
    try testing.expectError(error.HierarchyCycle, graph.reparent(w, a, a, .{}));
    try testing.expectEqual(@as(usize, 2), graph.childCount(w, root));

    // Head removal and middle removal keep the list consistent.
    try graph.reparent(w, b, null, .{});
    try testing.expectEqual(@as(usize, 1), graph.childCount(w, root));
    try testing.expect(graph.parentOf(w, b) == null);

    // preserve_world: c has world x = 100+1+3 = 104; moving it under b (root at x=2) keeps 104.
    try app.run();
    try testing.expectApproxEqAbs(@as(f32, 104), w.getConst(c, scene.Transform2D).?.world_x, 0.001);
    try graph.reparent(w, c, b, .{ .preserve_world = true });
    try testing.expectApproxEqAbs(@as(f32, 102), w.getConst(c, scene.Transform2D).?.x, 0.001);
    try testing.expectEqual(@as(usize, 0), graph.childCount(w, a));
    try testing.expectEqual(@as(usize, 1), graph.childCount(w, b));
}

test "SceneGraph despawn policies" {
    var app = engine.App.init(testing.allocator, .{ .max_frames = 1 });
    defer app.deinit();
    try app.registerModule(scene.module());
    const w = &app.world;

    const root = try spawnNode(w, 10);
    const mid = try spawnNode(w, 5);
    const leaf1 = try spawnNode(w, 1);
    const leaf2 = try spawnNode(w, 2);
    try graph.reparent(w, mid, root, .{});
    try graph.reparent(w, leaf1, mid, .{});
    try graph.reparent(w, leaf2, mid, .{});
    try app.run();

    try graph.despawnNode(w, mid, .reparent_to_parent);
    try testing.expect(!w.isAlive(mid));
    try testing.expectEqual(@as(usize, 2), graph.childCount(w, root));
    try testing.expectEqual(root, graph.parentOf(w, leaf1).?);
    // world x preserved: 10 + 5 + 1
    try testing.expectApproxEqAbs(@as(f32, 16), w.getConst(leaf1, scene.Transform2D).?.x + 10, 0.001);

    try graph.despawnNode(w, root, .orphan);
    try testing.expect(graph.parentOf(w, leaf1) == null);
    try testing.expect(w.isAlive(leaf1));

    const p = try spawnNode(w, 0);
    const k1 = try spawnNode(w, 0);
    const k2 = try spawnNode(w, 0);
    const gk = try spawnNode(w, 0);
    try graph.reparent(w, k1, p, .{});
    try graph.reparent(w, k2, p, .{});
    try graph.reparent(w, gk, k1, .{});
    try graph.despawnNode(w, p, .cascade);
    for ([_]engine.EntityHandle{ p, k1, k2, gk }) |e| try testing.expect(!w.isAlive(e));
    try testing.expect(w.isAlive(leaf1));
}

test "SceneGraph rebuildLinks repairs links from raw Parent components and breaks cycles" {
    var app = engine.App.init(testing.allocator, .{ .max_frames = 1 });
    defer app.deinit();
    try app.registerModule(scene.module());
    const w = &app.world;

    const p = try spawnNode(w, 0);
    const k = try spawnNode(w, 0);
    const x = try spawnNode(w, 0);
    const y = try spawnNode(w, 0);
    try w.set(k, scene.Parent, .{ .entity = p });
    try w.set(x, scene.Parent, .{ .entity = y });
    try w.set(y, scene.Parent, .{ .entity = x });
    try graph.rebuildLinks(w);
    try testing.expectEqual(@as(usize, 1), graph.childCount(w, p));
    // Exactly one edge of the 2-cycle survives.
    try testing.expectEqual(@as(usize, 1), graph.childCount(w, x) + graph.childCount(w, y));
}
