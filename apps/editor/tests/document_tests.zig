//! Editor document tests (`apps/editor/tests/document_tests.zig`): hierarchy, selection and
//! transform undo/redo over a headless `engine.World`.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const render_3d = @import("render_3d");
const document = @import("document");

fn spawnAt(app: *engine.App, x: f32) !engine.EntityHandle {
    const e = try app.world.spawn();
    try app.world.set(e, render_3d.Transform3D, .{ .position = .{ x, 0, 0 } });
    return e;
}

test "register, select and relative selection wrap through the hierarchy" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();
    var doc = document.EditorDocument.init(testing.allocator);
    defer doc.deinit();

    const a = try spawnAt(&app, 0);
    const b = try spawnAt(&app, 1);
    const c = try spawnAt(&app, 2);
    try doc.register(a, "A");
    try doc.register(b, "B");
    try doc.register(c, "C");

    try testing.expect(doc.selectedEntry() == null);
    doc.selectRelative(1); // nothing selected: first row
    try testing.expectEqualStrings("A", doc.selectedEntry().?.name());
    doc.selectRelative(-1); // wraps to the last row
    try testing.expectEqualStrings("C", doc.selectedEntry().?.name());
    doc.selectRelative(1);
    try testing.expectEqualStrings("A", doc.selectedEntry().?.name());

    doc.select(b);
    try testing.expectEqualStrings("B", doc.selectedEntry().?.name());
    doc.select(null);
    try testing.expect(doc.selected == null);

    const stranger = try spawnAt(&app, 9);
    doc.select(stranger); // not listed: cannot be selected
    try testing.expect(doc.selected == null);
}

test "long names are truncated" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();
    var doc = document.EditorDocument.init(testing.allocator);
    defer doc.deinit();
    const e = try spawnAt(&app, 0);
    try doc.register(e, "an-entity-name-that-is-much-longer-than-the-limit");
    try testing.expectEqual(@as(usize, document.MAX_NAME_LEN), doc.entries.items[0].name().len);
}

test "setTransform records history; undo and redo restore it; a new edit clears redo" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();
    var doc = document.EditorDocument.init(testing.allocator);
    defer doc.deinit();

    const e = try spawnAt(&app, 1);
    try doc.register(e, "E");

    try doc.setTransform(&app.world, e, .{ .position = .{ 2, 0, 0 } });
    try doc.setTransform(&app.world, e, .{ .position = .{ 3, 0, 0 } });
    try testing.expectEqual(@as(f32, 3), app.world.get(e, render_3d.Transform3D).?.position[0]);

    try testing.expect(try doc.undo(&app.world));
    try testing.expectEqual(@as(f32, 2), app.world.get(e, render_3d.Transform3D).?.position[0]);
    try testing.expect(try doc.undo(&app.world));
    try testing.expectEqual(@as(f32, 1), app.world.get(e, render_3d.Transform3D).?.position[0]);
    try testing.expect(!(try doc.undo(&app.world)));

    try testing.expect(try doc.redo(&app.world));
    try testing.expectEqual(@as(f32, 2), app.world.get(e, render_3d.Transform3D).?.position[0]);

    try doc.setTransform(&app.world, e, .{ .position = .{ 7, 0, 0 } });
    try testing.expect(!(try doc.redo(&app.world)));
    try testing.expectEqual(@as(f32, 7), app.world.get(e, render_3d.Transform3D).?.position[0]);
}

test "setTransform on an entity without a Transform3D fails without recording" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();
    var doc = document.EditorDocument.init(testing.allocator);
    defer doc.deinit();

    const bare = try app.world.spawn();
    try testing.expectError(error.EntityNotInDocument, doc.setTransform(&app.world, bare, .{}));
    try doc.register(bare, "Bare");
    try testing.expectError(error.MissingTransform, doc.setTransform(&app.world, bare, .{}));
    try testing.expect(!(try doc.undo(&app.world)));
}

test "undo skips stale targets and does not report false success" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();
    var doc = document.EditorDocument.init(testing.allocator);
    defer doc.deinit();

    const e = try spawnAt(&app, 1);
    try doc.register(e, "E");
    try doc.setTransform(&app.world, e, .{ .position = .{ 2, 0, 0 } });
    _ = try app.world.despawn(e);
    _ = doc.unregister(e);
    try testing.expect(!(try doc.undo(&app.world)));
}

test "unregister clears selection and drops that entity's history" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();
    var doc = document.EditorDocument.init(testing.allocator);
    defer doc.deinit();

    const a = try spawnAt(&app, 0);
    const b = try spawnAt(&app, 0);
    try doc.register(a, "A");
    try doc.register(b, "B");
    try doc.setTransform(&app.world, a, .{ .position = .{ 1, 0, 0 } });
    try doc.setTransform(&app.world, b, .{ .position = .{ 5, 0, 0 } });
    doc.select(a);

    try testing.expect(doc.unregister(a));
    try testing.expect(doc.selected == null);
    try testing.expect(!doc.unregister(a));
    try testing.expectEqual(@as(usize, 1), doc.entries.items.len);

    // Only b's edit remains.
    try testing.expect(try doc.undo(&app.world));
    try testing.expectEqual(@as(f32, 0), app.world.get(b, render_3d.Transform3D).?.position[0]);
    try testing.expect(!(try doc.undo(&app.world)));
}

test "history is bounded" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();
    var doc = document.EditorDocument.init(testing.allocator);
    defer doc.deinit();
    const e = try spawnAt(&app, 0);
    try doc.register(e, "E");

    var i: usize = 0;
    while (i < document.MAX_HISTORY + 10) : (i += 1) {
        try doc.setTransform(&app.world, e, .{ .position = .{ @floatFromInt(i + 1), 0, 0 } });
    }
    try testing.expectEqual(@as(usize, document.MAX_HISTORY), doc.undo_stack.items.len);
}
