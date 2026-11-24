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

test "ZE-002: EventBus reentrant unsubscribe, unsubscribeByOwner, and subscribe during drain()" {
    var bus = engine.EventBus.init(testing.allocator, 16, .drop_newest);
    defer bus.deinit();

    const State = struct {
        bus: *engine.EventBus,
        self_id: engine.events.SubscriptionId = 0,
        calls: usize = 0,

        fn onSelfUnsub(raw: ?*anyopaque, _: engine.EventEnvelope) void {
            const st: *@This() = @ptrCast(@alignCast(raw.?));
            st.calls += 1;
            _ = st.bus.unsubscribe(st.self_id);
        }

        fn onCount(raw: ?*anyopaque, _: engine.EventEnvelope) void {
            const st: *@This() = @ptrCast(@alignCast(raw.?));
            st.calls += 1;
        }
    };

    var s1 = State{ .bus = &bus };
    var s2 = State{ .bus = &bus };
    s1.self_id = try bus.subscribe(1, "tick", State.onSelfUnsub, &s1);
    _ = try bus.subscribe(2, "tick", State.onCount, &s2);

    try bus.post(.{ .name = "tick", .payload = "1" });
    try bus.post(.{ .name = "tick", .payload = "2" });
    _ = bus.drain();

    // s1 unsubscribed itself on the first event, so it only ran once; s2 ran twice.
    try testing.expectEqual(@as(usize, 1), s1.calls);
    try testing.expectEqual(@as(usize, 2), s2.calls);
    try testing.expectEqual(@as(usize, 1), bus.subscriptionCount());
}

test "ZE-003 & ZE-007: TypeRegistry and World.spawn remain consistent under OOM" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 2 });
    var reg = engine.TypeRegistry.init(failing.allocator());
    defer reg.deinit();

    const res = reg.registerSchema("ns", "Comp", 1, .blittable, &.{
        .{ .name = "x", .field_type = .f32_t },
    });
    try testing.expectError(error.OutOfMemory, res);

    var fail_world = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    var world = engine.World.init(fail_world.allocator(), .{ .index = 0, .generation = 1 });
    defer world.deinit();

    try testing.expectError(error.OutOfMemory, world.spawn());
    try testing.expectEqual(@as(usize, 0), world.entity_count);
    try testing.expectEqual(world.generations.items.len, world.alive_flags.items.len);
    try testing.expectEqual(world.generations.items.len, world.guids.items.len);
}

test "ZE-006: ComponentPool preserves align(64) across reallocations" {
    const Aligned64 = struct {
        value: u64 align(64),
    };

    var world = engine.World.init(testing.allocator, .{ .index = 0, .generation = 1 });
    defer world.deinit();

    for (0..64) |i| {
        const e = try world.spawn();
        try world.set(e, Aligned64, .{ .value = i });
        const ptr = world.getConst(e, Aligned64).?;
        try testing.expectEqual(@as(usize, 0), @intFromPtr(ptr) % 64);
        try testing.expectEqual(@as(u64, i), ptr.value);
    }
}

test "EventBus O(1) ring buffer drop_oldest preserves newest events across wrap-around" {
    var bus = engine.EventBus.init(testing.allocator, 3, .drop_oldest);
    defer bus.deinit();

    const Recorder = struct {
        sum: usize = 0,
        fn onEv(raw: ?*anyopaque, ev: engine.EventEnvelope) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.sum += ev.entity_handle;
        }
    };
    var rec = Recorder{};
    _ = try bus.subscribe(1, "num", Recorder.onEv, &rec);

    // Post 5 events into a capacity-3 ring: 1 and 2 are evicted; 3, 4, 5 remain.
    for (1..6) |i| {
        try bus.post(.{ .name = "num", .payload = "", .entity_handle = i });
    }
    try testing.expectEqual(@as(u64, 2), bus.dropped_events);
    try testing.expectEqual(@as(usize, 3), bus.pendingCount());

    _ = bus.drain();
    try testing.expectEqual(@as(usize, 3 + 4 + 5), rec.sum);
}

test "World.registerDynamicComponent rolls back cleanly on OOM" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 2 });
    var world = engine.World.init(failing.allocator(), .{ .index = 0, .generation = 1 });
    defer world.deinit();

    try testing.expectError(error.OutOfMemory, world.registerDynamicComponent("test.FailComp", 16));
    try testing.expectEqual(@as(usize, 0), world.pools.count());
}

