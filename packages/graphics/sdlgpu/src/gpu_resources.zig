//! Pure-Zig GPU Resource Handles and Vertex Batching Helpers (`packages/graphics/sdlgpu`).
//!
//! Kept free of SDL C imports so generational handle lifecycles and vertex packing
//! can be unit-tested on any platform (including headless CI).

const std = @import("std");
const graphics = @import("graphics");

pub const GpuBufferHandle = packed struct(u64) {
    index: u32,
    generation: u32,
};

pub const GpuPipelineHandle = packed struct(u64) {
    index: u32,
    generation: u32,
};

pub const GpuShaderHandle = packed struct(u64) {
    index: u32,
    generation: u32,
};

pub const GpuTextureHandle = packed struct(u64) {
    index: u32,
    generation: u32,
};

pub const GpuMeshHandle = packed struct(u64) {
    index: u32,
    generation: u32,
};

pub const MeshUniforms = extern struct {
    mvp: [16]f32,
    base_color: [4]f32,
};

/// Vertex layout matching `shaders/pos_color.vert`:
/// - location 0: `vec2 in_pos` (8 bytes)
/// - location 1: `vec4 in_color` (16 bytes)
pub const Vertex2D = extern struct {
    x: f32,
    y: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

/// Uniform block matching `FrameUniforms` in `shaders/pos_color.vert` (std140, 16 bytes).
pub const FrameUniforms = extern struct {
    viewport_w: f32,
    viewport_h: f32,
    use_pixel_coords: f32,
    _pad: f32 = 0.0,
};

/// Generational slot pool for GPU resource handles.
/// Ensures stale handles cannot alias newly allocated slots after destruction.
pub fn GenerationalPool(comptime T: type, comptime Handle: type) type {
    return struct {
        const Self = @This();

        const Slot = struct {
            value: T,
            generation: u32,
            alive: bool,
        };

        allocator: std.mem.Allocator,
        slots: std.ArrayList(Slot),

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .slots = .empty,
            };
        }

        pub fn deinit(self: *Self) void {
            self.slots.deinit(self.allocator);
        }

        pub fn insert(self: *Self, value: T) !Handle {
            for (self.slots.items, 0..) |*slot, i| {
                if (!slot.alive) {
                    const gen = if (slot.generation == 0) @as(u32, 1) else slot.generation;
                    slot.* = .{
                        .value = value,
                        .generation = gen,
                        .alive = true,
                    };
                    return .{ .index = @intCast(i), .generation = gen };
                }
            }
            const idx: u32 = @intCast(self.slots.items.len);
            try self.slots.append(self.allocator, .{
                .value = value,
                .generation = 1,
                .alive = true,
            });
            return .{ .index = idx, .generation = 1 };
        }

        pub fn get(self: *const Self, handle: Handle) ?T {
            if (handle.index >= self.slots.items.len) return null;
            const slot = &self.slots.items[handle.index];
            if (!slot.alive or slot.generation != handle.generation) return null;
            return slot.value;
        }

        pub fn remove(self: *Self, handle: Handle) ?T {
            if (handle.index >= self.slots.items.len) return null;
            const slot = &self.slots.items[handle.index];
            if (!slot.alive or slot.generation != handle.generation) return null;
            const val = slot.value;
            slot.alive = false;
            slot.generation +%= 1;
            return val;
        }

        pub fn aliveCount(self: *const Self) usize {
            var count: usize = 0;
            for (self.slots.items) |slot| {
                if (slot.alive) count += 1;
            }
            return count;
        }
    };
}

/// Appends 6 vertices (2 CCW triangles) representing a solid rectangle.
pub fn appendRectVertices(
    list: *std.ArrayList(Vertex2D),
    allocator: std.mem.Allocator,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    color: graphics.Color,
) !void {
    const x1 = x + w;
    const y1 = y + h;
    try list.appendSlice(allocator, &.{
        .{ .x = x, .y = y, .r = color.r, .g = color.g, .b = color.b, .a = color.a },
        .{ .x = x1, .y = y, .r = color.r, .g = color.g, .b = color.b, .a = color.a },
        .{ .x = x1, .y = y1, .r = color.r, .g = color.g, .b = color.b, .a = color.a },
        .{ .x = x, .y = y, .r = color.r, .g = color.g, .b = color.b, .a = color.a },
        .{ .x = x1, .y = y1, .r = color.r, .g = color.g, .b = color.b, .a = color.a },
        .{ .x = x, .y = y1, .r = color.r, .g = color.g, .b = color.b, .a = color.a },
    });
}

/// Vertex layout matching `shaders/textured.vert`:
/// - location 0: `vec2 in_pos` (8 bytes)
/// - location 1: `vec2 in_uv` (8 bytes)
/// - location 2: `vec4 in_color` (16 bytes)
pub const Vertex2DTextured = extern struct {
    x: f32,
    y: f32,
    u: f32,
    v: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

/// Uniform block matching `TexturedUniforms` in `shaders/textured.vert` (std140, 16 bytes).
pub const TexturedUniforms = extern struct {
    viewport_w: f32,
    viewport_h: f32,
    _pad0: f32 = 0.0,
    _pad1: f32 = 0.0,
};

pub const ScissorRect = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,

    pub fn eql(a: ?ScissorRect, b: ?ScissorRect) bool {
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        const sa = a.?;
        const sb = b.?;
        return sa.x == sb.x and sa.y == sb.y and sa.w == sb.w and sa.h == sb.h;
    }
};

pub const TexturedQuad = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    rotation_rad: f32 = 0.0,
    u0: f32 = 0.0,
    v0: f32 = 0.0,
    u1: f32 = 1.0,
    v1: f32 = 1.0,
    color: graphics.Color = .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 },
    texture: GpuTextureHandle = .{ .index = 0, .generation = 1 },
    scissor: ?ScissorRect = null,
};

