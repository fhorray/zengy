//! Converts a frame of `DrawCommand`s into textured triangles grouped into draw batches.
//!
//! Pure CPU code (no GPU types): a batch is a run of vertices that share one texture slot and one scissor
//! rectangle, so the renderer issues one draw call per batch. All coordinates are scaled from logical units
//! to physical pixels here, matching the legacy 2D contract (viewport in pixels, origin top-left).

const std = @import("std");
const graphics = @import("graphics");
const text = @import("text");
const tess = @import("tessellate.zig");

pub const Vertex = tess.Vertex2DTextured;
pub const ScissorRect = tess.ScissorRect;
pub const Quad = tess.TexturedQuad;

/// Which texture a batch samples. `user` carries the id handed out by the renderer.
pub const TextureSlot = union(enum) {
    white,
    font,
    icons,
    user: u64,
};

pub const Batch = struct {
    first_vertex: u32,
    vertex_count: u32,
    texture: TextureSlot,
    scissor: ?ScissorRect,
};

/// Baked CPU atlases the batcher needs for text measurement and glyph placement.
pub const Atlases = struct {
    font: *const text.TtfAtlas,
    icons: *const text.IconAtlas,
};

/// Maximum nested clip rectangles; deeper pushes are ignored (same limit as the legacy backend).
pub const max_clip_depth = 32;

