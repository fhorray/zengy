//! Unit Tests for `packages/text` (`packages/text/tests/text_tests.zig`).

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
    try testing.expectEqual(@as(f32, 32.0), size.height);

    var quads: std.ArrayList(text.TextQuad) = .empty;
    defer quads.deinit(testing.allocator);

    try text.emitTextQuads(testing.allocator, &quads, 10.0, 20.0, "A B", 2.0, .{ .r = 1, .g = 1, .b = 1, .a = 1 });
    // Space is skipped, so only 'A' and 'B' emit quads.
    try testing.expectEqual(@as(usize, 2), quads.items.len);
    try testing.expectEqual(@as(f32, 10.0), quads.items[0].x);
    try testing.expectEqual(@as(f32, 42.0), quads.items[1].x);
}