/// Appends 6 vertices (2 triangles) for a textured, optionally rotated quad.
pub fn appendTexturedQuadVertices(
    list: *std.ArrayList(Vertex2DTextured),
    allocator: std.mem.Allocator,
    q: TexturedQuad,
) !void {
    const cx = q.x + q.width * 0.5;
    const cy = q.y + q.height * 0.5;
    const hw = q.width * 0.5;
    const hh = q.height * 0.5;

    var p0x: f32 = q.x;
    var p0y: f32 = q.y;
    var p1x: f32 = q.x + q.width;
    var p1y: f32 = q.y;
    var p2x: f32 = q.x + q.width;
    var p2y: f32 = q.y + q.height;
    var p3x: f32 = q.x;
    var p3y: f32 = q.y + q.height;

    if (q.rotation_rad != 0.0) {
        const c = @cos(q.rotation_rad);
        const s = @sin(q.rotation_rad);
        p0x = cx + (-hw * c - (-hh) * s);
        p0y = cy + (-hw * s + (-hh) * c);
        p1x = cx + (hw * c - (-hh) * s);
        p1y = cy + (hw * s + (-hh) * c);
        p2x = cx + (hw * c - hh * s);
        p2y = cy + (hw * s + hh * c);
        p3x = cx + (-hw * c - hh * s);
        p3y = cy + (-hw * s + hh * c);
    }

    const col = q.color;
    try list.appendSlice(allocator, &.{
        .{ .x = p0x, .y = p0y, .u = q.u0, .v = q.v0, .r = col.r, .g = col.g, .b = col.b, .a = col.a },
        .{ .x = p1x, .y = p1y, .u = q.u1, .v = q.v0, .r = col.r, .g = col.g, .b = col.b, .a = col.a },
        .{ .x = p2x, .y = p2y, .u = q.u1, .v = q.v1, .r = col.r, .g = col.g, .b = col.b, .a = col.a },
        .{ .x = p0x, .y = p0y, .u = q.u0, .v = q.v0, .r = col.r, .g = col.g, .b = col.b, .a = col.a },
        .{ .x = p2x, .y = p2y, .u = q.u1, .v = q.v1, .r = col.r, .g = col.g, .b = col.b, .a = col.a },
        .{ .x = p3x, .y = p3y, .u = q.u0, .v = q.v1, .r = col.r, .g = col.g, .b = col.b, .a = col.a },
    });
}

fn pushTri(
    list: *std.ArrayList(Vertex2DTextured),
    allocator: std.mem.Allocator,
    x0: f32,
    y0: f32,
    c0: graphics.Color,
    x1: f32,
    y1: f32,
    c1: graphics.Color,
    x2: f32,
    y2: f32,
    c2: graphics.Color,
) !void {
    try list.appendSlice(allocator, &.{
        .{ .x = x0, .y = y0, .u = 0.5, .v = 0.5, .r = c0.r, .g = c0.g, .b = c0.b, .a = c0.a },
        .{ .x = x1, .y = y1, .u = 0.5, .v = 0.5, .r = c1.r, .g = c1.g, .b = c1.b, .a = c1.a },
        .{ .x = x2, .y = y2, .u = 0.5, .v = 0.5, .r = c2.r, .g = c2.g, .b = c2.b, .a = c2.a },
    });
}

fn pushSolidQuad(
    list: *std.ArrayList(Vertex2DTextured),
    allocator: std.mem.Allocator,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    col: graphics.Color,
) !void {
    if (w <= 0.0 or h <= 0.0 or col.a <= 0.0) return;
    try pushTri(list, allocator, x, y, col, x + w, y, col, x + w, y + h, col);
    try pushTri(list, allocator, x, y, col, x + w, y + h, col, x, y + h, col);
}

fn pushLineSeg(
    list: *std.ArrayList(Vertex2DTextured),
    allocator: std.mem.Allocator,
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    thickness: f32,
    col: graphics.Color,
) !void {
    const dx = x1 - x0;
    const dy = y1 - y0;
    const len = @sqrt(dx * dx + dy * dy);
    if (len <= 0.0001) return;
    const nx = (-dy / len) * (thickness * 0.5);
    const ny = (dx / len) * (thickness * 0.5);
    try pushTri(list, allocator, x0 + nx, y0 + ny, col, x1 + nx, y1 + ny, col, x1 - nx, y1 - ny, col);
    try pushTri(list, allocator, x0 + nx, y0 + ny, col, x1 - nx, y1 - ny, col, x0 - nx, y0 - ny, col);
}

fn lerpColor(a: graphics.Color, b: graphics.Color, t: f32) graphics.Color {
    return .{
        .r = a.r + (b.r - a.r) * t,
        .g = a.g + (b.g - a.g) * t,
        .b = a.b + (b.b - a.b) * t,
        .a = a.a + (b.a - a.a) * t,
    };
}

fn hueDegToRgb(hue_deg: f32) graphics.Color {
    const h = @mod(hue_deg, 360.0) / 60.0;
    const f = h - @floor(h);
    const sector: u32 = @intFromFloat(@floor(h));
    return switch (sector) {
        0 => .{ .r = 1.0, .g = f, .b = 0.0, .a = 1.0 },
        1 => .{ .r = 1.0 - f, .g = 1.0, .b = 0.0, .a = 1.0 },
        2 => .{ .r = 0.0, .g = 1.0, .b = f, .a = 1.0 },
        3 => .{ .r = 0.0, .g = 1.0 - f, .b = 1.0, .a = 1.0 },
        4 => .{ .r = f, .g = 0.0, .b = 1.0, .a = 1.0 },
        else => .{ .r = 1.0, .g = 0.0, .b = 1.0 - f, .a = 1.0 },
    };
}

fn clampCornerRadii(w: f32, h: f32, radii: [4]f32) [4]f32 {
    const max_r = @max(@as(f32, 0.0), @min(w, h) * 0.5);
    return .{
        @min(max_r, @max(@as(f32, 0.0), radii[0])),
        @min(max_r, @max(@as(f32, 0.0), radii[1])),
        @min(max_r, @max(@as(f32, 0.0), radii[2])),
        @min(max_r, @max(@as(f32, 0.0), radii[3])),
    };
}

