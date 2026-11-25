//! Editor shell tests (`apps/editor/tests/shell_tests.zig`).
//!
//! Validates Phase 12 `official.tools.editor_shell`: default panel registration,
//! schema-driven field inspection via `TypeRegistry`, and undo/redo transactions.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const window = @import("window");
const graphics = @import("graphics");
const ui_core = @import("ui_core");
const editor_shell = @import("editor_shell");

test "EditorShell panels, schema-driven inspector, and undo/redo" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(window.module());
    try app.registerModule(graphics.module());
    try app.registerModule(ui_core.module());
    try app.registerModule(editor_shell.module());
    try app.initialize();

    const shell = app.resources.get(editor_shell.EditorShellService).?;
    try testing.expectEqual(@as(usize, 5), shell.panelCount());

    const schema = try app.types.registerSchema("game", "Health", 1, .blittable, &.{
        .{ .name = "hp", .field_type = .f32_t },
    });
    _ = try app.world.registerDynamicComponent("game.Health", schema.byte_size);

    const e = try app.world.spawn();
    const init_bytes = try testing.allocator.alloc(u8, schema.byte_size);
    defer testing.allocator.free(init_bytes);
    @memset(init_bytes, 0);
    try engine.TypeRegistry.setField(schema, init_bytes, "hp", .{ .f32_t = 100.0 });
    try app.world.setRaw(e, schema.component_type_id, init_bytes);

    // Edit via inspector and verify undo/redo.
    try shell.setInspectedField(&app.world, &app.types, e, schema.schema_id, "hp", .{ .f32_t = 42.5 });
    const after_edit = try engine.TypeRegistry.getField(schema, app.world.getRaw(e, schema.component_type_id).?, "hp");
    try testing.expectApproxEqAbs(@as(f32, 42.5), after_edit.f32_t, 0.001);

    try testing.expect(try shell.undo(&app.world, &app.types));
    const after_undo = try engine.TypeRegistry.getField(schema, app.world.getRaw(e, schema.component_type_id).?, "hp");
    try testing.expectApproxEqAbs(@as(f32, 100.0), after_undo.f32_t, 0.001);

    try testing.expect(try shell.redo(&app.world, &app.types));
    const after_redo = try engine.TypeRegistry.getField(schema, app.world.getRaw(e, schema.component_type_id).?, "hp");
    try testing.expectApproxEqAbs(@as(f32, 42.5), after_redo.f32_t, 0.001);
}