test "event_subscribe_during_drain: subscribing during callback is safe and runs on next drain" {
    var bus = engine.EventBus.init(testing.allocator, 16, .drop_newest);
    defer bus.deinit();

    const State = struct {
        bus: *engine.EventBus,
        second_calls: usize = 0,

        fn onSecond(raw: ?*anyopaque, _: engine.EventEnvelope) void {
            const st: *@This() = @ptrCast(@alignCast(raw.?));
            st.second_calls += 1;
        }

        fn onFirst(raw: ?*anyopaque, _: engine.EventEnvelope) void {
            const st: *@This() = @ptrCast(@alignCast(raw.?));
            _ = st.bus.subscribe(2, "ping", onSecond, st) catch {};
        }
    };

    var st = State{ .bus = &bus };
    _ = try bus.subscribe(1, "ping", State.onFirst, &st);

    try bus.post(.{ .name = "ping", .payload = "a" });
    _ = bus.drain();
    // Newly subscribed handler did not run on the current event mid-loop.
    try testing.expectEqual(@as(usize, 0), st.second_calls);

    try bus.post(.{ .name = "ping", .payload = "b" });
    _ = bus.drain();
    try testing.expectEqual(@as(usize, 1), st.second_calls);
}

test "Audit 3.1: Scheduler.stepFrame sets fixed_dt in fixed_update and restores frame_dt in update" {
    const DtSpy = struct {
        var fixed_dts: [4]f32 = undefined;
        var fixed_count: usize = 0;
        var update_dt: f32 = 0;

        fn onFixed(ctx: *engine.SystemContext) !void {
            fixed_dts[fixed_count] = ctx.deltaSeconds();
            fixed_count += 1;
        }
        fn onUpdate(ctx: *engine.SystemContext) !void {
            update_dt = ctx.deltaSeconds();
        }
    };
    DtSpy.fixed_count = 0;
    DtSpy.update_dt = 0;

    var app = engine.App.init(testing.allocator, .{ .fixed_dt = 1.0 / 60.0 });
    defer app.deinit();
    try app.addSystem(.{ .name = "spy_fixed", .stage = .fixed_update, .run = DtSpy.onFixed });
    try app.addSystem(.{ .name = "spy_update", .stage = .update, .run = DtSpy.onUpdate });

    // 50ms frame should run 3 fixed ticks (~16.67ms each) and 1 update (~50ms).
    try app.tick(0.050);
    try testing.expectEqual(@as(usize, 3), DtSpy.fixed_count);
    for (0..3) |i| {
        try testing.expectApproxEqAbs(@as(f32, 1.0 / 60.0), DtSpy.fixed_dts[i], 0.0001);
    }
    try testing.expectApproxEqAbs(@as(f32, 0.050), DtSpy.update_dt, 0.0001);
}

test "Audit 3.2-3.6: World registration guard, layout validation, deferred spawn & align(64)" {
    const Aligned64 = struct { value: u64 align(64) };

    var world = engine.World.init(testing.allocator, .{ .index = 0, .generation = 1 });
    defer world.deinit();
    var events = engine.EventBus.init(testing.allocator, 8, .drop_newest);
    defer events.deinit();
    var cmds = engine.CommandBuffer.init(testing.allocator);
    defer cmds.deinit();

    // Deferred spawn + set with align(64) before component registration
    const pending_e = try cmds.spawn();
    try testing.expect(!world.isAlive(pending_e));
    try cmds.set(pending_e, Aligned64, .{ .value = 99 });
    try cmds.apply(&world, &events);
    try testing.expectEqual(@as(usize, 1), world.entity_count);

    // Querying keeps active_queries > 0 and blocks registering new components + CommandBuffer.apply
    var q = try world.query(.{ .read = .{Aligned64} });
    defer q.deinit();
    const row = q.next().?;
    try testing.expectEqual(@as(usize, 0), @intFromPtr(row.read(Aligned64)) % 64);
    try testing.expectEqual(@as(u64, 99), row.read(Aligned64).value);

    try testing.expectError(error.MutationDuringActiveQuery, world.registerComponent(Position));
    try cmds.set(row.entity, Position, .{ .x = 1, .y = 2 });
    try testing.expectError(error.MutationDuringActiveQuery, cmds.apply(&world, &events));
    cmds.clear();
    q.deinit();

    // Layout mismatch rejected on duplicate component name with different size/align
    _ = try world.registerComponentDesc(.{ .name = "custom.Item", .size = 8, .alignment = 8, .schema_version = 1 });
    try testing.expectError(error.ComponentLayoutMismatch, world.registerComponentDesc(.{ .name = "custom.Item", .size = 16, .alignment = 8, .schema_version = 1 }));
}

