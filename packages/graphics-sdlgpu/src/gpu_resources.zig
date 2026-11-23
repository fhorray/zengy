//! Pure-Zig GPU Resource Handles and Vertex Batching Helpers (`packages/graphics-sdlgpu`).
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
