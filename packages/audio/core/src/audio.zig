//! Agnostic Audio Contract & ECS Playback (`official.audio`).
//!
//! Defines `AudioSourceHandle`, `AudioPlayer`, `PlaybackSettings`,
//! `SpatialListener`, `AudioBackendVTable`, and `AudioService` (`engine.audio/1`)
//! without depending on any OS audio API or decoder library.

const std = @import("std");
const engine = @import("engine");

/// Encoded audio container/stream format hint passed to backends.
pub const AudioFormat = enum {
    auto,
    wav,
    ogg,
    pcm_f32,
};

/// Generational handle to a loaded audio source in `AudioService`.
pub const AudioSourceHandle = packed struct(u64) {
    index: u32,
    generation: u32,

    pub const invalid: AudioSourceHandle = .{ .index = 0, .generation = 0 };
};

/// Generational handle to an active playback instance.
pub const AudioPlaybackHandle = packed struct(u64) {
    index: u32,
    generation: u32,

    pub const invalid: AudioPlaybackHandle = .{ .index = 0, .generation = 0 };
};

/// Behavior when a non-looping `AudioPlayer` finishes playing.
pub const PlaybackMode = enum {
    once,
    loop,
    despawn,
    remove_component,
};

/// Playback parameters for `AudioService.play()` and `AudioPlayer`.
pub const PlaybackSettings = struct {
    mode: PlaybackMode = .once,
    volume: f32 = 1.0,
    speed: f32 = 1.0,
    paused: bool = false,
    spatial: bool = false,
    max_distance: f32 = 50.0,
};

/// ECS component that plays an `AudioSourceHandle` and tracks its active playback.
pub const AudioPlayer = struct {
    source: AudioSourceHandle,
    settings: PlaybackSettings = .{},
    position: [3]f32 = .{ 0, 0, 0 },
    auto_play: bool = true,
    active_playback: ?AudioPlaybackHandle = null,
    applied_source: AudioSourceHandle = .invalid,
    applied_volume: f32 = -1.0,
    applied_paused: bool = false,
    applied_speed: f32 = -1.0,
    applied_pan: f32 = -2.0,
};

/// ECS component marking the active listener position and right vector for spatial audio.
pub const SpatialListener = struct {
    position: [3]f32 = .{ 0, 0, 0 },
    right: [3]f32 = .{ 1, 0, 0 },
    master_volume: f32 = 1.0,
};

/// Backend vtable implemented by concrete audio providers (e.g. `official.audio.sdl3`, `official.audio.zaudio`).
pub const AudioBackendVTable = struct {
    ctx: *anyopaque,
    loadBytes: *const fn (ctx: *anyopaque, bytes: []const u8, format: AudioFormat) anyerror!u64,
    unloadSource: *const fn (ctx: *anyopaque, backend_source_id: u64) void,
    play: *const fn (ctx: *anyopaque, backend_source_id: u64, settings: PlaybackSettings) anyerror!u64,
    stop: *const fn (ctx: *anyopaque, backend_playback_id: u64) void,
    setVolume: *const fn (ctx: *anyopaque, backend_playback_id: u64, volume: f32) void,
    setPaused: *const fn (ctx: *anyopaque, backend_playback_id: u64, paused: bool) void,
    setSpeed: *const fn (ctx: *anyopaque, backend_playback_id: u64, speed: f32) void,
    isFinished: *const fn (ctx: *anyopaque, backend_playback_id: u64) bool,
    setPan: ?*const fn (ctx: *anyopaque, backend_playback_id: u64, pan: f32) void = null,
};

const SourceSlot = struct {
    generation: u32 = 1,
    alive: bool = false,
    backend_id: u64 = 0,
};

const PlaybackSlot = struct {
    generation: u32 = 1,
    alive: bool = false,
    backend_id: u64 = 0,
    source: AudioSourceHandle = .invalid,
};

