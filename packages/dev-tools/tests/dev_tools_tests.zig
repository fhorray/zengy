//! Developer Tools & Per-Pass Profiler Tests (`packages/dev-tools/tests/dev_tools_tests.zig`).

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const dev_tools = @import("dev_tools");

test "FrameProfilerService records per-pass timings and rolling FPS" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(dev_tools.module());
    try app.initialize();

    const prof = app.resources.get(dev_tools.FrameProfilerService).?;
    prof.beginFrame(1_000_000);
    prof.recordPass("Shadow", .shadow, 2_200_000);
    prof.recordPass("SSAO", .ssao, 1_100_000);
    prof.recordPass("Forward+", .forward_plus, 3_500_000);
    prof.recordPass("Volumetric", .volumetric, 900_000);
    prof.recordPass("Bloom", .bloom, 600_000);
    prof.recordPass("PostFX", .postfx, 400_000);
    prof.endFrame(9_700_000);

    try testing.expectEqual(@as(usize, 6), prof.latestPasses().len);
    try testing.expectEqualStrings("Shadow", prof.latestPasses()[0].nameSlice());
    try testing.expectApproxEqAbs(@as(f64, 2.2), prof.passMs(.shadow), 1e-4);
    try testing.expectApproxEqAbs(@as(f64, 3.5), prof.passMs(.forward_plus), 1e-4);
    try testing.expectApproxEqAbs(@as(f64, 8.7), prof.totalFrameMs(), 1e-4);
    try testing.expect(prof.fps() > 100.0);

    prof.reset();
    try testing.expectEqual(@as(usize, 0), prof.latestPasses().len);
    try testing.expectApproxEqAbs(@as(f64, 0.0), prof.totalFrameMs(), 1e-6);
}
