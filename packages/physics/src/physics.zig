//! Optional Agnostic Physics Contract Package (`official.physics`).
//!
//! Provides ECS-first physics components (`RigidBody`, `Collider`,
//! `Velocity`, `ExternalForce`, `GravityScale`), spatial query types
//! (`RaycastDesc`, `RaycastHit`), collision events (`CollisionEvent`), and a
//! pluggable `PhysicsBackendVTable` registered as `engine.physics/1`.
//!
//! When no backend is attached, `PhysicsService` runs in headless no-op mode
//! without any external C/C++ physics library dependencies.

const std = @import("std");
const engine = @import("engine");

pub const MODULE_OWNER_ID: u64 = 2012;

pub const RigidBodyType = enum {
    dynamic,
    static,
    kinematic,
};

pub const RigidBody = struct {
    body_type: RigidBodyType = .dynamic,
    mass: f32 = 1.0,
    linear_damping: f32 = 0.0,
    angular_damping: f32 = 0.05,
    lock_rotation: bool = false,
};

pub const ColliderShape = union(enum) {
    box: struct {
        half_x: f32,
        half_y: f32,
        half_z: f32 = 0.5,
    },
    sphere: struct {
        radius: f32,
    },
    capsule: struct {
        radius: f32,
        half_height: f32,
    },
};

pub const Collider = struct {
    shape: ColliderShape,
    friction: f32 = 0.5,
    restitution: f32 = 0.0,
    is_sensor: bool = false,
    layer_mask: u32 = 0xFFFF_FFFF,
};

pub const Velocity = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    angular_x: f32 = 0,
    angular_y: f32 = 0,
    angular_z: f32 = 0,
};

pub const ExternalForce = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    persistent: bool = false,
};

pub const GravityScale = struct {
    scale: f32 = 1.0,
};

/// Opaque backend body handle stored on entities managed by a physics backend.
pub const PhysicsBodyHandle = struct {
    id: u64 = 0,
};

pub const CollisionPhase = enum {
    started,
    ended,
};

pub const CollisionEvent = struct {
    entity_a: engine.EntityHandle,
    entity_b: engine.EntityHandle,
    phase: CollisionPhase,
    normal_x: f32 = 0,
    normal_y: f32 = 0,
    normal_z: f32 = 0,
};

pub const RaycastDesc = struct {
    origin: [3]f32,
    direction: [3]f32,
    max_distance: f32,
    layer_mask: u32 = 0xFFFF_FFFF,
};

pub const RaycastHit = struct {
    entity: engine.EntityHandle,
    distance: f32,
    point: [3]f32,
    normal: [3]f32,
};

pub const BodyTransform = struct {
    pos: [3]f32,
    rot_euler: [3]f32,
};

/// Pluggable backend hooks for physics solvers (e.g., `physics-simple`, `physics-box2d`, `physics-jolt`).
/// When `backend` is null, `PhysicsService` operates in headless no-op mode.
pub const PhysicsBackendVTable = struct {
    create_body: ?*const fn (
        ctx: *anyopaque,
        entity: engine.EntityHandle,
        pos: [3]f32,
        body: RigidBody,
        collider: ?Collider,
    ) anyerror!u64 = null,
    destroy_body: ?*const fn (ctx: *anyopaque, body_id: u64) void = null,
    set_transform: ?*const fn (ctx: *anyopaque, body_id: u64, pos: [3]f32, rot_euler: [3]f32) void = null,
    get_transform: ?*const fn (ctx: *anyopaque, body_id: u64) ?BodyTransform = null,
    set_velocity: ?*const fn (ctx: *anyopaque, body_id: u64, vel: Velocity) void = null,
    get_velocity: ?*const fn (ctx: *anyopaque, body_id: u64) ?Velocity = null,
    apply_force: ?*const fn (ctx: *anyopaque, body_id: u64, force: [3]f32) void = null,
    apply_impulse: ?*const fn (ctx: *anyopaque, body_id: u64, impulse: [3]f32) void = null,
    step: ?*const fn (ctx: *anyopaque, dt: f32, gravity: [3]f32) anyerror!void = null,
    raycast: ?*const fn (ctx: *anyopaque, desc: RaycastDesc) ?RaycastHit = null,
};