/// Resource & service (`engine.audio/1`) managing audio sources and active playbacks.
pub const AudioService = struct {
    allocator: std.mem.Allocator,
    backend: ?AudioBackendVTable = null,
    sources: std.ArrayList(SourceSlot) = .empty,
    playbacks: std.ArrayList(PlaybackSlot) = .empty,
    master_volume: f32 = 1.0,

    /// Initializes an empty `AudioService`.
    pub fn init(allocator: std.mem.Allocator) AudioService {
        return .{ .allocator = allocator };
    }

    /// Releases all active playbacks, loaded sources, and slot buffers.
    pub fn deinit(self: *AudioService) void {
        if (self.backend) |be| {
            for (self.playbacks.items) |*pb| {
                if (pb.alive) be.stop(be.ctx, pb.backend_id);
            }
            for (self.sources.items) |*src| {
                if (src.alive) be.unloadSource(be.ctx, src.backend_id);
            }
        }
        self.playbacks.deinit(self.allocator);
        self.sources.deinit(self.allocator);
        self.playbacks = .empty;
        self.sources = .empty;
        self.backend = null;
    }

    /// Registers or clears the active hardware/software audio backend.
    pub fn setBackend(self: *AudioService, backend: ?AudioBackendVTable) void {
        if (self.backend) |old_be| {
            for (self.playbacks.items) |*pb| {
                if (pb.alive) {
                    old_be.stop(old_be.ctx, pb.backend_id);
                    pb.alive = false;
                    pb.generation +%= 1;
                }
            }
            for (self.sources.items) |*src| {
                if (src.alive) {
                    old_be.unloadSource(old_be.ctx, src.backend_id);
                    src.alive = false;
                    src.generation +%= 1;
                }
            }
        }
        self.backend = backend;
    }

    /// Decodes/loads an audio source from raw file bytes (`wav`, `ogg`, or `auto`).
    pub fn loadFromBytes(self: *AudioService, bytes: []const u8, format: AudioFormat) !AudioSourceHandle {
        const be = self.backend orelse return error.MissingAudioBackend;
        const backend_id = try be.loadBytes(be.ctx, bytes, format);
        errdefer be.unloadSource(be.ctx, backend_id);

        for (self.sources.items, 0..) |*slot, i| {
            if (!slot.alive) {
                if (slot.generation == 0) slot.generation = 1;
                slot.alive = true;
                slot.backend_id = backend_id;
                return .{ .index = @intCast(i), .generation = slot.generation };
            }
        }

        const idx: u32 = @intCast(self.sources.items.len);
        try self.sources.append(self.allocator, .{
            .generation = 1,
            .alive = true,
            .backend_id = backend_id,
        });
        return .{ .index = idx, .generation = 1 };
    }

    /// Reads an audio file from disk via `std.Io` and loads it into the backend.
    pub fn loadFromFile(self: *AudioService, io: std.Io, path: []const u8) !AudioSourceHandle {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(64 * 1024 * 1024));
        defer self.allocator.free(bytes);
        const fmt: AudioFormat = if (std.mem.endsWith(u8, path, ".wav"))
            .wav
        else if (std.mem.endsWith(u8, path, ".ogg"))
            .ogg
        else
            .auto;
        return self.loadFromBytes(bytes, fmt);
    }

    /// Unloads a previously loaded `AudioSourceHandle` and invalidates stale handles.
    pub fn unloadSource(self: *AudioService, handle: AudioSourceHandle) bool {
        if (handle.index >= self.sources.items.len) return false;
        const slot = &self.sources.items[handle.index];
        if (!slot.alive or slot.generation != handle.generation) return false;

        if (self.backend) |be| {
            for (self.playbacks.items) |*pb| {
                if (pb.alive and std.meta.eql(pb.source, handle)) {
                    be.stop(be.ctx, pb.backend_id);
                    pb.alive = false;
                    pb.generation +%= 1;
                }
            }
            be.unloadSource(be.ctx, slot.backend_id);
        }
        slot.alive = false;
        slot.generation +%= 1;
        return true;
    }

    /// Starts playing `source` with `settings` and returns a generational `AudioPlaybackHandle`.
    pub fn play(self: *AudioService, source: AudioSourceHandle, settings: PlaybackSettings) !AudioPlaybackHandle {
        const be = self.backend orelse return error.MissingAudioBackend;
        if (source.index >= self.sources.items.len) return error.InvalidAudioSource;
        const src_slot = &self.sources.items[source.index];
        if (!src_slot.alive or src_slot.generation != source.generation) return error.InvalidAudioSource;

        var scaled = settings;
        scaled.volume = std.math.clamp(settings.volume * self.master_volume, 0.0, 4.0);
        const backend_id = try be.play(be.ctx, src_slot.backend_id, scaled);
        errdefer be.stop(be.ctx, backend_id);

        for (self.playbacks.items, 0..) |*slot, i| {
            if (!slot.alive) {
                if (slot.generation == 0) slot.generation = 1;
                slot.alive = true;
                slot.backend_id = backend_id;
                slot.source = source;
                return .{ .index = @intCast(i), .generation = slot.generation };
            }
        }

        const idx: u32 = @intCast(self.playbacks.items.len);
        try self.playbacks.append(self.allocator, .{
            .generation = 1,
            .alive = true,
            .backend_id = backend_id,
            .source = source,
        });
        return .{ .index = idx, .generation = 1 };
    }

    fn resolvePlayback(self: *const AudioService, handle: AudioPlaybackHandle) ?*const PlaybackSlot {
        if (handle.index >= self.playbacks.items.len) return null;
        const slot = &self.playbacks.items[handle.index];
        if (!slot.alive or slot.generation != handle.generation) return null;
        return slot;
    }

    /// Stops an active playback and invalidates `handle`.
    pub fn stop(self: *AudioService, handle: AudioPlaybackHandle) void {
        if (handle.index >= self.playbacks.items.len) return;
        const slot = &self.playbacks.items[handle.index];
        if (!slot.alive or slot.generation != handle.generation) return;
        if (self.backend) |be| be.stop(be.ctx, slot.backend_id);
        slot.alive = false;
        slot.generation +%= 1;
    }

    /// Updates playback volume (clamped >= 0).
    pub fn setVolume(self: *AudioService, handle: AudioPlaybackHandle, volume: f32) void {
        const slot = self.resolvePlayback(handle) orelse return;
        if (self.backend) |be| {
            be.setVolume(be.ctx, slot.backend_id, std.math.clamp(volume * self.master_volume, 0.0, 4.0));
        }
    }

    /// Pauses or resumes an active playback.
    pub fn setPaused(self: *AudioService, handle: AudioPlaybackHandle, paused: bool) void {
        const slot = self.resolvePlayback(handle) orelse return;
        if (self.backend) |be| be.setPaused(be.ctx, slot.backend_id, paused);
    }

    /// Updates playback speed/pitch ratio.
    pub fn setSpeed(self: *AudioService, handle: AudioPlaybackHandle, speed: f32) void {
        const slot = self.resolvePlayback(handle) orelse return;
        if (self.backend) |be| be.setSpeed(be.ctx, slot.backend_id, @max(0.05, speed));
    }

    /// Updates stereo pan in `[-1.0, 1.0]` (`-1` = left, `0` = center, `+1` = right).
    pub fn setPan(self: *AudioService, handle: AudioPlaybackHandle, pan: f32) void {
        const slot = self.resolvePlayback(handle) orelse return;
        if (self.backend) |be| {
            if (be.setPan) |fn_pan| {
                fn_pan(be.ctx, slot.backend_id, std.math.clamp(pan, -1.0, 1.0));
            }
        }
    }

    /// Returns `true` if `handle` is no longer active or the backend reports completion.
    pub fn isFinished(self: *const AudioService, handle: AudioPlaybackHandle) bool {
        const slot = self.resolvePlayback(handle) orelse return true;
        const be = self.backend orelse return true;
        return be.isFinished(be.ctx, slot.backend_id);
    }
};

