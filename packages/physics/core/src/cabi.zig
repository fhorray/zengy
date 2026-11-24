//! Stable C ABI between the engine and dynamically loaded physics backend plugins.
//!
//! In-process (statically linked) backends keep using the Zig `PhysicsBackendVTable`. Everything that
//! crosses a shared-library boundary uses *only* the `extern` types below: Zig auto-layout structs,
//! tagged unions and error unions are NOT stable between a host and a plugin built in different
//! optimize modes (Debug keeps declaration order, release modes reorder fields), which used to
//! segfault `zengy-runtime` when it loaded a ReleaseSafe plugin.
//!
//! Handshake: the host registers the capability `engine.physics.backend` v1 whose API is a `Slot`.
//! A plugin validates `abi_version` / `struct_size`, then stores its `Backend` vtable and context in
//! the slot. Version and size fields let both sides refuse a mismatched peer instead of crashing.

const std = @import("std");
const engine = @import("engine");
const physics = @import("physics.zig");

/// Bump when any extern type below changes layout or semantics.
pub const ABI_VERSION: u32 = 1;

/// Capability the host registers (major version 1) and plugins request.
pub const CAPABILITY = "engine.physics.backend";

/// Result codes returned by fallible backend callbacks.
pub const OK: i32 = 0;
pub const FAILED: i32 = 1;

pub const BodyDesc = extern struct {
    entity: u64,
    pos: [3]f32,
    /// 0 = dynamic, 1 = static, 2 = kinematic.
    body_type: u8,
    lock_rotation: u8,
    has_collider: u8,
    /// 0 = box, 1 = sphere, 2 = capsule.
    shape_kind: u8,
    mass: f32,
    linear_damping: f32,
    angular_damping: f32,
    /// box: half extents; sphere: [radius]; capsule: [radius, half_height].
    dims: [3]f32,
    friction: f32,
    restitution: f32,
    is_sensor: u8,
    reserved: [3]u8,
    layer_mask: u32,
};

pub const Transform = extern struct {
    pos: [3]f32,
    rot_euler: [3]f32,
};

pub const Velocity = extern struct {
    linear: [3]f32,
    angular: [3]f32,
};

pub const RaycastDesc = extern struct {
    origin: [3]f32,
    direction: [3]f32,
    max_distance: f32,
    layer_mask: u32,
};

pub const RaycastHit = extern struct {
    entity: u64,
    distance: f32,
    point: [3]f32,
    normal: [3]f32,
};

/// Backend vtable implemented by a plugin. Optional entries may be null.
pub const Backend = extern struct {
    abi_version: u32 = ABI_VERSION,
    struct_size: u32 = @sizeOf(Backend),
    create_body: ?*const fn (ctx: *anyopaque, desc: *const BodyDesc, out_id: *u64) callconv(.c) i32 = null,
    destroy_body: ?*const fn (ctx: *anyopaque, body_id: u64) callconv(.c) void = null,
    set_transform: ?*const fn (ctx: *anyopaque, body_id: u64, xf: *const Transform) callconv(.c) void = null,
    get_transform: ?*const fn (ctx: *anyopaque, body_id: u64, out: *Transform) callconv(.c) bool = null,
    set_velocity: ?*const fn (ctx: *anyopaque, body_id: u64, vel: *const Velocity) callconv(.c) void = null,
    get_velocity: ?*const fn (ctx: *anyopaque, body_id: u64, out: *Velocity) callconv(.c) bool = null,
    apply_force: ?*const fn (ctx: *anyopaque, body_id: u64, force: *const [3]f32) callconv(.c) void = null,
    apply_impulse: ?*const fn (ctx: *anyopaque, body_id: u64, impulse: *const [3]f32) callconv(.c) void = null,
    step: ?*const fn (ctx: *anyopaque, dt: f32, gravity: *const [3]f32) callconv(.c) i32 = null,
    raycast: ?*const fn (ctx: *anyopaque, desc: *const RaycastDesc, out: *RaycastHit) callconv(.c) bool = null,
};

