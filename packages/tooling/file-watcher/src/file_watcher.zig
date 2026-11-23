//! Optional File Watcher Adapter Package (`official.tooling.file_watcher`).
//!
//! Wraps the external `lookout` filesystem watcher behind a stable engine
//! capability (`engine.tooling.file_watcher/1`) for hot reload of scripts,
//! UI markup, and assets without adding OS watcher code to `src/core/`.

const std = @import("std");
const engine = @import("engine");
const lookout = @import("lookout");

pub const MODULE_OWNER_ID: u64 = 2012;

/// Engine adapter service over `lookout`.
pub const FileWatcherService = struct {
    /// Checks whether `candidate` is equal to or inside `base` directory using `lookout.path`.
    pub fn isWithin(base: []const u8, candidate: []const u8) bool {
        return lookout.path.within(base, candidate);
    }

    /// Returns the relative sub-path of `candidate` under `base`, or `null` if outside.
    pub fn relativeTo(base: []const u8, candidate: []const u8) ?[]const u8 {
        return lookout.path.relative(base, candidate);
    }
};

var g_watcher_service = FileWatcherService{};

fn buildModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    try app.services.register(.{
        .capability = "engine.tooling.file_watcher",
        .major_version = 1,
        .provider_id = "official.tooling.file_watcher.lookout",
        .owner_id = MODULE_OWNER_ID,
        .exclusive = true,
        .api_ptr = &g_watcher_service,
        .api_size = @sizeOf(FileWatcherService),
    });
}

fn stopModule(raw_app: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    _ = app.services.unregisterByOwner(MODULE_OWNER_ID);
}

pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = "official.tooling.file_watcher",
            .version = "0.1.0",
            .provides_capabilities = &.{"engine.tooling.file_watcher/1"},
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