test "Audit 3.7, 3.9, 3.11 & 7.1: Scheduler errors, App terminal stopped, AmbiguousProvider, ResourceRegistry deinit" {
    const Dummy = struct {
        fn run(_: *engine.SystemContext) !void {}
    };

    var sched = engine.scheduler.Scheduler.init(testing.allocator);
    defer sched.deinit();
    try sched.addSystem(.{ .name = "A", .stage = .update, .run = Dummy.run });
    try testing.expectError(error.DuplicateSystem, sched.addSystem(.{ .name = "A", .stage = .update, .run = Dummy.run }));

    try sched.addSystem(.{ .name = "B", .stage = .update, .run = Dummy.run, .after = &.{"missing"} });
    try testing.expectError(error.UnknownSystemDependency, sched.buildStageSchedule(.update));

    var sched_cross = engine.scheduler.Scheduler.init(testing.allocator);
    defer sched_cross.deinit();
    try sched_cross.addSystem(.{ .name = "FixedSys", .stage = .fixed_update, .run = Dummy.run });
    try sched_cross.addSystem(.{ .name = "UpdateSys", .stage = .update, .run = Dummy.run, .after = &.{"FixedSys"} });
    try testing.expectError(error.InvalidCrossStageDependency, sched_cross.buildStageSchedule(.update));

    var sched_self = engine.scheduler.Scheduler.init(testing.allocator);
    defer sched_self.deinit();
    try sched_self.addSystem(.{ .name = "SelfSys", .stage = .update, .run = Dummy.run, .before = &.{"SelfSys"} });
    try testing.expectError(error.InvalidSelfDependency, sched_self.buildStageSchedule(.update));

    // App stopped state is terminal
    var app = engine.App.init(testing.allocator, .{ .max_frames = 1 });
    defer app.deinit();
    try app.run();
    try testing.expectError(error.InvalidAppState, app.initialize());

    // ModuleRegistry rejects ambiguous providers
    const ModStub = struct {
        fn build(_: *anyopaque) !void {}
    };
    var mreg = engine.ModuleRegistry.init(testing.allocator);
    defer mreg.deinit();
    try mreg.register(.{ .descriptor = .{ .id = "p1", .version = "1", .provides_capabilities = &.{"cap.dup"} }, .build = ModStub.build });
    try mreg.register(.{ .descriptor = .{ .id = "p2", .version = "1", .provides_capabilities = &.{"cap.dup"} }, .build = ModStub.build });
    try mreg.register(.{ .descriptor = .{ .id = "c", .version = "1", .required_capabilities = &.{"cap.dup"} }, .build = ModStub.build });
    try testing.expectError(error.AmbiguousProvider, mreg.resolve());

    // ResourceRegistry calls deinit() on overwrite and remove
    const TrackedRes = struct {
        buf: []u8,
        pub fn deinit(self: *@This()) void {
            testing.allocator.free(self.buf);
        }
    };
    var rreg = engine.ResourceRegistry.init(testing.allocator);
    defer rreg.deinit();
    try rreg.insert(TrackedRes, .{ .buf = try testing.allocator.alloc(u8, 16) });
    try rreg.insert(TrackedRes, .{ .buf = try testing.allocator.alloc(u8, 32) });
    try testing.expect(rreg.remove(TrackedRes));
}

test "World rejects invalid component alignment and size overflow" {
    var world = engine.World.init(testing.allocator, .{ .index = 0, .generation = 1 });
    defer world.deinit();
    try testing.expectError(error.InvalidComponentAlignment, world.registerComponentDesc(.{ .name = "bad.Align12", .size = 12, .alignment = 12 }));
    try testing.expectError(error.UnsupportedComponentAlignment, world.registerComponentDesc(.{ .name = "bad.Align128", .size = 128, .alignment = 128 }));
    try testing.expectError(error.ComponentSizeOverflow, world.registerComponentDesc(.{ .name = "bad.Huge", .size = std.math.maxInt(usize) - 2, .alignment = 16 }));
    try testing.expectEqual(@as(usize, 0), world.pools.count());
}

test "World membership index: despawn clears every pool across >64 registered types" {
    var world = engine.World.init(testing.allocator, .{ .index = 0, .generation = 1 });
    defer world.deinit();

    // Entities spawned before the registry grows past one membership word must survive the re-layout.
    const early = try world.spawn();
    var ids: [130]engine.ComponentTypeId = undefined;
    var buf: [24]u8 = undefined;
    for (&ids, 0..) |*id, i| {
        id.* = try world.registerDynamicComponent(try std.fmt.bufPrint(&buf, "member.T{d}", .{i}), 8);
    }
    const late = try world.spawn();
    const payload: [8]u8 = @splat(7);
    for ([_]usize{ 0, 63, 64, 129 }) |i| {
        try world.setRaw(early, ids[i], &payload);
        try world.setRaw(late, ids[i], &payload);
    }
    try testing.expect(try world.removeRaw(early, ids[64]));
    try testing.expect(!(try world.removeRaw(early, ids[64])));

    try testing.expect(try world.despawn(early));
    for (ids) |id| try testing.expect(world.getRaw(early, id) == null);
    for ([_]usize{ 0, 63, 64, 129 }) |i| try testing.expect(world.getRaw(late, ids[i]) != null);

    // Reused slot must not inherit stale membership.
    const reused = try world.spawn();
    try testing.expectEqual(early.index, reused.index);
    try testing.expect(world.getRaw(reused, ids[0]) == null);
    try world.setRaw(reused, ids[129], &payload);
    try testing.expect(try world.despawn(reused));
    try testing.expect(try world.despawn(late));
    for (world.pool_list.items) |pool| try testing.expectEqual(@as(usize, 0), pool.dense_entities.items.len);
}

const Frozen = struct { tag: u8 = 0 };

