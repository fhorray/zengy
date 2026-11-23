//! Optional Jolt Physics Backend Package (`official.physics.jolt`).
//!
//! Implements `physics.PhysicsBackendVTable` backed by JoltPhysics (C++17)
//! via `jolt_c_api.h` and attaches automatically to `physics.PhysicsService`.

const std = @import("std");
const engine = @import("engine");
const physics = @import("physics");

const c = struct {
    pub const JoltWorld = opaque {};
    pub extern "c" fn jolt_world_create() ?*JoltWorld;
    pub extern "c" fn jolt_world_destroy(world: *JoltWorld) void;
    pub extern "c" fn jolt_world_create_body(
        world: *JoltWorld,
        entity_u64: u64,
        pos: *const [3]f32,
        body_type: u8,
        mass: f32,
        linear_damping: f32,
        angular_damping: f32,
        lock_rotation: bool,
        shape_kind: u8,
        dim0: f32,
        dim1: f32,
        dim2: f32,
        friction: f32,
        restitution: f32,
        is_sensor: bool,
    ) u64;
    pub extern "c" fn jolt_world_destroy_body(world: *JoltWorld, body_handle: u64) void;
    pub extern "c" fn jolt_world_set_transform(world: *JoltWorld, body_handle: u64, pos: *const [3]f32, rot_euler: *const [3]f32) void;
    pub extern "c" fn jolt_world_get_transform(world: *JoltWorld, body_handle: u64, out_pos: *[3]f32, out_rot_euler: *[3]f32) bool;
    pub extern "c" fn jolt_world_set_velocity(world: *JoltWorld, body_handle: u64, vel: *const [3]f32, ang_vel: *const [3]f32) void;
    pub extern "c" fn jolt_world_get_velocity(world: *JoltWorld, body_handle: u64, out_vel: *[3]f32, out_ang_vel: *[3]f32) bool;
    pub extern "c" fn jolt_world_apply_force(world: *JoltWorld, body_handle: u64, force: *const [3]f32) void;
    pub extern "c" fn jolt_world_apply_impulse(world: *JoltWorld, body_handle: u64, impulse: *const [3]f32) void;
    pub extern "c" fn jolt_world_step(world: *JoltWorld, dt: f32, gravity: *const [3]f32) void;
    pub extern "c" fn jolt_world_raycast(
        world: *JoltWorld,
        origin: *const [3]f32,
        dir: *const [3]f32,
        max_distance: f32,
        out_entity_u64: *u64,
        out_distance: *f32,
        out_point: *[3]f32,
        out_normal: *[3]f32,
    ) bool;
};

pub const MODULE_OWNER_ID: u64 = 2013;

