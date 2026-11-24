//! Tests for `official.audio.zaudio` (`packages/audio/zaudio`).

const std = @import("std");
const testing = std.testing;
const zaudio = @import("zaudio");
const audio_zaudio = @import("audio_zaudio");

test "zaudio module descriptor and miniaudio decoder work cleanly" {
    const desc = audio_zaudio.module().descriptor;
    try testing.expectEqualStrings("official.audio.zaudio", desc.id);

    // Minimal valid 44-byte silent PCM WAV (1 channel, 8000Hz, 8-bit, 4 samples).
    const tiny_wav = [_]u8{
        'R', 'I', 'F', 'F', 40, 0, 0, 0,
        'W', 'A', 'V', 'E', 'f', 'm', 't', ' ',
        16, 0, 0, 0, 1, 0, 1, 0,
        0x40, 0x1F, 0, 0, 0x40, 0x1F, 0, 0,
        1, 0, 8, 0, 'd', 'a', 't', 'a',
        4, 0, 0, 0, 128, 128, 128, 128,
    };

    zaudio.init(testing.allocator);
    defer zaudio.deinit();

    const decoder = try zaudio.Decoder.createFromMemory(
        &tiny_wav,
        tiny_wav.len,
        zaudio.Decoder.Config.initDefault(),
    );
    defer decoder.destroy();
}