test "Query .without excludes entities holding the listed component" {
    var world = engine.World.init(testing.allocator, .{ .index = 0, .generation = 1 });
    defer world.deinit();
    _ = try world.registerComponent(Position);
    _ = try world.registerComponent(Frozen);

    var frozen: engine.EntityHandle = undefined;
    for (0..5) |i| {
        const e = try world.spawn();
        try world.set(e, Position, .{ .x = @floatFromInt(i) });
        if (i == 2) {
            try world.set(e, Frozen, .{});
            frozen = e;
        }
    }
    {
        var q = try world.query(.{ .read = .{Position}, .without = .{Frozen} });
        defer q.deinit();
        var n: usize = 0;
        while (q.next()) |row| : (n += 1) try testing.expect(!std.meta.eql(row.entity, frozen));
        try testing.expectEqual(@as(usize, 4), n);
    }
    // Unregistered excluded type excludes nothing.
    const Unregistered = struct { a: u8 };
    var q2 = try world.query(.{ .read = .{Position}, .without = .{Unregistered} });
    defer q2.deinit();
    var n2: usize = 0;
    while (q2.next()) |_| n2 += 1;
    try testing.expectEqual(@as(usize, 5), n2);
}

test "CommandBuffer pending handles are never all-zero and zero handle is not pending" {
    var world = engine.World.init(testing.allocator, .{ .index = 0, .generation = 1 });
    defer world.deinit();
    var events = engine.EventBus.init(testing.allocator, 8, .drop_newest);
    defer events.deinit();
    var cmds = engine.CommandBuffer.init(testing.allocator);
    defer cmds.deinit();

    const first = try cmds.spawn();
    try testing.expect(first.toU64() != 0);
    try testing.expect(engine.CommandBuffer.isPending(first));
    try testing.expect(!engine.CommandBuffer.isPending(engine.EntityHandle.fromU64(0)));
    try testing.expect(!engine.CommandBuffer.isPending(engine.EntityHandle.invalid));

    // A zero-initialized handle must not resolve to the first spawn.
    const second = try cmds.spawn();
    try cmds.set(first, Position, .{ .x = 1 });
    try cmds.set(second, Position, .{ .x = 2 });
    try cmds.set(engine.EntityHandle.fromU64(0), Position, .{ .x = 99 });
    try cmds.apply(&world, &events);
    var q = try world.query(.{ .read = .{Position} });
    defer q.deinit();
    var sum: f32 = 0;
    while (q.next()) |row| sum += row.read(Position).x;
    try testing.expectEqual(@as(f32, 3), sum);
}

test "CommandBuffer.apply rejects conflicting layouts before mutating the world" {
    var world = engine.World.init(testing.allocator, .{ .index = 0, .generation = 1 });
    defer world.deinit();
    var events = engine.EventBus.init(testing.allocator, 8, .drop_newest);
    defer events.deinit();
    var cmds = engine.CommandBuffer.init(testing.allocator);
    defer cmds.deinit();

    const e = try world.spawn();
    try cmds.set(e, Position, .{ .x = 1 });
    // Same type id, different layout, queued in the same buffer.
    try cmds.commands.append(testing.allocator, .{ .set_raw = .{
        .entity = e,
        .type_id = engine.World.comptimeTypeId(Position),
        .type_name = @typeName(Position),
        .alignment = @alignOf(Position),
        .bytes = &.{ 1, 2, 3 },
    } });
    try testing.expectError(error.ComponentLayoutMismatch, cmds.apply(&world, &events));
    try testing.expect(!world.has(e, Position));
}

test "Scheduler rejects invalid fixed timesteps and clamps excess accumulator" {
    var app = engine.App.init(testing.allocator, .{ .max_frames = 1 });
    defer app.deinit();
    var ctx = app.makeSystemContext(0.016);
    const sched = &app.scheduler;

    for ([_]f64{ 0.0, -1.0, std.math.nan(f64), std.math.inf(f64) }) |bad| {
        sched.fixed_dt = bad;
        try testing.expectError(error.InvalidFixedTimestep, sched.stepFrame(0.016, &ctx));
        try testing.expectError(error.InvalidFixedTimestep, sched.stepFixedTick(&ctx));
    }

    sched.fixed_dt = 0.5;
    sched.max_fixed_steps = 2;
    try testing.expectEqual(@as(u32, 2), try sched.stepFrame(100.0, &ctx));
    try testing.expectEqual(@as(f64, 0.0), sched.accumulator);
}

fn failingSystem(_: *engine.SystemContext) !void {
    return error.SystemFailed;
}

test "App.runRealtime paces frames to min_frame_ns and failed frames still shut down" {
    const io = testing.io;
    {
        var app = engine.App.init(testing.allocator, .{ .max_frames = 4, .min_frame_ns = 5_000_000 });
        defer app.deinit();
        const t0 = std.Io.Clock.now(.awake, io);
        try app.runRealtime(io);
        const elapsed = t0.durationTo(std.Io.Clock.now(.awake, io)).nanoseconds;
        try testing.expect(elapsed >= 15_000_000); // 4 frames, first frame included in budget
    }
    {
        var app = engine.App.init(testing.allocator, .{ .max_frames = 4 });
        defer app.deinit();
        try app.addSystem(.{ .name = "boom", .stage = .update, .run = failingSystem });
        try testing.expectError(error.SystemFailed, app.run());
        try testing.expectEqual(engine.AppState.stopped, app.state);
    }
}