pub const JoltBackend = struct {
    world: *c.JoltWorld,

    pub fn init() !JoltBackend {
        const w = c.jolt_world_create() orelse return error.JoltInitFailed;
        return .{ .world = w };
    }

    pub fn deinit(self: *JoltBackend) void {
        c.jolt_world_destroy(self.world);
    }

    pub fn vtable() *const physics.PhysicsBackendVTable {
        return &backend_vtable;
    }

    pub fn attachTo(self: *JoltBackend, svc: *physics.PhysicsService) void {
        svc.setBackend(&backend_vtable, self);
    }

    pub fn createBody(
        self: *JoltBackend,
        entity: engine.EntityHandle,
        pos: [3]f32,
        body: physics.RigidBody,
        collider: ?physics.Collider,
    ) !u64 {
        const body_type: u8 = switch (body.body_type) {
            .dynamic => 0,
            .static => 1,
            .kinematic => 2,
        };

        var shape_kind: u8 = 0;
        var dim0: f32 = 0.5;
        var dim1: f32 = 0.5;
        var dim2: f32 = 0.5;
        var friction: f32 = 0.5;
        var restitution: f32 = 0.0;
        var is_sensor: bool = false;

        if (collider) |col| {
            friction = col.friction;
            restitution = col.restitution;
            is_sensor = col.is_sensor;
            switch (col.shape) {
                .box => |b| {
                    shape_kind = 0;
                    dim0 = b.half_x;
                    dim1 = b.half_y;
                    dim2 = b.half_z;
                },
                .sphere => |s| {
                    shape_kind = 1;
                    dim0 = s.radius;
                },
                .capsule => |cap| {
                    shape_kind = 2;
                    dim0 = cap.radius;
                    dim1 = cap.half_height;
                },
            }
        }

        const entity_u64: u64 = @bitCast(entity);
        const handle = c.jolt_world_create_body(
            self.world,
            entity_u64,
            &pos,
            body_type,
            body.mass,
            body.linear_damping,
            body.angular_damping,
            body.lock_rotation,
            shape_kind,
            dim0,
            dim1,
            dim2,
            friction,
            restitution,
            is_sensor,
        );
        if (handle == 0) return error.CreateBodyFailed;
        return handle;
    }

    pub fn destroyBody(self: *JoltBackend, body_id: u64) void {
        c.jolt_world_destroy_body(self.world, body_id);
    }

    pub fn setTransform(self: *JoltBackend, body_id: u64, pos: [3]f32, rot_euler: [3]f32) void {
        c.jolt_world_set_transform(self.world, body_id, &pos, &rot_euler);
    }

    pub fn getTransform(self: *JoltBackend, body_id: u64) ?physics.BodyTransform {
        var pos: [3]f32 = .{ 0, 0, 0 };
        var rot: [3]f32 = .{ 0, 0, 0 };
        if (!c.jolt_world_get_transform(self.world, body_id, &pos, &rot)) return null;
        return .{ .pos = pos, .rot_euler = rot };
    }

    pub fn setVelocity(self: *JoltBackend, body_id: u64, vel: physics.Velocity) void {
        const lin = [3]f32{ vel.x, vel.y, vel.z };
        const ang = [3]f32{ vel.angular_x, vel.angular_y, vel.angular_z };
        c.jolt_world_set_velocity(self.world, body_id, &lin, &ang);
    }

    pub fn getVelocity(self: *JoltBackend, body_id: u64) ?physics.Velocity {
        var lin: [3]f32 = .{ 0, 0, 0 };
        var ang: [3]f32 = .{ 0, 0, 0 };
        if (!c.jolt_world_get_velocity(self.world, body_id, &lin, &ang)) return null;
        return .{
            .x = lin[0],
            .y = lin[1],
            .z = lin[2],
            .angular_x = ang[0],
            .angular_y = ang[1],
            .angular_z = ang[2],
        };
    }

    pub fn applyForce(self: *JoltBackend, body_id: u64, force: [3]f32) void {
        c.jolt_world_apply_force(self.world, body_id, &force);
    }

    pub fn applyImpulse(self: *JoltBackend, body_id: u64, impulse: [3]f32) void {
        c.jolt_world_apply_impulse(self.world, body_id, &impulse);
    }

    pub fn step(self: *JoltBackend, dt: f32, gravity: [3]f32) void {
        c.jolt_world_step(self.world, dt, &gravity);
    }

    pub fn raycast(self: *JoltBackend, desc: physics.RaycastDesc) ?physics.RaycastHit {
        var entity_u64: u64 = 0;
        var dist: f32 = 0;
        var point: [3]f32 = .{ 0, 0, 0 };
        var normal: [3]f32 = .{ 0, 0, 0 };
        if (!c.jolt_world_raycast(
            self.world,
            &desc.origin,
            &desc.direction,
            desc.max_distance,
            &entity_u64,
            &dist,
            &point,
            &normal,
        )) return null;

        return .{
            .entity = @bitCast(entity_u64),
            .distance = dist,
            .point = point,
            .normal = normal,
        };
    }

    fn cbCreateBody(ctx: *anyopaque, entity: engine.EntityHandle, pos: [3]f32, body: physics.RigidBody, collider: ?physics.Collider) anyerror!u64 {
        const self: *JoltBackend = @ptrCast(@alignCast(ctx));
        return self.createBody(entity, pos, body, collider);
    }

    fn cbDestroyBody(ctx: *anyopaque, body_id: u64) void {
        const self: *JoltBackend = @ptrCast(@alignCast(ctx));
        self.destroyBody(body_id);
    }

    fn cbSetTransform(ctx: *anyopaque, body_id: u64, pos: [3]f32, rot_euler: [3]f32) void {
        const self: *JoltBackend = @ptrCast(@alignCast(ctx));
        self.setTransform(body_id, pos, rot_euler);
    }

    fn cbGetTransform(ctx: *anyopaque, body_id: u64) ?physics.BodyTransform {
        const self: *JoltBackend = @ptrCast(@alignCast(ctx));
        return self.getTransform(body_id);
    }

    fn cbSetVelocity(ctx: *anyopaque, body_id: u64, vel: physics.Velocity) void {
        const self: *JoltBackend = @ptrCast(@alignCast(ctx));
        self.setVelocity(body_id, vel);
    }

    fn cbGetVelocity(ctx: *anyopaque, body_id: u64) ?physics.Velocity {
        const self: *JoltBackend = @ptrCast(@alignCast(ctx));
        return self.getVelocity(body_id);
    }

    fn cbApplyForce(ctx: *anyopaque, body_id: u64, force: [3]f32) void {
        const self: *JoltBackend = @ptrCast(@alignCast(ctx));
        self.applyForce(body_id, force);
    }

    fn cbApplyImpulse(ctx: *anyopaque, body_id: u64, impulse: [3]f32) void {
        const self: *JoltBackend = @ptrCast(@alignCast(ctx));
        self.applyImpulse(body_id, impulse);
    }

    fn cbStep(ctx: *anyopaque, dt: f32, gravity: [3]f32) anyerror!void {
        const self: *JoltBackend = @ptrCast(@alignCast(ctx));
        self.step(dt, gravity);
    }

    fn cbRaycast(ctx: *anyopaque, desc: physics.RaycastDesc) ?physics.RaycastHit {
        const self: *JoltBackend = @ptrCast(@alignCast(ctx));
        return self.raycast(desc);
    }

    const backend_vtable = physics.PhysicsBackendVTable{
        .create_body = cbCreateBody,
        .destroy_body = cbDestroyBody,
        .set_transform = cbSetTransform,
        .get_transform = cbGetTransform,
        .set_velocity = cbSetVelocity,
        .get_velocity = cbGetVelocity,
        .apply_force = cbApplyForce,
        .apply_impulse = cbApplyImpulse,
        .step = cbStep,
        .raycast = cbRaycast,
    };
};

fn buildModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    const svc = app.resources.get(physics.PhysicsService) orelse return error.MissingPhysicsService;

    try app.resources.insert(JoltBackend, try JoltBackend.init());
    const backend = app.resources.get(JoltBackend).?;
    backend.attachTo(svc);
}

fn stopModule(raw_app: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    if (app.resources.get(physics.PhysicsService)) |svc| {
        svc.setBackend(null, null);
    }
    if (app.resources.get(JoltBackend)) |backend| {
        backend.deinit();
        _ = app.resources.remove(JoltBackend);
    }
}

pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = "official.physics.jolt",
            .version = "0.1.0",
            .required_capabilities = &.{"engine.physics/1"},
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