/// Tessellates a rounded rectangle (fill + per-side borders) into `Vertex2DTextured` triangles.
pub fn appendRoundedRectVertices(
    list: *std.ArrayList(Vertex2DTextured),
    allocator: std.mem.Allocator,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    color: graphics.Color,
    border_color: graphics.Color,
    border_widths: [4]f32,
    corner_radii: [4]f32,
) !void {
    if (w <= 0.0 or h <= 0.0) return;
    const r = clampCornerRadii(w, h, corner_radii);
    const has_radius = (r[0] > 0.5 or r[1] > 0.5 or r[2] > 0.5 or r[3] > 0.5);

    if (color.a > 0.0) {
        if (!has_radius) {
            try pushSolidQuad(list, allocator, x, y, w, h, color);
        } else {
            const cx = x + w * 0.5;
            const cy = y + h * 0.5;
            const segs: usize = 6;
            const corners = [4]struct { ox: f32, oy: f32, rad: f32, a0: f32 }{
                .{ .ox = x + r[0], .oy = y + r[0], .rad = r[0], .a0 = std.math.pi }, // TL
                .{ .ox = x + w - r[1], .oy = y + r[1], .rad = r[1], .a0 = 1.5 * std.math.pi }, // TR
                .{ .ox = x + w - r[2], .oy = y + h - r[2], .rad = r[2], .a0 = 0.0 }, // BR
                .{ .ox = x + r[3], .oy = y + h - r[3], .rad = r[3], .a0 = 0.5 * std.math.pi }, // BL
            };

            var pts: [32][2]f32 = undefined;
            var count: usize = 0;
            for (corners) |cn| {
                if (cn.rad <= 0.5) {
                    pts[count] = .{ cn.ox, cn.oy };
                    count += 1;
                } else {
                    for (0..segs + 1) |si| {
                        const t = @as(f32, @floatFromInt(si)) / @as(f32, @floatFromInt(segs));
                        const ang = cn.a0 + t * (std.math.pi * 0.5);
                        pts[count] = .{ cn.ox + @cos(ang) * cn.rad, cn.oy + @sin(ang) * cn.rad };
                        count += 1;
                    }
                }
            }
            for (0..count) |pi| {
                const p0 = pts[pi];
                const p1 = pts[(pi + 1) % count];
                try pushTri(list, allocator, cx, cy, color, p0[0], p0[1], color, p1[0], p1[1], color);
            }
        }
    }

    if (border_color.a > 0.0) {
        const bt = @max(@as(f32, 0.0), border_widths[0]);
        const br = @max(@as(f32, 0.0), border_widths[1]);
        const bb = @max(@as(f32, 0.0), border_widths[2]);
        const bl = @max(@as(f32, 0.0), border_widths[3]);
        if (!has_radius) {
            if (bt > 0.0) try pushSolidQuad(list, allocator, x, y, w, bt, border_color);
            if (bb > 0.0) try pushSolidQuad(list, allocator, x, y + h - bb, w, bb, border_color);
            if (bl > 0.0) try pushSolidQuad(list, allocator, x, y + bt, bl, @max(0.0, h - bt - bb), border_color);
            if (br > 0.0) try pushSolidQuad(list, allocator, x + w - br, y + bt, br, @max(0.0, h - bt - bb), border_color);
        } else if (bt > 0.0 or br > 0.0 or bb > 0.0 or bl > 0.0) {
            const avg_b = @max(bt, @max(br, @max(bb, bl)));
            const segs: usize = 6;
            const corners = [4]struct { ox: f32, oy: f32, rad: f32, a0: f32 }{
                .{ .ox = x + r[0], .oy = y + r[0], .rad = r[0], .a0 = std.math.pi },
                .{ .ox = x + w - r[1], .oy = y + r[1], .rad = r[1], .a0 = 1.5 * std.math.pi },
                .{ .ox = x + w - r[2], .oy = y + h - r[2], .rad = r[2], .a0 = 0.0 },
                .{ .ox = x + r[3], .oy = y + h - r[3], .rad = r[3], .a0 = 0.5 * std.math.pi },
            };
            var outer: [32][2]f32 = undefined;
            var inner: [32][2]f32 = undefined;
            var count: usize = 0;
            for (corners, 0..) |cn, ci| {
                const ir = @max(@as(f32, 0.0), cn.rad - avg_b);
                const ix_off: f32 = if (ci == 0 or ci == 3) bl else -br;
                const iy_off: f32 = if (ci == 0 or ci == 1) bt else -bb;
                if (cn.rad <= 0.5) {
                    outer[count] = .{ cn.ox, cn.oy };
                    inner[count] = .{ cn.ox + ix_off, cn.oy + iy_off };
                    count += 1;
                } else {
                    for (0..segs + 1) |si| {
                        const t = @as(f32, @floatFromInt(si)) / @as(f32, @floatFromInt(segs));
                        const ang = cn.a0 + t * (std.math.pi * 0.5);
                        const ca = @cos(ang);
                        const sa = @sin(ang);
                        outer[count] = .{ cn.ox + ca * cn.rad, cn.oy + sa * cn.rad };
                        inner[count] = .{ cn.ox + ca * ir, cn.oy + sa * ir };
                        count += 1;
                    }
                }
            }
            for (0..count) |pi| {
                const ni = (pi + 1) % count;
                try pushTri(list, allocator, outer[pi][0], outer[pi][1], border_color, outer[ni][0], outer[ni][1], border_color, inner[ni][0], inner[ni][1], border_color);
                try pushTri(list, allocator, outer[pi][0], outer[pi][1], border_color, inner[ni][0], inner[ni][1], border_color, inner[pi][0], inner[pi][1], border_color);
            }
        }
    }
}

