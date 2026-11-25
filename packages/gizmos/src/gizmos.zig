//! Agnostic 3D Debug & Editor Gizmos (`official.gizmos`).
//!
//! Provides an immediate-mode per-frame 3D line drawing API (`GizmoService`,
//! capability `engine.gizmos/1`) with configurable styling:
//! - `GizmoLineConfig`: `width` (pixel thickness) and `style` (`.solid`, `.dotted`, `.dashed`).
//! - `GizmoArrowConfig`: `style` (`.chevron`, `.cone`, `.diamond`), `tip_length`, `double_ended`.
//! - `pushConfig()` / `popConfig()` stack for per-group or per-call styling.
//! - Depth-tested and X-ray (always-on-top) layers.
//! Runs deterministically headless when no GPU backend is attached.

const std = @import("std");
const engine = @import("engine");
const camera = @import("camera");

/// Pure transform-manipulation math (axis drag, scale); no editor/history dependency.
pub const manipulator = @import("manipulator.zig");

/// Module owner identifier for `official.gizmos`.
pub const MODULE_OWNER_ID: u64 = 2040;

/// Single 3D gizmo line vertex (`28 bytes`, tightly packed for GPU upload).
pub const GizmoVertex = extern struct {
    pos: [3]f32,
    color: [4]f32,
};

/// Line pattern style for gizmos.
pub const GizmoLineStyle = union(enum) {
    solid,
    dotted,
    dashed: struct {
        gap_scale: f32 = 1.5,
        line_scale: f32 = 2.5,
    },
};

/// Line rendering configuration for gizmos.
pub const GizmoLineConfig = struct {
    width: f32 = 2.0,
    style: GizmoLineStyle = .solid,
};

/// Arrowhead geometry style.
pub const ArrowStyle = enum {
    chevron,
    cone,
    diamond,
};

/// Editor transform gizmo mode (`translate`, `rotate`, `scale`).
pub const TransformGizmoMode = enum {
    translate,
    rotate,
    scale,
};

/// Arrowhead configuration for `arrow()` and `axes()`.
pub const GizmoArrowConfig = struct {
    style: ArrowStyle = .cone,
    /// Optional fixed tip length in world units (`null` = `min(len * tip_ratio, 0.35)`).
    tip_length: ?f32 = null,
    tip_ratio: f32 = 0.22,
    tip_width_ratio: f32 = 0.45,
    double_ended: bool = false,
};

/// Per-call override options for `arrowWith()`.
pub const ArrowOptions = struct {
    style: ?ArrowStyle = null,
    tip_length: ?f32 = null,
    double_ended: ?bool = null,
    xray: bool = false,
};

/// Global or scoped configuration for gizmo rendering.
pub const GizmoConfig = struct {
    enabled: bool = true,
    line: GizmoLineConfig = .{},
    arrow: GizmoArrowConfig = .{},
    xray_alpha: f32 = 0.85,
    depth_bias: f32 = 0.0,
};

/// Render parameters passed to `GizmoBackendVTable.submitGizmos`.
pub const GizmoSubmitParams = struct {
    view_proj: [16]f32,
    line_width: f32 = 2.0,
    depth_bias: f32 = 0.0,
};

/// Backend vtable implemented by concrete renderers (e.g. `official.render.3d.gpu`).
pub const GizmoBackendVTable = struct {
    ctx: *anyopaque,
    submitGizmos: *const fn (
        ctx: *anyopaque,
        params: GizmoSubmitParams,
        depth_lines: []const GizmoVertex,
        xray_lines: []const GizmoVertex,
        solid_xray_tris: []const GizmoVertex,
    ) anyerror!void,
};