pub const Batcher = struct {
    allocator: std.mem.Allocator,
    vertices: std.ArrayList(Vertex) = .empty,
    batches: std.ArrayList(Batch) = .empty,
    text_scratch: std.ArrayList(text.TextQuad) = .empty,

    pub fn init(allocator: std.mem.Allocator) Batcher {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Batcher) void {
        self.vertices.deinit(self.allocator);
        self.batches.deinit(self.allocator);
        self.text_scratch.deinit(self.allocator);
    }

    /// Drops the previous frame while keeping capacity, so steady-state frames do not allocate.
    pub fn reset(self: *Batcher) void {
        self.vertices.clearRetainingCapacity();
        self.batches.clearRetainingCapacity();
    }

    fn flush(self: *Batcher, slot: TextureSlot, scissor: ?ScissorRect, first: u32, count: u32) !void {
        if (count == 0) return;
        if (self.batches.items.len > 0) {
            const last = &self.batches.items[self.batches.items.len - 1];
            if (std.meta.eql(last.texture, slot) and ScissorRect.eql(last.scissor, scissor)) {
                last.vertex_count += count;
                return;
            }
        }
        try self.batches.append(self.allocator, .{ .first_vertex = first, .vertex_count = count, .texture = slot, .scissor = scissor });
    }

    fn mark(self: *const Batcher) u32 {
        return @intCast(self.vertices.items.len);
    }

    fn added(self: *const Batcher, first: u32) u32 {
        return @intCast(self.vertices.items.len - first);
    }

    /// Rebuilds vertices and batches for one frame. `triangles` (three vertices each) and `queued` quads
    /// (sprites) are already in physical pixels and draw first, under the command list. The `.clear` command
    /// is the provider's business, not ours.
    pub fn build(
        self: *Batcher,
        commands: []const graphics.DrawCommand,
        queued: []const Quad,
        triangles: []const Vertex,
        dpi_scale: f32,
        atlases: Atlases,
    ) !void {
        self.reset();
        const dpi = if (dpi_scale > 0) dpi_scale else 1.0;
        var clip_stack: [max_clip_depth]ScissorRect = undefined;
        var clip_depth: usize = 0;
        var active: ?ScissorRect = null;

        if (triangles.len >= 3) {
            const first = self.mark();
            try self.vertices.appendSlice(self.allocator, triangles[0 .. triangles.len / 3 * 3]);
            try self.flush(.white, null, first, self.added(first));
        }

        for (queued) |q| {
            const first = self.mark();
            try tess.appendTexturedQuadVertices(&self.vertices, self.allocator, q);
            const slot: TextureSlot = if (q.texture == 0) .white else .{ .user = q.texture };
            try self.flush(slot, q.scissor, first, 6);
        }

        for (commands) |cmd| switch (cmd) {
            .clear => {},
            .clip_rect => |maybe| {
                clip_depth = 0;
                if (maybe) |r| {
                    const sc = toScissor(r, dpi);
                    clip_stack[0] = sc;
                    clip_depth = 1;
                    active = sc;
                } else active = null;
            },
            .clip_push => |r| {
                const sc = toScissor(r, dpi);
                const next = if (active) |prev| intersect(prev, sc) else sc;
                if (clip_depth < clip_stack.len) {
                    clip_stack[clip_depth] = next;
                    clip_depth += 1;
                }
                active = next;
            },
            .clip_pop => {
                if (clip_depth > 0) clip_depth -= 1;
                active = if (clip_depth > 0) clip_stack[clip_depth - 1] else null;
            },
            .rect => |r| {
                const first = self.mark();
                try tess.appendTexturedQuadVertices(&self.vertices, self.allocator, .{
                    .x = r.x * dpi,
                    .y = r.y * dpi,
                    .width = r.width * dpi,
                    .height = r.height * dpi,
                    .color = r.color,
                    .scissor = active,
                });
                try self.flush(.white, active, first, 6);
            },
            .rounded_rect => |rr| {
                const first = self.mark();
                try tess.appendRoundedRectVertices(
                    &self.vertices,
                    self.allocator,
                    rr.x * dpi,
                    rr.y * dpi,
                    rr.width * dpi,
                    rr.height * dpi,
                    rr.color,
                    rr.border_color,
                    scale4(rr.border_widths, dpi),
                    scale4(rr.corner_radii, dpi),
                );
                try self.flush(.white, active, first, self.added(first));
            },
            .gradient_rect => |gr| {
                const first = self.mark();
                try tess.appendGradientRectVertices(
                    &self.vertices,
                    self.allocator,
                    gr.x * dpi,
                    gr.y * dpi,
                    gr.width * dpi,
                    gr.height * dpi,
                    gr.kind,
                    gr.stops,
                    scale4(gr.corner_radii, dpi),
                );
                try self.flush(.white, active, first, self.added(first));
            },
            .color_wheel => |cw| {
                const first = self.mark();
                try tess.appendColorWheelVertices(&self.vertices, self.allocator, cw.x * dpi, cw.y * dpi, cw.size * dpi, cw.hue_deg, cw.ring_width * dpi);
                try self.flush(.white, active, first, self.added(first));
            },
            .icon => |ic| {
                const first = self.mark();
                if (atlases.icons.makeIconQuad(@backingInt(ic.kind), ic.x * dpi, ic.y * dpi, ic.size * dpi, ic.color)) |iq| {
                    try tess.appendTexturedQuadVertices(&self.vertices, self.allocator, .{
                        .x = iq.x,
                        .y = iq.y,
                        .width = iq.width,
                        .height = iq.height,
                        .u0 = iq.u0,
                        .v0 = iq.v0,
                        .u1 = iq.u1,
                        .v1 = iq.v1,
                        .color = iq.color,
                    });
                    try self.flush(.icons, active, first, self.added(first));
                } else {
                    // No baked glyph for this icon: fall back to the geometric vector icon.
                    try tess.appendIconVertices(&self.vertices, self.allocator, ic.x * dpi, ic.y * dpi, ic.size * dpi, ic.kind, ic.color);
                    try self.flush(.white, active, first, self.added(first));
                }
            },
            .image => |img| {
                if (img.texture_id == 0 or img.width <= 0 or img.height <= 0) continue;
                const first = self.mark();
                try tess.appendTexturedQuadVertices(&self.vertices, self.allocator, .{
                    .x = img.x * dpi,
                    .y = img.y * dpi,
                    .width = img.width * dpi,
                    .height = img.height * dpi,
                    .u0 = img.u0,
                    .v0 = img.v0,
                    .u1 = img.u1,
                    .v1 = img.v1,
                    .color = img.tint,
                    .scissor = active,
                });
                try self.flush(.{ .user = img.texture_id }, active, first, 6);
            },
            .text => |tx| {
                self.text_scratch.clearRetainingCapacity();
                const target_px = (if (tx.scale > 0.0) tx.scale else 2.0) * 8.0 * dpi;
                var draw_x = tx.x * dpi;
                if (tx.box_width > 0.0 and tx.align_mode != .left) {
                    const measured = atlases.font.measureText(tx.content, target_px);
                    const box_px = tx.box_width * dpi;
                    switch (tx.align_mode) {
                        .center => draw_x += @max(@as(f32, 0.0), (box_px - measured.width) * 0.5),
                        .right => draw_x += @max(@as(f32, 0.0), box_px - measured.width),
                        .left => {},
                    }
                }
                try atlases.font.emitTextQuads(self.allocator, &self.text_scratch, draw_x, tx.y * dpi, tx.content, target_px, tx.color);
                for (self.text_scratch.items) |tq| {
                    const first = self.mark();
                    try tess.appendTexturedQuadVertices(&self.vertices, self.allocator, .{
                        .x = tq.x,
                        .y = tq.y,
                        .width = tq.width,
                        .height = tq.height,
                        .u0 = tq.u0,
                        .v0 = tq.v0,
                        .u1 = tq.u1,
                        .v1 = tq.v1,
                        .color = tq.color,
                    });
                    try self.flush(.font, active, first, 6);
                }
            },
        };
    }
};