/// Tessellates a gradient or checkerboard rectangle (with optional rounded corners) into `Vertex2DTextured` triangles.
pub fn appendGradientRectVertices(
    list: *std.ArrayList(Vertex2DTextured),
    allocator: std.mem.Allocator,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    kind: graphics.GradientKind,
    stops: [4]graphics.Color,
    corner_radii: [4]f32,
) !void {
    if (w <= 0.0 or h <= 0.0) return;
    const rads = clampCornerRadii(w, h, corner_radii);
    const has_radius = (rads[0] > 0.5 or rads[1] > 0.5 or rads[2] > 0.5 or rads[3] > 0.5);

    if (has_radius and kind != .checkerboard) {
        const cx = x + w * 0.5;
        const cy = y + h * 0.5;
        const segs: usize = 8;
        const corners = [4]struct { ox: f32, oy: f32, rad: f32, a0: f32 }{
            .{ .ox = x + rads[0], .oy = y + rads[0], .rad = rads[0], .a0 = std.math.pi },
            .{ .ox = x + w - rads[1], .oy = y + rads[1], .rad = rads[1], .a0 = 1.5 * std.math.pi },
            .{ .ox = x + w - rads[2], .oy = y + h - rads[2], .rad = rads[2], .a0 = 0.0 },
            .{ .ox = x + rads[3], .oy = y + h - rads[3], .rad = rads[3], .a0 = 0.5 * std.math.pi },
        };
        var pts: [40][2]f32 = undefined;
        var count: usize = 0;
        for (corners) |cn| {
            if (cn.rad <= 0.5) {
                pts[count] = .{ cn.ox, cn.oy };
                count += 1;
            } else {
                for (0..segs + 1) |si| {
                    const t = @as(f32, @floatFromInt(si)) / @as(f32, @floatFromInt(segs));
                    const ang = cn.a0 + t * (std.math.pi * 0.5);
                    pts[count] = .{ cn.ox + @cos(ang) * cn.rad, cn.oy + @sin(ang) * cn.rad };
                    count += 1;
                }
            }
        }
        const sampleAt = struct {
            fn eval(px: f32, py: f32, rx: f32, ry: f32, rw: f32, rh: f32, k: graphics.GradientKind, st: [4]graphics.Color) graphics.Color {
                const tx = std.math.clamp((px - rx) / rw, 0.0, 1.0);
                const ty = std.math.clamp((py - ry) / rh, 0.0, 1.0);
                return switch (k) {
                    .linear_horizontal => lerpColor(st[0], st[1], tx),
                    .linear_vertical => lerpColor(st[0], st[1], ty),
                    .linear_horizontal_3 => if (tx < 0.5) lerpColor(st[0], st[1], tx * 2.0) else lerpColor(st[1], st[2], (tx - 0.5) * 2.0),
                    .bilinear => lerpColor(lerpColor(st[0], st[1], tx), lerpColor(st[3], st[2], tx), ty),
                    .hue_horizontal => hueDegToRgb(tx * 360.0),
                    .checkerboard => st[0],
                };
            }
        }.eval;

        const c_mid = sampleAt(cx, cy, x, y, w, h, kind, stops);
        for (0..count) |pi| {
            const p0 = pts[pi];
            const p1 = pts[(pi + 1) % count];
            const c0 = sampleAt(p0[0], p0[1], x, y, w, h, kind, stops);
            const c1 = sampleAt(p1[0], p1[1], x, y, w, h, kind, stops);
            try pushTri(list, allocator, cx, cy, c_mid, p0[0], p0[1], c0, p1[0], p1[1], c1);
        }
        return;
    }

    switch (kind) {
        .linear_horizontal => {
            const c0 = stops[0];
            const c1 = stops[1];
            try pushTri(list, allocator, x, y, c0, x + w, y, c1, x + w, y + h, c1);
            try pushTri(list, allocator, x, y, c0, x + w, y + h, c1, x, y + h, c0);
        },
        .linear_vertical => {
            const c0 = stops[0];
            const c1 = stops[1];
            try pushTri(list, allocator, x, y, c0, x + w, y, c0, x + w, y + h, c1);
            try pushTri(list, allocator, x, y, c0, x + w, y + h, c1, x, y + h, c1);
        },
        .linear_horizontal_3 => {
            const hw = w * 0.5;
            try pushTri(list, allocator, x, y, stops[0], x + hw, y, stops[1], x + hw, y + h, stops[1]);
            try pushTri(list, allocator, x, y, stops[0], x + hw, y + h, stops[1], x, y + h, stops[0]);
            try pushTri(list, allocator, x + hw, y, stops[1], x + w, y, stops[2], x + w, y + h, stops[2]);
            try pushTri(list, allocator, x + hw, y, stops[1], x + w, y + h, stops[2], x + hw, y + h, stops[1]);
        },
        .bilinear => {
            try pushTri(list, allocator, x, y, stops[0], x + w, y, stops[1], x + w, y + h, stops[2]);
            try pushTri(list, allocator, x, y, stops[0], x + w, y + h, stops[2], x, y + h, stops[3]);
        },
        .hue_horizontal => {
            const segs: usize = 6;
            const seg_w = w / @as(f32, @floatFromInt(segs));
            for (0..segs) |si| {
                const sx = x + @as(f32, @floatFromInt(si)) * seg_w;
                const c0 = hueDegToRgb(@as(f32, @floatFromInt(si)) * 60.0);
                const c1 = hueDegToRgb(@as(f32, @floatFromInt(si + 1)) * 60.0);
                try pushTri(list, allocator, sx, y, c0, sx + seg_w, y, c1, sx + seg_w, y + h, c1);
                try pushTri(list, allocator, sx, y, c0, sx + seg_w, y + h, c1, sx, y + h, c0);
            }
        },
        .checkerboard => {
            const cell: f32 = @max(@as(f32, 4.0), @min(@as(f32, 8.0), h * 0.5));
            const cols: usize = @intFromFloat(@ceil(w / cell));
            const rows: usize = @intFromFloat(@ceil(h / cell));
            for (0..rows) |ry| {
                const cy = y + @as(f32, @floatFromInt(ry)) * cell;
                const ch = @min(cell, y + h - cy);
                for (0..cols) |cx_i| {
                    const cx = x + @as(f32, @floatFromInt(cx_i)) * cell;
                    const cw = @min(cell, x + w - cx);
                    const col = if ((cx_i + ry) % 2 == 0) stops[0] else stops[1];
                    try pushSolidQuad(list, allocator, cx, cy, cw, ch, col);
                }
            }
        },
    }
}