const SpatialParams = struct { gain: f32, pan: f32 };

fn computeSpatialParams(listener_pos: [3]f32, listener_right: [3]f32, source_pos: [3]f32, max_distance: f32) SpatialParams {
    if (max_distance <= 0.0) return .{ .gain = 0.0, .pan = 0.0 };
    const dx = source_pos[0] - listener_pos[0];
    const dy = source_pos[1] - listener_pos[1];
    const dz = source_pos[2] - listener_pos[2];
    const dist = @sqrt(dx * dx + dy * dy + dz * dz);
    const gain = std.math.clamp(1.0 - dist / max_distance, 0.0, 1.0);
    const pan = if (dist > 0.001)
        std.math.clamp((dx * listener_right[0] + dy * listener_right[1] + dz * listener_right[2]) / dist, -1.0, 1.0)
    else
        0.0;
    return .{ .gain = gain, .pan = pan };
}

fn audioUpdateSystem(ctx: *engine.SystemContext) !void {
    const svc = ctx.resources.get(AudioService) orelse return;
    if (svc.backend == null) return;

    var listener_pos: ?[3]f32 = null;
    var listener_right: [3]f32 = .{ 1, 0, 0 };
    var listener_gain: f32 = 1.0;
    {
        var lq = try ctx.query(.{ .read = .{SpatialListener} });
        defer lq.deinit();
        if (lq.next()) |lrow| {
            const l = lrow.read(SpatialListener);
            listener_pos = l.position;
            listener_right = l.right;
            listener_gain = l.master_volume;
        }
    }

    var pq = try ctx.query(.{ .write = .{AudioPlayer} });
    defer pq.deinit();
    while (pq.next()) |row| {
        const p = row.write(AudioPlayer);
        const spatial: SpatialParams = if (p.settings.spatial and listener_pos != null)
            computeSpatialParams(listener_pos.?, listener_right, p.position, p.settings.max_distance)
        else
            .{ .gain = 1.0, .pan = 0.0 };
        const spatial_scale = spatial.gain * listener_gain;

        if (p.active_playback) |pb| {
            if (p.source != p.applied_source) {
                svc.stop(pb);
                p.active_playback = null;
            }
        }

        const eff_vol = p.settings.volume * spatial_scale;
        if (p.active_playback == null and p.auto_play) {
            var eff = p.settings;
            eff.volume = eff_vol;
            if (svc.play(p.source, eff)) |pb| {
                p.active_playback = pb;
                p.applied_source = p.source;
                p.applied_volume = eff_vol;
                p.applied_paused = p.settings.paused;
                p.applied_speed = p.settings.speed;
                p.applied_pan = if (p.settings.spatial) spatial.pan else 0.0;
                if (p.settings.spatial) svc.setPan(pb, spatial.pan);
            } else |err| {
                std.log.warn("audio: failed to start playback: {s}", .{@errorName(err)});
            }
            continue;
        }

        if (p.active_playback) |pb| {
            if (svc.isFinished(pb)) {
                svc.stop(pb);
                p.active_playback = null;
                p.applied_source = .invalid;
                switch (p.settings.mode) {
                    .once => p.auto_play = false,
                    .loop => {},
                    .despawn => try ctx.commands.despawn(row.entity),
                    .remove_component => try ctx.commands.remove(row.entity, AudioPlayer),
                }
            } else {
                if (@abs(eff_vol - p.applied_volume) > 1e-4) {
                    svc.setVolume(pb, eff_vol);
                    p.applied_volume = eff_vol;
                }
                if (p.settings.paused != p.applied_paused) {
                    svc.setPaused(pb, p.settings.paused);
                    p.applied_paused = p.settings.paused;
                }
                if (@abs(p.settings.speed - p.applied_speed) > 1e-4) {
                    svc.setSpeed(pb, p.settings.speed);
                    p.applied_speed = p.settings.speed;
                }
                if (p.settings.spatial and @abs(spatial.pan - p.applied_pan) > 1e-3) {
                    svc.setPan(pb, spatial.pan);
                    p.applied_pan = spatial.pan;
                }
            }
        }
    }
}

