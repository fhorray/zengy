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

pub const cabi = @import("cabi.zig");

/// Owner ID used when registering physics services and components.
pub const MODULE_OWNER_ID: u64 = 2012;

/// Simulation integration mode for an entity's physics body.
pub const RigidBodyType = enum {
    dynamic,
    static,
    kinematic,
};

/// Rigid body dynamics configuration attached to an entity.
pub const RigidBody = struct {
    body_type: RigidBodyType = .dynamic,
    mass: f32 = 1.0,
    linear_damping: f32 = 0.0,
    angular_damping: f32 = 0.05,
    lock_rotation: bool = false,
};

/// Collision primitive geometry attached to a `Collider`.
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

/// Collision shape and surface response properties for an entity.
pub const Collider = struct {
    shape: ColliderShape,
    friction: f32 = 0.5,
    restitution: f32 = 0.0,
    is_sensor: bool = false,
    layer_mask: u32 = 0xFFFF_FFFF,
};

/// Linear and angular velocity vector synchronized with the active physics backend.
pub const Velocity = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    angular_x: f32 = 0,
    angular_y: f32 = 0,
    angular_z: f32 = 0,
};

/// Force accumulator applied during `physicsSyncInSystem` (cleared each tick unless `persistent`).
pub const ExternalForce = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    persistent: bool = false,
};

/// Per-entity gravity multiplier.
pub const GravityScale = struct {
    scale: f32 = 1.0,
};

/// Opaque backend body handle stored on entities managed by a physics backend.
pub const PhysicsBodyHandle = struct {
    id: u64 = 0,
    /// Backend generation the id belongs to; ids from a replaced backend are discarded and recreated.
    epoch: u32 = 0,

    /// Marker id stored after a failed `createBody` so the sync system does not retry every step.
    /// Remove the component to request another attempt.
    pub const failed_id: u64 = std.math.maxInt(u64);
};

/// Contact lifecycle phase emitted by collision callbacks.
pub const CollisionPhase = enum {
    started,
    ended,
};

/// Contact event between two physics entities.
pub const CollisionEvent = struct {
    entity_a: engine.EntityHandle,
    entity_b: engine.EntityHandle,
    phase: CollisionPhase,
    normal_x: f32 = 0,
    normal_y: f32 = 0,
    normal_z: f32 = 0,
};

/// Parameters for a world-space raycast query against physics colliders.
pub const RaycastDesc = struct {
    origin: [3]f32,
    direction: [3]f32,
    max_distance: f32,
    layer_mask: u32 = 0xFFFF_FFFF,
};

/// Closest hit returned by `PhysicsService.raycast`.
pub const RaycastHit = struct {
    entity: engine.EntityHandle,
    distance: f32,
    point: [3]f32,
    normal: [3]f32,
};

/// World-space 3D spatial transform synchronized with physics bodies when present on an entity.
pub const PhysicsTransform = struct {
    pos: [3]f32 = .{ 0, 0, 0 },
    rot_euler: [3]f32 = .{ 0, 0, 0 },
};

/// World-space pose returned by backend body queries.
pub const BodyTransform = struct {
    pos: [3]f32,
    rot_euler: [3]f32,
};