/// Tessellates the HWB color wheel (360-degree hue ring + rotated HWB triangle).
pub fn appendColorWheelVertices(
    list: *std.ArrayList(Vertex2DTextured),
    allocator: std.mem.Allocator,
    x: f32,
    y: f32,
    size: f32,
    hue_deg: f32,
    ring_width: f32,
) !void {
    if (size <= 4.0) return;
    const cx = x + size * 0.5;
    const cy = y + size * 0.5;
    const outer_r = size * 0.5;
    const inner_r = @max(@as(f32, 2.0), outer_r - ring_width);
    const segs: usize = 72;

    for (0..segs) |si| {
        const t0 = @as(f32, @floatFromInt(si)) / @as(f32, @floatFromInt(segs));
        const t1 = @as(f32, @floatFromInt(si + 1)) / @as(f32, @floatFromInt(segs));
        const a0 = t0 * (2.0 * std.math.pi);
        const a1 = t1 * (2.0 * std.math.pi);
        const c0 = hueDegToRgb(t0 * 360.0);
        const c1 = hueDegToRgb(t1 * 360.0);
        const ox0 = cx + @cos(a0) * outer_r;
        const oy0 = cy + @sin(a0) * outer_r;
        const ox1 = cx + @cos(a1) * outer_r;
        const oy1 = cy + @sin(a1) * outer_r;
        const ix0 = cx + @cos(a0) * inner_r;
        const iy0 = cy + @sin(a0) * inner_r;
        const ix1 = cx + @cos(a1) * inner_r;
        const iy1 = cy + @sin(a1) * inner_r;
        try pushTri(list, allocator, ox0, oy0, c0, ox1, oy1, c1, ix1, iy1, c1);
        try pushTri(list, allocator, ox0, oy0, c0, ix1, iy1, c1, ix0, iy0, c0);
    }

    // Inner equilateral triangle: pure hue, white, black.
    const tri_r = @max(@as(f32, 1.0), inner_r - 3.0);
    const hue_rad = (hue_deg * std.math.pi) / 180.0;
    const a_h = hue_rad;
    const a_w = hue_rad + (2.0 * std.math.pi / 3.0);
    const a_b = hue_rad + (4.0 * std.math.pi / 3.0);

    const pure_col = hueDegToRgb(hue_deg);
    const white = graphics.Color{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 };
    const black = graphics.Color{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 };

    try pushTri(
        list,
        allocator,
        cx + @cos(a_h) * tri_r,
        cy + @sin(a_h) * tri_r,
        pure_col,
        cx + @cos(a_w) * tri_r,
        cy + @sin(a_w) * tri_r,
        white,
        cx + @cos(a_b) * tri_r,
        cy + @sin(a_b) * tri_r,
        black,
    );
}

fn pushCircleStroke(
    list: *std.ArrayList(Vertex2DTextured),
    allocator: std.mem.Allocator,
    cx: f32,
    cy: f32,
    r: f32,
    thickness: f32,
    color: graphics.Color,
) !void {
    const segs: usize = 14;
    for (0..segs) |i| {
        const a0 = (@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segs))) * 2.0 * std.math.pi;
        const a1 = (@as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(segs))) * 2.0 * std.math.pi;
        try pushLineSeg(list, allocator, cx + @cos(a0) * r, cy + @sin(a0) * r, cx + @cos(a1) * r, cy + @sin(a1) * r, thickness, color);
    }
}

