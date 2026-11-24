const std = @import("std");
const engine = @import("engine");
const physics = @import("physics");

const MockPhysicsBackend = struct {
    steps: u32 = 0,
    last_dt: f32 = 0,
    last_gravity: [3]f32 = .{ 0, 0, 0 },
    last_impulse: [3]f32 = .{ 0, 0, 0 },
    raycast_calls: u32 = 0,

    fn stepFn(ctx: *anyopaque, dt: f32, gravity: [3]f32) anyerror!void {
        const self: *MockPhysicsBackend = @ptrCast(@alignCast(ctx));
        self.steps += 1;
        self.last_dt = dt;
        self.last_gravity = gravity;
    }

    fn impulseFn(ctx: *anyopaque, _: u64, impulse: [3]f32) void {
        const self: *MockPhysicsBackend = @ptrCast(@alignCast(ctx));
        self.last_impulse = impulse;
    }

    fn raycastFn(ctx: *anyopaque, desc: physics.RaycastDesc) ?physics.RaycastHit {
        const self: *MockPhysicsBackend = @ptrCast(@alignCast(ctx));
        self.raycast_calls += 1;
        return .{
            .entity = .{ .index = 42, .generation = 1 },
            .distance = @min(2.5, desc.max_distance),
            .point = .{ 0, 1, 0 },
            .normal = .{ 0, 1, 0 },
        };
    }

    const vtable = physics.PhysicsBackendVTable{
        .step = stepFn,
        .apply_impulse = impulseFn,
        .raycast = raycastFn,
    };
};

test "PhysicsService works in headless no-op mode without backend" {
    var svc = physics.PhysicsService.init(std.testing.allocator);
    try std.testing.expect(!svc.hasBackend());
    try svc.step(1.0 / 60.0);
    try std.testing.expectEqual(@as(u64, 1), svc.step_count);
    try std.testing.expect(svc.raycast(.{
        .origin = .{ 0, 0, 0 },
        .direction = .{ 0, -1, 0 },
        .max_distance = 10.0,
    }) == null);
}

test "PhysicsService dispatches to pluggable PhysicsBackendVTable" {
    var mock = MockPhysicsBackend{};
    var svc = physics.PhysicsService.initWithBackend(
        std.testing.allocator,
        &MockPhysicsBackend.vtable,
        &mock,
    );
    try std.testing.expect(svc.hasBackend());

    try svc.step(1.0 / 60.0);
    try std.testing.expectEqual(@as(u32, 1), mock.steps);
    try std.testing.expectApproxEqAbs(@as(f32, -9.81), mock.last_gravity[1], 0.001);

    svc.applyImpulse(7, .{ 0, 5, 0 });
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), mock.last_impulse[1], 0.001);

    const hit = svc.raycast(.{
        .origin = .{ 0, 5, 0 },
        .direction = .{ 0, -1, 0 },
        .max_distance = 10.0,
    });
    try std.testing.expect(hit != null);
    try std.testing.expectEqual(@as(u32, 1), mock.raycast_calls);
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), hit.?.distance, 0.001);
}

test "official.physics module registers components and runs fixed_update" {
    var app = engine.App.init(std.testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(physics.module());
    try app.initialize();

    const e = try app.world.spawn();
    try app.world.set(e, physics.RigidBody, .{ .body_type = .dynamic, .mass = 2.0 });
    try app.world.set(e, physics.Collider, .{ .shape = .{ .box = .{ .half_x = 0.5, .half_y = 0.5 } } });
    try app.world.set(e, physics.Velocity, .{ .x = 1.0, .y = 0.0 });
    try app.world.set(e, physics.GravityScale, .{ .scale = 1.0 });

    try app.tick(1.0 / 60.0);

    const svc = app.resources.get(physics.PhysicsService).?;
    try std.testing.expect(svc.step_count >= 1);
    try std.testing.expectEqual(@as(u64, 0), svc.active_step_count);
}

test "PhysicsService rejects half-null setBackend and syncs ECS bodies with backend" {
    const SyncMock = struct {
        created: u32 = 0,
        pos: [3]f32 = .{ 0, 10, 0 },

        fn createBody(ctx: *anyopaque, _: engine.EntityHandle, pos: [3]f32, _: physics.RigidBody, _: ?physics.Collider) anyerror!u64 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.created += 1;
            self.pos = pos;
            return 77;
        }
        fn stepFn(ctx: *anyopaque, dt: f32, gravity: [3]f32) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.pos[1] += gravity[1] * dt;
        }
        fn getTransform(ctx: *anyopaque, _: u64) ?physics.BodyTransform {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return .{ .pos = self.pos, .rot_euler = .{ 0, 0, 0 } };
        }
        const vt = physics.PhysicsBackendVTable{
            .create_body = createBody,
            .step = stepFn,
            .get_transform = getTransform,
        };
    };

    var app = engine.App.init(std.testing.allocator, .{});
    defer app.deinit();
    try app.registerModule(physics.module());
    try app.initialize();

    const svc = app.resources.get(physics.PhysicsService).?;
    // Half-null backend must safely clear instead of leaving invalid ctx pointer
    svc.setBackend(&SyncMock.vt, null);
    try std.testing.expect(!svc.hasBackend());
    try svc.step(1.0 / 60.0);

    var mock = SyncMock{};
    svc.setBackend(&SyncMock.vt, &mock);
    try std.testing.expect(svc.hasBackend());

    const e = try app.world.spawn();
    try app.world.set(e, physics.RigidBody, .{ .body_type = .dynamic });
    try app.world.set(e, physics.PhysicsTransform, .{ .pos = .{ 0, 10, 0 } });

    try app.tick(1.0 / 60.0); // sync_in creates body & steps
    try app.tick(1.0 / 60.0); // sync_out writes simulated transform back
    try std.testing.expectEqual(@as(u32, 1), mock.created);
    try std.testing.expect(svc.active_step_count >= 2);
    const pt = app.world.getConst(e, physics.PhysicsTransform).?;
    try std.testing.expect(pt.pos[1] < 10.0);
}