/// Host-owned attachment point; plugins fill `vtable` and `ctx`.
pub const Slot = extern struct {
    abi_version: u32 = ABI_VERSION,
    struct_size: u32 = @sizeOf(Slot),
    vtable: ?*const Backend = null,
    ctx: ?*anyopaque = null,
};

/// True when `vt` was built against a compatible ABI.
pub fn isCompatible(vt: *const Backend) bool {
    return vt.abi_version == ABI_VERSION and vt.struct_size >= @sizeOf(Backend);
}

/// Plugin-side check of the slot handed out by the host.
pub fn slotIsCompatible(slot: *const Slot) bool {
    return slot.abi_version == ABI_VERSION and slot.struct_size == @sizeOf(Slot);
}

// ---------------------------------------------------------------------------------------------
// Conversions between the Zig-facing contract types and the C types.
// ---------------------------------------------------------------------------------------------

pub fn bodyDescFrom(
    entity: engine.EntityHandle,
    pos: [3]f32,
    body: physics.RigidBody,
    collider: ?physics.Collider,
) BodyDesc {
    var d: BodyDesc = .{
        .entity = @bitCast(entity),
        .pos = pos,
        .body_type = switch (body.body_type) {
            .dynamic => 0,
            .static => 1,
            .kinematic => 2,
        },
        .lock_rotation = @intFromBool(body.lock_rotation),
        .has_collider = 0,
        .shape_kind = 0,
        .mass = body.mass,
        .linear_damping = body.linear_damping,
        .angular_damping = body.angular_damping,
        .dims = .{ 0.5, 0.5, 0.5 },
        .friction = 0.5,
        .restitution = 0.0,
        .is_sensor = 0,
        .reserved = .{ 0, 0, 0 },
        .layer_mask = 0xFFFF_FFFF,
    };
    if (collider) |col| {
        d.has_collider = 1;
        d.friction = col.friction;
        d.restitution = col.restitution;
        d.is_sensor = @intFromBool(col.is_sensor);
        d.layer_mask = col.layer_mask;
        switch (col.shape) {
            .box => |b| {
                d.shape_kind = 0;
                d.dims = .{ b.half_x, b.half_y, b.half_z };
            },
            .sphere => |s| {
                d.shape_kind = 1;
                d.dims = .{ s.radius, 0, 0 };
            },
            .capsule => |cap| {
                d.shape_kind = 2;
                d.dims = .{ cap.radius, cap.half_height, 0 };
            },
        }
    }
    return d;
}

pub const BodyParts = struct {
    entity: engine.EntityHandle,
    pos: [3]f32,
    body: physics.RigidBody,
    collider: ?physics.Collider,
};

pub fn bodyPartsFrom(d: BodyDesc) BodyParts {
    const collider: ?physics.Collider = if (d.has_collider != 0) .{
        .shape = switch (d.shape_kind) {
            0 => .{ .box = .{ .half_x = d.dims[0], .half_y = d.dims[1], .half_z = d.dims[2] } },
            1 => .{ .sphere = .{ .radius = d.dims[0] } },
            else => .{ .capsule = .{ .radius = d.dims[0], .half_height = d.dims[1] } },
        },
        .friction = d.friction,
        .restitution = d.restitution,
        .is_sensor = d.is_sensor != 0,
        .layer_mask = d.layer_mask,
    } else null;
    return .{
        .entity = @bitCast(d.entity),
        .pos = d.pos,
        .body = .{
            .body_type = switch (d.body_type) {
                0 => .dynamic,
                1 => .static,
                else => .kinematic,
            },
            .mass = d.mass,
            .linear_damping = d.linear_damping,
            .angular_damping = d.angular_damping,
            .lock_rotation = d.lock_rotation != 0,
        },
        .collider = collider,
    };
}

fn velocityToC(v: physics.Velocity) Velocity {
    return .{ .linear = .{ v.x, v.y, v.z }, .angular = .{ v.angular_x, v.angular_y, v.angular_z } };
}

