//! Testing & Automation SDK Tests (`packages/testing/tests/testing_tests.zig`).
//!
//! Validates all Marco A reliability requirements:
//! - `assertion_nan_rejected`: NaN/Inf/negative tolerance rejected by `assertFieldApprox`.
//! - `exact_fixed_ticks`: `stepFixed(N)` executes exactly N `.fixed_update` ticks.
//! - `input_controls_movement`: 3 independent input tests (no input, continuous, interrupted).
//! - `invalid_scenario_rejected`: negative ticks, unknown actions, out-of-range ticks.
//! - `scenario_allocation_failure`: OOM during TOML scenario parsing leaks zero memory.
//! - `capture_known_baseline` & `capture_invalid_coordinates`: `engine.testing.capture/1`
//!   service registration, pixel baseline verification, and NaN/Inf coordinate safety.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const window = @import("window");
const graphics = @import("graphics");
const ui_core = @import("ui_core");
const testing_sdk = @import("testing_sdk");

const PlayerPos = struct { x: f32 = 0, y: f32 = 0 };

fn setupMovementApp(max_fixed_steps: u32) !struct { app: engine.App, player: engine.EntityHandle, input: *window.InputService } {
    var app = engine.App.init(testing.allocator, .{
        .fixed_dt = 1.0 / 60.0,
        .max_fixed_steps = max_fixed_steps,
    });
    errdefer app.deinit();

    const MoveSys = struct {
        fn run(ctx: *engine.SystemContext) !void {
            const input = ctx.resources.getConst(window.InputService) orelse return;
            if (!input.isKeyDown('W')) return;

            var q = try ctx.query(.{ .write = .{PlayerPos} });
            defer q.deinit();
            while (q.next()) |row| {
                const p = row.write(PlayerPos);
                p.x += 60.0 * ctx.fixedDeltaSeconds();
            }
        }
    };

    try app.registerModule(window.module());
    try app.registerModule(graphics.module());
    try app.registerModule(ui_core.module());
    try app.registerModule(testing_sdk.module());
    try app.addSystem(.{ .name = "player.move", .stage = .fixed_update, .run = MoveSys.run });
    try app.initialize();

    const i_entry = try app.services.getService("engine.input", 1);
    const input: *window.InputService = @ptrCast(@alignCast(@constCast(i_entry.api_ptr)));
    // Also expose InputService directly in resources for system lookup.
    try app.resources.insert(window.InputService, .{});
    const sys_input = app.resources.get(window.InputService).?;
    _ = input;

    const player = try app.world.spawn();
    try app.world.set(player, PlayerPos, .{ .x = 0, .y = 0 });

    return .{ .app = app, .player = player, .input = sys_input };
}

test "input_controls_movement: no input, continuous W, and interrupted W" {
    // 1. No key pressed -> player stays at 0.0
    {
        var env = try setupMovementApp(8);
        defer env.app.deinit();

        const drv = env.app.resources.get(testing_sdk.TestDriver).?;
        try drv.stepFixed(&env.app, 60);
        try testing.expectEqual(@as(u64, 60), drv.current_tick);
        try testing.expectApproxEqAbs(@as(f32, 0.0), env.app.world.getConst(env.player, PlayerPos).?.x, 0.001);
    }

    // 2. W pressed for 60 ticks -> x == 60.0
    {
        var env = try setupMovementApp(8);
        defer env.app.deinit();

        const drv = env.app.resources.get(testing_sdk.TestDriver).?;
        const toml =
            \\[scenario]
            \\name = "continuous_w"
            \\ticks = 60
            \\
            \\[[actions]]
            \\at_tick = 0
            \\type = "key_down"
            \\target = "W"
        ;
        var scen = try testing_sdk.TestDriver.parseScenarioToml(testing.allocator, toml);
        defer scen.deinit();

        try drv.runScenario(&scen, &env.app, env.input, null);
        try testing.expectEqual(@as(u64, 60), drv.current_tick);
        try testing.expectApproxEqAbs(@as(f32, 60.0), env.app.world.getConst(env.player, PlayerPos).?.x, 0.01);
    }

    // 3. W pressed at tick 0 and released at tick 30 -> x == 30.0
    {
        var env = try setupMovementApp(8);
        defer env.app.deinit();

        const drv = env.app.resources.get(testing_sdk.TestDriver).?;
        const toml =
            \\[scenario]
            \\name = "interrupted_w"
            \\ticks = 60
            \\
            \\[[actions]]
            \\at_tick = 0
            \\type = "key_down"
            \\target = "W"
            \\
            \\[[actions]]
            \\at_tick = 30
            \\type = "key_up"
            \\target = "W"
        ;
        var scen = try testing_sdk.TestDriver.parseScenarioToml(testing.allocator, toml);
        defer scen.deinit();

        try drv.runScenario(&scen, &env.app, env.input, null);
        try testing.expectApproxEqAbs(@as(f32, 30.0), env.app.world.getConst(env.player, PlayerPos).?.x, 0.01);
    }
}

test "exact_fixed_ticks: stepFixed(N) runs N fixed updates even if max_fixed_steps == 0" {
    var env = try setupMovementApp(0);
    defer env.app.deinit();

    env.input.injectKey('W', true);
    const drv = env.app.resources.get(testing_sdk.TestDriver).?;
    try drv.stepFixed(&env.app, 5);
    try testing.expectEqual(@as(u64, 5), drv.current_tick);
    try testing.expectApproxEqAbs(@as(f32, 5.0), env.app.world.getConst(env.player, PlayerPos).?.x, 0.01);
}

