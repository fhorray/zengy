//! Unified Pointer Picking & Input Focus (`official.picking`).
//!
//! Unifies mouse/touch interaction across UI, 2D, and 3D via pluggable
//! `PickingBackendVTable` providers (`engine.picking/1`) and tracks active
//! entity focus (`InputFocus`, `engine.input_focus/1`).
//!
//! Emits `PointerEnter`, `PointerLeave`, `PointerDown`, `PointerUp`, and
//! `PointerDrag` into `engine.EventBus`.

const std = @import("std");
const engine = @import("engine");
const camera = @import("camera");
const input = @import("input");
const render_3d = @import("render_3d");

/// Owner ID used when registering `official.picking` services.
pub const MODULE_OWNER_ID: u64 = 2043;

/// Identifies which layer produced a picking hit.
pub const PickingBackendKind = enum(u8) {
    ui = 0,
    world_2d = 1,
    world_3d = 2,
    custom = 3,
};

/// Controls whether a hit stops propagation to lower-priority layers.
pub const FocusPolicy = enum(u8) {
    block = 0,
    pass = 1,
};

/// Tracks the currently focused and hovered entities (`engine.input_focus/1`).
pub const InputFocus = struct {
    focused_entity: ?engine.EntityHandle = null,
    hovered_entity: ?engine.EntityHandle = null,

    /// Sets focus to `entity` (or clears focus when `null`).
    pub fn setFocus(self: *InputFocus, entity: ?engine.EntityHandle) void {
        self.focused_entity = entity;
    }

    /// Clears the current entity focus.
    pub fn clearFocus(self: *InputFocus) void {
        self.focused_entity = null;
    }

    /// Returns `true` if `entity` currently holds input focus.
    pub fn isFocused(self: *const InputFocus, entity: engine.EntityHandle) bool {
        const f = self.focused_entity orelse return false;
        return f.index == entity.index and f.generation == entity.generation;
    }
};

/// ECS component enabling 3D AABB raycast picking on an entity with `Transform3D`.
pub const Pickable3D = struct {
    half_extents: [3]f32 = .{ 0.5, 0.5, 0.5 },
    offset: [3]f32 = .{ 0, 0, 0 },
    enabled: bool = true,
    focus_policy: FocusPolicy = .block,
};

/// ECS component enabling 2D bounds picking in viewport coordinates.
pub const Pickable2D = struct {
    center: [2]f32 = .{ 0, 0 },
    half_extents: [2]f32 = .{ 32, 32 },
    z_order: f32 = 0.0,
    enabled: bool = true,
    focus_policy: FocusPolicy = .block,
};

/// ECS component enabling UI-layer bounds picking (`x, y, width, height`).
pub const PickableUi = struct {
    rect: [4]f32 = .{ 0, 0, 100, 32 },
    z_order: f32 = 100.0,
    enabled: bool = true,
    focus_policy: FocusPolicy = .block,
};

/// Single hit candidate produced by a `PickingBackendVTable`.
pub const PickHit = struct {
    entity: engine.EntityHandle,
    backend_kind: PickingBackendKind,
    priority: i32 = 0,
    depth: f32 = 0.0,
    focus_policy: FocusPolicy = .block,
    hit_world: [3]f32 = .{ 0, 0, 0 },
    hit_normal: [3]f32 = .{ 0, 1, 0 },
};

/// Pointer enter event emitted when a pointer moves onto an entity.
pub const PointerEnter = struct {
    entity: engine.EntityHandle,
    backend_kind: PickingBackendKind,
    position: [2]f32,
    hit_world: [3]f32,
    hit_normal: [3]f32,
};

/// Pointer leave event emitted when a pointer moves off an entity.
pub const PointerLeave = struct {
    entity: engine.EntityHandle,
    backend_kind: PickingBackendKind,
    position: [2]f32,
};

/// Pointer press event emitted when the primary button is pressed on an entity.
pub const PointerDown = struct {
    entity: engine.EntityHandle,
    backend_kind: PickingBackendKind,
    position: [2]f32,
    hit_world: [3]f32,
    hit_normal: [3]f32,
};

/// Pointer release event emitted when the primary button is released.
pub const PointerUp = struct {
    entity: engine.EntityHandle,
    backend_kind: PickingBackendKind,
    position: [2]f32,
    hit_world: [3]f32,
    hit_normal: [3]f32,
};

/// Pointer drag event emitted while holding the primary button on a pressed entity.
pub const PointerDrag = struct {
    entity: engine.EntityHandle,
    backend_kind: PickingBackendKind,
    position: [2]f32,
    delta: [2]f32,
    hit_world: [3]f32,
    hit_normal: [3]f32,
};