fn velocityFromC(v: Velocity) physics.Velocity {
    return .{
        .x = v.linear[0],
        .y = v.linear[1],
        .z = v.linear[2],
        .angular_x = v.angular[0],
        .angular_y = v.angular[1],
        .angular_z = v.angular[2],
    };
}

/// Builds a static C vtable from a Zig backend type `B` (plugin side). `B` provides any of:
/// `createBody`, `destroyBody`, `setTransform`, `getTransform`, `setVelocity`, `getVelocity`,
/// `applyForce`, `applyImpulse`, `step`, `raycast` with the same signatures as `physics_jolt.JoltBackend`.
/// Missing methods leave the corresponding entry null (the host treats it as a no-op).
pub fn vtableFor(comptime B: type) *const Backend {
    const Impl = struct {
        fn self(ctx: *anyopaque) *B {
            return @ptrCast(@alignCast(ctx));
        }

        fn createBody(ctx: *anyopaque, desc: *const BodyDesc, out_id: *u64) callconv(.c) i32 {
            const p = bodyPartsFrom(desc.*);
            out_id.* = self(ctx).createBody(p.entity, p.pos, p.body, p.collider) catch return FAILED;
            return OK;
        }

        fn destroyBody(ctx: *anyopaque, body_id: u64) callconv(.c) void {
            self(ctx).destroyBody(body_id);
        }

        fn setTransform(ctx: *anyopaque, body_id: u64, xf: *const Transform) callconv(.c) void {
            self(ctx).setTransform(body_id, xf.pos, xf.rot_euler);
        }

        fn getTransform(ctx: *anyopaque, body_id: u64, out: *Transform) callconv(.c) bool {
            const t = self(ctx).getTransform(body_id) orelse return false;
            out.* = .{ .pos = t.pos, .rot_euler = t.rot_euler };
            return true;
        }

        fn setVelocity(ctx: *anyopaque, body_id: u64, vel: *const Velocity) callconv(.c) void {
            self(ctx).setVelocity(body_id, velocityFromC(vel.*));
        }

        fn getVelocity(ctx: *anyopaque, body_id: u64, out: *Velocity) callconv(.c) bool {
            const v = self(ctx).getVelocity(body_id) orelse return false;
            out.* = velocityToC(v);
            return true;
        }

        fn applyForce(ctx: *anyopaque, body_id: u64, force: *const [3]f32) callconv(.c) void {
            self(ctx).applyForce(body_id, force.*);
        }

        fn applyImpulse(ctx: *anyopaque, body_id: u64, impulse: *const [3]f32) callconv(.c) void {
            self(ctx).applyImpulse(body_id, impulse.*);
        }

        fn step(ctx: *anyopaque, dt: f32, gravity: *const [3]f32) callconv(.c) i32 {
            const r = self(ctx).step(dt, gravity.*);
            if (@typeInfo(@TypeOf(r)) == .error_union) {
                _ = r catch return FAILED;
            }
            return OK;
        }

        fn raycast(ctx: *anyopaque, desc: *const RaycastDesc, out: *RaycastHit) callconv(.c) bool {
            const hit = self(ctx).raycast(.{
                .origin = desc.origin,
                .direction = desc.direction,
                .max_distance = desc.max_distance,
                .layer_mask = desc.layer_mask,
            }) orelse return false;
            out.* = .{
                .entity = @bitCast(hit.entity),
                .distance = hit.distance,
                .point = hit.point,
                .normal = hit.normal,
            };
            return true;
        }
    };

    const Static = struct {
        const vt: Backend = .{
            .create_body = if (@hasDecl(B, "createBody")) Impl.createBody else null,
            .destroy_body = if (@hasDecl(B, "destroyBody")) Impl.destroyBody else null,
            .set_transform = if (@hasDecl(B, "setTransform")) Impl.setTransform else null,
            .get_transform = if (@hasDecl(B, "getTransform")) Impl.getTransform else null,
            .set_velocity = if (@hasDecl(B, "setVelocity")) Impl.setVelocity else null,
            .get_velocity = if (@hasDecl(B, "getVelocity")) Impl.getVelocity else null,
            .apply_force = if (@hasDecl(B, "applyForce")) Impl.applyForce else null,
            .apply_impulse = if (@hasDecl(B, "applyImpulse")) Impl.applyImpulse else null,
            .step = if (@hasDecl(B, "step")) Impl.step else null,
            .raycast = if (@hasDecl(B, "raycast")) Impl.raycast else null,
        };
    };
    return &Static.vt;
}

