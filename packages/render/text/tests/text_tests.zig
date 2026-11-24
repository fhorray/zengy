//! Unit Tests for `packages/render/text` (`packages/render/text/tests/text_tests.zig`).

const std = @import("std");
const testing = std.testing;
const text = @import("text");

test "generateFontAtlasRgba8 produces expected dimensions and non-empty glyphs" {
    const pixels = try text.generateFontAtlasRgba8(testing.allocator);
    defer testing.allocator.free(pixels);

    try testing.expectEqual(@as(usize, text.ATLAS_WIDTH * text.ATLAS_HEIGHT * 4), pixels.len);

    var lit_pixels: usize = 0;
    var i: usize = 3;
    while (i < pixels.len) : (i += 4) {
        if (pixels[i] == 255) lit_pixels += 1;
    }
    try testing.expect(lit_pixels > 500);
}

test "measureText and emitTextQuads handle spaces and newlines" {
    const size = text.measureText("AB\nC", 2.0);
    try testing.expectEqual(@as(f32, 32.0), size.width);
    // 2 lines of 16 px glyphs plus one 4 px leading gap: the same pitch emitTextQuads uses.
    try testing.expectEqual(@as(f32, 36.0), size.height);

    var quads: std.ArrayList(text.TextQuad) = .empty;
    defer quads.deinit(testing.allocator);

    try text.emitTextQuads(testing.allocator, &quads, 10.0, 20.0, "A B", 2.0, .{ .r = 1, .g = 1, .b = 1, .a = 1 });
    // Space is skipped, so only 'A' and 'B' emit quads.
    try testing.expectEqual(@as(usize, 2), quads.items.len);
    try testing.expectEqual(@as(f32, 10.0), quads.items[0].x);
    try testing.expectEqual(@as(f32, 42.0), quads.items[1].x);
}

test "UTF-8 text measures and draws one glyph per code point, matching line pitch" {
    // "añ€😀" is 4 code points (1+2+3+4 bytes): width must be 4 glyphs, not 10.
    const size = text.measureText("añ€😀", 1.0);
    try testing.expectEqual(@as(f32, 4 * 8.0), size.width);

    var quads: std.ArrayList(text.TextQuad) = .empty;
    defer quads.deinit(testing.allocator);
    try text.emitTextQuads(testing.allocator, &quads, 0, 0, "añ€😀", 1.0, .{ .r = 1, .g = 1, .b = 1, .a = 1 });
    try testing.expectEqual(@as(usize, 4), quads.items.len);
    try testing.expectEqual(@as(f32, 24.0), quads.items[3].x);

    // Malformed bytes never loop or panic; each becomes one replacement glyph.
    const bad = text.measureText("a\xff\xc3", 1.0);
    try testing.expectEqual(@as(f32, 3 * 8.0), bad.width);

    // Measured block height equals the distance the last baseline moves when drawn.
    const two = text.measureText("a\nb", 1.0);
    quads.clearRetainingCapacity();
    try text.emitTextQuads(testing.allocator, &quads, 0, 0, "a\nb", 1.0, .{ .r = 1, .g = 1, .b = 1, .a = 1 });
    try testing.expectEqual(two.height, quads.items[1].y + 8.0);
    try testing.expectEqual(text.lineAdvance(1.0), quads.items[1].y - quads.items[0].y);
}

test "TtfAtlas bakes Latin, Greek, and Cyrillic glyphs and falls back to '?' for the rest" {
    var atlas = try text.TtfAtlas.bake(testing.allocator, text.FIRA_SANS_REGULAR, 28.0);
    defer atlas.deinit();
    try testing.expectEqual(@as(u32, 1024), atlas.width);

    // Extended glyphs exist, have real size and advance, and live in their own atlas cells.
    for ([_]u21{ 'é', 'ñ', 'Ž', 'ß', '€', 'Ж', 'я', 'Ω', 'λ', '—' }) |cp| {
        const g = atlas.glyph(cp);
        try testing.expect(g.xadvance > 0);
        try testing.expect(g.x1 > g.x0 and g.y1 > g.y0);
        try testing.expect(g != atlas.glyph('?'));
    }
    // 'é' and 'e' are different glyphs, and Cyrillic 'Ж' is wider than 'i'.
    try testing.expect(atlas.glyph('é') != atlas.glyph('e'));
    try testing.expect(atlas.glyph('Ж').xadvance > atlas.glyph('i').xadvance);
    // Not baked (CJK, emoji) -> the visible '?' glyph, never a blank or garbage.
    try testing.expect(atlas.glyph(0x4E2D) == atlas.glyph('?'));
    try testing.expect(atlas.glyph(0x1F600) == atlas.glyph('?'));
    try testing.expect(atlas.glyph(0x7F) == atlas.glyph('?'));

    // Extended cells never overlap ASCII cells and lie inside the texture.
    var ascii_bottom: u16 = 0;
    for (atlas.chars) |c| ascii_bottom = @max(ascii_bottom, c.y1);
    for (atlas.extra) |c| {
        if (c.xadvance < 0) continue;
        try testing.expect(c.y0 > ascii_bottom);
        try testing.expect(c.x1 <= atlas.width and c.y1 <= atlas.height);
    }

    // Measure and draw agree, one glyph per code point, extended text included.
    const size = atlas.measureText("café Жλ€", 28.0);
    var quads: std.ArrayList(text.TextQuad) = .empty;
    defer quads.deinit(testing.allocator);
    try atlas.emitTextQuads(testing.allocator, &quads, 0, 0, "café Жλ€", 28.0, .{ .r = 1, .g = 1, .b = 1, .a = 1 });
    try testing.expectEqual(@as(usize, 7), quads.items.len); // the space draws nothing
    try testing.expect(size.width > 8 * 5);
    const last = quads.items[quads.items.len - 1];
    try testing.expect(last.x < size.width);
    // Baked pixels for 'é' really contain ink (the alpha plane is not empty at its cell).
    const g = atlas.glyph('é');
    var ink: usize = 0;
    var yy: usize = g.y0;
    while (yy < g.y1) : (yy += 1) {
        var xx: usize = g.x0;
        while (xx < g.x1) : (xx += 1) {
            if (atlas.rgba_pixels[(yy * atlas.width + xx) * 4 + 3] > 0) ink += 1;
        }
    }
    try testing.expect(ink > 20);
}
