//! Agnostic, headless-first Camera & Projection package (`official.camera`),
//! inspired by `bevy_camera`.
//!
//! Provides unified 2D/3D `Camera`, `Projection` (`PerspectiveProjection` and
//! `OrthographicProjection`), `Viewport`, `RenderTarget`, `ClearColorConfig`,
//! `RenderLayers`, `Frustum` culling, `worldToViewport` / `viewportToWorld`
//! ray picking, and `CameraService` (`engine.camera/1`).

const std = @import("std");
const engine = @import("engine");
const graphics = @import("graphics");
const input = @import("input");
const scene = @import("scene");

/// Module owner identifier for `official.camera`.
pub const MODULE_OWNER_ID: u64 = 2016;

/// Capability ID provided by `official.camera`.
pub const CAPABILITY_ID = "engine.camera";

/// Provider identifier for `official.camera`.
pub const PROVIDER_ID = "official.camera";

/// 3D ray returned by `viewportToWorld` for ray picking.
pub const Ray3D = struct {
    origin: [3]f32,
    direction: [3]f32,
};

/// Render viewport region within a `RenderTarget`.
pub const Viewport = struct {
    physical_position: [2]u32 = .{ 0, 0 },
    physical_size: [2]u32 = .{ 1280, 720 },
    depth: [2]f32 = .{ 0.0, 1.0 },
};

/// Destination surface where a `Camera` renders its output.
pub const RenderTarget = union(enum) {
    primary_window,
    window: u64,
    image: u64,
};

/// Per-camera clear color behavior.
pub const ClearColorConfig = union(enum) {
    default,
    custom: graphics.Color,
    none,
};

/// Bitmask controlling which entities and lights are visible to a `Camera`.
pub const RenderLayers = struct {
    mask: u32 = 1,

    /// Returns a `RenderLayers` with only `idx` (0..31) enabled.
    pub fn layer(idx: u5) RenderLayers {
        return .{ .mask = @as(u32, 1) << idx };
    }

    /// Returns a `RenderLayers` with all layers enabled.
    pub fn all() RenderLayers {
        return .{ .mask = std.math.maxInt(u32) };
    }

    /// Returns a copy with layer `idx` added.
    pub fn with(self: RenderLayers, idx: u5) RenderLayers {
        return .{ .mask = self.mask | (@as(u32, 1) << idx) };
    }

    /// Returns a copy with layer `idx` removed.
    pub fn without(self: RenderLayers, idx: u5) RenderLayers {
        return .{ .mask = self.mask & ~(@as(u32, 1) << idx) };
    }

    /// Returns `true` when both masks share at least one enabled layer.
    pub fn intersects(self: RenderLayers, other: RenderLayers) bool {
        return (self.mask & other.mask) != 0;
    }
};

/// Scaling strategy for `OrthographicProjection`.
pub const ScalingMode = union(enum) {
    /// World units match physical/logical pixels (`1.0` unit = `1.0 * scale` px).
    window_size,
    /// Fixed world width; height scales by aspect ratio.
    fixed_horizontal: f32,
    /// Fixed world height; width scales by aspect ratio.
    fixed_vertical: f32,
    /// Fixed minimum width and height; expands whichever axis is larger.
    auto_min: [2]f32,
    /// Fixed maximum width and height; shrinks whichever axis is smaller.
    auto_max: [2]f32,
};

/// 3D perspective projection parameters (right-handed, `[0..1]` depth).
pub const PerspectiveProjection = struct {
    fov_rad: f32 = std.math.pi / 3.0,
    aspect_ratio: f32 = 16.0 / 9.0,
    near: f32 = 0.1,
    far: f32 = 1000.0,

    /// Updates `aspect_ratio` from viewport dimensions.
    pub fn update(self: *PerspectiveProjection, width: f32, height: f32) void {
        if (width > 0.0 and height > 0.0) {
            self.aspect_ratio = width / height;
        }
    }

    /// Computes column-major 4x4 perspective projection matrix (`[0..1]` depth).
    pub fn clipFromView(self: PerspectiveProjection) [16]f32 {
        const f = 1.0 / @tan(self.fov_rad * 0.5);
        const inv_range = 1.0 / (self.near - self.far);
        return .{
            f / self.aspect_ratio, 0, 0,                                0,
            0,                     f, 0,                                0,
            0,                     0, self.far * inv_range,             -1,
            0,                     0, self.near * self.far * inv_range, 0,
        };
    }
};

