//! Core Engine Unit & Integration Tests (`src/core/tests/core_tests.zig`).
//!
//! Validates:
//! - Phase 1: Headless `App` lifecycle, 1000-entity ECS simulation, generational handles,
//!   `Scheduler` topological ordering & cycle detection, `CommandBuffer`, and `EventBus`.
//! - Phase 2: `ServiceRegistry` capability/version/exclusivity resolution and `ModuleRegistry`
//!   topological ordering, rollback on init failure, and reverse teardown.
//! - Phase 4: `TypeRegistry` dynamic `ComponentSchema` registration and field reflection.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");

const Position = struct { x: f32 = 0, y: f32 = 0 };
const Velocity = struct { x: f32 = 0, y: f32 = 0 };

fn moveSystem(ctx: *engine.SystemContext) !void {
    const dt = ctx.fixedDeltaSeconds();
    var q = try ctx.query(.{ .write = .{Position}, .read = .{Velocity} });
    defer q.deinit();

    while (q.next()) |row| {
        const p = row.write(Position);
        const v = row.read(Velocity);
        p.x += v.x * dt;
        p.y += v.y * dt;
    }
}

test "Phase 1: Headless App with 1000 entities and movement system" {
    var app = engine.App.init(testing.allocator, .{
        .fixed_dt = 1.0 / 60.0,
        .max_frames = 5,
    });
    defer app.deinit();

    _ = try app.registerComponent(Position);
    _ = try app.registerComponent(Velocity);
    try app.addSystem(.{ .name = "move", .stage = .fixed_update, .run = moveSystem });

    var entities: [1000]engine.EntityHandle = undefined;
    for (0..1000) |i| {
        const e = try app.world.spawn();
        entities[i] = e;
        try app.world.set(e, Position, .{ .x = 0, .y = 0 });
        try app.world.set(e, Velocity, .{ .x = 60.0, .y = 120.0 });
    }

    try app.run();

    try testing.expectEqual(engine.AppState.stopped, app.state);
    try testing.expectEqual(@as(u64, 5), app.diagnostics.frame_count);

    const p0 = app.world.getConst(entities[0], Position).?;
    try testing.expectApproxEqAbs(@as(f32, 5.0), p0.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 10.0), p0.y, 0.01);
}

test "Phase 1: EntityHandle generational invalidation" {
    var world = engine.World.init(testing.allocator, .{ .index = 0, .generation = 1 });
    defer world.deinit();

    const e1 = try world.spawn();
    try world.set(e1, Position, .{ .x = 42, .y = 99 });
    try testing.expect(world.isAlive(e1));

    try testing.expect(try world.despawn(e1));
    try testing.expect(!world.isAlive(e1));
    try testing.expect(world.get(e1, Position) == null);

    const e2 = try world.spawn();
    try testing.expectEqual(e1.index, e2.index);
    try testing.expect(e1.generation != e2.generation);
    try testing.expect(world.isAlive(e2));
    try testing.expect(!world.isAlive(e1));
}

test "Phase 1: Scheduler topological ordering and cycle detection" {
    const Tracker = struct {
        var order: [3]u8 = .{ 0, 0, 0 };
        var idx: usize = 0;

        fn sysA(_: *engine.SystemContext) !void {
            order[idx] = 'A';
            idx += 1;
        }
        fn sysB(_: *engine.SystemContext) !void {
            order[idx] = 'B';
            idx += 1;
        }
        fn sysC(_: *engine.SystemContext) !void {
            order[idx] = 'C';
            idx += 1;
        }
    };
    Tracker.idx = 0;

    var app = engine.App.init(testing.allocator, .{ .max_frames = 1 });
    defer app.deinit();

    // Insert in reverse order, enforce A -> B -> C via before/after
    try app.addSystem(.{ .name = "C", .stage = .update, .run = Tracker.sysC, .after = &.{"B"} });
    try app.addSystem(.{ .name = "B", .stage = .update, .run = Tracker.sysB, .after = &.{"A"} });
    try app.addSystem(.{ .name = "A", .stage = .update, .run = Tracker.sysA });

    try app.run();
    try testing.expectEqualStrings("ABC", &Tracker.order);

    // Cycle detection
    var sched = engine.scheduler.Scheduler.init(testing.allocator);
    defer sched.deinit();
    try sched.addSystem(.{ .name = "X", .stage = .update, .run = Tracker.sysA, .after = &.{"Y"} });
    try sched.addSystem(.{ .name = "Y", .stage = .update, .run = Tracker.sysB, .after = &.{"X"} });
    try testing.expectError(error.DependencyCycle, sched.buildStageSchedule(.update));
}

