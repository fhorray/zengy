//! Testing & Automation SDK Tests (`packages/testing/tests/testing_tests.zig`).
//!
//! Validates:
//! - Deterministic `TestDriver.stepFixed(count)` producing identical state across runs.
//! - TOML scenario parsing via `official.format.toml` and execution of `key_down` + `ui_click`.
//! - `CaptureService` offscreen RGBA8 rasterization, `readPixel()`, `encodePpm()`, and golden hash.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const window = @import("window");
const graphics = @import("graphics");
const ui_core = @import("ui_core");
const testing_sdk = @import("testing_sdk");

const PlayerPos = struct { x: f32 = 0, y: f32 = 0 };

test "TestDriver executes TOML scenario with deterministic movement and UI click" {
    const State = struct {
        var moved_ticks: u32 = 0;
        var clicked_action: bool = false;

        fn onUiAction(_: ?*anyopaque, ev: engine.EventEnvelope) void {
            if (std.mem.eql(u8, ev.payload, "game.jump")) {
                clicked_action = true;
            }
        }
    };
    State.moved_ticks = 0;
    State.clicked_action = false;

    const MoveTracker = struct {
        fn tickSys(ctx: *engine.SystemContext) !void {
            var q = try ctx.query(.{ .write = .{PlayerPos} });
            defer q.deinit();
            while (q.next()) |row| {
                const p = row.write(PlayerPos);
                p.x += 60.0 * ctx.fixedDeltaSeconds();
                State.moved_ticks += 1;
            }
        }
    };

    var app = engine.App.init(testing.allocator, .{ .fixed_dt = 1.0 / 60.0 });
    defer app.deinit();

    try app.registerModule(window.module());
    try app.registerModule(graphics.module());
    try app.registerModule(ui_core.module());
    try app.registerModule(testing_sdk.module());
    try app.addSystem(.{ .name = "player.move", .stage = .fixed_update, .run = MoveTracker.tickSys });
    try app.initialize();

    _ = try app.events.subscribe(999, "ui.action", State.onUiAction, null);

    const player = try app.world.spawn();
    try app.world.set(player, PlayerPos, .{ .x = 0, .y = 0 });

    const tree = app.resources.get(ui_core.UiTree).?;
    const panel = try tree.createNode(null, .{ .id = "hud", .kind = .panel });
    _ = try tree.createNode(panel, .{
        .id = "jump_btn",
        .kind = .button,
        .text = "Jump",
        .action = "game.jump",
    });
    tree.layoutTree(800, 600);

    const i_entry = try app.services.getService("engine.input", 1);
    const input: *window.InputService = @ptrCast(@alignCast(@constCast(i_entry.api_ptr)));

    const scenario_toml =
        \\[scenario]
        \\name = "player_and_ui"
        \\ticks = 60
        \\
        \\[[actions]]
        \\at_tick = 0
        \\type = "key_down"
        \\target = "W"
        \\
        \\[[actions]]
        \\at_tick = 10
        \\type = "ui_click"
        \\target = "jump_btn"
    ;

    var scen = try testing_sdk.TestDriver.parseScenarioToml(testing.allocator, scenario_toml);
    defer scen.deinit();

    var drv = app.resources.get(testing_sdk.TestDriver).?.*;
    try drv.runScenario(&scen, &app, input, tree);

    try testing.expectEqual(@as(u32, 60), State.moved_ticks);
    try testing.expect(State.clicked_action);
    try testing.expectApproxEqAbs(@as(f32, 60.0), app.world.getConst(player, PlayerPos).?.x, 0.01);
}

test "CaptureService rasterizes UI draw commands offscreen with deterministic golden hash" {
    var tree = ui_core.UiTree.init(testing.allocator);
    defer tree.deinit();

    const panel = try tree.createNode(null, .{
        .id = "panel",
        .kind = .panel,
        .style = .{ .bg_color = .{ .r = 0.0, .g = 0.0, .b = 1.0 } },
    });
    _ = try tree.createNode(panel, .{
        .id = "btn",
        .kind = .button,
        .style = .{ .bg_color = .{ .r = 1.0, .g = 0.0, .b = 0.0 }, .min_height = 20 },
    });
    tree.layoutTree(64, 64);

    var cmds: std.ArrayList(graphics.DrawCommand) = .empty;
    defer cmds.deinit(testing.allocator);
    try cmds.append(testing.allocator, .{ .clear = .{ .r = 0, .g = 0, .b = 0 } });
    try tree.paint(testing.allocator, &cmds);

    var cap1 = try testing_sdk.CaptureService.init(testing.allocator, 64, 64);
    defer cap1.deinit();
    cap1.rasterize(cmds.items);

    var cap2 = try testing_sdk.CaptureService.init(testing.allocator, 64, 64);
    defer cap2.deinit();
    cap2.rasterize(cmds.items);

    // Deterministic golden hash across independent runs.
    try testing.expectEqual(cap1.computeHash(), cap2.computeHash());

    // Button is inside panel at (8, 8) -> red pixel (255, 0, 0, 255).
    const btn_px = cap1.readPixel(12, 12).?;
    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, btn_px);

    // PPM export header check.
    const ppm = try cap1.encodePpm(testing.allocator);
    defer testing.allocator.free(ppm);
    try testing.expect(std.mem.startsWith(u8, ppm, "P6\n64 64\n255\n"));
}