/// 2D / isometric orthographic projection parameters (`[0..1]` depth).
pub const OrthographicProjection = struct {
    near: f32 = -1000.0,
    far: f32 = 1000.0,
    scale: f32 = 1.0,
    scaling_mode: ScalingMode = .window_size,
    viewport_origin: [2]f32 = .{ 0.5, 0.5 },
    area_min: [2]f32 = .{ -640.0, -360.0 },
    area_max: [2]f32 = .{ 640.0, 360.0 },

    /// Recomputes `area_min` / `area_max` from viewport dimensions and `scaling_mode`.
    pub fn update(self: *OrthographicProjection, width: f32, height: f32) void {
        if (width <= 0.0 or height <= 0.0) return;
        const proj_size: [2]f32 = switch (self.scaling_mode) {
            .window_size => .{ width, height },
            .fixed_horizontal => |w| .{ w, w * height / width },
            .fixed_vertical => |h| .{ h * width / height, h },
            .auto_min => |m| blk: {
                const sx = width / m[0];
                const sy = height / m[1];
                if (sx > sy) break :blk .{ m[1] * width / height, m[1] } else break :blk .{ m[0], m[0] * height / width };
            },
            .auto_max => |m| blk: {
                const sx = width / m[0];
                const sy = height / m[1];
                if (sx < sy) break :blk .{ m[1] * width / height, m[1] } else break :blk .{ m[0], m[0] * height / width };
            },
        };
        const w = proj_size[0] * self.scale;
        const h = proj_size[1] * self.scale;
        self.area_min = .{ -w * self.viewport_origin[0], -h * self.viewport_origin[1] };
        self.area_max = .{ w * (1.0 - self.viewport_origin[0]), h * (1.0 - self.viewport_origin[1]) };
    }

    /// Computes column-major 4x4 orthographic projection matrix (`[0..1]` depth).
    pub fn clipFromView(self: OrthographicProjection) [16]f32 {
        const rml = self.area_max[0] - self.area_min[0];
        const tmb = self.area_max[1] - self.area_min[1];
        const fmn = self.far - self.near;
        if (@abs(rml) < 1e-6 or @abs(tmb) < 1e-6 or @abs(fmn) < 1e-6) return mat4Identity();
        return .{
            2.0 / rml,                                    0,                                            0,                0,
            0,                                            2.0 / tmb,                                    0,                0,
            0,                                            0,                                            -1.0 / fmn,       0,
            -(self.area_max[0] + self.area_min[0]) / rml, -(self.area_max[1] + self.area_min[1]) / tmb, -self.near / fmn, 1,
        };
    }
};

/// Camera projection component (`Perspective` or `Orthographic`).
pub const Projection = union(enum) {
    perspective: PerspectiveProjection,
    orthographic: OrthographicProjection,

    /// Updates projection bounds/aspect for `width` x `height`.
    pub fn update(self: *Projection, width: f32, height: f32) void {
        switch (self.*) {
            .perspective => |*p| p.update(width, height),
            .orthographic => |*o| o.update(width, height),
        }
    }

    /// Returns the column-major 4x4 clip-from-view matrix.
    pub fn clipFromView(self: Projection) [16]f32 {
        return switch (self) {
            .perspective => |p| p.clipFromView(),
            .orthographic => |o| o.clipFromView(),
        };
    }

    /// Returns the far plane distance.
    pub fn far(self: Projection) f32 {
        return switch (self) {
            .perspective => |p| p.far,
            .orthographic => |o| o.far,
        };
    }
};