test "Phase 1: CommandBuffer deferred barrier and EventBus bounded queue + owner unsubscribe" {
    var world = engine.World.init(testing.allocator, .{ .index = 0, .generation = 1 });
    defer world.deinit();
    var events = engine.EventBus.init(testing.allocator, 2, .drop_oldest);
    defer events.deinit();
    var cmds = engine.CommandBuffer.init(testing.allocator);
    defer cmds.deinit();

    const Counter = struct {
        count: usize = 0,
        fn onEvent(raw: ?*anyopaque, _: engine.EventEnvelope) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.count += 1;
        }
    };
    var c1 = Counter{};
    var c2 = Counter{};

    _ = try events.subscribe(101, "ping", Counter.onEvent, &c1);
    _ = try events.subscribe(202, "ping", Counter.onEvent, &c2);

    const e = try world.spawn();
    try cmds.set(e, Position, .{ .x = 7, .y = 8 });
    try cmds.emit(.{ .name = "ping", .payload = "1" });
    try cmds.emit(.{ .name = "ping", .payload = "2" });
    try cmds.emit(.{ .name = "ping", .payload = "3" }); // overflows cap=2, drops oldest

    try testing.expect(!world.has(e, Position));
    try cmds.apply(&world, &events);
    try testing.expect(world.has(e, Position));
    try testing.expectEqual(@as(u64, 1), events.dropped_events);

    _ = events.drain();
    try testing.expectEqual(@as(usize, 2), c1.count);
    try testing.expectEqual(@as(usize, 2), c2.count);

    // Owner 101 unloads: only c2 receives future events
    try testing.expectEqual(@as(usize, 1), events.unsubscribeByOwner(101));
    try events.post(.{ .name = "ping", .payload = "4" });
    _ = events.drain();
    try testing.expectEqual(@as(usize, 2), c1.count);
    try testing.expectEqual(@as(usize, 3), c2.count);
}

test "Phase 2: ServiceRegistry resolution, version mismatch, and ambiguous exclusive provider" {
    var reg = engine.ServiceRegistry.init(testing.allocator);
    defer reg.deinit();

    var dummy_a: u32 = 1;
    var dummy_b: u32 = 2;

    try testing.expectError(error.ProviderNotFound, reg.getService("engine.graphics.device", 1));

    try reg.register(.{
        .capability = "engine.graphics.device",
        .major_version = 1,
        .provider_id = "provider.a",
        .exclusive = true,
        .api_ptr = &dummy_a,
        .api_size = @sizeOf(u32),
    });

    try testing.expectError(error.VersionMismatch, reg.getService("engine.graphics.device", 2));

    const resolved = try reg.getService("engine.graphics.device", 1);
    try testing.expectEqualStrings("provider.a", resolved.provider_id);

    // Second exclusive provider causes AmbiguousProvider until explicitly selected
    try reg.register(.{
        .capability = "engine.graphics.device",
        .major_version = 1,
        .provider_id = "provider.b",
        .exclusive = true,
        .api_ptr = &dummy_b,
        .api_size = @sizeOf(u32),
    });
    try testing.expectError(error.AmbiguousProvider, reg.getService("engine.graphics.device", 1));

    try reg.selectProvider("engine.graphics.device", 1, "provider.b");
    const picked = try reg.getService("engine.graphics.device", 1);
    try testing.expectEqualStrings("provider.b", picked.provider_id);
}

