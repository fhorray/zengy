//! Engine Microbenchmark Suite (`benchmarks/main.zig`).
//!
//! Measures representative hot-path workloads (Phase C):
//! 1. `World.spawn` + `World.set` (10,000 entities)
//! 2. `World.query` iteration (10,000 entities x 100 frames = 1M updates)
//! 3. `EventBus.post` + `EventBus.drain` (10,000 events)
//! 4. `UiTree.layoutTree` + `UiTree.paint` (1,000 nodes)
//! 5. `Scene` 2D transform propagation (1,000 entities)
//!
//! Run with: `zig build run-bench -Doptimize=ReleaseFast`

const std = @import("std");
const engine = @import("engine");
const graphics = @import("graphics");
const ui_core = @import("ui_core");
const scene = @import("scene");
const json_format = @import("json_format");

const Position = struct { x: f32 = 0, y: f32 = 0 };
const Velocity = struct { x: f32 = 1, y: f32 = 2 };

fn elapsedNs(io: std.Io, start: std.Io.Timestamp) i96 {
    const end = std.Io.Clock.now(.awake, io);
    return start.durationTo(end).nanoseconds;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    std.debug.print("=== ZigEng Benchmark Suite ===\n", .{});

    // 1. World spawn + set (10,000 entities)
    var world = engine.World.init(allocator, .{ .index = 0, .generation = 1 });
    defer world.deinit();
    _ = try world.registerComponent(Position);
    _ = try world.registerComponent(Velocity);

    const t_spawn0 = std.Io.Clock.now(.awake, io);
    for (0..10_000) |i| {
        const e = try world.spawn();
        try world.set(e, Position, .{ .x = @floatFromInt(i), .y = 0 });
        try world.set(e, Velocity, .{ .x = 60.0, .y = 30.0 });
    }
    const spawn_ns = elapsedNs(io, t_spawn0);
    std.debug.print(
        "1. World spawn+set (10k entities): {d:.3} ms ({d} ns/entity)\n",
        .{ @as(f64, @floatFromInt(spawn_ns)) / 1_000_000.0, @divTrunc(spawn_ns, 10_000) },
    );

    // 2. Query iteration (10k entities x 100 frames = 1M entity updates)
    const t_query0 = std.Io.Clock.now(.awake, io);
    var checksum: f64 = 0;
    for (0..100) |_| {
        var q = try world.query(.{ .write = .{Position}, .read = .{Velocity} });
        defer q.deinit();
        while (q.next()) |row| {
            const p = row.write(Position);
            const v = row.read(Velocity);
            p.x += v.x * 0.016;
            p.y += v.y * 0.016;
            checksum += p.x;
        }
    }
    const query_ns = elapsedNs(io, t_query0);
    std.mem.doNotOptimizeAway(checksum);
    std.debug.print(
        "2. Query iter (10k x 100 = 1M updates): {d:.3} ms ({d} ns/update)\n",
        .{ @as(f64, @floatFromInt(query_ns)) / 1_000_000.0, @divTrunc(query_ns, 1_000_000) },
    );

    // 3. EventBus post + drain (10,000 events)
    var bus = engine.EventBus.init(allocator, 16_384, .drop_newest);
    defer bus.deinit();

    const Counter = struct {
        n: usize = 0,
        fn cb(raw: ?*anyopaque, _: engine.EventEnvelope) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.n += 1;
        }
    };
    var counter = Counter{};
    _ = try bus.subscribe(1, "bench.ev", Counter.cb, &counter);

    const t_ev0 = std.Io.Clock.now(.awake, io);
    for (0..10_000) |_| {
        try bus.post(.{ .name = "bench.ev", .payload = "payload" });
    }
    _ = bus.drain();
    const ev_ns = elapsedNs(io, t_ev0);
    std.debug.print(
        "3. EventBus post+drain (10k events): {d:.3} ms ({d} ns/event)\n",
        .{ @as(f64, @floatFromInt(ev_ns)) / 1_000_000.0, @divTrunc(ev_ns, 10_000) },
    );

    // 4. UiTree layout + paint (1,000 nodes)
    var tree = ui_core.UiTree.init(allocator);
    defer tree.deinit();
    const root = try tree.createNode(null, .{ .id = "root", .kind = .panel });
    for (0..1000) |_| {
        _ = try tree.createNode(root, .{ .id = "row", .kind = .label, .text = "item" });
    }
    var cmds: std.ArrayList(graphics.DrawCommand) = .empty;
    defer cmds.deinit(allocator);

    const t_ui0 = std.Io.Clock.now(.awake, io);
    for (0..10) |_| {
        tree.layoutTree(1280, 720);
        cmds.clearRetainingCapacity();
        try tree.paint(allocator, &cmds);
    }
    const ui_ns = elapsedNs(io, t_ui0);
    std.debug.print(
        "4. UiTree layout+paint (1k nodes x 10): {d:.3} ms ({d:.3} ms/frame)\n",
        .{ @as(f64, @floatFromInt(ui_ns)) / 1_000_000.0, @as(f64, @floatFromInt(ui_ns)) / 10_000_000.0 },
    );

    // 5. Scene 2D transform propagation (1,000 entities)
    var app = engine.App.init(allocator, .{ .max_frames = 10 });
    defer app.deinit();
    try app.registerModule(scene.module());
    const parent = try app.world.spawn();
    try app.world.set(parent, scene.Transform2D, .{ .x = 10, .y = 20 });
    for (0..999) |_| {
        const c = try app.world.spawn();
        try app.world.set(c, scene.Transform2D, .{ .x = 1, .y = 1 });
        try app.world.set(c, scene.Parent, .{ .entity = parent });
    }
    const t_sc0 = std.Io.Clock.now(.awake, io);
    try app.run();
    const sc_ns = elapsedNs(io, t_sc0);
    std.debug.print(
        "5. Scene2D propagate (1k entities x 10 frames): {d:.3} ms ({d:.3} ms/frame)\n",
        .{ @as(f64, @floatFromInt(sc_ns)) / 1_000_000.0, @as(f64, @floatFromInt(sc_ns)) / 10_000_000.0 },
    );

    // 6. JSON benchmark: std.json vs yyjson (small ~5KB, medium ~500KB, large ~5MB)
    const sizes = [_]usize{ 100, 10_000, 100_000 };
    const labels = [_][]const u8{ "~5 KB", "~500 KB", "~5 MB" };
    for (sizes, labels) |count, lbl| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.appendSlice(allocator, "{\"entities\":[");
        for (0..count) |idx| {
            if (idx > 0) try buf.append(allocator, ',');
            try buf.appendSlice(allocator, "{\"id\":123,\"x\":1.5,\"y\":2.5,\"name\":\"entity_item\"}");
        }
        try buf.appendSlice(allocator, "]}");

        const t_std0 = std.Io.Clock.now(.awake, io);
        const s_std = try json_format.JsonService.inspectStdJson(allocator, buf.items);
        const std_ns = elapsedNs(io, t_std0);
        std.mem.doNotOptimizeAway(s_std);

        const t_yy0 = std.Io.Clock.now(.awake, io);
        const s_yy = try json_format.JsonService.inspectYyjson(buf.items);
        const yy_ns = elapsedNs(io, t_yy0);
        std.mem.doNotOptimizeAway(s_yy);

        std.debug.print(
            "6. JSON ({s}, {d} KB): std.json={d:.3} ms vs yyjson={d:.3} ms\n",
            .{
                lbl,
                buf.items.len / 1024,
                @as(f64, @floatFromInt(std_ns)) / 1_000_000.0,
                @as(f64, @floatFromInt(yy_ns)) / 1_000_000.0,
            },
        );
    }
}
