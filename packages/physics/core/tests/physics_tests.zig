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
}
