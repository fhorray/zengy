//! Remote Inspector Protocol Tests (`packages/remote/tests/remote_tests.zig`).

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const window = @import("window");
const graphics = @import("graphics");
const ui_core = @import("ui_core");
const dev_tools = @import("dev_tools");
const editor_shell = @import("editor_shell");
const picking = @import("picking");
const remote = @import("remote");

test "RemoteInspectorService inspects live ECS, mutates fields with undo, and reads profiler passes" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(window.module());
    try app.registerModule(graphics.module());
    try app.registerModule(ui_core.module());
    try app.registerModule(dev_tools.module());
    try app.registerModule(editor_shell.module());
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

    // 3. Live set field (routed through EditorShellService undo stack)
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

    // 5. List editor-shell panels (including Profiler & Remote Inspector)
    const panels_res = try rem.handleRequest(&app, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"zengy/list_panels\"}", testing.allocator);
    defer testing.allocator.free(panels_res);
    try testing.expect(std.mem.indexOf(u8, panels_res, "editor.profiler") != null);
    try testing.expect(std.mem.indexOf(u8, panels_res, "editor.remote") != null);
}
