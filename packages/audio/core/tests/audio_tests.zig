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
    last_pan: f32 = 0.0,
    fail_play: bool = false,
    play_calls: usize = 0,
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
        self.play_calls += 1;
        if (self.fail_play) return error.MockPlaybackRejected;
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

    fn setPan(raw: *anyopaque, _: u64, pan: f32) void {
        const self: *MockAudioBackend = @ptrCast(@alignCast(raw));
        self.last_pan = pan;
    }

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
            .setPan = setPan,
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

test "setMasterVolume re-applies the master gain to live manual and component voices" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(audio.module());
    try app.initialize();

    var mock = MockAudioBackend{};
    const svc = app.resources.get(audio.AudioService).?;
    svc.setBackend(mock.vtable());
    const src = try svc.loadFromBytes("RIFFmock", .wav);

    const manual = try svc.play(src, .{ .volume = 1.0 });
    try testing.expectApproxEqAbs(@as(f32, 1.0), mock.last_volume, 1e-5);
    svc.setMasterVolume(0.2);
    try testing.expectApproxEqAbs(@as(f32, 0.2), mock.last_volume, 1e-5);
    svc.setVolume(manual, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.1), mock.last_volume, 1e-5);
    svc.setMasterVolume(1.0);
    try testing.expectApproxEqAbs(@as(f32, 0.5), mock.last_volume, 1e-5);
    svc.stop(manual);

    // Component voice: a master change must reach a voice that is already playing, without touching its component.
    const emitter = try app.world.spawn();
    try app.world.set(emitter, audio.AudioPlayer, .{
        .source = src,
        .settings = .{ .mode = .loop, .volume = 1.0 },
    });
    try app.tick(1.0 / 60.0);
    try testing.expectApproxEqAbs(@as(f32, 1.0), mock.last_volume, 1e-5);
    svc.setMasterVolume(0.2);
    try testing.expectApproxEqAbs(@as(f32, 0.2), mock.last_volume, 1e-5);
}

test "voices are released when their AudioPlayer is despawned or the component is removed" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(audio.module());
    try app.initialize();

    var mock = MockAudioBackend{};
    const svc = app.resources.get(audio.AudioService).?;
    svc.setBackend(mock.vtable());
    const src = try svc.loadFromBytes("RIFFmock", .wav);

    const despawned = try app.world.spawn();
    try app.world.set(despawned, audio.AudioPlayer, .{ .source = src, .settings = .{ .mode = .loop } });
    const detached = try app.world.spawn();
    try app.world.set(detached, audio.AudioPlayer, .{ .source = src, .settings = .{ .mode = .loop } });

    try app.tick(1.0 / 60.0);
    try testing.expectEqual(@as(usize, 2), mock.active_playbacks);

    _ = try app.world.despawn(despawned);
    _ = try app.world.remove(detached, audio.AudioPlayer);
    try app.tick(1.0 / 60.0);
    try testing.expectEqual(@as(usize, 0), mock.active_playbacks);
    try testing.expectEqual(@as(usize, 0), svc.component_voices.items.len);
}

test "collectFinished reclaims finished manual playbacks and leaves live ones" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(audio.module());
    try app.initialize();

    var mock = MockAudioBackend{};
    const svc = app.resources.get(audio.AudioService).?;
    svc.setBackend(mock.vtable());
    const src = try svc.loadFromBytes("RIFFmock", .wav);

    const sfx = try svc.play(src, .{});
    const music = try svc.play(src, .{});
    try testing.expectEqual(@as(usize, 2), mock.active_playbacks);

    // Only `sfx` ends; the mock reports completion globally, so flip it just for the collection call.
    mock.finished = true;
    try testing.expectEqual(@as(usize, 2), svc.collectFinished());
    try testing.expectEqual(@as(usize, 0), mock.active_playbacks);
    try testing.expect(svc.isFinished(sfx));
    try testing.expect(svc.isFinished(music));

    // A fresh manual playback reuses a released slot and is not confused with the stale handles.
    mock.finished = false;
    const next = try svc.play(src, .{});
    try testing.expect(!svc.isFinished(next));
    try testing.expectEqual(@as(usize, 0), svc.collectFinished());
    try testing.expectEqual(@as(usize, 1), mock.active_playbacks);
}

test "non-spatial AudioPlayer re-centers the pan left by a spatial voice" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(audio.module());
    try app.initialize();

    var mock = MockAudioBackend{};
    const svc = app.resources.get(audio.AudioService).?;
    svc.setBackend(mock.vtable());
    const src = try svc.loadFromBytes("RIFFmock", .wav);

    const listener = try app.world.spawn();
    try app.world.set(listener, audio.SpatialListener, .{ .position = .{ 0, 0, 0 } });
    const emitter = try app.world.spawn();
    try app.world.set(emitter, audio.AudioPlayer, .{
        .source = src,
        .position = .{ 5.0, 0, 0 },
        .settings = .{ .mode = .loop, .volume = 1.0, .spatial = true, .max_distance = 10.0 },
    });

    try app.tick(1.0 / 60.0);
    try testing.expectApproxEqAbs(@as(f32, 1.0), mock.last_pan, 1e-5);

    if (app.world.get(emitter, audio.AudioPlayer)) |ap| ap.settings.spatial = false;
    try app.tick(1.0 / 60.0);
    try testing.expectApproxEqAbs(@as(f32, 0.0), mock.last_pan, 1e-5);
}

test "an AudioPlayer stops retrying a failing start after the retry limit" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(audio.module());
    try app.initialize();

    var mock = MockAudioBackend{ .fail_play = true };
    const svc = app.resources.get(audio.AudioService).?;
    svc.setBackend(mock.vtable());
    const src = try svc.loadFromBytes("RIFFmock", .wav);

    const emitter = try app.world.spawn();
    try app.world.set(emitter, audio.AudioPlayer, .{ .source = src, .settings = .{ .mode = .loop } });

    // Every frame used to retry the start; now the attempts stop at the limit.
    for (0..6) |_| try app.tick(1.0 / 60.0);
    try testing.expectEqual(@as(usize, 3), mock.play_calls);
    const ap = app.world.get(emitter, audio.AudioPlayer).?;
    try testing.expect(!ap.auto_play);
    try testing.expect(ap.active_playback == null);
}

test "a released playback slot is reused and its old handle stays invalid" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(audio.module());
    try app.initialize();

    var mock = MockAudioBackend{};
    const svc = app.resources.get(audio.AudioService).?;
    svc.setBackend(mock.vtable());
    const src = try svc.loadFromBytes("RIFFmock", .wav);

    const first = try svc.play(src, .{});
    svc.stop(first);
    try testing.expect(svc.isFinished(first));

    const second = try svc.play(src, .{});
    try testing.expectEqual(first.index, second.index);
    try testing.expect(second.generation != first.generation);
    try testing.expect(svc.isFinished(first));
    try testing.expect(!svc.isFinished(second));
    try testing.expectEqual(@as(usize, 1), mock.active_playbacks);
}