pub const PhysicsService = struct {
    allocator: std.mem.Allocator,
    gravity: [3]f32 = .{ 0.0, -9.81, 0.0 },
    backend: ?*const PhysicsBackendVTable = null,
    backend_ctx: ?*anyopaque = null,
    step_count: u64 = 0,
    last_dt: f32 = 0,

    pub fn init(allocator: std.mem.Allocator) PhysicsService {
        return .{
            .allocator = allocator,
        };
    }

    pub fn initWithBackend(
        allocator: std.mem.Allocator,
        backend: *const PhysicsBackendVTable,
        backend_ctx: *anyopaque,
    ) PhysicsService {
        return .{
            .allocator = allocator,
            .backend = backend,
            .backend_ctx = backend_ctx,
        };
    }

    pub fn setBackend(self: *PhysicsService, backend: ?*const PhysicsBackendVTable, backend_ctx: ?*anyopaque) void {
        self.backend = backend;
        self.backend_ctx = backend_ctx;
    }

    pub fn hasBackend(self: *const PhysicsService) bool {
        return self.backend != null and self.backend_ctx != null;
    }

    pub fn step(self: *PhysicsService, dt: f32) !void {
        if (self.backend) |b| {
            if (b.step) |fn_step| {
                try fn_step(self.backend_ctx.?, dt, self.gravity);
            }
        }
        self.step_count += 1;
        self.last_dt = dt;
    }

    pub fn raycast(self: *const PhysicsService, desc: RaycastDesc) ?RaycastHit {
        if (self.backend) |b| {
            if (b.raycast) |fn_raycast| {
                return fn_raycast(self.backend_ctx.?, desc);
            }
        }
        return null;
    }

    pub fn applyImpulse(self: *PhysicsService, body_id: u64, impulse: [3]f32) void {
        if (self.backend) |b| {
            if (b.apply_impulse) |fn_impulse| {
                fn_impulse(self.backend_ctx.?, body_id, impulse);
            }
        }
    }
};

/// Runs once per fixed physics step during `.fixed_update`.
/// Future backend sync systems (`sync_in`, `step`, `sync_out`) attach around this stage.
pub fn physicsStepSystem(ctx: *engine.SystemContext) !void {
    const svc = ctx.resources.get(PhysicsService) orelse return;
    try svc.step(ctx.fixedDeltaSeconds());
}

fn buildModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));

    _ = try app.registerComponent(RigidBody);
    _ = try app.registerComponent(Collider);
    _ = try app.registerComponent(Velocity);
    _ = try app.registerComponent(ExternalForce);
    _ = try app.registerComponent(GravityScale);
    _ = try app.registerComponent(PhysicsBodyHandle);

    try app.resources.insert(PhysicsService, PhysicsService.init(app.allocator));
    const svc = app.resources.get(PhysicsService).?;

    try app.services.register(.{
        .capability = "engine.physics",
        .major_version = 1,
        .provider_id = "official.physics.noop",
        .owner_id = MODULE_OWNER_ID,
        .exclusive = true,
        .api_ptr = svc,
        .api_size = @sizeOf(PhysicsService),
    });

    try app.addSystem(.{
        .name = "physics.fixed_step",
        .stage = .fixed_update,
        .run = physicsStepSystem,
    });
}

fn stopModule(raw_app: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    _ = app.services.unregisterByOwner(MODULE_OWNER_ID);
    _ = app.resources.remove(PhysicsService);
}

pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = "official.physics",
            .version = "0.1.0",
            .provides_capabilities = &.{"engine.physics/1"},
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
