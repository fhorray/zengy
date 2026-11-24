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