const MODULE_OWNER_ID: u64 = 2035;

fn buildAudioModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    if (!app.resources.contains(AudioService)) {
        try app.resources.insert(AudioService, AudioService.init(app.allocator));
    }
    const svc = app.resources.get(AudioService).?;
    try app.services.register(.{
        .capability = "engine.audio",
        .major_version = 1,
        .provider_id = "official.audio.core",
        .owner_id = MODULE_OWNER_ID,
        .exclusive = true,
        .api_ptr = svc,
        .api_size = @sizeOf(AudioService),
    });
    _ = try app.world.registerComponent(AudioPlayer);
    _ = try app.world.registerComponent(SpatialListener);
    try app.addSystem(.{
        .name = "audio.update",
        .stage = .post_update,
        .run = audioUpdateSystem,
    });
}

fn startAudioModule(_: *anyopaque) !void {}

fn stopAudioModule(raw_app: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    _ = app.services.unregisterByOwner(MODULE_OWNER_ID);
    _ = app.resources.remove(AudioService);
}

/// Returns the `official.audio` module providing `engine.audio/1`.
pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = "official.audio",
            .version = "0.1.0",
            .provides_capabilities = &.{"engine.audio/1"},
        },
        .build = buildAudioModule,
        .start = startAudioModule,
        .stop = stopAudioModule,
    };
}