fn scale4(v: [4]f32, s: f32) [4]f32 {
    return .{ v[0] * s, v[1] * s, v[2] * s, v[3] * s };
}

fn toScissor(r: graphics.ClipRect, dpi: f32) ScissorRect {
    return .{
        .x = @intFromFloat(@max(0.0, r.x * dpi)),
        .y = @intFromFloat(@max(0.0, r.y * dpi)),
        .w = @intFromFloat(@max(0.0, r.width * dpi)),
        .h = @intFromFloat(@max(0.0, r.height * dpi)),
    };
}

fn intersect(a: ScissorRect, b: ScissorRect) ScissorRect {
    const ax1 = a.x + @as(i32, @intCast(a.w));
    const ay1 = a.y + @as(i32, @intCast(a.h));
    const bx1 = b.x + @as(i32, @intCast(b.w));
    const by1 = b.y + @as(i32, @intCast(b.h));
    const ix0 = @max(a.x, b.x);
    const iy0 = @max(a.y, b.y);
    const ix1 = @max(ix0, @min(ax1, bx1));
    const iy1 = @max(iy0, @min(ay1, by1));
    return .{ .x = ix0, .y = iy0, .w = @intCast(ix1 - ix0), .h = @intCast(iy1 - iy0) };
}

/// Clamps a scissor to the render target. Returns null when nothing remains visible.
pub fn clampScissor(sc: ScissorRect, width: u32, height: u32) ?ScissorRect {
    const max_w: i32 = @intCast(width);
    const max_h: i32 = @intCast(height);
    const x0 = std.math.clamp(sc.x, 0, max_w);
    const y0 = std.math.clamp(sc.y, 0, max_h);
    const x1 = std.math.clamp(sc.x + @as(i32, @intCast(sc.w)), 0, max_w);
    const y1 = std.math.clamp(sc.y + @as(i32, @intCast(sc.h)), 0, max_h);
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x = x0, .y = y0, .w = @intCast(x1 - x0), .h = @intCast(y1 - y0) };
}

const testing = std.testing;

fn testAtlases(font: *text.TtfAtlas, icons: *text.IconAtlas) !Atlases {
    font.* = try text.TtfAtlas.bake(testing.allocator, text.FIRA_SANS_REGULAR, 28.0);
    icons.* = try text.IconAtlas.bake(testing.allocator, 32.0);
    return .{ .font = font, .icons = icons };
}

test "adjacent rects share one batch and clip changes split it" {
    var font: text.TtfAtlas = undefined;
    var icons: text.IconAtlas = undefined;
    const atlases = try testAtlases(&font, &icons);
    defer font.deinit();
    defer icons.deinit();
    var b = Batcher.init(testing.allocator);
    defer b.deinit();

    const red: graphics.Color = .{ .r = 1, .g = 0, .b = 0 };
    try b.build(&.{
        .{ .rect = .{ .x = 0, .y = 0, .width = 10, .height = 10, .color = red } },
        .{ .rect = .{ .x = 10, .y = 0, .width = 10, .height = 10, .color = red } },
        .{ .clip_push = .{ .x = 5, .y = 5, .width = 20, .height = 20 } },
        .{ .rect = .{ .x = 0, .y = 0, .width = 10, .height = 10, .color = red } },
        .clip_pop,
        .{ .rect = .{ .x = 0, .y = 0, .width = 10, .height = 10, .color = red } },
    }, &.{}, &.{}, 1.0, atlases);

    try testing.expectEqual(@as(usize, 24), b.vertices.items.len);
    try testing.expectEqual(@as(usize, 3), b.batches.items.len);
    try testing.expectEqual(@as(u32, 12), b.batches.items[0].vertex_count);
    try testing.expect(b.batches.items[0].scissor == null);
    try testing.expectEqual(@as(i32, 5), b.batches.items[1].scissor.?.x);
    try testing.expect(b.batches.items[2].scissor == null);
}