var lifecycle_stops: u32 = 0;
fn noopSystem(_: *engine.SystemContext) !void {}
fn lcBuildOk(_: *anyopaque) anyerror!void {}
fn lcStop(_: *anyopaque) void {
    lifecycle_stops += 1;
}
fn lcBuildAddsSystem(raw: *anyopaque) anyerror!void {
    const app: *engine.App = @ptrCast(@alignCast(raw));
    try app.addSystem(.{ .name = "lc.leaked", .stage = .update, .run = noopSystem });
}
fn lcStartFails(_: *anyopaque) anyerror!void {
    return error.StartFailed;
}

test "App.initialize rolls back systems and stops every built module when start fails" {
    lifecycle_stops = 0;
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();
    try app.registerModule(.{ .descriptor = .{ .id = "lc.a", .version = "1.0.0", .provides_capabilities = &.{"lc.cap/1"} }, .build = lcBuildOk, .stop = lcStop });
    try app.registerModule(.{
        .descriptor = .{ .id = "lc.b", .version = "1.0.0", .required_capabilities = &.{"lc.cap/1"} },
        .build = lcBuildAddsSystem,
        .start = lcStartFails,
        .stop = lcStop,
    });
    try testing.expectError(error.StartFailed, app.initialize());
    try testing.expectEqual(@as(u32, 2), lifecycle_stops); // both A and the failed-start B
    for (app.scheduler.stages) |stage| try testing.expectEqual(@as(usize, 0), stage.items.len);
}

const Health = struct { hp: i32 = 10 };
const Shield = struct { v: i32 = 1 };
var seen_added: u32 = 0;
var seen_changed: u32 = 0;
var seen_shield_sum: i32 = 0;

fn observeAdded(ctx: *engine.SystemContext) !void {
    var q = try ctx.query(.{ .read = .{Health}, .added = .{Health} });
    defer q.deinit();
    while (q.next()) |_| seen_added += 1;
}
fn observeChanged(ctx: *engine.SystemContext) !void {
    var q = try ctx.query(.{ .read = .{Health}, .changed = .{Health}, .optional = .{Shield} });
    defer q.deinit();
    while (q.next()) |row| {
        seen_changed += 1;
        if (row.optional(Shield)) |sh| seen_shield_sum += sh.v;
    }
}

test "Query .added/.changed/.optional with per-system change ticks" {
    seen_added = 0;
    seen_changed = 0;
    seen_shield_sum = 0;
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();
    try app.world.enableChangeTracking(Health);
    _ = try app.registerComponent(Shield);
    try app.addSystem(.{ .name = "obs.added", .stage = .update, .run = observeAdded });
    try app.addSystem(.{ .name = "obs.changed", .stage = .update, .run = observeChanged });

    const a = try app.world.spawn();
    const b = try app.world.spawn();
    try app.world.set(a, Health, .{});
    try app.world.set(b, Health, .{});
    try app.world.set(a, Shield, .{ .v = 5 });

    try app.tick(1.0 / 60.0);
    try testing.expectEqual(@as(u32, 2), seen_added);
    try testing.expectEqual(@as(u32, 2), seen_changed); // adds count as changes
    try testing.expectEqual(@as(i32, 5), seen_shield_sum);

    // Nothing touched: neither filter fires.
    try app.tick(1.0 / 60.0);
    try testing.expectEqual(@as(u32, 2), seen_added);
    try testing.expectEqual(@as(u32, 2), seen_changed);

    // Mutable access marks only that entity changed; reads via getConst do not.
    _ = app.world.getConst(b, Health);
    app.world.get(a, Health).?.hp = 3;
    try app.tick(1.0 / 60.0);
    try testing.expectEqual(@as(u32, 2), seen_added);
    try testing.expectEqual(@as(u32, 3), seen_changed);

    // Overwriting through set() counts; removal + re-add counts as added.
    try app.world.set(b, Health, .{ .hp = 1 });
    try testing.expect(try app.world.remove(a, Health));
    try app.world.set(a, Health, .{});
    try app.tick(1.0 / 60.0);
    try testing.expectEqual(@as(u32, 3), seen_added);
    try testing.expectEqual(@as(u32, 5), seen_changed);
}

test "Query change filters require enableChangeTracking; pre-existing components are not new" {
    var world = engine.World.init(testing.allocator, .{ .index = 0, .generation = 1 });
    defer world.deinit();
    const e = try world.spawn();
    try world.set(e, Health, .{});
    try testing.expectError(error.ChangeTrackingNotEnabled, world.query(.{ .read = .{Health}, .changed = .{Health} }));
    try testing.expectEqual(@as(u32, 0), world.active_queries);

    try world.enableChangeTracking(Health);
    world.advanceTick();
    world.query_since = world.tick - 1;
    var q = try world.query(.{ .read = .{Health}, .added = .{Health} });
    defer q.deinit();
    try testing.expect(q.next() == null);
}