/// Resource & service (`engine.gizmos/1`) collecting per-frame 3D debug gizmos.
pub const GizmoService = struct {
    allocator: std.mem.Allocator,
    config: GizmoConfig = .{},
    config_stack: std.ArrayList(GizmoConfig) = .empty,
    backend: ?GizmoBackendVTable = null,
    depth_vertices: std.ArrayList(GizmoVertex) = .empty,
    xray_vertices: std.ArrayList(GizmoVertex) = .empty,
    solid_xray_vertices: std.ArrayList(GizmoVertex) = .empty,
    last_frame_depth_vertices: usize = 0,
    last_frame_xray_vertices: usize = 0,

    /// Initializes an empty `GizmoService`.
    pub fn init(allocator: std.mem.Allocator) GizmoService {
        return .{ .allocator = allocator };
    }

    /// Releases queued vertex buffers and config stack.
    pub fn deinit(self: *GizmoService) void {
        self.depth_vertices.deinit(self.allocator);
        self.xray_vertices.deinit(self.allocator);
        self.solid_xray_vertices.deinit(self.allocator);
        self.config_stack.deinit(self.allocator);
        self.depth_vertices = .empty;
        self.xray_vertices = .empty;
        self.solid_xray_vertices = .empty;
        self.config_stack = .empty;
    }

    /// Pushes the current `config` onto a stack and applies `next_config` for subsequent draws.
    pub fn pushConfig(self: *GizmoService, next_config: GizmoConfig) void {
        self.config_stack.append(self.allocator, self.config) catch return;
        self.config = next_config;
    }

    /// Restores the previous `GizmoConfig` pushed via `pushConfig()`.
    pub fn popConfig(self: *GizmoService) void {
        if (self.config_stack.items.len > 0) {
            self.config = self.config_stack.pop().?;
        }
    }

    /// Registers or clears the concrete GPU gizmo backend.
    pub fn setBackend(self: *GizmoService, backend: ?GizmoBackendVTable) void {
        self.backend = backend;
    }

    /// Appends a depth-tested 3D line segment (respecting `config.line.style`).
    pub fn line(self: *GizmoService, start: [3]f32, end: [3]f32, color: [4]f32) void {
        self.emitStyledSegment(start, end, color, false);
    }

    /// Appends an X-ray (always-on-top) 3D line segment (respecting `config.line.style`).
    pub fn lineXray(self: *GizmoService, start: [3]f32, end: [3]f32, color: [4]f32) void {
        const col = [4]f32{ color[0], color[1], color[2], color[3] * self.config.xray_alpha };
        self.emitStyledSegment(start, end, col, true);
    }

    fn emitRawSegment(self: *GizmoService, start: [3]f32, end: [3]f32, color: [4]f32, xray: bool) void {
        const list = if (xray) &self.xray_vertices else &self.depth_vertices;
        list.append(self.allocator, .{ .pos = start, .color = color }) catch return;
        list.append(self.allocator, .{ .pos = end, .color = color }) catch return;
    }

    fn emitStyledSegment(self: *GizmoService, start: [3]f32, end: [3]f32, color: [4]f32, xray: bool) void {
        if (!self.config.enabled) return;
        switch (self.config.line.style) {
            .solid => self.emitRawSegment(start, end, color, xray),
            .dotted => {
                const seg_len = dist3(start, end);
                if (seg_len < 1e-4) return;
                const unit = @max(self.config.line.width * 0.04, 0.06);
                const stride = unit * 2.5;
                const dot_len = unit * 0.85;
                var t: f32 = 0.0;
                var count: usize = 0;
                while (t < seg_len and count < 256) : ({
                    t += stride;
                    count += 1;
                }) {
                    const t0 = t / seg_len;
                    const t1 = @min((t + dot_len) / seg_len, 1.0);
                    self.emitRawSegment(lerp3(start, end, t0), lerp3(start, end, t1), color, xray);
                }
            },
            .dashed => |d| {
                const seg_len = dist3(start, end);
                if (seg_len < 1e-4) return;
                const base = @max(self.config.line.width * 0.05, 0.08);
                const dash_len = @max(d.line_scale, 0.25) * base;
                const gap_len = @max(d.gap_scale, 0.15) * base;
                const stride = dash_len + gap_len;
                var t: f32 = 0.0;
                var count: usize = 0;
                while (t < seg_len and count < 256) : ({
                    t += stride;
                    count += 1;
                }) {
                    const t0 = t / seg_len;
                    const t1 = @min((t + dash_len) / seg_len, 1.0);
                    self.emitRawSegment(lerp3(start, end, t0), lerp3(start, end, t1), color, xray);
                }
            },
        }
    }

    /// Draws a ray starting at `origin` with displacement `vector`.
    pub fn ray(self: *GizmoService, origin: [3]f32, vector: [3]f32, color: [4]f32) void {
        self.line(origin, .{
            origin[0] + vector[0],
            origin[1] + vector[1],
            origin[2] + vector[2],
        }, color);
    }

    /// Draws a depth-tested 3D arrow from `origin` along `vector`.
    pub fn arrow(self: *GizmoService, origin: [3]f32, vector: [3]f32, color: [4]f32) void {
        self.arrowWith(origin, vector, color, .{});
    }

    /// Draws an X-ray (always-on-top) 3D arrow from `origin` along `vector`.
    pub fn arrowXray(self: *GizmoService, origin: [3]f32, vector: [3]f32, color: [4]f32) void {
        self.arrowWith(origin, vector, color, .{ .xray = true });
    }

    /// Draws a 3D arrow with per-call style/tip overrides (falls back to `config.arrow`).
    pub fn arrowWith(self: *GizmoService, origin: [3]f32, vector: [3]f32, color: [4]f32, opts: ArrowOptions) void {
        const tip = [3]f32{
            origin[0] + vector[0],
            origin[1] + vector[1],
            origin[2] + vector[2],
        };
        const xray = opts.xray;
        const draw_col = if (xray) [4]f32{ color[0], color[1], color[2], color[3] * self.config.xray_alpha } else color;
        self.emitStyledSegment(origin, tip, draw_col, xray);

        const len = @sqrt(vector[0] * vector[0] + vector[1] * vector[1] + vector[2] * vector[2]);
        if (len < 1e-5) return;
        const dir = [3]f32{ vector[0] / len, vector[1] / len, vector[2] / len };
        const style = opts.style orelse self.config.arrow.style;
        const head_len = opts.tip_length orelse (self.config.arrow.tip_length orelse @min(len * self.config.arrow.tip_ratio, 0.35));
        const head_w = head_len * self.config.arrow.tip_width_ratio;
        const double_ended = opts.double_ended orelse self.config.arrow.double_ended;

        self.emitArrowHead(tip, dir, head_len, head_w, style, draw_col, xray);
        if (double_ended) {
            self.emitArrowHead(origin, .{ -dir[0], -dir[1], -dir[2] }, head_len, head_w, style, draw_col, xray);
        }
    }

    fn emitArrowHead(
        self: *GizmoService,
        tip: [3]f32,
        dir: [3]f32,
        head_len: f32,
        head_w: f32,
        style: ArrowStyle,
        col: [4]f32,
        xray: bool,
    ) void {
        const up: [3]f32 = if (@abs(dir[1]) < 0.9) .{ 0, 1, 0 } else .{ 1, 0, 0 };
        const right = normalize3(cross3(dir, up));
        const ortho = cross3(right, dir);
        const base = [3]f32{
            tip[0] - dir[0] * head_len,
            tip[1] - dir[1] * head_len,
            tip[2] - dir[2] * head_len,
        };
        const offsets = [4][3]f32{
            .{ right[0] * head_w, right[1] * head_w, right[2] * head_w },
            .{ -right[0] * head_w, -right[1] * head_w, -right[2] * head_w },
            .{ ortho[0] * head_w, ortho[1] * head_w, ortho[2] * head_w },
            .{ -ortho[0] * head_w, -ortho[1] * head_w, -ortho[2] * head_w },
        };

        switch (style) {
            .chevron => {
                for (offsets) |o| {
                    self.emitRawSegment(tip, .{ base[0] + o[0], base[1] + o[1], base[2] + o[2] }, col, xray);
                }
            },
            .cone => {
                const segs: usize = 8;
                const step = (2.0 * std.math.pi) / @as(f32, @floatFromInt(segs));
                var prev = [3]f32{ base[0] + right[0] * head_w, base[1] + right[1] * head_w, base[2] + right[2] * head_w };
                for (1..segs + 1) |i| {
                    const ang = @as(f32, @floatFromInt(i)) * step;
                    const ca = @cos(ang) * head_w;
                    const sa = @sin(ang) * head_w;
                    const next = [3]f32{
                        base[0] + right[0] * ca + ortho[0] * sa,
                        base[1] + right[1] * ca + ortho[1] * sa,
                        base[2] + right[2] * ca + ortho[2] * sa,
                    };
                    self.emitRawSegment(tip, next, col, xray);
                    self.emitRawSegment(prev, next, col, xray);
                    prev = next;
                }
            },
            .diamond => {
                const tail = [3]f32{
                    tip[0] - dir[0] * (head_len * 1.6),
                    tip[1] - dir[1] * (head_len * 1.6),
                    tip[2] - dir[2] * (head_len * 1.6),
                };
                for (offsets) |o| {
                    const p = [3]f32{ base[0] + o[0], base[1] + o[1], base[2] + o[2] };
                    self.emitRawSegment(tip, p, col, xray);
                    self.emitRawSegment(tail, p, col, xray);
                }
            },
        }
    }

    /// Draws an axis-aligned wireframe cuboid centered at `center` with full `size`.
    pub fn cuboid(self: *GizmoService, center: [3]f32, size: [3]f32, color: [4]f32) void {
        self.cuboidInternal(center, size, color, false);
    }

    /// Draws an X-ray (always-on-top) wireframe cuboid centered at `center` with full `size`.
    pub fn cuboidXray(self: *GizmoService, center: [3]f32, size: [3]f32, color: [4]f32) void {
        const col = [4]f32{ color[0], color[1], color[2], color[3] * self.config.xray_alpha };
        self.cuboidInternal(center, size, col, true);
    }

    fn cuboidInternal(self: *GizmoService, center: [3]f32, size: [3]f32, color: [4]f32, xray: bool) void {
        const hx = size[0] * 0.5;
        const hy = size[1] * 0.5;
        const hz = size[2] * 0.5;
        const c = center;
        const p000 = [3]f32{ c[0] - hx, c[1] - hy, c[2] - hz };
        const p100 = [3]f32{ c[0] + hx, c[1] - hy, c[2] - hz };
        const p010 = [3]f32{ c[0] - hx, c[1] + hy, c[2] - hz };
        const p110 = [3]f32{ c[0] + hx, c[1] + hy, c[2] - hz };
        const p001 = [3]f32{ c[0] - hx, c[1] - hy, c[2] + hz };
        const p101 = [3]f32{ c[0] + hx, c[1] - hy, c[2] + hz };
        const p011 = [3]f32{ c[0] - hx, c[1] + hy, c[2] + hz };
        const p111 = [3]f32{ c[0] + hx, c[1] + hy, c[2] + hz };

        self.emitStyledSegment(p000, p100, color, xray);
        self.emitStyledSegment(p100, p110, color, xray);
        self.emitStyledSegment(p110, p010, color, xray);
        self.emitStyledSegment(p010, p000, color, xray);

        self.emitStyledSegment(p001, p101, color, xray);
        self.emitStyledSegment(p101, p111, color, xray);
        self.emitStyledSegment(p111, p011, color, xray);
        self.emitStyledSegment(p011, p001, color, xray);

        self.emitStyledSegment(p000, p001, color, xray);
        self.emitStyledSegment(p100, p101, color, xray);
        self.emitStyledSegment(p110, p111, color, xray);
        self.emitStyledSegment(p010, p011, color, xray);
    }

    /// Draws a 3D rounded wireframe cuboid with beveled/curved corner arcs.
    pub fn roundedCuboid(self: *GizmoService, center: [3]f32, size: [3]f32, radius: f32, color: [4]f32) void {
        const r = @min(radius, @min(size[0], @min(size[1], size[2])) * 0.45);
        const hx = size[0] * 0.5 - r;
        const hy = size[1] * 0.5 - r;
        const hz = size[2] * 0.5 - r;
        const ox = size[0] * 0.5;
        const oy = size[1] * 0.5;
        const oz = size[2] * 0.5;
        const c = center;

        // 24 straight face-border edges around the 6 flat faces.
        const sx = [2]f32{ -1, 1 };
        for (sx) |s1| {
            for (sx) |s2| {
                // Edges along X
                self.line(.{ c[0] - hx, c[1] + s1 * oy, c[2] + s2 * hz }, .{ c[0] + hx, c[1] + s1 * oy, c[2] + s2 * hz }, color);
                self.line(.{ c[0] - hx, c[1] + s1 * hy, c[2] + s2 * oz }, .{ c[0] + hx, c[1] + s1 * hy, c[2] + s2 * oz }, color);
                // Edges along Y
                self.line(.{ c[0] + s1 * ox, c[1] - hy, c[2] + s2 * hz }, .{ c[0] + s1 * ox, c[1] + hy, c[2] + s2 * hz }, color);
                self.line(.{ c[0] + s1 * hx, c[1] - hy, c[2] + s2 * oz }, .{ c[0] + s1 * hx, c[1] + hy, c[2] + s2 * oz }, color);
                // Edges along Z
                self.line(.{ c[0] + s1 * ox, c[1] + s2 * hy, c[2] - hz }, .{ c[0] + s1 * ox, c[1] + s2 * hy, c[2] + hz }, color);
                self.line(.{ c[0] + s1 * hx, c[1] + s2 * oy, c[2] - hz }, .{ c[0] + s1 * hx, c[1] + s2 * oy, c[2] + hz }, color);
            }
        }
        // 8 corner quarter-arc triplets.
        for (sx) |ix| {
            for (sx) |iy| {
                for (sx) |iz| {
                    const corner = [3]f32{ c[0] + ix * hx, c[1] + iy * hy, c[2] + iz * hz };
                    self.quarterArc(corner, .{ ix, 0, 0 }, .{ 0, iy, 0 }, r, 6, color);
                    self.quarterArc(corner, .{ ix, 0, 0 }, .{ 0, 0, iz }, r, 6, color);
                    self.quarterArc(corner, .{ 0, iy, 0 }, .{ 0, 0, iz }, r, 6, color);
                }
            }
        }
    }

    fn quarterArc(self: *GizmoService, origin: [3]f32, u: [3]f32, v: [3]f32, radius: f32, segs: u32, color: [4]f32) void {
        const step = (std.math.pi * 0.5) / @as(f32, @floatFromInt(segs));
        var prev = [3]f32{ origin[0] + u[0] * radius, origin[1] + u[1] * radius, origin[2] + u[2] * radius };
        for (1..segs + 1) |i| {
            const ang = @as(f32, @floatFromInt(i)) * step;
            const ca = @cos(ang) * radius;
            const sa = @sin(ang) * radius;
            const next = [3]f32{
                origin[0] + u[0] * ca + v[0] * sa,
                origin[1] + u[1] * ca + v[1] * sa,
                origin[2] + u[2] * ca + v[2] * sa,
            };
            self.line(prev, next, color);
            prev = next;
        }
    }

    /// Draws an X-ray solid filled cone at `tip` pointing along `dir`.
    pub fn coneSolidXray(self: *GizmoService, tip: [3]f32, dir: [3]f32, length: f32, radius: f32, segments: u32, color: [4]f32) void {
        if (!self.config.enabled) return;
        const col = [4]f32{ color[0], color[1], color[2], color[3] * self.config.xray_alpha };
        const d = normalize3(dir);
        const up: [3]f32 = if (@abs(d[1]) < 0.9) .{ 0, 1, 0 } else .{ 1, 0, 0 };
        const right = normalize3(cross3(d, up));
        const ortho = cross3(right, d);
        const base = [3]f32{ tip[0] - d[0] * length, tip[1] - d[1] * length, tip[2] - d[2] * length };
        const segs = @max(segments, 6);
        const step = (2.0 * std.math.pi) / @as(f32, @floatFromInt(segs));
        var prev = [3]f32{ base[0] + right[0] * radius, base[1] + right[1] * radius, base[2] + right[2] * radius };
        for (1..segs + 1) |i| {
            const ang = @as(f32, @floatFromInt(i)) * step;
            const ca = @cos(ang) * radius;
            const sa = @sin(ang) * radius;
            const next = [3]f32{
                base[0] + right[0] * ca + ortho[0] * sa,
                base[1] + right[1] * ca + ortho[1] * sa,
                base[2] + right[2] * ca + ortho[2] * sa,
            };
            self.solid_xray_vertices.appendSlice(self.allocator, &.{
                .{ .pos = tip, .color = col },
                .{ .pos = prev, .color = col },
                .{ .pos = next, .color = col },
                .{ .pos = base, .color = col },
                .{ .pos = next, .color = col },
                .{ .pos = prev, .color = col },
            }) catch return;
            prev = next;
        }
    }

    /// Draws an X-ray solid filled cuboid centered at `center` with full `size`.
    pub fn cuboidSolidXray(self: *GizmoService, center: [3]f32, size: [3]f32, color: [4]f32) void {
        if (!self.config.enabled) return;
        const col = [4]f32{ color[0], color[1], color[2], color[3] * self.config.xray_alpha };
        const hx = size[0] * 0.5;
        const hy = size[1] * 0.5;
        const hz = size[2] * 0.5;
        const c = center;
        const v = [8][3]f32{
            .{ c[0] - hx, c[1] - hy, c[2] - hz },
            .{ c[0] + hx, c[1] - hy, c[2] - hz },
            .{ c[0] + hx, c[1] + hy, c[2] - hz },
            .{ c[0] - hx, c[1] + hy, c[2] - hz },
            .{ c[0] - hx, c[1] - hy, c[2] + hz },
            .{ c[0] + hx, c[1] - hy, c[2] + hz },
            .{ c[0] + hx, c[1] + hy, c[2] + hz },
            .{ c[0] - hx, c[1] + hy, c[2] + hz },
        };
        const tris = [12][3]usize{
            .{ 0, 1, 2 }, .{ 0, 2, 3 }, // -Z
            .{ 5, 4, 7 }, .{ 5, 7, 6 }, // +Z
            .{ 4, 0, 3 }, .{ 4, 3, 7 }, // -X
            .{ 1, 5, 6 }, .{ 1, 6, 2 }, // +X
            .{ 4, 5, 1 }, .{ 4, 1, 0 }, // -Y
            .{ 3, 2, 6 }, .{ 3, 6, 7 }, // +Y
        };
        for (tris) |tri| {
            self.solid_xray_vertices.append(self.allocator, .{ .pos = v[tri[0]], .color = col }) catch return;
            self.solid_xray_vertices.append(self.allocator, .{ .pos = v[tri[1]], .color = col }) catch return;
            self.solid_xray_vertices.append(self.allocator, .{ .pos = v[tri[2]], .color = col }) catch return;
        }
    }

    /// Draws an interactive editor transform gizmo (`translate` arrows, `rotate` rings, or `scale` solid cube-tipped handles).
    /// `active_axis`: `0=none, 1=X, 2=Y, 3=Z`.
    pub fn transformGizmo(self: *GizmoService, center: [3]f32, mode: TransformGizmoMode, size: f32, active_axis: u8) void {
        const x_col: [4]f32 = if (active_axis == 1) .{ 1.0, 1.0, 0.2, 1.0 } else .{ 1.0, 0.2, 0.2, 1.0 };
        const y_col: [4]f32 = if (active_axis == 2) .{ 1.0, 1.0, 0.2, 1.0 } else .{ 0.2, 1.0, 0.2, 1.0 };
        const z_col: [4]f32 = if (active_axis == 3) .{ 1.0, 1.0, 0.2, 1.0 } else .{ 0.2, 0.5, 1.0, 1.0 };
        switch (mode) {
            .translate => {
                if (self.config.arrow.style == .cone) {
                    const tip_l = size * 0.18;
                    const tip_r = tip_l * 0.36;
                    self.lineXray(center, .{ center[0] + size - tip_l, center[1], center[2] }, x_col);
                    self.coneSolidXray(.{ center[0] + size, center[1], center[2] }, .{ 1, 0, 0 }, tip_l, tip_r, 14, x_col);
                    self.lineXray(center, .{ center[0], center[1] + size - tip_l, center[2] }, y_col);
                    self.coneSolidXray(.{ center[0], center[1] + size, center[2] }, .{ 0, 1, 0 }, tip_l, tip_r, 14, y_col);
                    self.lineXray(center, .{ center[0], center[1], center[2] + size - tip_l }, z_col);
                    self.coneSolidXray(.{ center[0], center[1], center[2] + size }, .{ 0, 0, 1 }, tip_l, tip_r, 14, z_col);
                } else {
                    self.arrowXray(center, .{ size, 0, 0 }, x_col);
                    self.arrowXray(center, .{ 0, size, 0 }, y_col);
                    self.arrowXray(center, .{ 0, 0, size }, z_col);
                }
            },
            .rotate => {
                self.circleXray(center, .{ 1, 0, 0 }, size * 0.85, 40, x_col);
                self.circleXray(center, .{ 0, 1, 0 }, size * 0.85, 40, y_col);
                self.circleXray(center, .{ 0, 0, 1 }, size * 0.85, 40, z_col);
            },
            .scale => {
                const tip = size * 0.10;
                self.lineXray(center, .{ center[0] + size, center[1], center[2] }, x_col);
                self.cuboidSolidXray(.{ center[0] + size, center[1], center[2] }, .{ tip, tip, tip }, x_col);
                self.lineXray(center, .{ center[0], center[1] + size, center[2] }, y_col);
                self.cuboidSolidXray(.{ center[0], center[1] + size, center[2] }, .{ tip, tip, tip }, y_col);
                self.lineXray(center, .{ center[0], center[1], center[2] + size }, z_col);
                self.cuboidSolidXray(.{ center[0], center[1], center[2] + size }, .{ tip, tip, tip }, z_col);
                self.cuboidSolidXray(center, .{ tip * 1.15, tip * 1.15, tip * 1.15 }, .{ 0.95, 0.95, 0.95, 1.0 });
            },
        }
    }

    /// Draws RGB X/Y/Z coordinate axes at `origin` with length `scale`.
    pub fn axes(self: *GizmoService, origin: [3]f32, scale: f32) void {
        self.arrow(origin, .{ scale, 0, 0 }, .{ 1.0, 0.2, 0.2, 1.0 });
        self.arrow(origin, .{ 0, scale, 0 }, .{ 0.2, 1.0, 0.2, 1.0 });
        self.arrow(origin, .{ 0, 0, scale }, .{ 0.2, 0.5, 1.0, 1.0 });
    }

    /// Draws a depth-tested 3D circle in the plane perpendicular to `normal`.
    pub fn circle(self: *GizmoService, center: [3]f32, normal: [3]f32, radius: f32, segments: u32, color: [4]f32) void {
        self.circleInternal(center, normal, radius, segments, color, false);
    }

    /// Draws an X-ray (always-on-top) 3D circle in the plane perpendicular to `normal`.
    pub fn circleXray(self: *GizmoService, center: [3]f32, normal: [3]f32, radius: f32, segments: u32, color: [4]f32) void {
        const col = [4]f32{ color[0], color[1], color[2], color[3] * self.config.xray_alpha };
        self.circleInternal(center, normal, radius, segments, col, true);
    }

    fn circleInternal(self: *GizmoService, center: [3]f32, normal: [3]f32, radius: f32, segments: u32, color: [4]f32, xray: bool) void {
        const segs = @max(segments, 6);
        const n = normalize3(normal);
        const ref: [3]f32 = if (@abs(n[1]) < 0.9) .{ 0, 1, 0 } else .{ 1, 0, 0 };
        const u = normalize3(cross3(n, ref));
        const v = cross3(n, u);

        const step = (2.0 * std.math.pi) / @as(f32, @floatFromInt(segs));
        var prev = [3]f32{ center[0] + u[0] * radius, center[1] + u[1] * radius, center[2] + u[2] * radius };
        for (1..segs + 1) |i| {
            const ang = @as(f32, @floatFromInt(i)) * step;
            const ca = @cos(ang) * radius;
            const sa = @sin(ang) * radius;
            const next = [3]f32{
                center[0] + u[0] * ca + v[0] * sa,
                center[1] + u[1] * ca + v[1] * sa,
                center[2] + u[2] * ca + v[2] * sa,
            };
            self.emitStyledSegment(prev, next, color, xray);
            prev = next;
        }
    }

    /// Draws a wireframe sphere (3 orthogonal great circles).
    pub fn sphere(self: *GizmoService, center: [3]f32, radius: f32, segments: u32, color: [4]f32) void {
        self.circle(center, .{ 1, 0, 0 }, radius, segments, color);
        self.circle(center, .{ 0, 1, 0 }, radius, segments, color);
        self.circle(center, .{ 0, 0, 1 }, radius, segments, color);
    }

    /// Draws a 3D wireframe rectangle centered at `center` perpendicular to `normal`.
    pub fn rect(self: *GizmoService, center: [3]f32, normal: [3]f32, size: [2]f32, color: [4]f32) void {
        const n = normalize3(normal);
        const ref: [3]f32 = if (@abs(n[1]) < 0.9) .{ 0, 1, 0 } else .{ 1, 0, 0 };
        const u = normalize3(cross3(n, ref));
        const v = cross3(n, u);
        const hx = size[0] * 0.5;
        const hy = size[1] * 0.5;
        const p0 = [3]f32{ center[0] - u[0] * hx - v[0] * hy, center[1] - u[1] * hx - v[1] * hy, center[2] - u[2] * hx - v[2] * hy };
        const p1 = [3]f32{ center[0] + u[0] * hx - v[0] * hy, center[1] + u[1] * hx - v[1] * hy, center[2] + u[2] * hx - v[2] * hy };
        const p2 = [3]f32{ center[0] + u[0] * hx + v[0] * hy, center[1] + u[1] * hx + v[1] * hy, center[2] + u[2] * hx + v[2] * hy };
        const p3 = [3]f32{ center[0] - u[0] * hx + v[0] * hy, center[1] - u[1] * hx + v[1] * hy, center[2] - u[2] * hx + v[2] * hy };
        self.line(p0, p1, color);
        self.line(p1, p2, color);
        self.line(p2, p3, color);
        self.line(p3, p0, color);
    }

    /// Draws a 3D cross (`+` along X/Y/Z) centered at `center` with half-extent `size`.
    pub fn cross(self: *GizmoService, center: [3]f32, size: f32, color: [4]f32) void {
        self.line(.{ center[0] - size, center[1], center[2] }, .{ center[0] + size, center[1], center[2] }, color);
        self.line(.{ center[0], center[1] - size, center[2] }, .{ center[0], center[1] + size, center[2] }, color);
        self.line(.{ center[0], center[1], center[2] - size }, .{ center[0], center[1], center[2] + size }, color);
    }

    /// Draws a tilted/oriented 3D grid centered at `center` perpendicular to `normal`.
    pub fn gridOriented(self: *GizmoService, center: [3]f32, normal: [3]f32, cell_count: [2]u32, spacing: [2]f32, color: [4]f32) void {
        const nx = @max(cell_count[0], 1);
        const ny = @max(cell_count[1], 1);
        const n = normalize3(normal);
        const ref: [3]f32 = if (@abs(n[1]) < 0.9) .{ 0, 1, 0 } else .{ 1, 0, 0 };
        const u = normalize3(cross3(n, ref));
        const v = cross3(n, u);
        const hw = @as(f32, @floatFromInt(nx)) * spacing[0] * 0.5;
        const hh = @as(f32, @floatFromInt(ny)) * spacing[1] * 0.5;

        for (0..nx + 1) |ix| {
            const x = -hw + @as(f32, @floatFromInt(ix)) * spacing[0];
            const a = [3]f32{ center[0] + u[0] * x - v[0] * hh, center[1] + u[1] * x - v[1] * hh, center[2] + u[2] * x - v[2] * hh };
            const b = [3]f32{ center[0] + u[0] * x + v[0] * hh, center[1] + u[1] * x + v[1] * hh, center[2] + u[2] * x + v[2] * hh };
            self.line(a, b, color);
        }
        for (0..ny + 1) |iy| {
            const y = -hh + @as(f32, @floatFromInt(iy)) * spacing[1];
            const a = [3]f32{ center[0] - u[0] * hw + v[0] * y, center[1] - u[1] * hw + v[1] * y, center[2] - u[2] * hw + v[2] * y };
            const b = [3]f32{ center[0] + u[0] * hw + v[0] * y, center[1] + u[1] * hw + v[1] * y, center[2] + u[2] * hw + v[2] * y };
            self.line(a, b, color);
        }
    }

    /// Draws an XZ ground grid centered at `center`.
    pub fn grid(self: *GizmoService, center: [3]f32, cell_count: [2]u32, spacing: [2]f32, color: [4]f32) void {
        const nx = @max(cell_count[0], 1);
        const nz = @max(cell_count[1], 1);
        const half_w = @as(f32, @floatFromInt(nx)) * spacing[0] * 0.5;
        const half_d = @as(f32, @floatFromInt(nz)) * spacing[1] * 0.5;

        for (0..nx + 1) |ix| {
            const x = center[0] - half_w + @as(f32, @floatFromInt(ix)) * spacing[0];
            self.line(.{ x, center[1], center[2] - half_d }, .{ x, center[1], center[2] + half_d }, color);
        }
        for (0..nz + 1) |iz| {
            const z = center[2] - half_d + @as(f32, @floatFromInt(iz)) * spacing[1];
            self.line(.{ center[0] - half_w, center[1], z }, .{ center[0] + half_w, center[1], z }, color);
        }
    }
};