/// 6-plane camera frustum for sphere culling (`[nx, ny, nz, d]`).
pub const Frustum = struct {
    planes: [6][4]f32 = @splat(.{ 0, 0, 1, 1000 }),

    /// Extracts 6 normalized frustum planes from a column-major clip-from-world matrix.
    pub fn fromClipMatrix(m: [16]f32) Frustum {
        const r0 = [4]f32{ m[0], m[4], m[8], m[12] };
        const r1 = [4]f32{ m[1], m[5], m[9], m[13] };
        const r2 = [4]f32{ m[2], m[6], m[10], m[14] };
        const r3 = [4]f32{ m[3], m[7], m[11], m[15] };

        const raw = [6][4]f32{
            .{ r3[0] + r0[0], r3[1] + r0[1], r3[2] + r0[2], r3[3] + r0[3] }, // left
            .{ r3[0] - r0[0], r3[1] - r0[1], r3[2] - r0[2], r3[3] - r0[3] }, // right
            .{ r3[0] + r1[0], r3[1] + r1[1], r3[2] + r1[2], r3[3] + r1[3] }, // bottom
            .{ r3[0] - r1[0], r3[1] - r1[1], r3[2] - r1[2], r3[3] - r1[3] }, // top
            .{ r2[0], r2[1], r2[2], r2[3] }, // near [0..1]
            .{ r3[0] - r2[0], r3[1] - r2[1], r3[2] - r2[2], r3[3] - r2[3] }, // far
        };
        var out: Frustum = .{};
        for (raw, 0..) |p, i| {
            const len = @sqrt(p[0] * p[0] + p[1] * p[1] + p[2] * p[2]);
            if (len > 1e-6) {
                const inv = 1.0 / len;
                out.planes[i] = .{ p[0] * inv, p[1] * inv, p[2] * inv, p[3] * inv };
            }
        }
        return out;
    }

    /// Returns `true` when sphere `(center, radius)` intersects or lies inside all 6 planes.
    pub fn containsSphere(self: Frustum, center: [3]f32, radius: f32) bool {
        for (self.planes) |p| {
            const dist = p[0] * center[0] + p[1] * center[1] + p[2] * center[2] + p[3];
            if (dist < -radius) return false;
        }
        return true;
    }
};

/// World-space camera pose component (position, forward, up).
pub const CameraPose = struct {
    position: [3]f32 = .{ 0, 0, 5 },
    forward: [3]f32 = .{ 0, 0, -1 },
    up: [3]f32 = .{ 0, 1, 0 },

    /// Builds a `CameraPose` positioned at `eye` looking toward `target`.
    pub fn lookAt(eye: [3]f32, target: [3]f32, up: [3]f32) CameraPose {
        const fwd = vec3Normalize(.{ target[0] - eye[0], target[1] - eye[1], target[2] - eye[2] });
        return .{ .position = eye, .forward = fwd, .up = vec3Normalize(up) };
    }

    /// Computes column-major 4x4 view matrix (`view_from_world`).
    pub fn viewFromWorld(self: CameraPose) [16]f32 {
        const f = vec3Normalize(self.forward);
        const s = vec3Normalize(vec3Cross(f, self.up));
        const u = vec3Cross(s, f);
        return .{
            s[0],                       u[0],                       -f[0],                     0,
            s[1],                       u[1],                       -f[1],                     0,
            s[2],                       u[2],                       -f[2],                     0,
            -vec3Dot(s, self.position), -vec3Dot(u, self.position), vec3Dot(f, self.position), 1,
        };
    }

    /// Computes column-major 4x4 camera transform (`world_from_view`).
    pub fn worldFromView(self: CameraPose) [16]f32 {
        const f = vec3Normalize(self.forward);
        const s = vec3Normalize(vec3Cross(f, self.up));
        const u = vec3Cross(s, f);
        return .{
            s[0],             s[1],             s[2],             0,
            u[0],             u[1],             u[2],             0,
            -f[0],            -f[1],            -f[2],            0,
            self.position[0], self.position[1], self.position[2], 1,
        };
    }
};