test "nested clips intersect and dpi scales coordinates" {
    var font: text.TtfAtlas = undefined;
    var icons: text.IconAtlas = undefined;
    const atlases = try testAtlases(&font, &icons);
    defer font.deinit();
    defer icons.deinit();
    var b = Batcher.init(testing.allocator);
    defer b.deinit();

    const c: graphics.Color = .{ .r = 1, .g = 1, .b = 1 };
    try b.build(&.{
        .{ .clip_push = .{ .x = 0, .y = 0, .width = 50, .height = 50 } },
        .{ .clip_push = .{ .x = 25, .y = 25, .width = 50, .height = 50 } },
        .{ .rect = .{ .x = 1, .y = 2, .width = 3, .height = 4, .color = c } },
    }, &.{}, &.{}, 2.0, atlases);

    const sc = b.batches.items[0].scissor.?;
    try testing.expectEqual(@as(i32, 50), sc.x);
    try testing.expectEqual(@as(u32, 50), sc.w); // (0..100) ∩ (50..150) at 2x
    try testing.expectEqual(@as(f32, 2.0), b.vertices.items[0].x);
    try testing.expectEqual(@as(f32, 4.0), b.vertices.items[0].y);
}

test "DrawCommand.image samples a user texture slot" {
    var font: text.TtfAtlas = undefined;
    var icons: text.IconAtlas = undefined;
    const atlases = try testAtlases(&font, &icons);
    defer font.deinit();
    defer icons.deinit();
    var b = Batcher.init(testing.allocator);
    defer b.deinit();

    try b.build(&.{
        .{ .image = .{ .x = 0, .y = 0, .width = 8, .height = 8, .texture_id = 99 } },
    }, &.{}, &.{}, 1.0, atlases);
    try testing.expectEqual(@as(usize, 1), b.batches.items.len);
    try testing.expectEqual(TextureSlot{ .user = 99 }, b.batches.items[0].texture);
    try testing.expectEqual(@as(u32, 6), b.batches.items[0].vertex_count);
}

test "text and icons go to their atlas slots, queued quads use user textures" {
    var font: text.TtfAtlas = undefined;
    var icons: text.IconAtlas = undefined;
    const atlases = try testAtlases(&font, &icons);
    defer font.deinit();
    defer icons.deinit();
    var b = Batcher.init(testing.allocator);
    defer b.deinit();

    const white: graphics.Color = .{ .r = 1, .g = 1, .b = 1 };
    try b.build(&.{
        .{ .text = .{ .x = 0, .y = 0, .content = "Hi", .color = white } },
        .{ .icon = .{ .x = 0, .y = 0, .size = 16, .kind = .check, .color = white } },
    }, &.{.{ .x = 0, .y = 0, .width = 4, .height = 4, .texture = 42 }}, &.{}, 1.0, atlases);

    try testing.expect(b.batches.items.len >= 3);
    try testing.expectEqual(TextureSlot{ .user = 42 }, b.batches.items[0].texture);
    try testing.expectEqual(TextureSlot.font, b.batches.items[1].texture);
    try testing.expectEqual(TextureSlot.icons, b.batches.items[b.batches.items.len - 1].texture);
}

test "scissor clamping rejects empty and out-of-bounds regions" {
    try testing.expect(clampScissor(.{ .x = 200, .y = 0, .w = 10, .h = 10 }, 100, 100) == null);
    const r = clampScissor(.{ .x = -5, .y = -5, .w = 20, .h = 20 }, 100, 100).?;
    try testing.expectEqual(@as(i32, 0), r.x);
    try testing.expectEqual(@as(u32, 15), r.w);
}

test "queued triangles draw first as a white batch" {
    var font: text.TtfAtlas = undefined;
    var icons: text.IconAtlas = undefined;
    const atlases = try testAtlases(&font, &icons);
    defer font.deinit();
    defer icons.deinit();
    var b = Batcher.init(testing.allocator);
    defer b.deinit();

    const v = Vertex{ .x = 0, .y = 0, .u = 0, .v = 0, .r = 1, .g = 0, .b = 0, .a = 1 };
    try b.build(&.{.{ .rect = .{ .x = 0, .y = 0, .width = 4, .height = 4, .color = .{ .r = 1, .g = 1, .b = 1 } } }}, &.{}, &.{ v, v, v, v }, 1.0, atlases);
    // The stray 4th vertex is dropped: only whole triangles are accepted.
    try testing.expectEqual(@as(usize, 9), b.vertices.items.len);
    try testing.expectEqual(@as(u32, 9), b.batches.items[0].vertex_count); // white triangle + white rect merge
}
