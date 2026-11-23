//! File Watcher Adapter Tests (`packages/tooling/file-watcher/tests/file_watcher_tests.zig`).
//!
//! Validates `official.tooling.file_watcher` (`lookout` adapter) registration
//! and path containment helpers under Zig 0.17.1.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const file_watcher = @import("file_watcher");

test "FileWatcherService registers and resolves watch paths via lookout" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(file_watcher.module());
    try app.initialize();

    try testing.expect(app.services.hasService("engine.tooling.file_watcher", 1));
    try testing.expect(file_watcher.FileWatcherService.isWithin("/project/assets", "/project/assets/player.png"));
    try testing.expectEqualStrings("player.png", file_watcher.FileWatcherService.relativeTo("/project/assets", "/project/assets/player.png").?);
    try testing.expect(!file_watcher.FileWatcherService.isWithin("/project/assets", "/project/other/x.png"));
}