test "Physics bodies are destroyed with their entities, rotated at creation, and not retried after failure" {
    const LifeMock = struct {
        next_id: u64 = 1,
        live: u32 = 0,
        fail_create: bool = false,
        create_calls: u32 = 0,
        last_rot: [3]f32 = .{ 0, 0, 0 },

        fn createBody(ctx: *anyopaque, _: engine.EntityHandle, _: [3]f32, _: physics.RigidBody, _: ?physics.Collider) anyerror!u64 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.create_calls += 1;
            if (self.fail_create) return error.BackendRefused;
            self.live += 1;
            defer self.next_id += 1;
            return self.next_id;
        }
        fn destroyBody(ctx: *anyopaque, _: u64) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.live -= 1;
        }
        fn setTransform(ctx: *anyopaque, _: u64, _: [3]f32, rot: [3]f32) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.last_rot = rot;
        }
        const vt = physics.PhysicsBackendVTable{
            .create_body = createBody,
            .destroy_body = destroyBody,
            .set_transform = setTransform,
        };
    };

    var app = engine.App.init(std.testing.allocator, .{});
    defer app.deinit();
    try app.registerModule(physics.module());
    try app.initialize();
    const svc = app.resources.get(physics.PhysicsService).?;
    var mock = LifeMock{};
    svc.setBackend(&LifeMock.vt, &mock);

    const a = try app.world.spawn();
    try app.world.set(a, physics.RigidBody, .{ .body_type = .dynamic });
    try app.world.set(a, physics.PhysicsTransform, .{ .rot_euler = .{ 0, 1.5, 0 } });
    const b = try app.world.spawn();
    try app.world.set(b, physics.RigidBody, .{ .body_type = .dynamic });
    try app.world.set(b, physics.PhysicsTransform, .{ .rot_euler = .{ 0, 1.5, 0 } });

    try app.tickFixed();
    try std.testing.expectEqual(@as(u32, 2), mock.live);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), mock.last_rot[1], 0.0001);

    // Despawn and component removal must both release backend bodies on the next sync.
    _ = try app.world.despawn(a);
    _ = try app.world.remove(b, physics.RigidBody);
    try app.tickFixed();
    try std.testing.expectEqual(@as(u32, 0), mock.live);
    try std.testing.expectEqual(@as(usize, 0), svc.live_bodies.count());

    // A failing backend is tried once, not every step.
    mock.fail_create = true;
    mock.create_calls = 0;
    const c = try app.world.spawn();
    try app.world.set(c, physics.RigidBody, .{ .body_type = .dynamic });
    try app.world.set(c, physics.PhysicsTransform, .{});
    try app.tickFixed();
    try app.tickFixed();
    try app.tickFixed();
    try std.testing.expectEqual(@as(u32, 1), mock.create_calls);

    // Replacing the backend destroys its bodies and invalidates ECS handles (epoch bump).
    mock.fail_create = false;
    _ = try app.world.remove(c, physics.PhysicsBodyHandle);
    try app.tickFixed();
    try std.testing.expectEqual(@as(u32, 1), mock.live);
    var mock2 = LifeMock{};
    svc.setBackend(&LifeMock.vt, &mock2);
    try std.testing.expectEqual(@as(u32, 0), mock.live);
    try app.tickFixed();
    try std.testing.expectEqual(@as(u32, 1), mock2.live);
}