/// Derived matrices, viewport sizes, and frustum updated each frame by `cameraUpdateSystem`.
pub const ComputedCameraValues = struct {
    target_size: [2]u32 = .{ 1280, 720 },
    viewport_pos: [2]f32 = .{ 0, 0 },
    viewport_size: [2]f32 = .{ 1280, 720 },
    clip_from_view: [16]f32 = mat4Identity(),
    view_from_world: [16]f32 = mat4Identity(),
    world_from_view: [16]f32 = mat4Identity(),
    clip_from_world: [16]f32 = mat4Identity(),
    frustum: Frustum = .{},
};

/// Unified `Camera` component supporting 2D, 3D, multiple viewports, and offscreen targets.
pub const Camera = struct {
    is_active: bool = true,
    order: isize = 0,
    viewport: ?Viewport = null,
    target: RenderTarget = .primary_window,
    clear_color: ClearColorConfig = .default,
    computed: ComputedCameraValues = .{},

    /// Projects a world-space point into logical viewport coordinates `(x, y)` (top-left origin).
    pub fn worldToViewport(self: Camera, world_pos: [3]f32) ?[2]f32 {
        const c = mat4MulVec4(self.computed.clip_from_world, .{ world_pos[0], world_pos[1], world_pos[2], 1.0 });
        if (c[3] <= 1e-6) return null;
        const inv_w = 1.0 / c[3];
        const ndc_x = c[0] * inv_w;
        const ndc_y = c[1] * inv_w;
        const vw = self.computed.viewport_size[0];
        const vh = self.computed.viewport_size[1];
        if (vw <= 0.0 or vh <= 0.0) return null;
        return .{
            self.computed.viewport_pos[0] + (ndc_x * 0.5 + 0.5) * vw,
            self.computed.viewport_pos[1] + (0.5 - ndc_y * 0.5) * vh,
        };
    }

    /// Unprojects a viewport coordinate `(x, y)` (top-left origin) into a world-space `Ray3D`.
    pub fn viewportToWorld(self: Camera, viewport_pos: [2]f32) ?Ray3D {
        const vw = self.computed.viewport_size[0];
        const vh = self.computed.viewport_size[1];
        if (vw <= 0.0 or vh <= 0.0) return null;
        const inv_clip = mat4Inverse(self.computed.clip_from_world) orelse return null;

        const lx = viewport_pos[0] - self.computed.viewport_pos[0];
        const ly = viewport_pos[1] - self.computed.viewport_pos[1];
        const ndc_x = (lx / vw) * 2.0 - 1.0;
        const ndc_y = 1.0 - (ly / vh) * 2.0;

        const near_h = mat4MulVec4(inv_clip, .{ ndc_x, ndc_y, 0.0, 1.0 });
        const far_h = mat4MulVec4(inv_clip, .{ ndc_x, ndc_y, 1.0, 1.0 });
        if (@abs(near_h[3]) < 1e-6 or @abs(far_h[3]) < 1e-6) return null;

        const near_p = [3]f32{ near_h[0] / near_h[3], near_h[1] / near_h[3], near_h[2] / near_h[3] };
        const far_p = [3]f32{ far_h[0] / far_h[3], far_h[1] / far_h[3], far_h[2] / far_h[3] };
        const dir = vec3Normalize(.{ far_p[0] - near_p[0], far_p[1] - near_p[1], far_p[2] - near_p[2] });
        return .{ .origin = near_p, .direction = dir };
    }
};

/// Ordered snapshot entry produced by `cameraUpdateSystem`.
pub const ActiveCameraEntry = struct {
    entity: engine.EntityHandle,
    order: isize,
    target: RenderTarget,
    computed: ComputedCameraValues,
};

