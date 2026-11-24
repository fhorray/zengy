//! Headless tests for `official.audio` (`packages/audio/core`).

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const audio = @import("audio");

const MockAudioBackend = struct {
    next_src: u64 = 1,
    next_pb: u64 = 100,
    last_volume: f32 = 1.0,
    last_paused: bool = false,
    finished: bool = false,
    active_playbacks: usize = 0,
    active_sources: usize = 0,

    fn loadBytes(raw: *anyopaque, _: []const u8, _: audio.AudioFormat) anyerror!u64 {
        const self: *MockAudioBackend = @ptrCast(@alignCast(raw));
        const id = self.next_src;
        self.next_src += 1;
        self.active_sources += 1;
        return id;
    }

    fn unloadSource(raw: *anyopaque, _: u64) void {
        const self: *MockAudioBackend = @ptrCast(@alignCast(raw));
        if (self.active_sources > 0) self.active_sources -= 1;
    }

    fn play(raw: *anyopaque, _: u64, settings: audio.PlaybackSettings) anyerror!u64 {
        const self: *MockAudioBackend = @ptrCast(@alignCast(raw));
        const id = self.next_pb;
        self.next_pb += 1;
        self.active_playbacks += 1;
        self.last_volume = settings.volume;
        self.last_paused = settings.paused;
        return id;
    }

    fn stop(raw: *anyopaque, _: u64) void {
        const self: *MockAudioBackend = @ptrCast(@alignCast(raw));
        if (self.active_playbacks > 0) self.active_playbacks -= 1;
    }

    fn setVolume(raw: *anyopaque, _: u64, volume: f32) void {
        const self: *MockAudioBackend = @ptrCast(@alignCast(raw));
        self.last_volume = volume;
    }

    fn setPaused(raw: *anyopaque, _: u64, paused: bool) void {
        const self: *MockAudioBackend = @ptrCast(@alignCast(raw));
        self.last_paused = paused;
    }

    fn setSpeed(_: *anyopaque, _: u64, _: f32) void {}

    fn isFinished(raw: *anyopaque, _: u64) bool {
        const self: *MockAudioBackend = @ptrCast(@alignCast(raw));
        return self.finished;
    }

    fn vtable(self: *MockAudioBackend) audio.AudioBackendVTable {
        return .{
            .ctx = self,
            .loadBytes = loadBytes,
            .unloadSource = unloadSource,
            .play = play,
            .stop = stop,
            .setVolume = setVolume,
            .setPaused = setPaused,
            .setSpeed = setSpeed,
            .isFinished = isFinished,
        };
    }
};

test "AudioService plays AudioPlayer, applies spatial gain, and despawns on finish" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(audio.module());
    try app.initialize();

    var mock = MockAudioBackend{};
    const svc = app.resources.get(audio.AudioService).?;
    svc.setBackend(mock.vtable());

    const src = try svc.loadFromBytes("RIFFmock", .wav);
    try testing.expectEqual(@as(usize, 1), mock.active_sources);

    const listener = try app.world.spawn();
    try app.world.set(listener, audio.SpatialListener, .{ .position = .{ 0, 0, 0 } });

    const emitter = try app.world.spawn();
    try app.world.set(emitter, audio.AudioPlayer, .{
        .source = src,
        .position = .{ 5.0, 0, 0 },
        .settings = .{ .mode = .despawn, .volume = 1.0, .spatial = true, .max_distance = 10.0 },
    });

    try app.tick(1.0 / 60.0);
    try testing.expectEqual(@as(usize, 1), mock.active_playbacks);
    try testing.expectApproxEqAbs(@as(f32, 0.5), mock.last_volume, 1e-5);

    mock.finished = true;
    try app.tick(1.0 / 60.0);
    try testing.expectEqual(@as(usize, 0), mock.active_playbacks);
    try testing.expect(!app.world.isAlive(emitter));

    try testing.expect(svc.unloadSource(src));
    try testing.expectEqual(@as(usize, 0), mock.active_sources);
}