/// Tessellates geometric vector icons without external image assets.
pub fn appendIconVertices(
    list: *std.ArrayList(Vertex2DTextured),
    allocator: std.mem.Allocator,
    x: f32,
    y: f32,
    size: f32,
    kind: graphics.IconKind,
    color: graphics.Color,
) !void {
    if (size <= 1.0 or color.a <= 0.0) return;
    const t = @max(@as(f32, 1.5), size * 0.14);
    switch (kind) {
        .check => {
            try pushLineSeg(list, allocator, x + size * 0.18, y + size * 0.52, x + size * 0.42, y + size * 0.76, t, color);
            try pushLineSeg(list, allocator, x + size * 0.40, y + size * 0.76, x + size * 0.84, y + size * 0.24, t, color);
        },
        .chevron_down => {
            try pushLineSeg(list, allocator, x + size * 0.22, y + size * 0.35, x + size * 0.50, y + size * 0.65, t, color);
            try pushLineSeg(list, allocator, x + size * 0.50, y + size * 0.65, x + size * 0.78, y + size * 0.35, t, color);
        },
        .chevron_left => {
            try pushLineSeg(list, allocator, x + size * 0.65, y + size * 0.22, x + size * 0.35, y + size * 0.50, t, color);
            try pushLineSeg(list, allocator, x + size * 0.35, y + size * 0.50, x + size * 0.65, y + size * 0.78, t, color);
        },
        .chevron_right => {
            try pushLineSeg(list, allocator, x + size * 0.35, y + size * 0.22, x + size * 0.65, y + size * 0.50, t, color);
            try pushLineSeg(list, allocator, x + size * 0.65, y + size * 0.50, x + size * 0.35, y + size * 0.78, t, color);
        },
        .chevron_up => {
            try pushLineSeg(list, allocator, x + size * 0.22, y + size * 0.65, x + size * 0.50, y + size * 0.35, t, color);
            try pushLineSeg(list, allocator, x + size * 0.50, y + size * 0.35, x + size * 0.78, y + size * 0.65, t, color);
        },
        .plus => {
            try pushLineSeg(list, allocator, x + size * 0.50, y + size * 0.20, x + size * 0.50, y + size * 0.80, t, color);
            try pushLineSeg(list, allocator, x + size * 0.20, y + size * 0.50, x + size * 0.80, y + size * 0.50, t, color);
        },
        .minus => {
            try pushLineSeg(list, allocator, x + size * 0.20, y + size * 0.50, x + size * 0.80, y + size * 0.50, t, color);
        },
        .search => {
            try pushCircleStroke(list, allocator, x + size * 0.43, y + size * 0.43, size * 0.27, t, color);
            try pushLineSeg(list, allocator, x + size * 0.63, y + size * 0.63, x + size * 0.84, y + size * 0.84, t, color);
        },
        .settings => {
            try pushCircleStroke(list, allocator, x + size * 0.50, y + size * 0.50, size * 0.20, t, color);
            try pushCircleStroke(list, allocator, x + size * 0.50, y + size * 0.50, size * 0.36, t * 0.85, color);
        },
        .eye, .eye_off => {
            try pushLineSeg(list, allocator, x + size * 0.12, y + size * 0.50, x + size * 0.50, y + size * 0.24, t, color);
            try pushLineSeg(list, allocator, x + size * 0.50, y + size * 0.24, x + size * 0.88, y + size * 0.50, t, color);
            try pushLineSeg(list, allocator, x + size * 0.12, y + size * 0.50, x + size * 0.50, y + size * 0.76, t, color);
            try pushLineSeg(list, allocator, x + size * 0.50, y + size * 0.76, x + size * 0.88, y + size * 0.50, t, color);
            try pushCircleStroke(list, allocator, x + size * 0.50, y + size * 0.50, size * 0.12, t, color);
        },
        .droplet => {
            try pushLineSeg(list, allocator, x + size * 0.50, y + size * 0.16, x + size * 0.24, y + size * 0.56, t, color);
            try pushLineSeg(list, allocator, x + size * 0.50, y + size * 0.16, x + size * 0.76, y + size * 0.56, t, color);
            try pushLineSeg(list, allocator, x + size * 0.24, y + size * 0.56, x + size * 0.36, y + size * 0.80, t, color);
            try pushLineSeg(list, allocator, x + size * 0.76, y + size * 0.56, x + size * 0.64, y + size * 0.80, t, color);
            try pushLineSeg(list, allocator, x + size * 0.36, y + size * 0.80, x + size * 0.64, y + size * 0.80, t, color);
        },
        .opacity => {
            const c = size * 0.22;
            for (0..3) |ry| {
                for (0..3) |rx| {
                    if ((rx + ry) % 2 == 0) {
                        try pushSolidQuad(list, allocator, x + size * 0.17 + @as(f32, @floatFromInt(rx)) * c, y + size * 0.17 + @as(f32, @floatFromInt(ry)) * c, c, c, color);
                    }
                }
            }
        },
        .corner_radius => {
            try pushLineSeg(list, allocator, x + size * 0.20, y + size * 0.42, x + size * 0.20, y + size * 0.20, t, color);
            try pushLineSeg(list, allocator, x + size * 0.20, y + size * 0.20, x + size * 0.42, y + size * 0.20, t, color);
            try pushLineSeg(list, allocator, x + size * 0.58, y + size * 0.20, x + size * 0.80, y + size * 0.20, t, color);
            try pushLineSeg(list, allocator, x + size * 0.80, y + size * 0.20, x + size * 0.80, y + size * 0.42, t, color);
            try pushLineSeg(list, allocator, x + size * 0.20, y + size * 0.58, x + size * 0.20, y + size * 0.80, t, color);
            try pushLineSeg(list, allocator, x + size * 0.20, y + size * 0.80, x + size * 0.42, y + size * 0.80, t, color);
            try pushLineSeg(list, allocator, x + size * 0.58, y + size * 0.80, x + size * 0.80, y + size * 0.80, t, color);
            try pushLineSeg(list, allocator, x + size * 0.80, y + size * 0.80, x + size * 0.80, y + size * 0.58, t, color);
        },
        .maximize_2 => {
            try pushLineSeg(list, allocator, x + size * 0.58, y + size * 0.18, x + size * 0.82, y + size * 0.18, t, color);
            try pushLineSeg(list, allocator, x + size * 0.82, y + size * 0.18, x + size * 0.82, y + size * 0.42, t, color);
            try pushLineSeg(list, allocator, x + size * 0.82, y + size * 0.18, x + size * 0.55, y + size * 0.45, t, color);
            try pushLineSeg(list, allocator, x + size * 0.18, y + size * 0.58, x + size * 0.18, y + size * 0.82, t, color);
            try pushLineSeg(list, allocator, x + size * 0.18, y + size * 0.82, x + size * 0.42, y + size * 0.82, t, color);
            try pushLineSeg(list, allocator, x + size * 0.18, y + size * 0.82, x + size * 0.45, y + size * 0.55, t, color);
        },
        .grid_2x2 => {
            const q = size * 0.26;
            const d = @max(@as(f32, 1.2), t * 0.8);
            const coords = [2]f32{ 0.18, 0.56 };
            for (coords) |cy_n| {
                for (coords) |cx_n| {
                    const rx = x + size * cx_n;
                    const ry = y + size * cy_n;
                    try pushLineSeg(list, allocator, rx, ry, rx + q, ry, d, color);
                    try pushLineSeg(list, allocator, rx + q, ry, rx + q, ry + q, d, color);
                    try pushLineSeg(list, allocator, rx + q, ry + q, rx, ry + q, d, color);
                    try pushLineSeg(list, allocator, rx, ry + q, rx, ry, d, color);
                }
            }
        },
        .sliders_horizontal => {
            try pushLineSeg(list, allocator, x + size * 0.15, y + size * 0.28, x + size * 0.85, y + size * 0.28, t * 0.85, color);
            try pushLineSeg(list, allocator, x + size * 0.15, y + size * 0.50, x + size * 0.85, y + size * 0.50, t * 0.85, color);
            try pushLineSeg(list, allocator, x + size * 0.15, y + size * 0.72, x + size * 0.85, y + size * 0.72, t * 0.85, color);
            try pushLineSeg(list, allocator, x + size * 0.35, y + size * 0.18, x + size * 0.35, y + size * 0.38, t, color);
            try pushLineSeg(list, allocator, x + size * 0.65, y + size * 0.40, x + size * 0.65, y + size * 0.60, t, color);
            try pushLineSeg(list, allocator, x + size * 0.42, y + size * 0.62, x + size * 0.42, y + size * 0.82, t, color);
        },
        .align_left => {
            try pushLineSeg(list, allocator, x + size * 0.16, y + size * 0.26, x + size * 0.84, y + size * 0.26, t * 0.85, color);
            try pushLineSeg(list, allocator, x + size * 0.16, y + size * 0.50, x + size * 0.62, y + size * 0.50, t * 0.85, color);
            try pushLineSeg(list, allocator, x + size * 0.16, y + size * 0.74, x + size * 0.74, y + size * 0.74, t * 0.85, color);
        },
        .align_center => {
            try pushLineSeg(list, allocator, x + size * 0.16, y + size * 0.26, x + size * 0.84, y + size * 0.26, t * 0.85, color);
            try pushLineSeg(list, allocator, x + size * 0.28, y + size * 0.50, x + size * 0.72, y + size * 0.50, t * 0.85, color);
            try pushLineSeg(list, allocator, x + size * 0.22, y + size * 0.74, x + size * 0.78, y + size * 0.74, t * 0.85, color);
        },
        .align_right => {
            try pushLineSeg(list, allocator, x + size * 0.16, y + size * 0.26, x + size * 0.84, y + size * 0.26, t * 0.85, color);
            try pushLineSeg(list, allocator, x + size * 0.38, y + size * 0.50, x + size * 0.84, y + size * 0.50, t * 0.85, color);
            try pushLineSeg(list, allocator, x + size * 0.26, y + size * 0.74, x + size * 0.84, y + size * 0.74, t * 0.85, color);
        },
        .align_justify => {
            try pushLineSeg(list, allocator, x + size * 0.16, y + size * 0.26, x + size * 0.84, y + size * 0.26, t * 0.85, color);
            try pushLineSeg(list, allocator, x + size * 0.16, y + size * 0.50, x + size * 0.84, y + size * 0.50, t * 0.85, color);
            try pushLineSeg(list, allocator, x + size * 0.16, y + size * 0.74, x + size * 0.84, y + size * 0.74, t * 0.85, color);
        },
        .align_top => {
            try pushLineSeg(list, allocator, x + size * 0.18, y + size * 0.22, x + size * 0.82, y + size * 0.22, t * 0.85, color);
            try pushLineSeg(list, allocator, x + size * 0.50, y + size * 0.34, x + size * 0.50, y + size * 0.80, t * 0.85, color);
            try pushLineSeg(list, allocator, x + size * 0.34, y + size * 0.48, x + size * 0.50, y + size * 0.34, t * 0.85, color);
            try pushLineSeg(list, allocator, x + size * 0.66, y + size * 0.48, x + size * 0.50, y + size * 0.34, t * 0.85, color);
        },
        .align_middle => {
            try pushLineSeg(list, allocator, x + size * 0.18, y + size * 0.50, x + size * 0.82, y + size * 0.50, t * 0.85, color);
            try pushLineSeg(list, allocator, x + size * 0.50, y + size * 0.16, x + size * 0.50, y + size * 0.40, t * 0.85, color);
            try pushLineSeg(list, allocator, x + size * 0.50, y + size * 0.60, x + size * 0.50, y + size * 0.84, t * 0.85, color);
            try pushLineSeg(list, allocator, x + size * 0.36, y + size * 0.30, x + size * 0.50, y + size * 0.40, t * 0.85, color);
            try pushLineSeg(list, allocator, x + size * 0.64, y + size * 0.30, x + size * 0.50, y + size * 0.40, t * 0.85, color);
            try pushLineSeg(list, allocator, x + size * 0.36, y + size * 0.70, x + size * 0.50, y + size * 0.60, t * 0.85, color);
            try pushLineSeg(list, allocator, x + size * 0.64, y + size * 0.70, x + size * 0.50, y + size * 0.60, t * 0.85, color);
        },
        .align_bottom => {
            try pushLineSeg(list, allocator, x + size * 0.18, y + size * 0.78, x + size * 0.82, y + size * 0.78, t * 0.85, color);
            try pushLineSeg(list, allocator, x + size * 0.50, y + size * 0.20, x + size * 0.50, y + size * 0.66, t * 0.85, color);
            try pushLineSeg(list, allocator, x + size * 0.34, y + size * 0.52, x + size * 0.50, y + size * 0.66, t * 0.85, color);
            try pushLineSeg(list, allocator, x + size * 0.66, y + size * 0.52, x + size * 0.50, y + size * 0.66, t * 0.85, color);
        },
        .underline => {
            try pushLineSeg(list, allocator, x + size * 0.28, y + size * 0.20, x + size * 0.28, y + size * 0.52, t, color);
            try pushLineSeg(list, allocator, x + size * 0.72, y + size * 0.20, x + size * 0.72, y + size * 0.52, t, color);
            try pushLineSeg(list, allocator, x + size * 0.28, y + size * 0.52, x + size * 0.50, y + size * 0.64, t, color);
            try pushLineSeg(list, allocator, x + size * 0.72, y + size * 0.52, x + size * 0.50, y + size * 0.64, t, color);
            try pushLineSeg(list, allocator, x + size * 0.20, y + size * 0.80, x + size * 0.80, y + size * 0.80, t, color);
        },
        .strikethrough => {
            try pushLineSeg(list, allocator, x + size * 0.16, y + size * 0.50, x + size * 0.84, y + size * 0.50, t, color);
            try pushLineSeg(list, allocator, x + size * 0.30, y + size * 0.22, x + size * 0.70, y + size * 0.22, t * 0.85, color);
            try pushLineSeg(list, allocator, x + size * 0.30, y + size * 0.78, x + size * 0.70, y + size * 0.78, t * 0.85, color);
        },
        .list_bullet, .list_ordered => {
            try pushSolidQuad(list, allocator, x + size * 0.18, y + size * 0.23, t, t, color);
            try pushSolidQuad(list, allocator, x + size * 0.18, y + size * 0.47, t, t, color);
            try pushSolidQuad(list, allocator, x + size * 0.18, y + size * 0.71, t, t, color);
            try pushLineSeg(list, allocator, x + size * 0.38, y + size * 0.26, x + size * 0.84, y + size * 0.26, t * 0.85, color);
            try pushLineSeg(list, allocator, x + size * 0.38, y + size * 0.50, x + size * 0.84, y + size * 0.50, t * 0.85, color);
            try pushLineSeg(list, allocator, x + size * 0.38, y + size * 0.74, x + size * 0.84, y + size * 0.74, t * 0.85, color);
        },
        .trash_2 => {
            try pushLineSeg(list, allocator, x + size * 0.18, y + size * 0.26, x + size * 0.82, y + size * 0.26, t, color);
            try pushLineSeg(list, allocator, x + size * 0.28, y + size * 0.26, x + size * 0.32, y + size * 0.82, t * 0.9, color);
            try pushLineSeg(list, allocator, x + size * 0.72, y + size * 0.26, x + size * 0.68, y + size * 0.82, t * 0.9, color);
            try pushLineSeg(list, allocator, x + size * 0.32, y + size * 0.82, x + size * 0.68, y + size * 0.82, t * 0.9, color);
        },
        .copy => {
            try pushLineSeg(list, allocator, x + size * 0.36, y + size * 0.36, x + size * 0.82, y + size * 0.36, t * 0.85, color);
            try pushLineSeg(list, allocator, x + size * 0.82, y + size * 0.36, x + size * 0.82, y + size * 0.82, t * 0.85, color);
            try pushLineSeg(list, allocator, x + size * 0.82, y + size * 0.82, x + size * 0.36, y + size * 0.82, t * 0.85, color);
            try pushLineSeg(list, allocator, x + size * 0.36, y + size * 0.82, x + size * 0.36, y + size * 0.36, t * 0.85, color);
            try pushLineSeg(list, allocator, x + size * 0.18, y + size * 0.64, x + size * 0.18, y + size * 0.18, t * 0.85, color);
            try pushLineSeg(list, allocator, x + size * 0.18, y + size * 0.18, x + size * 0.64, y + size * 0.18, t * 0.85, color);
        },
        .folder => {
            try pushLineSeg(list, allocator, x + size * 0.14, y + size * 0.24, x + size * 0.42, y + size * 0.24, t * 0.9, color);
            try pushLineSeg(list, allocator, x + size * 0.42, y + size * 0.24, x + size * 0.50, y + size * 0.34, t * 0.9, color);
            try pushLineSeg(list, allocator, x + size * 0.50, y + size * 0.34, x + size * 0.86, y + size * 0.34, t * 0.9, color);
            try pushLineSeg(list, allocator, x + size * 0.86, y + size * 0.34, x + size * 0.86, y + size * 0.78, t * 0.9, color);
            try pushLineSeg(list, allocator, x + size * 0.86, y + size * 0.78, x + size * 0.14, y + size * 0.78, t * 0.9, color);
            try pushLineSeg(list, allocator, x + size * 0.14, y + size * 0.78, x + size * 0.14, y + size * 0.24, t * 0.9, color);
        },
        .file => {
            try pushLineSeg(list, allocator, x + size * 0.24, y + size * 0.16, x + size * 0.60, y + size * 0.16, t * 0.9, color);
            try pushLineSeg(list, allocator, x + size * 0.60, y + size * 0.16, x + size * 0.78, y + size * 0.34, t * 0.9, color);
            try pushLineSeg(list, allocator, x + size * 0.78, y + size * 0.34, x + size * 0.78, y + size * 0.84, t * 0.9, color);
            try pushLineSeg(list, allocator, x + size * 0.78, y + size * 0.84, x + size * 0.24, y + size * 0.84, t * 0.9, color);
            try pushLineSeg(list, allocator, x + size * 0.24, y + size * 0.84, x + size * 0.24, y + size * 0.16, t * 0.9, color);
        },
        .play => {
            try pushTri(list, allocator, x + size * 0.28, y + size * 0.20, color, x + size * 0.82, y + size * 0.50, color, x + size * 0.28, y + size * 0.80, color);
        },
        .pause => {
            try pushSolidQuad(list, allocator, x + size * 0.26, y + size * 0.20, size * 0.16, size * 0.60, color);
            try pushSolidQuad(list, allocator, x + size * 0.58, y + size * 0.20, size * 0.16, size * 0.60, color);
        },
        .refresh_cw => {
            try pushCircleStroke(list, allocator, x + size * 0.50, y + size * 0.50, size * 0.30, t, color);
            try pushLineSeg(list, allocator, x + size * 0.68, y + size * 0.20, x + size * 0.82, y + size * 0.32, t, color);
        },
        .help_circle, .info, .check_circle => {
            try pushCircleStroke(list, allocator, x + size * 0.50, y + size * 0.50, size * 0.36, t * 0.9, color);
            try pushLineSeg(list, allocator, x + size * 0.50, y + size * 0.44, x + size * 0.50, y + size * 0.70, t, color);
            try pushSolidQuad(list, allocator, x + size * 0.46, y + size * 0.28, t, t, color);
        },
        .alert_triangle => {
            try pushLineSeg(list, allocator, x + size * 0.50, y + size * 0.18, x + size * 0.86, y + size * 0.80, t, color);
            try pushLineSeg(list, allocator, x + size * 0.86, y + size * 0.80, x + size * 0.14, y + size * 0.80, t, color);
            try pushLineSeg(list, allocator, x + size * 0.14, y + size * 0.80, x + size * 0.50, y + size * 0.18, t, color);
            try pushLineSeg(list, allocator, x + size * 0.50, y + size * 0.42, x + size * 0.50, y + size * 0.62, t, color);
        },
        .close_x => {
            try pushLineSeg(list, allocator, x + size * 0.24, y + size * 0.24, x + size * 0.76, y + size * 0.76, t, color);
            try pushLineSeg(list, allocator, x + size * 0.76, y + size * 0.24, x + size * 0.24, y + size * 0.76, t, color);
        },
        .grip_vertical => {
            const dot = @max(@as(f32, 1.5), size * 0.14);
            const cols = [2]f32{ x + size * 0.32, x + size * 0.62 };
            const rows = [3]f32{ y + size * 0.22, y + size * 0.48, y + size * 0.74 };
            for (rows) |ry| {
                for (cols) |cx| {
                    try pushSolidQuad(list, allocator, cx, ry, dot, dot, color);
                }
            }
        },
        .color_wheel => {
            const cx = x + size * 0.5;
            const cy = y + size * 0.5;
            const r_out = size * 0.44;
            const r_in = size * 0.28;
            const segs: usize = 16;
            for (0..segs) |si| {
                const a0 = (@as(f32, @floatFromInt(si)) / @as(f32, @floatFromInt(segs))) * 2.0 * std.math.pi;
                const a1 = (@as(f32, @floatFromInt(si + 1)) / @as(f32, @floatFromInt(segs))) * 2.0 * std.math.pi;
                try pushTri(list, allocator, cx + @cos(a0) * r_out, cy + @sin(a0) * r_out, color, cx + @cos(a1) * r_out, cy + @sin(a1) * r_out, color, cx + @cos(a1) * r_in, cy + @sin(a1) * r_in, color);
                try pushTri(list, allocator, cx + @cos(a0) * r_out, cy + @sin(a0) * r_out, color, cx + @cos(a1) * r_in, cy + @sin(a1) * r_in, color, cx + @cos(a0) * r_in, cy + @sin(a0) * r_in, color);
            }
            const tri_r = r_in * 0.85;
            try pushLineSeg(list, allocator, cx, cy - tri_r, cx + tri_r * 0.866, cy + tri_r * 0.5, t * 0.8, color);
            try pushLineSeg(list, allocator, cx + tri_r * 0.866, cy + tri_r * 0.5, cx - tri_r * 0.866, cy + tri_r * 0.5, t * 0.8, color);
            try pushLineSeg(list, allocator, cx - tri_r * 0.866, cy + tri_r * 0.5, cx, cy - tri_r, t * 0.8, color);
        },
    }
}
