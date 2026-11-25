//! Reusable transform manipulation math for translate/rotate/scale gizmos.
//!
//! Pure geometry: consumes a camera ray and a target transform snapshot, emits begin/update/
//! commit intents. Does not depend on editor history, selection or UI packages.

const std = @import("std");

/// World-space ray used for axis/plane intersection.
pub const Ray = struct {
    origin: [3]f32,
    direction: [3]f32,
};

/// Authorable TRS snapshot (position + Euler radians + scale).
pub const TransformSnapshot = struct {
    position: [3]f32 = .{ 0, 0, 0 },
    rotation_euler: [3]f32 = .{ 0, 0, 0 },
    scale: [3]f32 = .{ 1, 1, 1 },
};

pub const Mode = enum { translate, rotate, scale };
pub const Axis = enum { x, y, z };

pub const Intent = union(enum) {
    begin: void,
    update: TransformSnapshot,
    commit: TransformSnapshot,
    cancel: void,
};

/// Active drag state. Store beside the editor selection; never inside the gizmo package's module state.
pub const DragState = struct {
    mode: Mode,
    axis: Axis,
    start: TransformSnapshot,
    grab_point: [3]f32,
    active: bool = false,

    pub fn begin(mode: Mode, axis: Axis, start: TransformSnapshot, grab_point: [3]f32) DragState {
        return .{ .mode = mode, .axis = axis, .start = start, .grab_point = grab_point, .active = true };
    }

    pub fn cancel(self: *DragState) Intent {
        self.active = false;
        return .cancel;
    }

    pub fn commit(self: *DragState, current: TransformSnapshot) Intent {
        self.active = false;
        return .{ .commit = current };
    }
};

fn axisVector(axis: Axis) [3]f32 {
    return switch (axis) {
        .x => .{ 1, 0, 0 },
        .y => .{ 0, 1, 0 },
        .z => .{ 0, 0, 1 },
    };
}

fn dot(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn add(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}

fn scale(v: [3]f32, s: f32) [3]f32 {
    return .{ v[0] * s, v[1] * s, v[2] * s };
}

fn sub(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

/// Closest point on `axis` through `origin` to `ray`. Returns null when ray is parallel to the axis.
pub fn closestOnAxis(origin: [3]f32, axis: Axis, ray: Ray) ?[3]f32 {
    const d = axisVector(axis);
    const w0 = sub(ray.origin, origin);
    const a = dot(d, d);
    const b = dot(d, ray.direction);
    const c = dot(ray.direction, ray.direction);
    const d_ = dot(d, w0);
    const e = dot(ray.direction, w0);
    const denom = a * c - b * b;
    if (!std.math.isFinite(denom) or @abs(denom) < 1e-8) return null;
    const t = (b * e - c * d_) / denom;
    return add(origin, scale(d, t));
}

/// Translates along `axis` from `drag.start` using the current ray. Degenerate rays leave the start pose.
pub fn updateTranslate(drag: *const DragState, ray: Ray) TransformSnapshot {
    var next = drag.start;
    const hit = closestOnAxis(drag.start.position, drag.axis, ray) orelse return next;
    const grab = closestOnAxis(drag.start.position, drag.axis, .{
        .origin = drag.grab_point,
        .direction = ray.direction,
    }) orelse drag.grab_point;
    const delta = sub(hit, grab);
    next.position = add(drag.start.position, delta);
    return next;
}

/// Uniform/axis scale from ray motion projected onto the axis. Negative scales are clamped to a small epsilon.
pub fn updateScale(drag: *const DragState, ray: Ray) TransformSnapshot {
    var next = drag.start;
    const hit = closestOnAxis(drag.start.position, drag.axis, ray) orelse return next;
    const start_hit = closestOnAxis(drag.start.position, drag.axis, .{
        .origin = drag.grab_point,
        .direction = ray.direction,
    }) orelse return next;
    const axis = axisVector(drag.axis);
    const start_t = dot(sub(start_hit, drag.start.position), axis);
    const cur_t = dot(sub(hit, drag.start.position), axis);
    if (@abs(start_t) < 1e-5) return next;
    const factor = cur_t / start_t;
    if (!std.math.isFinite(factor)) return next;
    const idx: usize = switch (drag.axis) {
        .x => 0,
        .y => 1,
        .z => 2,
    };
    next.scale[idx] = @max(0.05, drag.start.scale[idx] * factor);
    return next;
}

test "closestOnAxis rejects parallel rays" {
    const hit = closestOnAxis(.{ 0, 0, 0 }, .x, .{ .origin = .{ 0, 1, 0 }, .direction = .{ 1, 0, 0 } });
    try std.testing.expect(hit == null);
}

test "updateTranslate moves only along the dragged axis" {
    const drag = DragState.begin(.translate, .y, .{ .position = .{ 1, 2, 3 } }, .{ 1, 4, 3 });
    const next = updateTranslate(&drag, .{ .origin = .{ 10, 0, 3 }, .direction = .{ -1, 0.2, 0 } });
    try std.testing.expectApproxEqAbs(@as(f32, 1), next.position[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 3), next.position[2], 1e-4);
}