test "Phase 2: ModuleRegistry topological order, rollback, and reverse teardown" {
    const Trace = struct {
        var events: [16]u8 = undefined;
        var len: usize = 0;

        fn push(ch: u8) void {
            events[len] = ch;
            len += 1;
        }
        fn slice() []const u8 {
            return events[0..len];
        }
    };

    const ModA = struct {
        fn build(_: *anyopaque) !void {
            Trace.push('A');
        }
        fn stop(_: *anyopaque) void {
            Trace.push('a');
        }
    };
    const ModB = struct {
        fn build(_: *anyopaque) !void {
            Trace.push('B');
        }
        fn stop(_: *anyopaque) void {
            Trace.push('b');
        }
    };
    const ModFail = struct {
        fn build(_: *anyopaque) !void {
            return error.SimulatedInitFailure;
        }
    };

    // Topological order independent of insertion order + reverse teardown
    Trace.len = 0;
    {
        var app = engine.App.init(testing.allocator, .{});
        defer app.deinit();

        try app.registerModule(.{
            .descriptor = .{
                .id = "consumer.b",
                .version = "0.1.0",
                .required_capabilities = &.{"cap.a"},
            },
            .build = ModB.build,
            .stop = ModB.stop,
        });
        try app.registerModule(.{
            .descriptor = .{
                .id = "provider.a",
                .version = "0.1.0",
                .provides_capabilities = &.{"cap.a"},
            },
            .build = ModA.build,
            .stop = ModA.stop,
        });

        try app.initialize();
        try testing.expectEqualStrings("AB", Trace.slice());
        app.shutdown();
        try testing.expectEqualStrings("ABba", Trace.slice());
    }

    // Rollback on build failure
    Trace.len = 0;
    {
        var app = engine.App.init(testing.allocator, .{});
        defer app.deinit();

        try app.registerModule(.{
            .descriptor = .{
                .id = "provider.a",
                .version = "0.1.0",
                .provides_capabilities = &.{"cap.a"},
            },
            .build = ModA.build,
            .stop = ModA.stop,
        });
        try app.registerModule(.{
            .descriptor = .{
                .id = "failing.mod",
                .version = "0.1.0",
                .required_capabilities = &.{"cap.a"},
            },
            .build = ModFail.build,
        });

        try testing.expectError(error.SimulatedInitFailure, app.initialize());
        try testing.expectEqualStrings("Aa", Trace.slice());
    }
}

test "Phase 4: TypeRegistry dynamic ComponentSchema and field reflection" {
    var reg = engine.TypeRegistry.init(testing.allocator);
    defer reg.deinit();

    const schema = try reg.registerSchema("sample.gameplay", "Health", 1, .blittable, &.{
        .{ .name = "current", .field_type = .f32_t },
        .{ .name = "maximum", .field_type = .f32_t },
    });

    var world = engine.World.init(testing.allocator, .{ .index = 0, .generation = 1 });
    defer world.deinit();

    const tid = try world.registerDynamicComponent("sample.gameplay.Health", schema.byte_size);
    try testing.expectEqual(schema.component_type_id, tid);

    const e = try world.spawn();
    const initial = try testing.allocator.alloc(u8, schema.byte_size);
    defer testing.allocator.free(initial);
    @memset(initial, 0);

    try engine.TypeRegistry.setField(schema, initial, "current", .{ .f32_t = 75.5 });
    try engine.TypeRegistry.setField(schema, initial, "maximum", .{ .f32_t = 100.0 });
    try world.setRaw(e, tid, initial);

    const stored = world.getRaw(e, tid).?;
    const cur = try engine.TypeRegistry.getField(schema, stored, "current");
    const max = try engine.TypeRegistry.getField(schema, stored, "maximum");
    try testing.expectApproxEqAbs(@as(f32, 75.5), cur.f32_t, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 100.0), max.f32_t, 0.001);
}