/// Paired vtable and opaque context ensuring a backend is never half-configured.
pub const BackendInstance = struct {
    vtable: *const PhysicsBackendVTable,
    context: *anyopaque,
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

/// Host-facing physics service (`engine.physics/1`) dispatching to either a C-ABI plugin
/// slot or a Zig `PhysicsBackendVTable`, falling back to deterministic no-op ticks.
pub const PhysicsService = struct {
    allocator: std.mem.Allocator,
    gravity: [3]f32 = .{ 0.0, -9.81, 0.0 },
    backend: ?BackendInstance = null,
    /// C-ABI attachment point for dynamically loaded plugins (see `cabi.zig`). Takes precedence over `backend`.
    slot: cabi.Slot = .{},
    step_count: u64 = 0,
    active_step_count: u64 = 0,
    last_dt: f32 = 0,
    /// Body id -> owning entity for every body this service created on the current backend.
    live_bodies: std.AutoHashMapUnmanaged(u64, engine.EntityHandle) = .empty,
    /// Bumped whenever the backend is replaced; invalidates `PhysicsBodyHandle`s from the old one.
    backend_epoch: u32 = 0,
    skipped_static_count: usize = 0,
    skipped_unchanged_dynamic: usize = 0,

    pub fn init(allocator: std.mem.Allocator) PhysicsService {
        return .{
            .allocator = allocator,
        };
    }

    /// Releases bookkeeping and destroys any bodies still alive on the backend.
    pub fn deinit(self: *PhysicsService) void {
        self.deinitBodies();
        self.live_bodies.deinit(self.allocator);
    }

    fn deinitBodies(self: *PhysicsService) void {
        var it = self.live_bodies.keyIterator();
        while (it.next()) |id| self.destroyBackendBody(id.*);
        self.live_bodies.clearRetainingCapacity();
        self.backend_epoch +%= 1;
    }

    fn destroyBackendBody(self: *PhysicsService, body_id: u64) void {
        if (self.hasPluginBackend()) return cabi.hostDestroyBody(&self.slot, body_id);
        if (self.backend) |b| {
            if (b.vtable.destroy_body) |f| f(b.context, body_id);
        }
    }

    /// Destroys a body created through `createBody` and forgets it. Unknown ids are ignored.
    pub fn destroyBody(self: *PhysicsService, body_id: u64) void {
        if (self.live_bodies.remove(body_id)) self.destroyBackendBody(body_id);
    }

    pub fn initWithBackend(
        allocator: std.mem.Allocator,
        backend: *const PhysicsBackendVTable,
        backend_ctx: *anyopaque,
    ) PhysicsService {
        return .{
            .allocator = allocator,
            .backend = .{ .vtable = backend, .context = backend_ctx },
        };
    }

    /// Sets or clears the Zig backend; passing null for either parameter clears the backend
    /// atomically so invalid half-initialized states are unrepresentable.
    pub fn setBackend(self: *PhysicsService, backend: ?*const PhysicsBackendVTable, backend_ctx: ?*anyopaque) void {
        // Bodies belong to the outgoing backend: destroy them there and invalidate ECS handles.
        self.deinitBodies();
        if (backend != null and backend_ctx != null) {
            self.backend = .{ .vtable = backend.?, .context = backend_ctx.? };
        } else {
            self.backend = null;
        }
    }

    pub fn hasBackend(self: *const PhysicsService) bool {
        return self.backend != null or self.hasPluginBackend();
    }

    /// True when a dynamic plugin attached a C-ABI backend through `slot`.
    pub fn hasPluginBackend(self: *const PhysicsService) bool {
        return self.slot.vtable != null and self.slot.ctx != null;
    }

    pub fn createBody(self: *PhysicsService, entity: engine.EntityHandle, pos: [3]f32, body: RigidBody, collider: ?Collider) !u64 {
        const id = try self.createBackendBody(entity, pos, body, collider);
        self.live_bodies.put(self.allocator, id, entity) catch |err| {
            self.destroyBackendBody(id); // never hand out a body we cannot track and later destroy
            return err;
        };
        return id;
    }

    fn createBackendBody(self: *PhysicsService, entity: engine.EntityHandle, pos: [3]f32, body: RigidBody, collider: ?Collider) !u64 {
        if (self.hasPluginBackend()) return cabi.hostCreateBody(&self.slot, entity, pos, body, collider);
        if (self.backend) |b| {
            if (b.vtable.create_body) |fn_create| {
                return fn_create(b.context, entity, pos, body, collider);
            }
        }
        return error.MissingPhysicsBackend;
    }

    pub fn setBodyTransform(self: *PhysicsService, body_id: u64, pos: [3]f32, rot_euler: [3]f32) void {
        if (self.hasPluginBackend()) return cabi.hostSetTransform(&self.slot, body_id, pos, rot_euler);
        if (self.backend) |b| {
            if (b.vtable.set_transform) |fn_set| fn_set(b.context, body_id, pos, rot_euler);
        }
    }

    pub fn getBodyTransform(self: *const PhysicsService, body_id: u64) ?BodyTransform {
        if (self.hasPluginBackend()) return cabi.hostGetTransform(&self.slot, body_id);
        if (self.backend) |b| {
            if (b.vtable.get_transform) |fn_get| return fn_get(b.context, body_id);
        }
        return null;
    }

    pub fn getBodyVelocity(self: *const PhysicsService, body_id: u64) ?Velocity {
        if (self.hasPluginBackend()) return cabi.hostGetVelocity(&self.slot, body_id);
        if (self.backend) |b| {
            if (b.vtable.get_velocity) |fn_get| return fn_get(b.context, body_id);
        }
        return null;
    }

    pub fn applyForce(self: *PhysicsService, body_id: u64, force: [3]f32) void {
        if (self.hasPluginBackend()) return cabi.hostApplyForce(&self.slot, body_id, force);
        if (self.backend) |b| {
            if (b.vtable.apply_force) |fn_force| fn_force(b.context, body_id, force);
        }
    }

    pub fn step(self: *PhysicsService, dt: f32) !void {
        if (self.hasPluginBackend()) {
            try cabi.hostStep(&self.slot, dt, self.gravity);
            self.active_step_count += 1;
        } else if (self.backend) |b| {
            if (b.vtable.step) |fn_step| {
                try fn_step(b.context, dt, self.gravity);
                self.active_step_count += 1;
            }
        }
        self.step_count += 1;
        self.last_dt = dt;
    }

    pub fn raycast(self: *const PhysicsService, desc: RaycastDesc) ?RaycastHit {
        if (self.hasPluginBackend()) return cabi.hostRaycast(&self.slot, desc);
        if (self.backend) |b| {
            if (b.vtable.raycast) |fn_raycast| {
                return fn_raycast(b.context, desc);
            }
        }
        return null;
    }

    pub fn applyImpulse(self: *PhysicsService, body_id: u64, impulse: [3]f32) void {
        if (self.hasPluginBackend()) return cabi.hostApplyImpulse(&self.slot, body_id, impulse);
        if (self.backend) |b| {
            if (b.vtable.apply_impulse) |fn_impulse| {
                fn_impulse(b.context, body_id, impulse);
            }
        }
    }
};

/// Destroys backend bodies whose entity died or lost its `RigidBody`/`PhysicsBodyHandle`.
fn reapOrphanBodies(ctx: *engine.SystemContext, svc: *PhysicsService) !void {
    var doomed: std.ArrayList(u64) = .empty;
    defer doomed.deinit(svc.allocator);
    var it = svc.live_bodies.iterator();
    while (it.next()) |entry| {
        const e = entry.value_ptr.*;
        const owned = ctx.world.isAlive(e) and ctx.world.has(e, RigidBody) and
            (if (ctx.world.getConst(e, PhysicsBodyHandle)) |h| h.id == entry.key_ptr.* else true);
        if (!owned) try doomed.append(svc.allocator, entry.key_ptr.*);
    }
    for (doomed.items) |id| svc.destroyBody(id);
}

/// Creates missing backend bodies and pushes kinematic transforms + forces before `step()`.
pub fn physicsSyncInSystem(ctx: *engine.SystemContext) !void {
    const svc = ctx.resources.get(PhysicsService) orelse return;
    if (!svc.hasBackend()) return;
    try reapOrphanBodies(ctx, svc);
    svc.skipped_static_count = 0;

    var q = try ctx.query(.{ .read = .{ RigidBody, PhysicsTransform } });
    defer q.deinit();
    while (q.next()) |row| {
        const rb = row.read(RigidBody);
        const xf = row.read(PhysicsTransform);
        const existing = ctx.world.getConst(row.entity, PhysicsBodyHandle);
        var body_id: u64 = if (existing) |h| (if (h.epoch == svc.backend_epoch) h.id else 0) else 0;
        if (body_id == PhysicsBodyHandle.failed_id) continue;
        if (body_id == 0) {
            const col: ?Collider = if (ctx.world.getConst(row.entity, Collider)) |c| c.* else null;
            body_id = svc.createBody(row.entity, xf.pos, rb.*, col) catch {
                ctx.diagnostics.log(.warn, "physics", "createBody failed; entity skipped until PhysicsBodyHandle is removed") catch {};
                try ctx.commands.set(row.entity, PhysicsBodyHandle, .{ .id = PhysicsBodyHandle.failed_id, .epoch = svc.backend_epoch });
                continue;
            };
            // Backends take only a position at creation; push the full pose so rotation is honored.
            svc.setBodyTransform(body_id, xf.pos, xf.rot_euler);
            try ctx.commands.set(row.entity, PhysicsBodyHandle, .{ .id = body_id, .epoch = svc.backend_epoch });
        } else if (rb.body_type == .static) {
            // Static bodies never move or receive external forces once created.
            svc.skipped_static_count += 1;
            continue;
        } else if (rb.body_type == .kinematic) {
            svc.setBodyTransform(body_id, xf.pos, xf.rot_euler);
            continue;
        }
        if (ctx.world.getConst(row.entity, ExternalForce)) |cef| {
            // Skip the backend call for zero force: it is a no-op that would still cost a lookup
            // and a Zig/backend crossing for every body with the component on every step.
            if (cef.x == 0 and cef.y == 0 and cef.z == 0) continue;
            svc.applyForce(body_id, .{ cef.x, cef.y, cef.z });
            if (!cef.persistent) {
                const ef = ctx.world.get(row.entity, ExternalForce).?;
                ef.x = 0;
                ef.y = 0;
                ef.z = 0;
            }
        }
    }
}

/// Runs once per fixed physics step during `.fixed_update`.
pub fn physicsStepSystem(ctx: *engine.SystemContext) !void {
    const svc = ctx.resources.get(PhysicsService) orelse return;
    try svc.step(ctx.fixedDeltaSeconds());
}

/// Pulls dynamic body transforms and velocities back into ECS components after `step()`.
pub fn physicsSyncOutSystem(ctx: *engine.SystemContext) !void {
    const svc = ctx.resources.get(PhysicsService) orelse return;
    if (!svc.hasBackend()) return;
    svc.skipped_unchanged_dynamic = 0;

    var q = try ctx.query(.{ .write = .{PhysicsTransform}, .read = .{ RigidBody, PhysicsBodyHandle } });
    defer q.deinit();
    while (q.next()) |row| {
        const rb = row.read(RigidBody);
        if (rb.body_type != .dynamic) continue;
        const bh = row.read(PhysicsBodyHandle);
        if (bh.id == 0 or bh.id == PhysicsBodyHandle.failed_id or bh.epoch != svc.backend_epoch) continue;
        if (svc.getBodyTransform(bh.id)) |xf| {
            const pt_const = ctx.world.getConst(row.entity, PhysicsTransform).?;
            if (!std.meta.eql(pt_const.pos, xf.pos) or !std.meta.eql(pt_const.rot_euler, xf.rot_euler)) {
                const pt = row.write(PhysicsTransform);
                pt.pos = xf.pos;
                pt.rot_euler = xf.rot_euler;
            } else {
                svc.skipped_unchanged_dynamic += 1;
            }
        }
        if (ctx.world.get(row.entity, Velocity)) |vel| {
            if (svc.getBodyVelocity(bh.id)) |bv| {
                if (!std.meta.eql(vel.*, bv)) vel.* = bv;
            }
        }
    }
}

fn buildModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));

    _ = try app.registerComponent(RigidBody);
    _ = try app.registerComponent(Collider);
    _ = try app.registerComponent(Velocity);
    _ = try app.registerComponent(ExternalForce);
    _ = try app.registerComponent(GravityScale);
    _ = try app.registerComponent(PhysicsBodyHandle);
    _ = try app.registerComponent(PhysicsTransform);

    try app.resources.insert(PhysicsService, PhysicsService.init(app.allocator));
    errdefer _ = app.resources.remove(PhysicsService);
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
    errdefer _ = app.services.unregisterByOwner(MODULE_OWNER_ID);

    try app.services.register(.{
        .capability = cabi.CAPABILITY,
        .major_version = 1,
        .provider_id = "official.physics.noop",
        .owner_id = MODULE_OWNER_ID,
        .exclusive = true,
        .api_ptr = &svc.slot,
        .api_size = @sizeOf(cabi.Slot),
    });

    try app.addSystem(.{
        .name = "physics.sync_in",
        .stage = .fixed_update,
        .run = physicsSyncInSystem,
        .before = &.{"physics.fixed_step"},
    });
    try app.addSystem(.{
        .name = "physics.fixed_step",
        .stage = .fixed_update,
        .run = physicsStepSystem,
    });
    try app.addSystem(.{
        .name = "physics.sync_out",
        .stage = .fixed_update,
        .run = physicsSyncOutSystem,
        .after = &.{"physics.fixed_step"},
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
            .version = "0.2.1",
            .provides_capabilities = &.{ "engine.physics/1", "engine.physics.backend/1" },
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