test "CommandBuffer.apply is atomic with respect to allocation failure" {
    var fail_index: usize = 0;
    var saw_failure = false;
    var saw_success = false;
    while (fail_index < 200) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
        var world = engine.World.init(failing.allocator(), .{ .index = 0, .generation = 1 });
        defer world.deinit();
        var events = engine.EventBus.init(testing.allocator, 8, .drop_newest);
        defer events.deinit();
        var cmds = engine.CommandBuffer.init(testing.allocator);
        defer cmds.deinit();

        const keep = try world.spawn();
        try world.set(keep, Health, .{ .hp = 7 });
        const victim = try world.spawn();
        try world.set(victim, Health, .{ .hp = 9 });
        const entities_before = world.entity_count;

        const p1 = try cmds.spawn();
        const p2 = try cmds.spawn();
        try cmds.set(p1, Health, .{ .hp = 1 });
        try cmds.set(p2, Shield, .{ .v = 2 });
        try cmds.set(keep, Shield, .{ .v = 3 });
        try cmds.despawn(victim);

        failing.fail_index = failing.alloc_index + fail_index;
        if (cmds.apply(&world, &events)) |_| {
            saw_success = true;
            try testing.expectEqual(entities_before + 2 - 1, world.entity_count);
            try testing.expect(!world.isAlive(victim));
            try testing.expectEqual(@as(i32, 3), world.getConst(keep, Shield).?.v);
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            saw_failure = true;
            // Nothing visible happened: same entities, no new components, victim intact.
            try testing.expectEqual(entities_before, world.entity_count);
            try testing.expect(world.isAlive(victim));
            try testing.expectEqual(@as(i32, 9), world.getConst(victim, Health).?.hp);
            try testing.expect(!world.has(keep, Shield));
        }
    }
    try testing.expect(saw_failure and saw_success);
}

var res_destroy_log: [4]u8 = undefined;
var res_destroy_len: usize = 0;
const ResA = struct {
    v: u8 = 0,
    pub fn deinit(self: *ResA) void {
        res_destroy_log[res_destroy_len] = 'A' + self.v;
        res_destroy_len += 1;
    }
};
const ResB = struct {
    v: u8 = 0,
    pub fn deinit(self: *ResB) void {
        res_destroy_log[res_destroy_len] = 'a' + self.v;
        res_destroy_len += 1;
    }
};

test "ResourceRegistry destroys in reverse insertion order, overwrite runs deinit, remove keeps order consistent" {
    res_destroy_len = 0;
    {
        var reg = engine.ResourceRegistry.init(testing.allocator);
        defer reg.deinit();
        try reg.insert(ResA, .{ .v = 0 });
        try reg.insert(ResB, .{ .v = 0 });
        try reg.insert(ResA, .{ .v = 1 }); // overwrite: old A deinit runs immediately
        try testing.expectEqual(@as(usize, 1), res_destroy_len);
        try testing.expectEqual(@as(u8, 1), reg.get(ResA).?.v);
        try testing.expectEqual(@as(usize, 2), reg.order.items.len);
    }
    // deinit: B (inserted last) before A.
    try testing.expectEqual(@as(usize, 3), res_destroy_len);
    try testing.expectEqual(@as(u8, 'A'), res_destroy_log[0]);
    try testing.expectEqual(@as(u8, 'a'), res_destroy_log[1]);
    try testing.expectEqual(@as(u8, 'B'), res_destroy_log[2]);
}

const PropA = struct { v: u32 = 0 };
const PropB = struct { v: u32 = 0, w: u32 = 0 };
const PropTag = struct {};