/// Service (`engine.camera/1`) tracking target dimensions and sorted active cameras.
pub const CameraService = struct {
    allocator: std.mem.Allocator,
    primary_target_size: [2]u32 = .{ 1280, 720 },
    active_cameras: std.ArrayList(ActiveCameraEntry),

    /// Initializes a `CameraService`.
    pub fn init(allocator: std.mem.Allocator) CameraService {
        return .{
            .allocator = allocator,
            .active_cameras = .empty,
        };
    }

    /// Releases resources owned by `CameraService`.
    pub fn deinit(self: *CameraService) void {
        self.active_cameras.deinit(self.allocator);
    }

    /// Sets the primary render target size in pixels.
    pub fn setPrimaryTargetSize(self: *CameraService, width: u32, height: u32) void {
        if (width > 0 and height > 0) {
            self.primary_target_size = .{ width, height };
        }
    }

    /// Returns active cameras sorted by `order` ascending.
    pub fn sortedActiveCameras(self: *const CameraService) []const ActiveCameraEntry {
        return self.active_cameras.items;
    }
};

/// `.post_update` system that updates `Projection`, `Camera.computed`, `Frustum`, and `CameraService.active_cameras`.
pub fn cameraUpdateSystem(ctx: *engine.SystemContext) !void {
    const svc = ctx.resources.get(CameraService) orelse return;
    svc.active_cameras.clearRetainingCapacity();

    var q = try ctx.query(.{ .write = .{Camera} });
    defer q.deinit();
    while (q.next()) |row| {
        const entity = row.entity;
        const cam = row.write(Camera);
        if (!cam.is_active) continue;

        const target_sz = svc.primary_target_size;
        const vp_pos: [2]f32 = if (cam.viewport) |vp|
            .{ @floatFromInt(vp.physical_position[0]), @floatFromInt(vp.physical_position[1]) }
        else
            .{ 0, 0 };
        const vp_sz: [2]f32 = if (cam.viewport) |vp|
            .{ @floatFromInt(vp.physical_size[0]), @floatFromInt(vp.physical_size[1]) }
        else
            .{ @floatFromInt(target_sz[0]), @floatFromInt(target_sz[1]) };

        var clip_from_view = mat4Identity();
        if (ctx.world.get(entity, Projection)) |proj| {
            proj.update(vp_sz[0], vp_sz[1]);
            clip_from_view = proj.clipFromView();
        } else {
            var default_proj = Projection{ .perspective = .{} };
            default_proj.update(vp_sz[0], vp_sz[1]);
            clip_from_view = default_proj.clipFromView();
        }

        var view_from_world: [16]f32 = undefined;
        var world_from_view: [16]f32 = undefined;
        if (ctx.world.getConst(entity, scene.incremental.GlobalTransform3D)) |gt| {
            world_from_view = gt.m;
            view_from_world = mat4Inverse(gt.m) orelse (CameraPose{}).viewFromWorld();
        } else {
            const pose = if (ctx.world.get(entity, CameraPose)) |p| p.* else CameraPose{};
            view_from_world = pose.viewFromWorld();
            world_from_view = pose.worldFromView();
        }
        const clip_from_world = mat4Mul(clip_from_view, view_from_world);

        cam.computed = .{
            .target_size = target_sz,
            .viewport_pos = vp_pos,
            .viewport_size = vp_sz,
            .clip_from_view = clip_from_view,
            .view_from_world = view_from_world,
            .world_from_view = world_from_view,
            .clip_from_world = clip_from_world,
            .frustum = Frustum.fromClipMatrix(clip_from_world),
        };

        try svc.active_cameras.append(svc.allocator, .{
            .entity = entity,
            .order = cam.order,
            .target = cam.target,
            .computed = cam.computed,
        });
    }

    std.sort.insertion(ActiveCameraEntry, svc.active_cameras.items, {}, struct {
        fn lessThan(_: void, a: ActiveCameraEntry, b: ActiveCameraEntry) bool {
            if (a.order != b.order) return a.order < b.order;
            return a.entity.index < b.entity.index;
        }
    }.lessThan);
}

