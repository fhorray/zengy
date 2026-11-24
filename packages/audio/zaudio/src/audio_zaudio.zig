//! `zaudio` (miniaudio) Audio Provider (`official.audio.zaudio`).
//!
//! Implements `AudioBackendVTable` for `official.audio` (`engine.audio/1`) on top of
//! `zig-gamedev/zaudio` (`miniaudio`), supporting WAV, OGG Vorbis, FLAC, and MP3
//! from memory without leaking `zaudio` types into `audio-core` or `src/core/`.

const std = @import("std");
const engine = @import("engine");
const audio = @import("audio");
const zaudio = @import("zaudio");

/// Module owner identifier for `official.audio.zaudio`.
pub const MODULE_OWNER_ID: u64 = 2037;

/// Provider identifier for `official.audio.zaudio`.
pub const PROVIDER_ID = "official.audio.zaudio";

const SourceEntry = struct {
    id: u64,
    bytes: []u8,
};

const PlaybackEntry = struct {
    id: u64,
    decoder: *zaudio.Decoder,
    sound: *zaudio.Sound,
    paused: bool,
};

const ZaudioState = struct {
    allocator: std.mem.Allocator,
    zaudio_inited: bool = false,
    ma_engine: ?*zaudio.Engine = null,
    next_source_id: u64 = 1,
    next_playback_id: u64 = 1,
    // Keyed by backend id: every per-voice call (volume, pan, finished, stop) is O(1) instead of a scan.
    sources: std.AutoHashMapUnmanaged(u64, SourceEntry) = .empty,
    playbacks: std.AutoHashMapUnmanaged(u64, PlaybackEntry) = .empty,

    fn deinit(self: *ZaudioState) void {
        var pb_it = self.playbacks.valueIterator();
        while (pb_it.next()) |pb| {
            pb.sound.stop() catch {};
            pb.sound.destroy();
            pb.decoder.destroy();
        }
        self.playbacks.deinit(self.allocator);
        self.playbacks = .empty;

        var src_it = self.sources.valueIterator();
        while (src_it.next()) |src| {
            self.allocator.free(src.bytes);
        }
        self.sources.deinit(self.allocator);
        self.sources = .empty;

        if (self.ma_engine) |eng| {
            eng.destroy();
            self.ma_engine = null;
        }
        if (self.zaudio_inited) {
            zaudio.deinit();
            self.zaudio_inited = false;
        }
    }

    fn findSource(self: *const ZaudioState, id: u64) ?SourceEntry {
        return self.sources.get(id);
    }

    fn findPlaybackMut(self: *ZaudioState, id: u64) ?*PlaybackEntry {
        return self.playbacks.getPtr(id);
    }

    fn loadBytes(raw: *anyopaque, bytes: []const u8, format: audio.AudioFormat) anyerror!u64 {
        _ = format;
        const self: *ZaudioState = @ptrCast(@alignCast(raw));
        if (bytes.len == 0) return error.InvalidAudioData;

        // Validate that miniaudio/stb_vorbis can decode this buffer before storing it.
        const probe = try zaudio.Decoder.createFromMemory(
            bytes.ptr,
            bytes.len,
            zaudio.Decoder.Config.initDefault(),
        );
        probe.destroy();

        const copy = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(copy);
        const id = self.next_source_id;
        self.next_source_id += 1;
        try self.sources.put(self.allocator, id, .{ .id = id, .bytes = copy });
        return id;
    }

    fn unloadSource(raw: *anyopaque, backend_source_id: u64) void {
        const self: *ZaudioState = @ptrCast(@alignCast(raw));
        if (self.sources.fetchRemove(backend_source_id)) |kv| self.allocator.free(kv.value.bytes);
    }

    fn play(raw: *anyopaque, backend_source_id: u64, settings: audio.PlaybackSettings) anyerror!u64 {
        const self: *ZaudioState = @ptrCast(@alignCast(raw));
        const eng = self.ma_engine orelse return error.AudioDeviceUnavailable;
        const src = self.findSource(backend_source_id) orelse return error.InvalidAudioSource;

        const decoder = try zaudio.Decoder.createFromMemory(
            src.bytes.ptr,
            src.bytes.len,
            zaudio.Decoder.Config.initDefault(),
        );
        errdefer decoder.destroy();

        const sound = try eng.createSoundFromDataSource(decoder.asDataSourceMut(), .{}, null);
        errdefer sound.destroy();

        sound.setVolume(@max(0.0, settings.volume));
        sound.setPitch(@max(0.05, settings.speed));
        sound.setLooping(settings.mode == .loop);
        if (!settings.paused) {
            try sound.start();
        }

        const id = self.next_playback_id;
        self.next_playback_id += 1;
        try self.playbacks.put(self.allocator, id, .{
            .id = id,
            .decoder = decoder,
            .sound = sound,
            .paused = settings.paused,
        });
        return id;
    }

    fn stop(raw: *anyopaque, backend_playback_id: u64) void {
        const self: *ZaudioState = @ptrCast(@alignCast(raw));
        if (self.playbacks.fetchRemove(backend_playback_id)) |kv| {
            kv.value.sound.stop() catch {};
            kv.value.sound.destroy();
            kv.value.decoder.destroy();
        }
    }

    fn setVolume(raw: *anyopaque, backend_playback_id: u64, volume: f32) void {
        const self: *ZaudioState = @ptrCast(@alignCast(raw));
        const pb = self.findPlaybackMut(backend_playback_id) orelse return;
        pb.sound.setVolume(@max(0.0, volume));
    }

    fn setPaused(raw: *anyopaque, backend_playback_id: u64, paused: bool) void {
        const self: *ZaudioState = @ptrCast(@alignCast(raw));
        const pb = self.findPlaybackMut(backend_playback_id) orelse return;
        if (pb.paused == paused) return;
        pb.paused = paused;
        if (paused) {
            pb.sound.stop() catch {};
        } else {
            pb.sound.start() catch {};
        }
    }

    fn setSpeed(raw: *anyopaque, backend_playback_id: u64, speed: f32) void {
        const self: *ZaudioState = @ptrCast(@alignCast(raw));
        const pb = self.findPlaybackMut(backend_playback_id) orelse return;
        pb.sound.setPitch(@max(0.05, speed));
    }

    fn setPan(raw: *anyopaque, backend_playback_id: u64, pan: f32) void {
        const self: *ZaudioState = @ptrCast(@alignCast(raw));
        const pb = self.findPlaybackMut(backend_playback_id) orelse return;
        pb.sound.setPan(std.math.clamp(pan, -1.0, 1.0));
    }

    fn isFinished(raw: *anyopaque, backend_playback_id: u64) bool {
        const self: *ZaudioState = @ptrCast(@alignCast(raw));
        const pb = self.findPlaybackMut(backend_playback_id) orelse return true;
        return pb.sound.isAtEnd();
    }

    fn vtable(self: *ZaudioState) audio.AudioBackendVTable {
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

fn buildZaudio(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    if (!app.resources.contains(ZaudioState)) {
        try app.resources.insert(ZaudioState, .{ .allocator = app.allocator });
    }
}

fn startZaudio(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    const st = app.resources.get(ZaudioState) orelse return error.MissingAudioState;
    if (!st.zaudio_inited) {
        zaudio.init(app.allocator);
        st.zaudio_inited = true;
    }
    if (st.ma_engine == null) {
        st.ma_engine = try zaudio.Engine.create(null);
    }
    if (app.resources.get(audio.AudioService)) |svc| {
        svc.setBackend(st.vtable());
    }
}

fn stopZaudio(raw_app: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    if (app.resources.get(audio.AudioService)) |svc| {
        svc.setBackend(null);
    }
    _ = app.resources.remove(ZaudioState);
}

/// Returns the `official.audio.zaudio` module providing `engine.audio.backend/1`.
pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = PROVIDER_ID,
            .version = "0.1.0",
            .provides_capabilities = &.{"engine.audio.backend/1"},
            .required_capabilities = &.{"engine.audio/1"},
        },
        .build = buildZaudio,
        .start = startZaudio,
        .stop = stopZaudio,
    };
}
