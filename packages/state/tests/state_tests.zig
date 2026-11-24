//! Headless tests for `official.state` (`packages/state`).

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const state = @import("state");

const GameState = enum {
    menu,
    playing,
    paused,
};

test "StateMachine transitions in pre_update, gates systems with inState, and emits events" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(state.module());
    try state.registerState(&app, GameState, .menu);

    const Counters = struct {
        menu_ticks: u32 = 0,
        play_ticks: u32 = 0,
        entered_playing: bool = false,
        exited_menu: bool = false,
    };
    try app.resources.insert(Counters, .{});

    const EventCatcher = struct {
        fn onEvent(raw: ?*anyopaque, env: engine.EventEnvelope) void {
            const c: *Counters = @ptrCast(@alignCast(raw.?));
            if (std.mem.eql(u8, env.name, "state.exited") and std.mem.eql(u8, env.payload, "menu")) {
                c.exited_menu = true;
            } else if (std.mem.eql(u8, env.name, "state.entered") and std.mem.eql(u8, env.payload, "playing")) {
                c.entered_playing = true;
            }
        }
    };
    _ = try app.events.subscribe(1, "*", EventCatcher.onEvent, app.resources.get(Counters).?);

    const menu_sys = struct {
        fn run(ctx: *engine.SystemContext) !void {
            ctx.resources.get(Counters).?.menu_ticks += 1;
        }
    }.run;
    const play_sys = struct {
        fn run(ctx: *engine.SystemContext) !void {
            ctx.resources.get(Counters).?.play_ticks += 1;
        }
    }.run;

    try app.addSystem(.{ .name = "menu.tick", .run = menu_sys, .run_if = state.inState(GameState, .menu) });
    try app.addSystem(.{ .name = "play.tick", .run = play_sys, .run_if = state.inState(GameState, .playing) });

    try app.tick(1.0 / 60.0);
    const c = app.resources.getConst(Counters).?;
    try testing.expectEqual(@as(u32, 1), c.menu_ticks);
    try testing.expectEqual(@as(u32, 0), c.play_ticks);

    // Queue transition to .playing; applied in next .pre_update.
    app.resources.get(state.StateMachine(GameState)).?.set(.playing);
    try app.tick(1.0 / 60.0);
    try testing.expectEqual(@as(u32, 1), c.menu_ticks);
    try testing.expectEqual(@as(u32, 1), c.play_ticks);
    try testing.expect(c.exited_menu);
    try testing.expect(c.entered_playing);
    try testing.expect(app.resources.getConst(state.StateMachine(GameState)).?.justEntered(.playing));
    try testing.expect(app.resources.getConst(state.StateMachine(GameState)).?.justExited(.menu));
}
