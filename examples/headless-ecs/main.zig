const std = @import("std");
const engine = @import("engine");

const Position = struct {
    x: f32 = 0,
    y: f32 = 0,
};

const Velocity = struct {
    x: f32 = 0,
    y: f32 = 0,
};

fn movementSystem(ctx: *engine.SystemContext) !void {
    const dt = ctx.fixedDeltaSeconds();
    var q = try ctx.query(.{ .write = .{Position}, .read = .{Velocity} });
    defer q.deinit();

    while (q.next()) |row| {
        const pos = row.write(Position);
        const vel = row.read(Velocity);
        pos.x += vel.x * dt;
        pos.y += vel.y * dt;
    }
}

fn onSimulationDone(_: ?*anyopaque, ev: engine.EventEnvelope) void {
    std.debug.print("[event] {s}: {s}\n", .{ ev.name, ev.payload });
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = engine.App.init(allocator, .{
        .fixed_dt = 1.0 / 60.0,
        .max_frames = 10,
    });
    defer app.deinit();

    _ = try app.registerComponent(Position);
    _ = try app.registerComponent(Velocity);

    _ = try app.events.subscribe(1, "sim.completed", onSimulationDone, null);

    // Spawn 1,000 entities without any window, GPU, or scripting VM.
    for (0..1000) |i| {
        const entity = try app.world.spawn();
        try app.world.set(entity, Position, .{ .x = @floatFromInt(i), .y = 0 });
        try app.world.set(entity, Velocity, .{ .x = 60.0, .y = 12.0 });
    }

    try app.addSystem(.{
        .name = "movement",
        .stage = .fixed_update,
        .run = movementSystem,
    });

    try app.run();

    try app.events.post(.{
        .name = "sim.completed",
        .payload = "1000 entities simulated for 10 frames",
    });
    _ = app.events.drain();

    std.debug.print(
        "Headless ECS complete: entities={}, frames={}\n",
        .{ app.world.entity_count, app.diagnostics.frame_count },
    );
}
