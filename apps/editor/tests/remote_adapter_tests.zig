//! Remote integration tests for the editor shell adapter (`apps/editor/tests/remote_adapter_tests.zig`).

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const window = @import("window");
const graphics = @import("graphics");
const ui_core = @import("ui_core");
const dev_tools = @import("dev_tools");
const picking = @import("picking");
const remote = @import("remote");
const editor_shell = @import("editor_shell");
const remote_adapter = @import("remote_adapter");

const Fixture = struct {
    app: engine.App,
    schema: engine.reflection.ComponentSchema,
    entity: engine.EntityHandle,

    fn setup(self: *Fixture) !void {
        self.app = engine.App.init(testing.allocator, .{});
        errdefer self.app.deinit();
        try self.app.registerModule(window.module());
        try self.app.registerModule(graphics.module());
        try self.app.registerModule(ui_core.module());
        try self.app.registerModule(dev_tools.module());
        try self.app.registerModule(editor_shell.module());
        try self.app.registerModule(picking.module());
        try self.app.registerModule(remote.module());
        try self.app.initialize();

        self.schema = try self.app.types.registerSchema("game", "Health", 1, .blittable, &.{
            .{ .name = "hp", .field_type = .f32_t },
        });
        _ = try self.app.world.registerDynamicComponent("game.Health", self.schema.byte_size);
        self.entity = try self.app.world.spawn();
        const bytes = try testing.allocator.alloc(u8, self.schema.byte_size);
        defer testing.allocator.free(bytes);
        @memset(bytes, 0);
        try engine.TypeRegistry.setField(self.schema, bytes, "hp", .{ .f32_t = 100.0 });
        try self.app.world.setRaw(self.entity, self.schema.component_type_id, bytes);
    }

    fn hp(self: *Fixture) !f32 {
        const v = try engine.TypeRegistry.getField(self.schema, self.app.world.getRawConst(self.entity, self.schema.component_type_id).?, "hp");
        return v.f32_t;
    }

    fn setRequest(self: *Fixture, value: []const u8) ![]u8 {
        const req = try std.fmt.allocPrint(
            testing.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"zengy/set_component_field\",\"params\":{{\"index\":{d},\"generation\":{d},\"schema\":\"game.Health\",\"field\":\"hp\",\"value\":{s}}}}}",
            .{ self.entity.index, self.entity.generation, value },
        );
        defer testing.allocator.free(req);
        const rem = self.app.resources.get(remote.RemoteInspectorService).?;
        return rem.handleRequest(&self.app, req, testing.allocator);
    }
};

test "remote edit through the adapter records exactly one undo transaction" {
    var fx: Fixture = undefined;
    try fx.setup();
    defer fx.app.deinit();
    try remote_adapter.attach(&fx.app);

    const shell = fx.app.resources.get(editor_shell.EditorShellService).?;
    const res = try fx.setRequest("55.5");
    defer testing.allocator.free(res);
    try testing.expect(std.mem.indexOf(u8, res, "\"ok\":true") != null);
    try testing.expectEqual(@as(usize, 1), shell.authoring().undo_stack.items.len);
    try testing.expectApproxEqAbs(@as(f32, 55.5), try fx.hp(), 1e-3);

    try testing.expect(try shell.undo(&fx.app.world, &fx.app.types));
    try testing.expectApproxEqAbs(@as(f32, 100.0), try fx.hp(), 1e-3);
    try testing.expect(try shell.redo(&fx.app.world, &fx.app.types));
    try testing.expectApproxEqAbs(@as(f32, 55.5), try fx.hp(), 1e-3);
}

test "list_panels through the adapter exposes the five default panels" {
    var fx: Fixture = undefined;
    try fx.setup();
    defer fx.app.deinit();
    try remote_adapter.attach(&fx.app);

    const rem = fx.app.resources.get(remote.RemoteInspectorService).?;
    const res = try rem.handleRequest(&fx.app, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"zengy/list_panels\"}", testing.allocator);
    defer testing.allocator.free(res);
    for ([_][]const u8{ "editor.hierarchy", "editor.inspector", "editor.console", "editor.profiler", "editor.remote" }) |id| {
        try testing.expect(std.mem.indexOf(u8, res, id) != null);
    }
}

test "invalid remote edits through the adapter leave no history and no mutation" {
    var fx: Fixture = undefined;
    try fx.setup();
    defer fx.app.deinit();
    try remote_adapter.attach(&fx.app);
    const shell = fx.app.resources.get(editor_shell.EditorShellService).?;

    const bad = try fx.setRequest("\"not a number\"");
    defer testing.allocator.free(bad);
    try testing.expect(std.mem.indexOf(u8, bad, "\"error\"") != null);
    try testing.expectEqual(@as(usize, 0), shell.authoring().undo_stack.items.len);
    try testing.expectApproxEqAbs(@as(f32, 100.0), try fx.hp(), 1e-3);
}

test "adapter error is propagated without a direct-write fallback" {
    var fx: Fixture = undefined;
    try fx.setup();
    defer fx.app.deinit();
    try remote_adapter.attach(&fx.app);

    // Remove the shell resource while the adapter is still attached.
    _ = fx.app.resources.remove(editor_shell.EditorShellService);
    try testing.expectError(error.EditorShellUnavailable, fx.setRequest("1.0"));
    try testing.expectApproxEqAbs(@as(f32, 100.0), try fx.hp(), 1e-3);
}

test "detached adapter restores direct edits and an empty panel list" {
    var fx: Fixture = undefined;
    try fx.setup();
    defer fx.app.deinit();
    try remote_adapter.attach(&fx.app);
    remote_adapter.detach(&fx.app);

    const shell = fx.app.resources.get(editor_shell.EditorShellService).?;
    const res = try fx.setRequest("12.0");
    defer testing.allocator.free(res);
    try testing.expect(std.mem.indexOf(u8, res, "\"ok\":true") != null);
    try testing.expectEqual(@as(usize, 0), shell.authoring().undo_stack.items.len);
    try testing.expectApproxEqAbs(@as(f32, 12.0), try fx.hp(), 1e-3);

    const rem = fx.app.resources.get(remote.RemoteInspectorService).?;
    const panels = try rem.handleRequest(&fx.app, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"zengy/list_panels\"}", testing.allocator);
    defer testing.allocator.free(panels);
    try testing.expect(std.mem.indexOf(u8, panels, "\"panels\":[]") != null);
}