test "property: World matches a reference model under random structural operations" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rng = prng.random();

    var world = engine.World.init(testing.allocator, .{ .index = 0, .generation = 1 });
    defer world.deinit();
    try world.enableChangeTracking(PropA);
    _ = try world.registerComponent(PropB);
    _ = try world.registerComponent(PropTag);

    const Model = struct { handle: engine.EntityHandle, a: ?u32 = null, b: ?u32 = null, tag: bool = false };
    var model: std.ArrayList(Model) = .empty;
    defer model.deinit(testing.allocator);
    var dead: std.ArrayList(engine.EntityHandle) = .empty;
    defer dead.deinit(testing.allocator);

    for (0..20_000) |step| {
        switch (rng.uintLessThan(u8, 7)) {
            0, 1 => try model.append(testing.allocator, .{ .handle = try world.spawn() }),
            2 => if (model.items.len > 0) {
                const i = rng.uintLessThan(usize, model.items.len);
                try testing.expect(try world.despawn(model.items[i].handle));
                try dead.append(testing.allocator, model.items[i].handle);
                _ = model.swapRemove(i);
            },
            3 => if (model.items.len > 0) {
                const m = &model.items[rng.uintLessThan(usize, model.items.len)];
                const v = rng.int(u32);
                try world.set(m.handle, PropA, .{ .v = v });
                m.a = v;
            },
            4 => if (model.items.len > 0) {
                const m = &model.items[rng.uintLessThan(usize, model.items.len)];
                const v = rng.int(u32);
                try world.set(m.handle, PropB, .{ .v = v, .w = ~v });
                m.b = v;
            },
            5 => if (model.items.len > 0) {
                const m = &model.items[rng.uintLessThan(usize, model.items.len)];
                if (rng.boolean()) {
                    try world.set(m.handle, PropTag, .{});
                    m.tag = true;
                } else {
                    try testing.expectEqual(m.tag, try world.remove(m.handle, PropTag));
                    m.tag = false;
                }
            },
            else => if (model.items.len > 0) {
                const m = &model.items[rng.uintLessThan(usize, model.items.len)];
                if (rng.boolean()) {
                    try testing.expectEqual(m.a != null, try world.remove(m.handle, PropA));
                    m.a = null;
                } else {
                    try testing.expectEqual(m.b != null, try world.remove(m.handle, PropB));
                    m.b = null;
                }
            },
        }

        if (step % 500 != 0) continue;
        try testing.expectEqual(model.items.len, world.entity_count);
        for (model.items) |m| {
            try testing.expect(world.isAlive(m.handle));
            try testing.expectEqual(m.a, if (world.getConst(m.handle, PropA)) |c| c.v else null);
            try testing.expectEqual(m.b, if (world.getConst(m.handle, PropB)) |c| c.v else null);
            try testing.expectEqual(m.tag, world.has(m.handle, PropTag));
        }
        for (dead.items) |h| {
            try testing.expect(!world.isAlive(h));
            try testing.expect(world.getConst(h, PropA) == null);
        }
        // Query results must equal the model's view of "has A and B", without .without(Tag) hits.
        var expected: usize = 0;
        for (model.items) |m| {
            if (m.a != null and m.b != null and !m.tag) expected += 1;
        }
        var q = try world.query(.{ .read = .{ PropA, PropB }, .without = .{PropTag} });
        defer q.deinit();
        var got: usize = 0;
        while (q.next()) |row| {
            got += 1;
            try testing.expectEqual(row.read(PropB).v, ~row.read(PropB).w);
        }
        try testing.expectEqual(expected, got);
    }

    // Every pool's dense arrays stay parallel (tracked arrays included).
    for (world.pool_list.items) |pool| {
        if (pool.tracked) {
            try testing.expectEqual(pool.dense_entities.items.len, pool.added_ticks.items.len);
            try testing.expectEqual(pool.dense_entities.items.len, pool.changed_ticks.items.len);
        }
    }
}

fn migrateStatsV1ToV2(allocator: std.mem.Allocator, old: []const u8) anyerror![]u8 {
    // v1 { hp: i32 } -> v2 { hp: i32, armor: f32 = 0.5 }
    const out = try allocator.alloc(u8, 8);
    @memcpy(out[0..4], old[0..4]);
    const armor: f32 = 0.5;
    @memcpy(out[4..8], std.mem.asBytes(&armor));
    return out;
}

