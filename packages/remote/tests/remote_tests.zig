//! Remote Inspector Protocol Tests (`packages/remote/tests/remote_tests.zig`).

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const window = @import("window");
const graphics = @import("graphics");
const ui_core = @import("ui_core");
const dev_tools = @import("dev_tools");
const picking = @import("picking");
const remote = @import("remote");

test "RemoteInspectorService inspects live ECS, mutates fields, and reads profiler passes" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(window.module());
    try app.registerModule(graphics.module());
    try app.registerModule(ui_core.module());
    try app.registerModule(dev_tools.module());
    try app.registerModule(picking.module());
    try app.registerModule(remote.module());
    try app.initialize();

    const schema = try app.types.registerSchema("game", "Health", 1, .blittable, &.{
        .{ .name = "hp", .field_type = .f32_t },
    });
    _ = try app.world.registerDynamicComponent("game.Health", schema.byte_size);

    const e = try app.world.spawn();
    const bytes = try testing.allocator.alloc(u8, schema.byte_size);
    defer testing.allocator.free(bytes);
    @memset(bytes, 0);
    try engine.TypeRegistry.setField(schema, bytes, "hp", .{ .f32_t = 100.0 });
    try app.world.setRaw(e, schema.component_type_id, bytes);

    const prof = app.resources.get(dev_tools.FrameProfilerService).?;
    prof.beginFrame(1_000_000);
    prof.recordPass("Shadow", .shadow, 1_500_000);
    prof.recordPass("SSAO", .ssao, 800_000);
    prof.recordPass("Forward+", .forward_plus, 2_400_000);
    prof.recordPass("Volumetric", .volumetric, 700_000);
    prof.recordPass("Bloom", .bloom, 450_000);
    prof.recordPass("PostFX", .postfx, 350_000);
    prof.endFrame(7_200_000);

    const rem = app.resources.get(remote.RemoteInspectorService).?;

    // 1. List entities
    const list_res = try rem.handleRequest(&app, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"zengy/list_entities\"}", testing.allocator);
    defer testing.allocator.free(list_res);
    try testing.expect(std.mem.indexOf(u8, list_res, "game.Health") != null);

    // 2. Get entity
    const get_req = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"zengy/get_entity\",\"params\":{{\"index\":{d},\"generation\":{d}}}}}",
        .{ e.index, e.generation },
    );
    defer testing.allocator.free(get_req);
    const get_res = try rem.handleRequest(&app, get_req, testing.allocator);
    defer testing.allocator.free(get_res);
    try testing.expect(std.mem.indexOf(u8, get_res, "100.0000") != null);

    // 3. Live set field (direct reflected edit; no integration attached)
    const set_req = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"zengy/set_component_field\",\"params\":{{\"index\":{d},\"generation\":{d},\"schema\":\"game.Health\",\"field\":\"hp\",\"value\":55.5}}}}",
        .{ e.index, e.generation },
    );
    defer testing.allocator.free(set_req);
    const set_res = try rem.handleRequest(&app, set_req, testing.allocator);
    defer testing.allocator.free(set_res);
    try testing.expect(std.mem.indexOf(u8, set_res, "\"ok\":true") != null);

    const updated = try engine.TypeRegistry.getField(schema, app.world.getRaw(e, schema.component_type_id).?, "hp");
    try testing.expectApproxEqAbs(@as(f32, 55.5), updated.f32_t, 1e-3);

    // 4. Query profiler pass timings
    const prof_res = try rem.handleRequest(&app, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"zengy/get_profiler\"}", testing.allocator);
    defer testing.allocator.free(prof_res);
    try testing.expect(std.mem.indexOf(u8, prof_res, "\"Shadow\"") != null);
    try testing.expect(std.mem.indexOf(u8, prof_res, "\"Volumetric\"") != null);
    try testing.expect(std.mem.indexOf(u8, prof_res, "\"PostFX\"") != null);

    // 5. Without an integration, list_panels keeps its shape and returns no panels
    const panels_res = try rem.handleRequest(&app, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"zengy/list_panels\"}", testing.allocator);
    defer testing.allocator.free(panels_res);
    try testing.expect(std.mem.indexOf(u8, panels_res, "\"panels\":[]") != null);
}

const TestIntegration = struct {
    edits: u32 = 0,
    fail: bool = false,

    fn edit(ctx: *anyopaque, app: *engine.App, req: remote.FieldEditRequest) anyerror!void {
        _ = app;
        _ = req;
        const self: *TestIntegration = @ptrCast(@alignCast(ctx));
        self.edits += 1;
        if (self.fail) return error.TestEditFailed;
    }

    fn panels(ctx: *anyopaque, app: *engine.App, visitor: remote.PanelVisitor) anyerror!void {
        _ = ctx;
        _ = app;
        try visitor.visit(visitor.context, .{ .id = "test.panel", .title = "Test", .open = true });
    }
};