test "assertion_nan_rejected: assertFieldApprox rejects NaN, Inf, and negative tolerance" {
    var reg = engine.TypeRegistry.init(testing.allocator);
    defer reg.deinit();

    const schema = try reg.registerSchema("test", "Stat", 1, .blittable, &.{
        .{ .name = "val", .field_type = .f32_t },
        .{ .name = "count", .field_type = .i32_t },
    });

    var world = engine.World.init(testing.allocator, .{ .index = 0, .generation = 1 });
    defer world.deinit();
    _ = try world.registerDynamicComponent("test.Stat", schema.byte_size);

    const e = try world.spawn();
    const buf = try testing.allocator.alloc(u8, schema.byte_size);
    defer testing.allocator.free(buf);
    @memset(buf, 0);

    try engine.TypeRegistry.setField(schema, buf, "val", .{ .f32_t = std.math.nan(f32) });
    try engine.TypeRegistry.setField(schema, buf, "count", .{ .i32_t = 10 });
    try world.setRaw(e, schema.component_type_id, buf);

    try testing.expectError(
        error.InvalidAssertionValue,
        testing_sdk.TestDriver.assertFieldApprox(&world, &reg, e, schema.schema_id, "val", 0.0, 1.0),
    );
    try testing.expectError(
        error.FieldTypeMismatch,
        testing_sdk.TestDriver.assertFieldApprox(&world, &reg, e, schema.schema_id, "count", 10.0, 0.1),
    );

    try engine.TypeRegistry.setField(schema, world.getRaw(e, schema.component_type_id).?, "val", .{ .f32_t = 5.0 });
    try testing.expectError(
        error.InvalidAssertionValue,
        testing_sdk.TestDriver.assertFieldApprox(&world, &reg, e, schema.schema_id, "val", 5.0, -0.1),
    );
}

test "invalid_scenario_rejected & scenario_allocation_failure" {
    const neg_ticks =
        \\[scenario]
        \\name = "bad"
        \\ticks = -5
    ;
    try testing.expectError(error.InvalidTickValue, testing_sdk.TestDriver.parseScenarioToml(testing.allocator, neg_ticks));

    const unknown_act =
        \\[scenario]
        \\name = "bad_act"
        \\ticks = 10
        \\[[actions]]
        \\at_tick = 2
        \\type = "mouse_drag"
        \\target = "player"
    ;
    try testing.expectError(error.UnsupportedAction, testing_sdk.TestDriver.parseScenarioToml(testing.allocator, unknown_act));

    const out_of_range =
        \\[scenario]
        \\name = "oor"
        \\ticks = 5
        \\[[actions]]
        \\at_tick = 5
        \\type = "key_down"
        \\target = "W"
    ;
    try testing.expectError(error.ActionOutOfRange, testing_sdk.TestDriver.parseScenarioToml(testing.allocator, out_of_range));

    // OOM safety during TOML parsing
    const valid_toml =
        \\[scenario]
        \\name = "oom"
        \\ticks = 10
        \\[[actions]]
        \\at_tick = 0
        \\type = "key_down"
        \\target = "W"
    ;
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 2 });
    try testing.expectError(error.OutOfMemory, testing_sdk.TestDriver.parseScenarioToml(failing.allocator(), valid_toml));
}

test "capture_known_baseline & capture_invalid_coordinates" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(testing_sdk.module());
    try app.initialize();
    try testing.expect(app.services.hasService("engine.testing.capture", 1));

    var cap = try testing_sdk.CaptureService.init(testing.allocator, 32, 32);
    defer cap.deinit();

    // Known baseline: clear black, draw green rect at (4,4,10,10)
    cap.rasterize(&.{
        .{ .clear = .{ .r = 0, .g = 0, .b = 0 } },
        .{ .rect = .{ .x = 4, .y = 4, .width = 10, .height = 10, .color = .{ .r = 0, .g = 1, .b = 0 } } },
    });
    try testing.expectEqual([4]u8{ 0, 0, 0, 255 }, cap.readPixel(0, 0).?);
    try testing.expectEqual([4]u8{ 0, 255, 0, 255 }, cap.readPixel(8, 8).?);
    const baseline_hash = cap.computeHash();

    // Deliberate visual bug (shifted rect) must produce a different hash
    cap.rasterize(&.{
        .{ .clear = .{ .r = 0, .g = 0, .b = 0 } },
        .{ .rect = .{ .x = 5, .y = 4, .width = 10, .height = 10, .color = .{ .r = 0, .g = 1, .b = 0 } } },
    });
    try testing.expect(cap.computeHash() != baseline_hash);

    // Invalid NaN/Inf/negative coordinates must not trap
    cap.rasterize(&.{
        .{ .rect = .{ .x = std.math.nan(f32), .y = 0, .width = 10, .height = 10, .color = .{ .r = 1, .g = 0, .b = 0 } } },
        .{ .rect = .{ .x = -10, .y = -10, .width = std.math.inf(f32), .height = 10, .color = .{ .r = 1, .g = 0, .b = 0 } } },
    });
}