/// Pluggable picking backend interface.
pub const PickingBackendVTable = struct {
    id: []const u8,
    kind: PickingBackendKind,
    priority: i32 = 0,
    ctx: ?*anyopaque = null,
    hit_test: *const fn (
        ctx: ?*anyopaque,
        world: *engine.World,
        resources: *engine.ResourceRegistry,
        pointer_pos: [2]f32,
        allocator: std.mem.Allocator,
        out_hits: *std.ArrayList(PickHit),
    ) anyerror!void,
};

fn sameEntity(a: ?engine.EntityHandle, b: ?engine.EntityHandle) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.index == b.?.index and a.?.generation == b.?.generation;
}

fn intersectRayAabbNormal(
    origin: [3]f32,
    dir: [3]f32,
    min_b: [3]f32,
    max_b: [3]f32,
) ?struct { t: f32, normal: [3]f32 } {
    var tmin: f32 = 0.0;
    var tmax: f32 = 1e6;
    var hit_axis: usize = 0;
    var hit_sign: f32 = -1.0;

    inline for (0..3) |i| {
        if (@abs(dir[i]) < 1e-6) {
            if (origin[i] < min_b[i] or origin[i] > max_b[i]) return null;
        } else {
            const inv = 1.0 / dir[i];
            var t1 = (min_b[i] - origin[i]) * inv;
            var t2 = (max_b[i] - origin[i]) * inv;
            var s: f32 = if (inv >= 0.0) -1.0 else 1.0;
            if (t1 > t2) {
                const tmp = t1;
                t1 = t2;
                t2 = tmp;
                s = -s;
            }
            if (t1 > tmin) {
                tmin = t1;
                hit_axis = i;
                hit_sign = s;
            }
            tmax = @min(tmax, t2);
            if (tmin > tmax) return null;
        }
    }
    var n = [3]f32{ 0, 0, 0 };
    n[hit_axis] = hit_sign;
    return .{ .t = tmin, .normal = n };
}

fn hitTestUi(
    _: ?*anyopaque,
    world: *engine.World,
    _: *engine.ResourceRegistry,
    pointer_pos: [2]f32,
    allocator: std.mem.Allocator,
    out_hits: *std.ArrayList(PickHit),
) !void {
    var q = try world.query(.{ .read = .{PickableUi} });
    defer q.deinit();
    while (q.next()) |row| {
        const ui = row.read(PickableUi);
        if (!ui.enabled) continue;
        const x0 = ui.rect[0];
        const y0 = ui.rect[1];
        const x1 = x0 + ui.rect[2];
        const y1 = y0 + ui.rect[3];
        if (pointer_pos[0] >= x0 and pointer_pos[0] <= x1 and pointer_pos[1] >= y0 and pointer_pos[1] <= y1) {
            try out_hits.append(allocator, .{
                .entity = row.entity,
                .backend_kind = .ui,
                .priority = 300,
                .depth = -ui.z_order,
                .focus_policy = ui.focus_policy,
                .hit_world = .{ pointer_pos[0], pointer_pos[1], ui.z_order },
                .hit_normal = .{ 0, 0, 1 },
            });
        }
    }
}

fn hitTest2D(
    _: ?*anyopaque,
    world: *engine.World,
    _: *engine.ResourceRegistry,
    pointer_pos: [2]f32,
    allocator: std.mem.Allocator,
    out_hits: *std.ArrayList(PickHit),
) !void {
    var q = try world.query(.{ .read = .{Pickable2D} });
    defer q.deinit();
    while (q.next()) |row| {
        const p2d = row.read(Pickable2D);
        if (!p2d.enabled) continue;
        if (@abs(pointer_pos[0] - p2d.center[0]) <= p2d.half_extents[0] and
            @abs(pointer_pos[1] - p2d.center[1]) <= p2d.half_extents[1])
        {
            try out_hits.append(allocator, .{
                .entity = row.entity,
                .backend_kind = .world_2d,
                .priority = 200,
                .depth = -p2d.z_order,
                .focus_policy = p2d.focus_policy,
                .hit_world = .{ pointer_pos[0], pointer_pos[1], p2d.z_order },
                .hit_normal = .{ 0, 0, 1 },
            });
        }
    }
}