fn setupHealth(app: *engine.App) !struct { schema: engine.reflection.ComponentSchema, entity: engine.EntityHandle } {
    const schema = try app.types.registerSchema("game", "Health", 1, .blittable, &.{
        .{ .name = "hp", .field_type = .f32_t },
    });
    _ = try app.world.registerDynamicComponent("game.Health", schema.byte_size);
    const e = try app.world.spawn();
    const bytes = try testing.allocator.alloc(u8, schema.byte_size);
    defer testing.allocator.free(bytes);
    @memset(bytes, 0);
    try engine.TypeRegistry.setField(schema, bytes, "hp", .{ .f32_t = 100.0 });
    try app.world.setRaw(e, schema.component_type_id, bytes);
    return .{ .schema = schema, .entity = e };
}

fn setReq(e: engine.EntityHandle, schema_name: []const u8, value: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"zengy/set_component_field\",\"params\":{{\"index\":{d},\"generation\":{d},\"schema\":\"{s}\",\"field\":\"hp\",\"value\":{s}}}}}",
        .{ e.index, e.generation, schema_name, value },
    );
}

test "attached integration receives each valid edit once and drives list_panels" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();
    try app.registerModule(remote.module());
    try app.initialize();
    const h = try setupHealth(&app);
    const rem = app.resources.get(remote.RemoteInspectorService).?;

    var hooks = TestIntegration{};
    rem.setIntegration(.{ .context = &hooks, .edit_field = TestIntegration.edit, .visit_panels = TestIntegration.panels });

    const req = try setReq(h.entity, "game.Health", "5.0");
    defer testing.allocator.free(req);
    const res = try rem.handleRequest(&app, req, testing.allocator);
    defer testing.allocator.free(res);
    try testing.expect(std.mem.indexOf(u8, res, "\"ok\":true") != null);
    try testing.expectEqual(@as(u32, 1), hooks.edits);
    // The integration owns the write: Remote must not also write directly.
    try testing.expectApproxEqAbs(@as(f32, 100.0), (try engine.TypeRegistry.getField(h.schema, app.world.getRaw(h.entity, h.schema.component_type_id).?, "hp")).f32_t, 1e-3);

    const panels = try rem.handleRequest(&app, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"zengy/list_panels\"}", testing.allocator);
    defer testing.allocator.free(panels);
    try testing.expect(std.mem.indexOf(u8, panels, "test.panel") != null);

    rem.clearIntegration();
    const res2 = try rem.handleRequest(&app, req, testing.allocator);
    defer testing.allocator.free(res2);
    try testing.expectEqual(@as(u32, 1), hooks.edits);
    try testing.expectApproxEqAbs(@as(f32, 5.0), (try engine.TypeRegistry.getField(h.schema, app.world.getRaw(h.entity, h.schema.component_type_id).?, "hp")).f32_t, 1e-3);
}

test "invalid edits never reach the integration and adapter errors do not fall back to a direct write" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();
    try app.registerModule(remote.module());
    try app.initialize();
    const h = try setupHealth(&app);
    const rem = app.resources.get(remote.RemoteInspectorService).?;

    var hooks = TestIntegration{};
    rem.setIntegration(.{ .context = &hooks, .edit_field = TestIntegration.edit });

    const bad_type = try setReq(h.entity, "game.Health", "\"text\"");
    defer testing.allocator.free(bad_type);
    const r1 = try rem.handleRequest(&app, bad_type, testing.allocator);
    defer testing.allocator.free(r1);
    try testing.expect(std.mem.indexOf(u8, r1, "\"error\"") != null);

    const bad_schema = try setReq(h.entity, "game.Missing", "1.0");
    defer testing.allocator.free(bad_schema);
    const r2 = try rem.handleRequest(&app, bad_schema, testing.allocator);
    defer testing.allocator.free(r2);
    try testing.expect(std.mem.indexOf(u8, r2, "\"error\"") != null);
    try testing.expectEqual(@as(u32, 0), hooks.edits);

    hooks.fail = true;
    const good = try setReq(h.entity, "game.Health", "7.0");
    defer testing.allocator.free(good);
    try testing.expectError(error.TestEditFailed, rem.handleRequest(&app, good, testing.allocator));
    try testing.expectEqual(@as(u32, 1), hooks.edits);
    try testing.expectApproxEqAbs(@as(f32, 100.0), (try engine.TypeRegistry.getField(h.schema, app.world.getRaw(h.entity, h.schema.component_type_id).?, "hp")).f32_t, 1e-3);
}