// ---------------------------------------------------------------------------------------------
// Host-side helpers used by `PhysicsService` when a plugin filled the slot.
// ---------------------------------------------------------------------------------------------

pub fn hostCreateBody(
    slot: *const Slot,
    entity: engine.EntityHandle,
    pos: [3]f32,
    body: physics.RigidBody,
    collider: ?physics.Collider,
) !u64 {
    const vt = slot.vtable orelse return error.MissingPhysicsBackend;
    const f = vt.create_body orelse return error.UnsupportedPhysicsOp;
    const desc = bodyDescFrom(entity, pos, body, collider);
    var out_id: u64 = 0;
    if (f(slot.ctx.?, &desc, &out_id) != OK) return error.PhysicsBackendFailed;
    return out_id;
}

pub fn hostSetTransform(slot: *const Slot, body_id: u64, pos: [3]f32, rot_euler: [3]f32) void {
    const vt = slot.vtable orelse return;
    const f = vt.set_transform orelse return;
    const xf: Transform = .{ .pos = pos, .rot_euler = rot_euler };
    f(slot.ctx.?, body_id, &xf);
}

pub fn hostGetTransform(slot: *const Slot, body_id: u64) ?physics.BodyTransform {
    const vt = slot.vtable orelse return null;
    const f = vt.get_transform orelse return null;
    var out: Transform = undefined;
    if (!f(slot.ctx.?, body_id, &out)) return null;
    return .{ .pos = out.pos, .rot_euler = out.rot_euler };
}

pub fn hostSetVelocity(slot: *const Slot, body_id: u64, vel: physics.Velocity) void {
    const vt = slot.vtable orelse return;
    const f = vt.set_velocity orelse return;
    const cv = velocityToC(vel);
    f(slot.ctx.?, body_id, &cv);
}

pub fn hostGetVelocity(slot: *const Slot, body_id: u64) ?physics.Velocity {
    const vt = slot.vtable orelse return null;
    const f = vt.get_velocity orelse return null;
    var out: Velocity = undefined;
    if (!f(slot.ctx.?, body_id, &out)) return null;
    return velocityFromC(out);
}

pub fn hostApplyForce(slot: *const Slot, body_id: u64, force: [3]f32) void {
    const vt = slot.vtable orelse return;
    const f = vt.apply_force orelse return;
    f(slot.ctx.?, body_id, &force);
}

pub fn hostStep(slot: *const Slot, dt: f32, gravity: [3]f32) !void {
    const vt = slot.vtable orelse return;
    const f = vt.step orelse return;
    if (f(slot.ctx.?, dt, &gravity) != OK) return error.PhysicsBackendFailed;
}

pub fn hostRaycast(slot: *const Slot, desc: physics.RaycastDesc) ?physics.RaycastHit {
    const vt = slot.vtable orelse return null;
    const f = vt.raycast orelse return null;
    const cdesc: RaycastDesc = .{
        .origin = desc.origin,
        .direction = desc.direction,
        .max_distance = desc.max_distance,
        .layer_mask = desc.layer_mask,
    };
    var out: RaycastHit = undefined;
    if (!f(slot.ctx.?, &cdesc, &out)) return null;
    return .{
        .entity = @bitCast(out.entity),
        .distance = out.distance,
        .point = out.point,
        .normal = out.normal,
    };
}

pub fn hostApplyImpulse(slot: *const Slot, body_id: u64, impulse: [3]f32) void {
    const vt = slot.vtable orelse return;
    const f = vt.apply_impulse orelse return;
    f(slot.ctx.?, body_id, &impulse);
}