/// Bevy-inspired fly/free camera controller configuration (`FreeCamera`).
pub const FreeCamera = struct {
    sensitivity: f32 = 0.0045,
    walk_speed: f32 = 5.0,
    run_speed: f32 = 12.0,
    scroll_factor: f32 = 0.1,
    key_forward: input.KeyCode = .key_w,
    key_back: input.KeyCode = .key_s,
    key_left: input.KeyCode = .key_a,
    key_right: input.KeyCode = .key_d,
    key_up: input.KeyCode = .key_e,
    key_down: input.KeyCode = .key_q,
    key_run: input.KeyCode = .shift_left,
    look_button: ?input.MouseButton = .right,
    /// When true, movement keys only apply while `look_button` is held (or always when
    /// `look_button` is null). Games keep the default false; editors should set true so typing
    /// in panels cannot fly the camera.
    require_look_for_move: bool = false,
    invert_x: bool = false,
    invert_y: bool = false,
    enabled: bool = true,
    state: FreeCameraState = .{},
};

/// Dynamic runtime state for `FreeCamera` (`yaw`, `pitch`, `speed_multiplier`).
pub const FreeCameraState = struct {
    yaw: f32 = 0.0,
    pitch: f32 = 0.0,
    speed_multiplier: f32 = 1.0,
    initialized: bool = false,
};

/// `.update` system driving `CameraPose` from `FreeCamera` and `official.input` resources.
pub fn freeCameraSystem(ctx: *engine.SystemContext) !void {
    const keys = ctx.resources.get(input.KeyInput) orelse return;
    const mouse = ctx.resources.get(input.MouseInput) orelse return;
    const motion = ctx.resources.get(input.AccumulatedMouseMotion) orelse return;
    const scroll = ctx.resources.get(input.AccumulatedMouseScroll) orelse return;

    var q = try ctx.query(.{ .write = .{ FreeCamera, CameraPose } });
    defer q.deinit();
    while (q.next()) |row| {
        const cfg = row.write(FreeCamera);
        if (!cfg.enabled) continue;
        const pose = row.write(CameraPose);
        const state = &cfg.state;

        if (!state.initialized) {
            const f = vec3Normalize(pose.forward);
            state.pitch = std.math.asin(std.math.clamp(f[1], -0.999, 0.999));
            state.yaw = std.math.atan2(f[0], -f[2]);
            state.initialized = true;
        }

        if (@abs(scroll.delta[1]) > 0.001) {
            state.speed_multiplier = std.math.clamp(
                state.speed_multiplier * (1.0 + scroll.delta[1] * cfg.scroll_factor),
                0.1,
                10.0,
            );
        }

        const looking = if (cfg.look_button) |btn| mouse.pressed(btn) else true;
        if (looking and (@abs(motion.delta[0]) > 0.0 or @abs(motion.delta[1]) > 0.0)) {
            const dx_sign: f32 = if (cfg.invert_x) -1.0 else 1.0;
            const dy_sign: f32 = if (cfg.invert_y) 1.0 else -1.0;
            state.yaw += motion.delta[0] * cfg.sensitivity * dx_sign;
            state.pitch = std.math.clamp(
                state.pitch + motion.delta[1] * cfg.sensitivity * dy_sign,
                -1.52,
                1.52,
            );
        }

        const cp = @cos(state.pitch);
        const sp = @sin(state.pitch);
        const sy = @sin(state.yaw);
        const cy = @cos(state.yaw);
        const fwd = vec3Normalize(.{ sy * cp, sp, -cy * cp });
        const right = vec3Normalize(vec3Cross(fwd, .{ 0, 1, 0 }));

        const can_move = if (cfg.require_look_for_move) looking else true;
        var move = [3]f32{ 0, 0, 0 };
        if (can_move) {
            if (keys.pressed(cfg.key_forward)) move = .{ move[0] + fwd[0], move[1] + fwd[1], move[2] + fwd[2] };
            if (keys.pressed(cfg.key_back)) move = .{ move[0] - fwd[0], move[1] - fwd[1], move[2] - fwd[2] };
            if (keys.pressed(cfg.key_right)) move = .{ move[0] + right[0], move[1] + right[1], move[2] + right[2] };
            if (keys.pressed(cfg.key_left)) move = .{ move[0] - right[0], move[1] - right[1], move[2] - right[2] };
            if (keys.pressed(cfg.key_up)) move[1] += 1.0;
            if (keys.pressed(cfg.key_down)) move[1] -= 1.0;
        }

        const move_len = @sqrt(move[0] * move[0] + move[1] * move[1] + move[2] * move[2]);
        if (move_len > 1e-4) {
            const base_speed = if (keys.pressed(cfg.key_run)) cfg.run_speed else cfg.walk_speed;
            const step = (base_speed * state.speed_multiplier * ctx.dt) / move_len;
            pose.position[0] += move[0] * step;
            pose.position[1] += move[1] * step;
            pose.position[2] += move[2] * step;
        }
        pose.forward = fwd;
    }
}

