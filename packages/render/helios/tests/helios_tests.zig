//! Helios Stage 09 Hybrid Lighting Tests (`packages/render/helios/tests/helios_tests.zig`).

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const prism = @import("prism");
const helios = @import("helios");

test "HeliosService combines SSGI, probes, and sky without double-counting and manages WorldRadianceCache" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(prism.module());
    try app.registerModule(helios.module());
    try app.initialize();

    const hsvc = app.resources.get(helios.HeliosService).?;
    hsvc.beginFrame();

    // Energy conservation: identical inputs must not exceed input energy
    const c_same = helios.contract.combineIndirectDiffuse(.{ 0.5, 0.5, 0.5 }, 0.7, .{ 0.5, 0.5, 0.5 }, 0.8, .{ 0.5, 0.5, 0.5 });
    try testing.expectApproxEqAbs(@as(f32, 0.5), c_same[0], 1e-5);

    // Hi-Z SSGI traversal hits an occluder along the ray
    var depth: [16]f32 = @splat(0.95);
    depth[1 * 4 + 2] = 0.45;
    var hiz = prism.HiZPyramid.init(testing.allocator);
    defer hiz.deinit();
    try hiz.buildFromDepth(&depth, 4, 4);
    const trace = helios.ssgi.traceHiZScreenSpace(&hiz, .{ 0.1, 0.35 }, 0.35, .{ 0.25, 0.0, 0.06 }, 8, 0.1);
    try testing.expect(trace.hit);
    try testing.expect(trace.confidence > 0.0);

    // Cosine hemisphere sample points into positive normal hemisphere
    const sdir = helios.ssgi.cosineHemisphereSample(0.3, 0.6, .{ 0, 1, 0 });
    try testing.expect(sdir[1] >= 0.0);

    // Evaluate with probe volume and verify WorldRadianceCache occupancy + eviction
    var vol = try prism.baked_gi.IrradianceProbeVolume.init(testing.allocator, .{ 0, 0, 0 }, .{ 2, 2, 2 }, .{ 2, 2, 2 });
    defer vol.deinit();
    for (vol.probes) |*p| p.sh.addDirectional(.{ 0, 1, 0 }, .{ 0.9, 0.7, 0.5 }, 1.0);

    const out = try hsvc.evaluatePoint(.{ 1, 1, 1 }, .{ 0, 1, 0 }, &vol, .{ 0.2, 0.3, 0.4 }, .{ 0.8, 0.4, 0.2 }, 0.5);
    try testing.expect(out.diffuse_rgb[0] > 0.4);
    try testing.expect(hsvc.cache.cells.count() == 1);
    try testing.expect(hsvc.cache.hits >= 1);

    // Stale eviction
    const evicted = hsvc.cache.evictStale(500, 100);
    try testing.expectEqual(@as(usize, 1), evicted);
    try testing.expectEqual(@as(usize, 0), hsvc.cache.cells.count());
}

test "Stage 11 Helios software BVH closest-hit and any-hit match brute-force reference" {
    const tris = [_]helios.ray_query.BvhTriangle{
        .{ .v0 = .{ -1, -1, -3 }, .v1 = .{ 1, -1, -3 }, .v2 = .{ 0, 1, -3 }, .instance_id = 1, .primitive_id = 10 },
        .{ .v0 = .{ -1, -1, -6 }, .v1 = .{ 1, -1, -6 }, .v2 = .{ 0, 1, -6 }, .instance_id = 2, .primitive_id = 20 },
        .{ .v0 = .{ 4, -1, -4 }, .v1 = .{ 6, -1, -4 }, .v2 = .{ 5, 1, -4 }, .instance_id = 3, .primitive_id = 30 },
        .{ .v0 = .{ -6, -1, -4 }, .v1 = .{ -4, -1, -4 }, .v2 = .{ -5, 1, -4 }, .instance_id = 4, .primitive_id = 40 },
    };

    var bvh = helios.ray_query.Bvh.init(testing.allocator);
    defer bvh.deinit();
    try bvh.build(&tris);

    var stats = helios.ray_query.QueryStats{};
    const r_center = helios.ray_query.Ray{ .origin = .{ 0, 0, 0 }, .direction = .{ 0, 0, -1 } };
    const hit = bvh.traceClosest(r_center, &stats);
    try testing.expect(hit.hit);
    try testing.expectEqual(@as(u32, 10), hit.primitive_id);
    try testing.expectApproxEqAbs(@as(f32, 3.0), hit.t, 1e-4);
    try testing.expectEqual(@as(u64, 0), stats.stack_overflows);
    try testing.expect(bvh.traceAnyHit(r_center, &stats));

    // Differential check against brute-force across 25 deterministic rays
    var prng = std.Random.DefaultPrng.init(0x4845_4C49_4F53);
    const rand = prng.random();
    for (0..25) |_| {
        const ox = rand.float(f32) * 12.0 - 6.0;
        const oy = rand.float(f32) * 2.0 - 1.0;
        const ray = helios.ray_query.Ray{ .origin = .{ ox, oy, 1.0 }, .direction = .{ 0, 0, -1 } };

        const bvh_hit = bvh.traceClosest(ray, null);
        var ref_hit = helios.ray_query.RayHit{ .t = ray.t_max };
        for (tris) |t| {
            if (helios.ray_query.intersectTriangle(ray, t, ref_hit.t)) |h| ref_hit = h;
        }
        try testing.expectEqual(ref_hit.hit, bvh_hit.hit);
        if (ref_hit.hit) {
            try testing.expectApproxEqAbs(ref_hit.t, bvh_hit.t, 1e-4);
            try testing.expectEqual(ref_hit.primitive_id, bvh_hit.primitive_id);
        }
    }
}