fn dist3(a: [3]f32, b: [3]f32) f32 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const dz = b[2] - a[2];
    return @sqrt(dx * dx + dy * dy + dz * dz);
}

fn lerp3(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    return .{
        a[0] + (b[0] - a[0]) * t,
        a[1] + (b[1] - a[1]) * t,
        a[2] + (b[2] - a[2]) * t,
    };
}

fn cross3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

fn normalize3(v: [3]f32) [3]f32 {
    const len = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (len < 1e-6) return .{ 0, 1, 0 };
    return .{ v[0] / len, v[1] / len, v[2] / len };
}

fn extractGizmosSystem(ctx: *engine.SystemContext) !void {
    const svc = ctx.resources.get(GizmoService) orelse return;
    defer {
        svc.last_frame_depth_vertices = svc.depth_vertices.items.len;
        svc.last_frame_xray_vertices = svc.xray_vertices.items.len + svc.solid_xray_vertices.items.len;
        svc.depth_vertices.clearRetainingCapacity();
        svc.xray_vertices.clearRetainingCapacity();
        svc.solid_xray_vertices.clearRetainingCapacity();
    }

    if (!svc.config.enabled) return;
    if (svc.depth_vertices.items.len == 0 and svc.xray_vertices.items.len == 0 and svc.solid_xray_vertices.items.len == 0) return;

    const be = svc.backend orelse return;
    const cam_svc = ctx.resources.get(camera.CameraService) orelse return;
    const active = cam_svc.sortedActiveCameras();
    if (active.len == 0) return;
    const vp = active[active.len - 1].computed.clip_from_world;

    try be.submitGizmos(be.ctx, .{
        .view_proj = vp,
        .line_width = svc.config.line.width,
        .depth_bias = svc.config.depth_bias,
    }, svc.depth_vertices.items, svc.xray_vertices.items, svc.solid_xray_vertices.items);
}

fn buildGizmosModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    if (!app.resources.contains(GizmoService)) {
        try app.resources.insert(GizmoService, GizmoService.init(app.allocator));
    }
    const svc = app.resources.get(GizmoService).?;
    try app.services.register(.{
        .capability = "engine.gizmos",
        .major_version = 1,
        .provider_id = "official.gizmos",
        .owner_id = MODULE_OWNER_ID,
        .exclusive = true,
        .api_ptr = svc,
        .api_size = @sizeOf(GizmoService),
    });
    try app.addSystem(.{
        .name = "gizmos.extract",
        .stage = .render_extract,
        .run = extractGizmosSystem,
    });
}

fn stopGizmosModule(raw_app: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    _ = app.services.unregisterByOwner(MODULE_OWNER_ID);
    if (app.resources.get(GizmoService)) |svc| {
        svc.deinit();
    }
    _ = app.resources.remove(GizmoService);
}

/// Returns the `official.gizmos` module providing `engine.gizmos/1`.
pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = "official.gizmos",
            .version = "0.1.0",
            .provides_capabilities = &.{"engine.gizmos/1"},
            .required_capabilities = &.{"engine.camera/1"},
        },
        .build = buildGizmosModule,
        .stop = stopGizmosModule,
    };
}
