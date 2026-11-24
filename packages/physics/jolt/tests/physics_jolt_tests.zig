const std = @import("std");
const engine = @import("engine");
const physics = @import("physics");
const physics_jolt = @import("physics_jolt");

test "JoltBackend simulates gravity and floor collision" {
    var jolt = try physics_jolt.JoltBackend.init();
    defer jolt.deinit();

    var svc = physics.PhysicsService.init(std.testing.allocator);
    jolt.attachTo(&svc);
    try std.testing.expect(svc.hasBackend());

    const vt = svc.backend.?;

    // Static floor at y = 0.0 (top surface at y = 0.5)
    const floor_ent = engine.EntityHandle{ .index = 1, .generation = 1 };
    const floor_id = try vt.create_body.?(
        svc.backend_ctx.?,
        floor_ent,
        .{ 0.0, 0.0, 0.0 },
        .{ .body_type = .static },
        .{ .shape = .{ .box = .{ .half_x = 10.0, .half_y = 0.5, .half_z = 10.0 } } },
    );
    defer vt.destroy_body.?(svc.backend_ctx.?, floor_id);

    // Dynamic box at y = 3.0 (half_y = 0.5, so resting center should be ~1.0)
    const box_ent = engine.EntityHandle{ .index = 2, .generation = 1 };
    const box_id = try vt.create_body.?(
        svc.backend_ctx.?,
        box_ent,
        .{ 0.0, 3.0, 0.0 },
        .{ .body_type = .dynamic, .mass = 1.0 },
        .{ .shape = .{ .box = .{ .half_x = 0.5, .half_y = 0.5, .half_z = 0.5 } } },
    );
    defer vt.destroy_body.?(svc.backend_ctx.?, box_id);

    // Step 120 frames at 60 Hz (2 seconds)
    var i: usize = 0;
    while (i < 120) : (i += 1) {
        try svc.step(1.0 / 60.0);
    }

    const t = vt.get_transform.?(svc.backend_ctx.?, box_id).?;
    // Box should have fallen from 3.0 and come to rest on floor top (0.5 + 0.5 = 1.0)
    try std.testing.expect(t.pos[1] < 1.2);
    try std.testing.expect(t.pos[1] > 0.85);
}

test "JoltBackend raycast hits static floor and returns entity handle" {
    var jolt = try physics_jolt.JoltBackend.init();
    defer jolt.deinit();

    var svc = physics.PhysicsService.init(std.testing.allocator);
    jolt.attachTo(&svc);

    const floor_ent = engine.EntityHandle{ .index = 77, .generation = 3 };
    const floor_id = try svc.backend.?.create_body.?(
        svc.backend_ctx.?,
        floor_ent,
        .{ 0.0, 0.0, 0.0 },
        .{ .body_type = .static },
        .{ .shape = .{ .box = .{ .half_x = 5.0, .half_y = 0.5, .half_z = 5.0 } } },
    );
    defer svc.backend.?.destroy_body.?(svc.backend_ctx.?, floor_id);

    const hit = svc.raycast(.{
        .origin = .{ 0.0, 5.0, 0.0 },
        .direction = .{ 0.0, -1.0, 0.0 },
        .max_distance = 10.0,
    });
    try std.testing.expect(hit != null);
    try std.testing.expectEqual(floor_ent.index, hit.?.entity.index);
    try std.testing.expectEqual(floor_ent.generation, hit.?.entity.generation);
    try std.testing.expectApproxEqAbs(@as(f32, 4.5), hit.?.distance, 0.05);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), hit.?.normal[1], 0.05);
}

test "JoltBackend applyImpulse launches body upward" {
    var jolt = try physics_jolt.JoltBackend.init();
    defer jolt.deinit();

    var svc = physics.PhysicsService.init(std.testing.allocator);
    jolt.attachTo(&svc);

    const sphere_ent = engine.EntityHandle{ .index = 10, .generation = 1 };
    const sphere_id = try svc.backend.?.create_body.?(
        svc.backend_ctx.?,
        sphere_ent,
        .{ 0.0, 1.0, 0.0 },
        .{ .body_type = .dynamic, .mass = 1.0 },
        .{ .shape = .{ .sphere = .{ .radius = 0.5 } } },
    );
    defer svc.backend.?.destroy_body.?(svc.backend_ctx.?, sphere_id);

    svc.applyImpulse(sphere_id, .{ 0.0, 10.0, 0.0 });
    try svc.step(1.0 / 60.0);

    const vel = svc.backend.?.get_velocity.?(svc.backend_ctx.?, sphere_id).?;
    try std.testing.expect(vel.y > 5.0);
}

test "official.physics.jolt module attaches to App and steps in fixed_update" {
    var app = engine.App.init(std.testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(physics.module());
    try app.registerModule(physics_jolt.module());
    try app.initialize();

    const svc = app.resources.get(physics.PhysicsService).?;
    try std.testing.expect(svc.hasBackend());

    try app.tick(1.0 / 60.0);
    try std.testing.expect(svc.step_count >= 1);
}