test "Schema v2: stable ids, portable encoding, and migration chain" {
    var reg = engine.TypeRegistry.init(testing.allocator);
    defer reg.deinit();

    const v1 = try reg.registerSchema("game", "Stats", 1, .blittable, &.{.{ .name = "hp", .field_type = .i32_t }});
    var old_bytes: [4]u8 = undefined;
    try engine.TypeRegistry.setField(v1, &old_bytes, "hp", .{ .i32_t = 77 });

    // Persist with only v1 known.
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(testing.allocator);
    try engine.TypeRegistry.encodeComponent(testing.allocator, v1, &old_bytes, &file);
    try testing.expectEqual(@as(usize, 24 + 4), file.items.len);

    // The stable id does not depend on version, and the encoding has no host padding.
    const v2 = try reg.registerSchema("game", "Stats", 2, .blittable, &.{
        .{ .name = "hp", .field_type = .i32_t },
        .{ .name = "armor", .field_type = .f32_t },
    });
    try testing.expectEqual(v1.stable_id, v2.stable_id);
    try testing.expect(v1.schema_id != v2.schema_id);

    // Without a migration, old data cannot be loaded.
    try testing.expectError(error.MissingMigration, reg.decodeComponent(testing.allocator, file.items));
    try reg.registerMigration("game", "Stats", 1, migrateStatsV1ToV2);

    const dec = try reg.decodeComponent(testing.allocator, file.items);
    defer testing.allocator.free(dec.bytes);
    try testing.expectEqual(@as(u32, 2), dec.schema.version);
    try testing.expectEqual(@as(i32, 77), (try engine.TypeRegistry.getField(dec.schema, dec.bytes, "hp")).i32_t);
    try testing.expectEqual(@as(f32, 0.5), (try engine.TypeRegistry.getField(dec.schema, dec.bytes, "armor")).f32_t);
    try testing.expectEqual(file.items.len, dec.consumed);

    // Current-version roundtrip with vec fields and padding between fields.
    const t = try reg.registerSchema("game", "Pose", 1, .blittable, &.{
        .{ .name = "alive", .field_type = .bool_t },
        .{ .name = "id", .field_type = .u64_t },
        .{ .name = "pos", .field_type = .vec3_t },
    });
    const pose = try testing.allocator.alloc(u8, t.byte_size);
    defer testing.allocator.free(pose);
    @memset(pose, 0);
    try engine.TypeRegistry.setField(t, pose, "alive", .{ .bool_t = true });
    try engine.TypeRegistry.setField(t, pose, "id", .{ .u64_t = 0xDEADBEEF });
    try engine.TypeRegistry.setField(t, pose, "pos", .{ .vec3_t = .{ 1, 2, 3 } });
    var f2: std.ArrayList(u8) = .empty;
    defer f2.deinit(testing.allocator);
    try engine.TypeRegistry.encodeComponent(testing.allocator, t, pose, &f2);
    try testing.expectEqual(@as(usize, 24 + 1 + 8 + 12), f2.items.len);
    const d2 = try reg.decodeComponent(testing.allocator, f2.items);
    defer testing.allocator.free(d2.bytes);
    try testing.expectEqual(@as(u64, 0xDEADBEEF), (try engine.TypeRegistry.getField(d2.schema, d2.bytes, "id")).u64_t);
    try testing.expectEqual([3]f32{ 1, 2, 3 }, (try engine.TypeRegistry.getField(d2.schema, d2.bytes, "pos")).vec3_t);

    // Truncated / unknown / too-new inputs are rejected, never misread.
    try testing.expectError(error.PayloadTruncated, reg.decodeComponent(testing.allocator, f2.items[0 .. f2.items.len - 1]));
    var bad = try testing.allocator.dupe(u8, f2.items);
    defer testing.allocator.free(bad);
    std.mem.writeInt(u32, bad[16..20], 9, .little);
    try testing.expectError(error.SchemaTooNew, reg.decodeComponent(testing.allocator, bad));
    std.mem.writeInt(u128, bad[0..16], 12345, .little);
    try testing.expectError(error.UnknownSchema, reg.decodeComponent(testing.allocator, bad));
}

test "Scheduler.parallelBatches groups only conflict-free, unordered systems" {
    var sched = engine.scheduler.Scheduler.init(testing.allocator);
    defer sched.deinit();
    const noop = struct {
        fn run(_: *engine.SystemContext) !void {}
    }.run;
    try sched.addSystem(.{ .name = "physics", .run = noop, .writes = &.{"Transform"} });
    try sched.addSystem(.{ .name = "ai", .run = noop, .writes = &.{"Brain"}, .reads = &.{"Config"} });
    try sched.addSystem(.{ .name = "audio", .run = noop, .reads = &.{"Config"} });
    try sched.addSystem(.{ .name = "render_prep", .run = noop, .reads = &.{"Transform"} }); // reads what physics writes
    try sched.addSystem(.{ .name = "cleanup", .run = noop, .exclusive = true });
    try sched.addSystem(.{ .name = "ui", .run = noop, .after = &.{"cleanup"}, .reads = &.{"Ui"} });

    var plan = try sched.parallelBatches(.update);
    defer plan.deinit();
    // [physics, ai, audio] are independent; render_prep conflicts with physics; cleanup is exclusive;
    // ui is ordered after cleanup.
    try testing.expectEqual(@as(usize, 4), plan.batchCount());
    try testing.expectEqual(@as(usize, 3), plan.batch(0).len);
    try testing.expectEqual(@as(usize, 1), plan.batch(1).len);
    try testing.expectEqual(@as(usize, 1), plan.batch(2).len);
    try testing.expectEqual(@as(usize, 1), plan.batch(3).len);
    // Flattening the batches reproduces the serial order exactly.
    var flat: usize = 0;
    for (0..plan.batchCount()) |b| {
        for (plan.batch(b)) |idx| {
            try testing.expectEqual(plan.order[flat], idx);
            flat += 1;
        }
    }
    try testing.expectEqual(@as(usize, 6), flat);
}

test "World.setGuidNamespace partitions GUIDs and is rejected once entities exist" {
    var a = engine.World.init(testing.allocator, .{ .index = 0, .generation = 1 });
    defer a.deinit();
    var b = engine.World.init(testing.allocator, .{ .index = 1, .generation = 1 });
    defer b.deinit();
    try a.setGuidNamespace(0xA);
    try b.setGuidNamespace(0xB);
    const ea = try a.spawn();
    const eb = try b.spawn();
    const ga = a.getGuid(ea).?;
    const gb = b.getGuid(eb).?;
    try testing.expect(ga != gb);
    try testing.expectEqual(@as(u64, 0xA), @as(u64, @truncate(ga >> 64)));
    try testing.expectEqual(@as(u64, 0xB), @as(u64, @truncate(gb >> 64)));
    try testing.expectError(error.WorldNotEmpty, a.setGuidNamespace(0xC));
}