fn hitTest3D(
    _: ?*anyopaque,
    world: *engine.World,
    resources: *engine.ResourceRegistry,
    pointer_pos: [2]f32,
    allocator: std.mem.Allocator,
    out_hits: *std.ArrayList(PickHit),
) !void {
    const cam_svc = resources.get(camera.CameraService) orelse return;
    const active_cams = cam_svc.sortedActiveCameras();
    if (active_cams.len == 0) return;
    // Match render_3d extraction: highest-order active camera is primary (last in sorted list).
    const cam = world.getConst(active_cams[active_cams.len - 1].entity, camera.Camera) orelse return;
    const ray = cam.viewportToWorld(pointer_pos) orelse return;

    var q = try world.query(.{ .read = .{ Pickable3D, render_3d.Transform3D } });
    defer q.deinit();
    while (q.next()) |row| {
        const p3d = row.read(Pickable3D);
        if (!p3d.enabled) continue;
        const tf = row.read(render_3d.Transform3D);

        const c = [3]f32{
            tf.position[0] + p3d.offset[0],
            tf.position[1] + p3d.offset[1],
            tf.position[2] + p3d.offset[2],
        };
        const h = [3]f32{
            p3d.half_extents[0] * @abs(tf.scale[0]),
            p3d.half_extents[1] * @abs(tf.scale[1]),
            p3d.half_extents[2] * @abs(tf.scale[2]),
        };
        const min_b = [3]f32{ c[0] - h[0], c[1] - h[1], c[2] - h[2] };
        const max_b = [3]f32{ c[0] + h[0], c[1] + h[1], c[2] + h[2] };

        if (intersectRayAabbNormal(ray.origin, ray.direction, min_b, max_b)) |hit| {
            try out_hits.append(allocator, .{
                .entity = row.entity,
                .backend_kind = .world_3d,
                .priority = 100,
                .depth = hit.t,
                .focus_policy = p3d.focus_policy,
                .hit_world = .{
                    ray.origin[0] + ray.direction[0] * hit.t,
                    ray.origin[1] + ray.direction[1] * hit.t,
                    ray.origin[2] + ray.direction[2] * hit.t,
                },
                .hit_normal = hit.normal,
            });
        }
    }
}

/// Manages pluggable picking backends and unified pointer interaction state (`engine.picking/1`).
pub const PickingService = struct {
    allocator: std.mem.Allocator,
    backends: std.ArrayList(PickingBackendVTable),
    hovered: ?PickHit = null,
    pressed: ?PickHit = null,
    auto_focus_on_press: bool = true,
    /// When false, `picking.update` does not call `updatePointer` so the application can own
    /// pointer routing (DPI, viewport gating, capture). Games that opt into automatic picking
    /// leave this true (default).
    auto_update: bool = true,

    /// Initializes `PickingService` with built-in UI, 2D, and 3D backends.
    pub fn init(allocator: std.mem.Allocator) !PickingService {
        var svc = PickingService{
            .allocator = allocator,
            .backends = .empty,
        };
        errdefer svc.deinit();
        try svc.registerBackend(.{ .id = "official.picking.ui", .kind = .ui, .priority = 300, .hit_test = hitTestUi });
        try svc.registerBackend(.{ .id = "official.picking.2d", .kind = .world_2d, .priority = 200, .hit_test = hitTest2D });
        try svc.registerBackend(.{ .id = "official.picking.3d", .kind = .world_3d, .priority = 100, .hit_test = hitTest3D });
        return svc;
    }

    /// Frees registered backend list.
    pub fn deinit(self: *PickingService) void {
        self.backends.deinit(self.allocator);
    }

    /// Registers an additional picking backend.
    pub fn registerBackend(self: *PickingService, backend: PickingBackendVTable) !void {
        try self.backends.append(self.allocator, backend);
    }

    /// Evaluates all backends at `pointer_pos` and returns the highest-priority closest hit.
    pub fn pickTop(
        self: *PickingService,
        world: *engine.World,
        resources: *engine.ResourceRegistry,
        pointer_pos: [2]f32,
    ) !?PickHit {
        var hits = std.ArrayList(PickHit).empty;
        defer hits.deinit(self.allocator);

        for (self.backends.items) |b| {
            try b.hit_test(b.ctx, world, resources, pointer_pos, self.allocator, &hits);
        }
        if (hits.items.len == 0) return null;

        std.mem.sort(PickHit, hits.items, {}, struct {
            fn lessThan(_: void, a: PickHit, b: PickHit) bool {
                if (a.priority != b.priority) return a.priority > b.priority;
                return a.depth < b.depth;
            }
        }.lessThan);

        return hits.items[0];
    }

    /// Runs hit-testing, updates hover/press/drag & `InputFocus`, and emits pointer events.
    pub fn updatePointer(
        self: *PickingService,
        world: *engine.World,
        resources: *engine.ResourceRegistry,
        events: *engine.EventBus,
        pointer_pos: [2]f32,
        delta: [2]f32,
        primary_down: bool,
        just_pressed: bool,
        just_released: bool,
    ) !?PickHit {
        const top = try self.pickTop(world, resources, pointer_pos);
        const top_ent: ?engine.EntityHandle = if (top) |h| h.entity else null;
        const prev_ent: ?engine.EntityHandle = if (self.hovered) |h| h.entity else null;

        if (!sameEntity(prev_ent, top_ent)) {
            if (self.hovered) |prev| {
                const ev = PointerLeave{
                    .entity = prev.entity,
                    .backend_kind = prev.backend_kind,
                    .position = pointer_pos,
                };
                try events.post(.{
                    .name = "picking.pointer_leave",
                    .payload = std.mem.asBytes(&ev),
                    .entity_handle = @bitCast(ev.entity),
                });
            }
            if (top) |cur| {
                const ev = PointerEnter{
                    .entity = cur.entity,
                    .backend_kind = cur.backend_kind,
                    .position = pointer_pos,
                    .hit_world = cur.hit_world,
                    .hit_normal = cur.hit_normal,
                };
                try events.post(.{
                    .name = "picking.pointer_enter",
                    .payload = std.mem.asBytes(&ev),
                    .entity_handle = @bitCast(ev.entity),
                });
            }
        }
        self.hovered = top;

        if (resources.get(InputFocus)) |focus| {
            focus.hovered_entity = top_ent;
            if (just_pressed and self.auto_focus_on_press) {
                focus.setFocus(top_ent);
            }
        }

        if (just_pressed) {
            if (top) |cur| {
                self.pressed = cur;
                const ev = PointerDown{
                    .entity = cur.entity,
                    .backend_kind = cur.backend_kind,
                    .position = pointer_pos,
                    .hit_world = cur.hit_world,
                    .hit_normal = cur.hit_normal,
                };
                try events.post(.{
                    .name = "picking.pointer_down",
                    .payload = std.mem.asBytes(&ev),
                    .entity_handle = @bitCast(ev.entity),
                });
            }
        }

        if (primary_down and !just_pressed and (delta[0] != 0.0 or delta[1] != 0.0)) {
            if (self.pressed) |p| {
                const ev = PointerDrag{
                    .entity = p.entity,
                    .backend_kind = p.backend_kind,
                    .position = pointer_pos,
                    .delta = delta,
                    .hit_world = if (top) |t| t.hit_world else p.hit_world,
                    .hit_normal = if (top) |t| t.hit_normal else p.hit_normal,
                };
                try events.post(.{
                    .name = "picking.pointer_drag",
                    .payload = std.mem.asBytes(&ev),
                    .entity_handle = @bitCast(ev.entity),
                });
            }
        }

        if (just_released) {
            if (self.pressed) |p| {
                const ev = PointerUp{
                    .entity = p.entity,
                    .backend_kind = p.backend_kind,
                    .position = pointer_pos,
                    .hit_world = if (top) |t| t.hit_world else p.hit_world,
                    .hit_normal = if (top) |t| t.hit_normal else p.hit_normal,
                };
                try events.post(.{
                    .name = "picking.pointer_up",
                    .payload = std.mem.asBytes(&ev),
                    .entity_handle = @bitCast(ev.entity),
                });
                self.pressed = null;
            }
        }

        return top;
    }
};