fn buildModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    try app.resources.insert(CameraService, CameraService.init(app.allocator));
    const svc = app.resources.get(CameraService).?;

    try app.services.register(.{
        .capability = CAPABILITY_ID,
        .major_version = 1,
        .provider_id = PROVIDER_ID,
        .owner_id = MODULE_OWNER_ID,
        .exclusive = true,
        .api_ptr = svc,
        .api_size = @sizeOf(CameraService),
    });

    try app.scheduler.addSystem(.{
        .name = "camera.free_controller",
        .stage = .update,
        .run = freeCameraSystem,
    });
    const has_scene = if (app.services.getService("engine.scene.2d", 1)) |_| true else |_| false;
    try app.scheduler.addSystem(.{
        .name = "camera_update",
        .stage = .post_update,
        .after = if (has_scene) &.{"scene.propagate_local_3d"} else &.{},
        .run = cameraUpdateSystem,
    });
}

fn stopModule(raw_app: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    _ = app.services.unregisterByOwner(MODULE_OWNER_ID);
    _ = app.resources.remove(CameraService);
}

/// Returns the `official.camera` module descriptor.
pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = PROVIDER_ID,
            .version = "0.1.0",
            .provides_capabilities = &.{"engine.camera/1"},
            .required_capabilities = &.{},
        },
        .build = buildModule,
        .stop = stopModule,
    };
}

// ---------------------------------------------------------------------------
// Internal column-major 4x4 matrix & Vec3 helpers
// ---------------------------------------------------------------------------

fn vec3Dot(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn vec3Cross(a: [3]f32, b: [3]f32) [3]f32 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

fn vec3Normalize(v: [3]f32) [3]f32 {
    const len = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (len <= 1e-6) return .{ 0, 0, -1 };
    const inv = 1.0 / len;
    return .{ v[0] * inv, v[1] * inv, v[2] * inv };
}

fn mat4Identity() [16]f32 {
    return .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    };
}

fn mat4Mul(a: [16]f32, b: [16]f32) [16]f32 {
    var out: [16]f32 = undefined;
    for (0..4) |col| {
        for (0..4) |row| {
            out[col * 4 + row] =
                a[0 * 4 + row] * b[col * 4 + 0] +
                a[1 * 4 + row] * b[col * 4 + 1] +
                a[2 * 4 + row] * b[col * 4 + 2] +
                a[3 * 4 + row] * b[col * 4 + 3];
        }
    }
    return out;
}

fn mat4MulVec4(m: [16]f32, v: [4]f32) [4]f32 {
    return .{
        m[0] * v[0] + m[4] * v[1] + m[8] * v[2] + m[12] * v[3],
        m[1] * v[0] + m[5] * v[1] + m[9] * v[2] + m[13] * v[3],
        m[2] * v[0] + m[6] * v[1] + m[10] * v[2] + m[14] * v[3],
        m[3] * v[0] + m[7] * v[1] + m[11] * v[2] + m[15] * v[3],
    };
}

