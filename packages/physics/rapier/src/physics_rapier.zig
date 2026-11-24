//! Optional Rapier3D Physics Backend Package (`official.physics.rapier`).
//!
//! Wraps `zengy_rapier_ffi` (compiled from Rust via `cargo build --release`
//! on the user's machine) and implements `physics.PhysicsBackendVTable`.

const std = @import("std");
const engine = @import("engine");
const physics = @import("physics");

const c = struct {
    pub const RapierWorld = opaque {};
    pub extern "c" fn rapier_world_create() ?*RapierWorld;
    pub extern "c" fn rapier_world_destroy(world: *RapierWorld) void;
    pub extern "c" fn rapier_world_create_body(
        world: *RapierWorld,
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
    pub extern "c" fn rapier_world_destroy_body(world: *RapierWorld, body_handle: u64) void;
    pub extern "c" fn rapier_world_get_transform(world: *RapierWorld, body_handle: u64, out_pos: *[3]f32, out_rot_euler: *[3]f32) bool;
    pub extern "c" fn rapier_world_apply_impulse(world: *RapierWorld, body_handle: u64, impulse: *const [3]f32) void;
    pub extern "c" fn rapier_world_step(world: *RapierWorld, dt: f32, gravity: *const [3]f32) void;
};

pub const RapierBackend = struct {
    world: *c.RapierWorld,

    pub fn init() !RapierBackend {
        const w = c.rapier_world_create() orelse return error.RapierInitFailed;
        return .{ .world = w };
    }

    pub fn deinit(self: *RapierBackend) void {
        c.rapier_world_destroy(self.world);
    }

    pub fn attachTo(self: *RapierBackend, svc: *physics.PhysicsService) void {
        svc.setBackend(&backend_vtable, self);
    }

    pub fn createBody(
        self: *RapierBackend,
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
        const h = c.rapier_world_create_body(
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
        if (h == 0) return error.CreateBodyFailed;
        return h;
    }

    pub fn destroyBody(self: *RapierBackend, body_id: u64) void {
        c.rapier_world_destroy_body(self.world, body_id);
    }

    pub fn getTransform(self: *RapierBackend, body_id: u64) ?physics.BodyTransform {
        var pos: [3]f32 = .{ 0, 0, 0 };
        var rot: [3]f32 = .{ 0, 0, 0 };
        if (!c.rapier_world_get_transform(self.world, body_id, &pos, &rot)) return null;
        return .{ .pos = pos, .rot_euler = rot };
    }

    pub fn applyImpulse(self: *RapierBackend, body_id: u64, impulse: [3]f32) void {
        c.rapier_world_apply_impulse(self.world, body_id, &impulse);
    }

    pub fn step(self: *RapierBackend, dt: f32, gravity: [3]f32) void {
        c.rapier_world_step(self.world, dt, &gravity);
    }

    fn cbCreateBody(ctx: *anyopaque, entity: engine.EntityHandle, pos: [3]f32, body: physics.RigidBody, collider: ?physics.Collider) anyerror!u64 {
        const self: *RapierBackend = @ptrCast(@alignCast(ctx));
        return self.createBody(entity, pos, body, collider);
    }

    fn cbDestroyBody(ctx: *anyopaque, body_id: u64) void {
        const self: *RapierBackend = @ptrCast(@alignCast(ctx));
        self.destroyBody(body_id);
    }

    fn cbGetTransform(ctx: *anyopaque, body_id: u64) ?physics.BodyTransform {
        const self: *RapierBackend = @ptrCast(@alignCast(ctx));
        return self.getTransform(body_id);
    }

    fn cbApplyImpulse(ctx: *anyopaque, body_id: u64, impulse: [3]f32) void {
        const self: *RapierBackend = @ptrCast(@alignCast(ctx));
        self.applyImpulse(body_id, impulse);
    }

    fn cbStep(ctx: *anyopaque, dt: f32, gravity: [3]f32) anyerror!void {
        const self: *RapierBackend = @ptrCast(@alignCast(ctx));
        self.step(dt, gravity);
    }

    const backend_vtable = physics.PhysicsBackendVTable{
        .create_body = cbCreateBody,
        .destroy_body = cbDestroyBody,
        .get_transform = cbGetTransform,
        .apply_impulse = cbApplyImpulse,
        .step = cbStep,
    };
};