fn pickingUpdateSystem(ctx: *engine.SystemContext) !void {
    const svc = ctx.resources.get(PickingService) orelse return;
    if (!svc.auto_update) return;
    const mouse = ctx.resources.get(input.MouseInput) orelse return;
    const motion = ctx.resources.get(input.AccumulatedMouseMotion) orelse return;

    _ = try svc.updatePointer(
        ctx.world,
        ctx.resources,
        ctx.events,
        motion.position,
        motion.delta,
        mouse.pressed(.left),
        mouse.justPressed(.left),
        mouse.justReleased(.left),
    );
}

fn buildModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    try app.resources.insert(InputFocus, .{});
    const focus = app.resources.get(InputFocus).?;

    try app.resources.insert(PickingService, try PickingService.init(app.allocator));
    const svc = app.resources.get(PickingService).?;

    try app.services.register(.{
        .capability = "engine.input_focus",
        .major_version = 1,
        .provider_id = "official.picking",
        .owner_id = MODULE_OWNER_ID,
        .exclusive = true,
        .api_ptr = focus,
        .api_size = @sizeOf(InputFocus),
    });
    try app.services.register(.{
        .capability = "engine.picking",
        .major_version = 1,
        .provider_id = "official.picking",
        .owner_id = MODULE_OWNER_ID,
        .exclusive = true,
        .api_ptr = svc,
        .api_size = @sizeOf(PickingService),
    });

    try app.addSystem(.{
        .name = "picking.update",
        .stage = .update,
        .run = pickingUpdateSystem,
    });
}

fn stopModule(raw_app: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    _ = app.services.unregisterByOwner(MODULE_OWNER_ID);
    _ = app.resources.remove(PickingService);
    _ = app.resources.remove(InputFocus);
}

/// Returns the `official.picking` module descriptor.
pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = "official.picking",
            .version = "0.1.0",
            .provides_capabilities = &.{ "engine.picking/1", "engine.input_focus/1" },
            .required_capabilities = &.{},
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