fn mat4Inverse(m: [16]f32) ?[16]f32 {
    var inv: [16]f32 = undefined;
    inv[0] = m[5] * m[10] * m[15] - m[5] * m[11] * m[14] - m[9] * m[6] * m[15] + m[9] * m[7] * m[14] + m[13] * m[6] * m[11] - m[13] * m[7] * m[10];
    inv[4] = -m[4] * m[10] * m[15] + m[4] * m[11] * m[14] + m[8] * m[6] * m[15] - m[8] * m[7] * m[14] - m[12] * m[6] * m[11] + m[12] * m[7] * m[10];
    inv[8] = m[4] * m[9] * m[15] - m[4] * m[11] * m[13] - m[8] * m[5] * m[15] + m[8] * m[7] * m[13] + m[12] * m[5] * m[11] - m[12] * m[7] * m[9];
    inv[12] = -m[4] * m[9] * m[14] + m[4] * m[10] * m[13] + m[8] * m[5] * m[14] - m[8] * m[6] * m[13] - m[12] * m[5] * m[10] + m[12] * m[6] * m[9];
    inv[1] = -m[1] * m[10] * m[15] + m[1] * m[11] * m[14] + m[9] * m[2] * m[15] - m[9] * m[3] * m[14] - m[13] * m[2] * m[11] + m[13] * m[3] * m[10];
    inv[5] = m[0] * m[10] * m[15] - m[0] * m[11] * m[14] - m[8] * m[2] * m[15] + m[8] * m[3] * m[14] + m[12] * m[2] * m[11] - m[12] * m[3] * m[10];
    inv[9] = -m[0] * m[9] * m[15] + m[0] * m[11] * m[13] + m[8] * m[1] * m[15] - m[8] * m[3] * m[13] - m[12] * m[1] * m[11] + m[12] * m[3] * m[9];
    inv[13] = m[0] * m[9] * m[14] - m[0] * m[10] * m[13] - m[8] * m[1] * m[14] + m[8] * m[2] * m[13] + m[12] * m[1] * m[10] - m[12] * m[2] * m[9];
    inv[2] = m[1] * m[6] * m[15] - m[1] * m[7] * m[14] - m[5] * m[2] * m[15] + m[5] * m[3] * m[14] + m[13] * m[2] * m[7] - m[13] * m[3] * m[6];
    inv[6] = -m[0] * m[6] * m[15] + m[0] * m[7] * m[14] + m[4] * m[2] * m[15] - m[4] * m[3] * m[14] - m[12] * m[2] * m[7] + m[12] * m[3] * m[6];
    inv[10] = m[0] * m[5] * m[15] - m[0] * m[7] * m[13] - m[4] * m[1] * m[15] + m[4] * m[3] * m[13] + m[12] * m[1] * m[7] - m[12] * m[3] * m[5];
    inv[14] = -m[0] * m[5] * m[14] + m[0] * m[6] * m[13] + m[4] * m[1] * m[14] - m[4] * m[2] * m[13] - m[12] * m[1] * m[6] + m[12] * m[2] * m[5];
    inv[3] = -m[1] * m[6] * m[11] + m[1] * m[7] * m[10] + m[5] * m[2] * m[11] - m[5] * m[3] * m[10] - m[9] * m[2] * m[7] + m[9] * m[3] * m[6];
    inv[7] = m[0] * m[6] * m[11] - m[0] * m[7] * m[10] - m[4] * m[2] * m[11] + m[4] * m[3] * m[10] + m[8] * m[2] * m[7] - m[8] * m[3] * m[6];
    inv[11] = -m[0] * m[5] * m[11] + m[0] * m[7] * m[9] + m[4] * m[1] * m[11] - m[4] * m[3] * m[9] - m[8] * m[1] * m[7] + m[8] * m[3] * m[5];
    inv[15] = m[0] * m[5] * m[10] - m[0] * m[6] * m[9] - m[4] * m[1] * m[10] + m[4] * m[2] * m[9] + m[8] * m[1] * m[6] - m[8] * m[2] * m[5];

    const det = m[0] * inv[0] + m[1] * inv[4] + m[2] * inv[8] + m[3] * inv[12];
    if (@abs(det) < 1e-8) return null;
    const inv_det = 1.0 / det;
    for (&inv) |*v| v.* *= inv_det;
    return inv;
}
