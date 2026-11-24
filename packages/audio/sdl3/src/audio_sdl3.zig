//! SDL3 Audio Provider (`official.audio.sdl3`).
//!
//! Implements `AudioBackendVTable` for `official.audio` (`engine.audio/1`) using
//! SDL3's `SDL_AudioStream` and `SDL_LoadWAV_IO` without leaking SDL types into
//! `audio-core` or `src/core/`.

const std = @import("std");
const engine = @import("engine");
const audio = @import("audio");
const c = @import("sdl3_c");

/// Module owner identifier for `official.audio.sdl3`.
pub const MODULE_OWNER_ID: u64 = 2036;

/// Provider identifier for `official.audio.sdl3`.
pub const PROVIDER_ID = "official.audio.sdl3";

const LoadedSource = struct {
    id: u64,
    spec: c.SDL_AudioSpec,
    data: [*]u8,
    len: u32,
    sdl_owned: bool,
};

const ActivePlayback = struct {
    id: u64,
    source_id: u64,
    stream: *c.SDL_AudioStream,
    loop: bool,
    paused: bool,
};

const SdlAudioState = struct {
    allocator: std.mem.Allocator,
    device_id: c.SDL_AudioDeviceID = 0,
    initialized_subsys: bool = false,
    next_source_id: u64 = 1,
    next_playback_id: u64 = 1,
    sources: std.ArrayList(LoadedSource) = .empty,
    playbacks: std.ArrayList(ActivePlayback) = .empty,

    fn deinit(self: *SdlAudioState) void {
        for (self.playbacks.items) |pb| {
            c.SDL_DestroyAudioStream(pb.stream);
        }
        self.playbacks.deinit(self.allocator);
        self.playbacks = .empty;

        for (self.sources.items) |src| {
            if (src.sdl_owned) {
                c.SDL_free(src.data);
            } else {
                self.allocator.free(src.data[0..src.len]);
            }
        }
        self.sources.deinit(self.allocator);
        self.sources = .empty;

        if (self.device_id != 0) {
            c.SDL_CloseAudioDevice(self.device_id);
            self.device_id = 0;
        }
        if (self.initialized_subsys) {
            c.SDL_QuitSubSystem(c.SDL_INIT_AUDIO);
            self.initialized_subsys = false;
        }
    }

    fn findSource(self: *const SdlAudioState, id: u64) ?LoadedSource {
        for (self.sources.items) |src| {
            if (src.id == id) return src;
        }
        return null;
    }

    fn findPlaybackMut(self: *SdlAudioState, id: u64) ?*ActivePlayback {
        for (self.playbacks.items) |*pb| {
            if (pb.id == id) return pb;
        }
        return null;
    }

    fn loadBytes(raw: *anyopaque, bytes: []const u8, format: audio.AudioFormat) anyerror!u64 {
        const self: *SdlAudioState = @ptrCast(@alignCast(raw));
        if (bytes.len == 0) return error.InvalidAudioData;

        const is_wav = format == .wav or (format == .auto and bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "RIFF"));
        if (is_wav) {
            const io = c.SDL_IOFromConstMem(bytes.ptr, bytes.len) orelse return error.SdlAudioLoadFailed;
            var spec: c.SDL_AudioSpec = undefined;
            var buf: ?[*]u8 = null;
            var len: u32 = 0;
            if (!c.SDL_LoadWAV_IO(io, true, &spec, @ptrCast(&buf), &len)) {
                return error.SdlAudioLoadFailed;
            }
            const ptr = buf orelse return error.SdlAudioLoadFailed;
            const id = self.next_source_id;
            self.next_source_id += 1;
            errdefer c.SDL_free(ptr);
            try self.sources.append(self.allocator, .{
                .id = id,
                .spec = spec,
                .data = ptr,
                .len = len,
                .sdl_owned = true,
            });
            return id;
        }

        if (format == .pcm_f32) {
            const copy = try self.allocator.dupe(u8, bytes);
            errdefer self.allocator.free(copy);
            const id = self.next_source_id;
            self.next_source_id += 1;
            try self.sources.append(self.allocator, .{
                .id = id,
                .spec = .{ .format = c.SDL_AUDIO_F32, .channels = 2, .freq = 48000 },
                .data = copy.ptr,
                .len = @intCast(copy.len),
                .sdl_owned = false,
            });
            return id;
        }

        return error.UnsupportedAudioFormat;
    }

    fn unloadSource(raw: *anyopaque, backend_source_id: u64) void {
        const self: *SdlAudioState = @ptrCast(@alignCast(raw));
        for (self.sources.items, 0..) |src, i| {
            if (src.id == backend_source_id) {
                if (src.sdl_owned) {
                    c.SDL_free(src.data);
                } else {
                    self.allocator.free(src.data[0..src.len]);
                }
                _ = self.sources.swapRemove(i);
                return;
            }
        }
    }

    fn play(raw: *anyopaque, backend_source_id: u64, settings: audio.PlaybackSettings) anyerror!u64 {
        const self: *SdlAudioState = @ptrCast(@alignCast(raw));
        if (self.device_id == 0) return error.AudioDeviceUnavailable;
        const src = self.findSource(backend_source_id) orelse return error.InvalidAudioSource;

        const stream = c.SDL_CreateAudioStream(&src.spec, null) orelse return error.SdlAudioStreamFailed;
        errdefer c.SDL_DestroyAudioStream(stream);

        if (settings.paused) {
            c.SDL_UnbindAudioStream(stream);
        } else if (!c.SDL_BindAudioStream(self.device_id, stream)) {
            return error.SdlAudioBindFailed;
        }
        _ = c.SDL_SetAudioStreamGain(stream, @max(0.0, settings.volume));
        _ = c.SDL_SetAudioStreamFrequencyRatio(stream, @max(0.05, settings.speed));
        if (!c.SDL_PutAudioStreamData(stream, src.data, @intCast(src.len))) {
            return error.SdlAudioStreamFailed;
        }
        if (settings.mode != .loop) {
            _ = c.SDL_FlushAudioStream(stream);
        }

        const id = self.next_playback_id;
        self.next_playback_id += 1;
        try self.playbacks.append(self.allocator, .{
            .id = id,
            .source_id = backend_source_id,
            .stream = stream,
            .loop = settings.mode == .loop,
            .paused = settings.paused,
        });
        return id;
    }

    fn stop(raw: *anyopaque, backend_playback_id: u64) void {
        const self: *SdlAudioState = @ptrCast(@alignCast(raw));
        for (self.playbacks.items, 0..) |pb, i| {
            if (pb.id == backend_playback_id) {
                c.SDL_DestroyAudioStream(pb.stream);
                _ = self.playbacks.swapRemove(i);
                return;
            }
        }
    }

    fn setVolume(raw: *anyopaque, backend_playback_id: u64, volume: f32) void {
        const self: *SdlAudioState = @ptrCast(@alignCast(raw));
        const pb = self.findPlaybackMut(backend_playback_id) orelse return;
        _ = c.SDL_SetAudioStreamGain(pb.stream, @max(0.0, volume));
    }

    fn setPaused(raw: *anyopaque, backend_playback_id: u64, paused: bool) void {
        const self: *SdlAudioState = @ptrCast(@alignCast(raw));
        const pb = self.findPlaybackMut(backend_playback_id) orelse return;
        if (pb.paused == paused) return;
        pb.paused = paused;
        // Unbind/rebind per stream so pausing one voice never pauses the entire SDL audio device.
        if (paused) {
            c.SDL_UnbindAudioStream(pb.stream);
        } else if (self.device_id != 0) {
            _ = c.SDL_BindAudioStream(self.device_id, pb.stream);
        }
    }

    fn setSpeed(raw: *anyopaque, backend_playback_id: u64, speed: f32) void {
        const self: *SdlAudioState = @ptrCast(@alignCast(raw));
        const pb = self.findPlaybackMut(backend_playback_id) orelse return;
        _ = c.SDL_SetAudioStreamFrequencyRatio(pb.stream, @max(0.05, speed));
    }

    fn isFinished(raw: *anyopaque, backend_playback_id: u64) bool {
        const self: *SdlAudioState = @ptrCast(@alignCast(raw));
        const pb = self.findPlaybackMut(backend_playback_id) orelse return true;
        if (pb.paused) return false;
        const queued = c.SDL_GetAudioStreamQueued(pb.stream);
        if (pb.loop) {
            if (self.findSource(pb.source_id)) |src| {
                const threshold: i32 = @intCast(@min(src.len / 2, 65536));
                if (queued <= threshold) {
                    _ = c.SDL_PutAudioStreamData(pb.stream, src.data, @intCast(src.len));
                }
                return false;
            }
        }
        return queued <= 0;
    }

    fn vtable(self: *SdlAudioState) audio.AudioBackendVTable {
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

fn buildSdl3Audio(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    if (!app.resources.contains(SdlAudioState)) {
        try app.resources.insert(SdlAudioState, .{ .allocator = app.allocator });
    }
}

fn startSdl3Audio(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    const st = app.resources.get(SdlAudioState) orelse return error.MissingAudioState;
    if (c.SDL_WasInit(c.SDL_INIT_AUDIO) == 0) {
        if (!c.SDL_InitSubSystem(c.SDL_INIT_AUDIO)) return error.SdlAudioInitFailed;
        st.initialized_subsys = true;
    }
    if (st.device_id == 0) {
        st.device_id = c.SDL_OpenAudioDevice(c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, null);
        if (st.device_id == 0) return error.SdlAudioDeviceFailed;
    }
    if (app.resources.get(audio.AudioService)) |svc| {
        svc.setBackend(st.vtable());
    }
}

fn stopSdl3Audio(raw_app: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    if (app.resources.get(audio.AudioService)) |svc| {
        svc.setBackend(null);
    }
    _ = app.resources.remove(SdlAudioState);
}

/// Returns the `official.audio.sdl3` module providing `engine.audio.backend/1`.
pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = PROVIDER_ID,
            .version = "0.1.0",
            .provides_capabilities = &.{"engine.audio.backend/1"},
            .required_capabilities = &.{"engine.audio/1"},
        },
        .build = buildSdl3Audio,
        .start = startSdl3Audio,
        .stop = stopSdl3Audio,
    };
}
