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
    try testing.expectEqual(@as(u64, 0), hsvc.cache.hits);
    _ = try hsvc.evaluatePoint(.{ 1, 1, 1 }, .{ 0, 1, 0 }, &vol, .{ 0.2, 0.3, 0.4 }, .{ 0.8, 0.4, 0.2 }, 0.5);
    try testing.expectEqual(@as(u64, 1), hsvc.cache.hits);

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

const MockRtState = struct { builds: usize = 0, destroys: usize = 0 };
fn mockBuildBlas(ctx: ?*anyopaque, _: u64, _: []const u8, _: []const u8) !helios.hw_rt.BlasHandle {
    const s: *MockRtState = @ptrCast(@alignCast(ctx.?));
    s.builds += 1;
    return .{ .index = @intCast(s.builds), .generation = 1 };
}
fn mockDestroyBlas(ctx: ?*anyopaque, _: helios.hw_rt.BlasHandle) void {
    const s: *MockRtState = @ptrCast(@alignCast(ctx.?));
    s.destroys += 1;
}
fn mockBuildTlas(_: ?*anyopaque, _: []const helios.hw_rt.TlasInstanceDesc) !helios.hw_rt.TlasHandle {
    return .{ .index = 1, .generation = 1 };
}
fn mockDestroyTlas(_: ?*anyopaque, _: helios.hw_rt.TlasHandle) void {}

test "Stage 12 RT acceleration contract & BLAS cache and Stage 13 AliasTable, ReSTIR DI, PathTracer, A-Trous" {
    // Stage 12: SDL fallback explicitly rejects hardware RT
    var cache = helios.hw_rt.BlasCache.init(testing.allocator);
    try testing.expectError(
        error.UnsupportedHardwareRayTracing,
        cache.getOrBuild(helios.hw_rt.UNSUPPORTED_RT_VTABLE, 1, 1, &.{}, &.{}),
    );
    cache.deinit(helios.hw_rt.UNSUPPORTED_RT_VTABLE);

    // Stage 12: Mock native RT provider caches BLAS by revision and destroys on revision change
    var mock_rt = MockRtState{};
    const rt_vt = helios.hw_rt.RtAccelerationVTable{
        .provider_id = "mock.native.rt",
        .capabilities = .{ .supports_ray_query = true, .supports_acceleration_structure = true },
        .ctx = &mock_rt,
        .build_blas = mockBuildBlas,
        .destroy_blas = mockDestroyBlas,
        .build_tlas = mockBuildTlas,
        .destroy_tlas = mockDestroyTlas,
    };
    var native_cache = helios.hw_rt.BlasCache.init(testing.allocator);
    const b1 = try native_cache.getOrBuild(rt_vt, 10, 1, &.{}, &.{});
    const b1_again = try native_cache.getOrBuild(rt_vt, 10, 1, &.{}, &.{});
    try testing.expectEqual(b1.index, b1_again.index);
    try testing.expectEqual(@as(usize, 1), mock_rt.builds);
    _ = try native_cache.getOrBuild(rt_vt, 10, 2, &.{}, &.{});
    try testing.expectEqual(@as(usize, 2), mock_rt.builds);
    try testing.expectEqual(@as(usize, 1), mock_rt.destroys);
    native_cache.deinit(rt_vt);
    try testing.expectEqual(@as(usize, 2), mock_rt.destroys);

    // Stage 13.1: Vose AliasTable PDF normalization & O(1) sampling
    var alias = try helios.light_sampling.AliasTable.build(testing.allocator, &.{ 1.0, 3.0, 6.0 });
    defer alias.deinit();
    var pdf_sum: f32 = 0.0;
    for (alias.entries) |e| pdf_sum += e.pdf;
    try testing.expectApproxEqAbs(@as(f32, 1.0), pdf_sum, 1e-5);
    const samp = alias.sample(0.5, 0.25);
    try testing.expect(samp.index < 3 and samp.pdf > 0.0);
    try testing.expectApproxEqAbs(@as(f32, 0.5), helios.light_sampling.misPowerHeuristic(2.0, 2.0), 1e-5);

    // Stage 13.1: ReSTIR DI Reservoir update, finalize, and temporal/spatial merge
    var res_a = helios.light_sampling.Reservoir{};
    _ = res_a.update(0, 0.5, 2.0, 0.1);
    _ = res_a.update(1, 0.8, 4.0, 0.9);
    res_a.finalize();
    try testing.expect(res_a.unbiased_weight > 0.0);
    var res_b = helios.light_sampling.Reservoir{};
    _ = res_b.update(2, 1.0, 5.0, 0.2);
    res_b.finalize();
    _ = res_a.merge(res_b, 1.0, 0.1);
    try testing.expectEqual(@as(u32, 3), res_a.sample_count);

    // Stage 13.2 & 13.3: ReferencePathTracer progressive accumulation & A-Trous edge-stopping denoiser
    const tris = [_]helios.ray_query.BvhTriangle{
        .{ .v0 = .{ -2, -2, -3 }, .v1 = .{ 2, -2, -3 }, .v2 = .{ 0, 2, -3 }, .instance_id = 0, .primitive_id = 0 },
    };
    const mats = [_]helios.path_tracer.PathTraceMaterial{
        .{ .albedo = .{ 0.8, 0.2, 0.2 }, .emissive = .{ 1.0, 0.5, 0.2 } },
    };
    var bvh = helios.ray_query.Bvh.init(testing.allocator);
    defer bvh.deinit();
    try bvh.build(&tris);

    var pt = try helios.path_tracer.ReferencePathTracer.init(testing.allocator, .{ .width = 8, .height = 8, .max_bounces = 2 });
    defer pt.deinit();
    pt.accumulatePass(&bvh, &mats, .{ 0, 0, 0 });
    pt.accumulatePass(&bvh, &mats, .{ 0, 0, 0 });
    try testing.expectEqual(@as(u32, 2), pt.sample_count);
    const center_px = pt.resolvedPixel(4, 4);
    try testing.expect(center_px[0] > 0.5);

    // A-Trous edge preservation: sharp depth cliff prevents bleeding across edge
    const src = [_][3]f32{
        .{ 1, 1, 1 }, .{ 1, 1, 1 }, .{ 0, 0, 0 },
        .{ 1, 1, 1 }, .{ 1, 1, 1 }, .{ 0, 0, 0 },
        .{ 1, 1, 1 }, .{ 1, 1, 1 }, .{ 0, 0, 0 },
    };
    const depths = [_]f32{
        1.0, 1.0, 50.0,
        1.0, 1.0, 50.0,
        1.0, 1.0, 50.0,
    };
    const norms: [9][3]f32 = @splat(.{ 0, 0, 1 });
    var dst: [9][3]f32 = @splat(.{ 0, 0, 0 });
    helios.path_tracer.atrousDenoisePass(&src, &depths, &norms, &dst, 3, 3, 1, 0.5, 16.0, 2.0);
    try testing.expect(dst[4][0] > 0.95); // Center stays bright, does not bleed from depth=50 column
    try testing.expect(dst[5][0] < 0.05); // Depth=50 column stays dark
}

test "Stage 13.2 one-bounce RT indirect diffuse/specular, cache population, and quality budgets" {
    const tris = [_]helios.ray_query.BvhTriangle{
        // Emissive red ceiling plane at y = 3
        .{ .v0 = .{ -4, 3, -4 }, .v1 = .{ 4, 3, -4 }, .v2 = .{ 4, 3, 4 }, .instance_id = 0, .primitive_id = 0 },
        .{ .v0 = .{ -4, 3, -4 }, .v1 = .{ 4, 3, 4 }, .v2 = .{ -4, 3, 4 }, .instance_id = 0, .primitive_id = 1 },
    };
    const mats = [_]helios.indirect_rt.SurfaceMaterial{
        .{ .albedo = .{ 0.8, 0.1, 0.1 }, .emissive = .{ 3.0, 0.2, 0.1 }, .roughness = 0.4 },
    };
    var bvh = helios.ray_query.Bvh.init(testing.allocator);
    defer bvh.deinit();
    try bvh.build(&tris);

    var stats = helios.ray_query.QueryStats{};
    const diff = helios.indirect_rt.traceIndirectDiffuse(&bvh, &mats, .{ 0, 0, 0 }, .{ 0, 1, 0 }, 0.1, 0.2, 20.0, .{ 0.1, 0.2, 0.4 }, &stats);
    try testing.expect(diff.hit);
    try testing.expect(diff.radiance_rgb[0] > 2.0);
    try testing.expect(stats.rays_cast >= 1);

    const spec = helios.indirect_rt.traceIndirectSpecular(&bvh, &mats, .{ 0, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 1, 0 }, 0.1, 0.2, 0.1, 20.0, .{ 0.1, 0.2, 0.4 }, &stats);
    try testing.expect(spec.hit);
    try testing.expect(spec.radiance_rgb[0] > 2.0);

    var cache = helios.WorldRadianceCache.init(testing.allocator, 2.0, 64);
    defer cache.deinit();
    const avg = try helios.indirect_rt.populateRadianceCacheFromRays(&bvh, &mats, &cache, .{ 0, 0, 0 }, .{ 0, 1, 0 }, 8, 20.0, .{ 0.1, 0.2, 0.4 }, 1, &stats);
    try testing.expect(avg[0] > 1.5);
    try testing.expect(cache.query(.{ 0, 0, 0 }, 0, 1) != null);

    const low_b = helios.indirect_rt.budgetForTier(.low);
    const high_b = helios.indirect_rt.budgetForTier(.high);
    try testing.expect(high_b.rays_per_pixel > low_b.rays_per_pixel);
    try testing.expect(high_b.cache_update_budget > low_b.cache_update_budget);
}

test "Helios Instant-Radiosity BVH GI solver produces colored bounce VPLs in a Cornell room" {
    var tris = std.ArrayList(helios.ray_query.BvhTriangle).empty;
    defer tris.deinit(testing.allocator);
    // Red left wall (mat 0), green right wall (mat 1), white floor (mat 2)
    try helios.gi_solver.appendBoxTriangles(testing.allocator, &tris, .{ -4.0, 3.0, 0.0 }, .{ 0.25, 3.0, 4.0 }, 0);
    try helios.gi_solver.appendBoxTriangles(testing.allocator, &tris, .{ 4.0, 3.0, 0.0 }, .{ 0.25, 3.0, 4.0 }, 1);
    try helios.gi_solver.appendBoxTriangles(testing.allocator, &tris, .{ 0.0, 0.0, 0.0 }, .{ 4.0, 0.25, 4.0 }, 2);

    const mats = [_]helios.indirect_rt.SurfaceMaterial{
        .{ .albedo = .{ 0.85, 0.12, 0.10 } },
        .{ .albedo = .{ 0.12, 0.78, 0.16 } },
        .{ .albedo = .{ 0.80, 0.80, 0.78 } },
    };
    var bvh = helios.ray_query.Bvh.init(testing.allocator);
    defer bvh.deinit();
    try bvh.build(tris.items);

    const emitters = [_]helios.gi_solver.DirectPointEmitter{
        .{ .position = .{ 0.0, 5.0, 0.0 }, .color = .{ 1.0, 0.96, 0.90 }, .lumens = 3000.0, .range = 14.0 },
    };
    var vpls = std.ArrayList(helios.gi_solver.VirtualPointLight).empty;
    defer vpls.deinit(testing.allocator);

    const stats = try helios.gi_solver.solveInstantRadiosity(
        testing.allocator,
        &bvh,
        &mats,
        &emitters,
        null,
        helios.gi_solver.configForTier(.high),
        &vpls,
    );
    try testing.expect(stats.rays_cast >= 64);
    try testing.expect(vpls.items.len >= 3);

    var found_red = false;
    var found_green = false;
    for (vpls.items) |v| {
        if (v.color[0] > 0.7 and v.color[1] < 0.35) found_red = true;
        if (v.color[1] > 0.7 and v.color[0] < 0.35) found_green = true;
    }
    try testing.expect(found_red);
    try testing.expect(found_green);
}

test "GI solver: adaptive sun sampling finds a thin gap that the uniform grid misses" {
    // A sealed room (floor, ceiling, back wall) whose front wall is split by a 4 cm vertical gap. The sun comes
    // through the gap and lands on the floor inside; only the refined sampling can see that.
    var tris = std.ArrayList(helios.ray_query.BvhTriangle).empty;
    defer tris.deinit(testing.allocator);
    const A = testing.allocator;
    try helios.gi_solver.appendBoxTriangles(A, &tris, .{ 0, -0.1, 0 }, .{ 6, 0.1, 6 }, 0); // floor
    try helios.gi_solver.appendBoxTriangles(A, &tris, .{ 0, 4.1, 0 }, .{ 6, 0.1, 6 }, 1); // ceiling
    try helios.gi_solver.appendBoxTriangles(A, &tris, .{ 0, 2, -6 }, .{ 6, 2, 0.1 }, 2); // back wall
    try helios.gi_solver.appendBoxTriangles(A, &tris, .{ -2.88, 2, 6 }, .{ 3.17, 2, 0.1 }, 3); // front wall, left
    try helios.gi_solver.appendBoxTriangles(A, &tris, .{ 3.19, 2, 6 }, .{ 2.86, 2, 0.1 }, 4); // front wall, right (gap 0.04 at x = 0.31, off the sample lattice)
    try helios.gi_solver.appendBoxTriangles(A, &tris, .{ -6.05, 2, 0 }, .{ 0.1, 2, 6 }, 5);
    try helios.gi_solver.appendBoxTriangles(A, &tris, .{ 6.05, 2, 0 }, .{ 0.1, 2, 6 }, 6);

    var bvh = helios.ray_query.Bvh.init(A);
    defer bvh.deinit();
    try bvh.build(tris.items);

    var mats: [7]helios.indirect_rt.SurfaceMaterial = undefined;
    for (&mats) |*m| m.* = .{ .albedo = .{ 0.8, 0.8, 0.8 } };
    mats[0] = .{ .albedo = .{ 0.9, 0.1, 0.1 } }; // red floor

    const sun = helios.gi_solver.DirectSunEmitter{
        .direction = .{ 0.0, -0.45, -1.0 },
        .illuminance_lux = 48000.0,
        .scene_center = .{ 0, 1.5, 0 },
        .scene_radius = 8.0,
    };
    var cfg = helios.gi_solver.configForTier(.high);
    cfg.max_vpls = 64; // keep every cluster so the ranking cannot hide the one behind the gap
    cfg.sun_refine_discontinuities = false; // Isolate the legacy seam-refinement regression.

    // Count candidates that landed on the interior floor (z < 5.5): they exist only if a ray went through the gap.
    var vpls = std.ArrayList(helios.gi_solver.VirtualPointLight).empty;
    defer vpls.deinit(A);

    cfg.sun_refine_max_depth = 0;
    _ = try helios.gi_solver.solveInstantRadiosity(A, &bvh, &mats, &.{}, sun, cfg, &vpls);
    var inside_uniform: usize = 0;
    for (vpls.items) |v| {
        if (v.position[2] < 5.5 and v.position[1] < 2.0 and v.color[0] > 0.7 and v.color[1] < 0.35) inside_uniform += 1;
    }

    cfg.sun_refine_max_depth = 5;
    const stats = try helios.gi_solver.solveInstantRadiosity(A, &bvh, &mats, &.{}, sun, cfg, &vpls);
    var inside_refined: usize = 0;
    for (vpls.items) |v| {
        if (v.position[2] < 5.5 and v.position[1] < 2.0 and v.color[0] > 0.7 and v.color[1] < 0.35) inside_refined += 1;
    }
    try testing.expectEqual(@as(usize, 0), inside_uniform);
    try testing.expect(inside_refined >= 1);
    // The refinement budget bounds the extra work.
    try testing.expect(stats.rays_cast <= 18 * 18 + 19 * 19 + cfg.sun_refine_ray_budget);
}

test "lighting hardening: BVH parallel slab and coincident centroids" {
    const triangle = helios.ray_query.BvhTriangle{
        .v0 = .{ 0, 0, -2 }, .v1 = .{ 1, 0, -2 }, .v2 = .{ 0, 1, -2 },
    };
    const triangles = [_]helios.ray_query.BvhTriangle{triangle} ** 32;
    var bvh = helios.ray_query.Bvh.init(testing.allocator);
    defer bvh.deinit();
    try bvh.build(&triangles);
    try testing.expect(bvh.nodes.items.len > 1);
    const hit = helios.ray_query.Ray{ .origin = .{ 0, 0.25, 0 }, .direction = .{ 0, 0, -1 } };
    try testing.expect(bvh.traceClosest(hit, null).hit);
    try testing.expect(bvh.traceAnyHit(hit, null));
    const miss = helios.ray_query.Ray{ .origin = .{ -0.01, 0.25, 0 }, .direction = .{ 0, 0, -1 } };
    try testing.expect(!bvh.traceClosest(miss, null).hit);
    try testing.expect(!bvh.traceAnyHit(miss, null));
}

test "lighting hardening: directional cache does not revive stale samples" {
    var cache = helios.WorldRadianceCache.init(testing.allocator, 2, 16);
    defer cache.deinit();
    const pos = [3]f32{ 0.5, 0.5, 0.5 };
    try cache.accumulateSurface(pos, .{ 0, 1, 0 }, 0, .{ 1, 0, 0 }, 1);
    try testing.expect(cache.querySurface(pos, .{ 0, -1, 0 }, 0, 2) == null);
    try testing.expect(cache.querySurface(pos, .{ 0, 1, 0 }, 0, 2) != null);
    try testing.expect(cache.querySurface(pos, .{ 0, 1, 0 }, 0, 500) == null);
    try cache.accumulateSurface(pos, .{ 0, 1, 0 }, 0, .{ 0, 1, 0 }, 500);
    const cell = cache.querySurface(pos, .{ 0, 1, 0 }, 0, 500).?;
    try testing.expectEqual(@as(u32, 1), cell.sample_count);
    try testing.expectEqual(@as(f32, 1), cell.rgb[1]);
}


test "radiance cache evicts the actual least recently used entry" {
    var cache = helios.WorldRadianceCache.init(testing.allocator, 1, 16);
    defer cache.deinit();
    for (0..16) |i| {
        const x: f32 = @floatFromInt(i);
        try cache.accumulate(.{ x, 0, 0 }, 0, .{ 1, 1, 1 }, 1);
    }
    _ = cache.query(.{ 0, 0, 0 }, 0, 2);
    try cache.accumulate(.{ 16, 0, 0 }, 0, .{ 1, 1, 1 }, 3);
    try testing.expect(cache.query(.{ 0, 0, 0 }, 0, 3) != null);
    try testing.expect(cache.query(.{ 1, 0, 0 }, 0, 3) == null);
    try testing.expectEqual(@as(usize, 16), cache.cells.count());
    try testing.expectEqual(@as(usize, 16), cache.evictStale(500, 100));
    try testing.expect(cache.oldest_key == null and cache.newest_key == null);
    try cache.accumulate(.{ 9, 0, 0 }, 0, .{ 1, 1, 1 }, 501);
    cache.invalidateAll();
    try testing.expect(cache.oldest_key == null and cache.newest_key == null);
}


test "Helios runtime retains scene after invalid geometry replacement" {
    var runtime = helios.LightingRuntime.init(testing.allocator);
    defer runtime.deinit();
    const tri = helios.ray_query.BvhTriangle{
        .v0 = .{ 0, 0, -2 }, .v1 = .{ 1, 0, -2 }, .v2 = .{ 0, 1, -2 },
    };
    const mats = [_]helios.indirect_rt.SurfaceMaterial{.{} };
    try runtime.replaceGeometry(&.{tri}, &mats);
    const revision = runtime.geometry_revision;
    try testing.expectError(error.InvalidMaterialIndex, runtime.replaceGeometry(&.{tri}, &.{}));
    try testing.expectEqual(revision, runtime.geometry_revision);
    const ray = helios.ray_query.Ray{ .origin = .{ 0.2, 0.2, 0 }, .direction = .{ 0, 0, -1 } };
    try testing.expect(runtime.bvh.traceClosest(ray, null).hit);
    _ = try runtime.solve(&.{}, null, helios.gi_solver.configForTier(.off));
    try testing.expectEqual(@as(usize, 0), runtime.result().len);
    try testing.expect(!runtime.dirty);
}


test "Dynamic GI: empty scene converges to sky with bounded probe updates" {
    var bvh = helios.ray_query.Bvh.init(testing.allocator);
    defer bvh.deinit();
    var grid = helios.dynamic_gi.Grid{};
    grid.origin_enabled[3] = 1;
    var cursor: usize = 0;
    const cfg = helios.dynamic_gi.Settings{ .probes_per_frame = 64, .rays_per_probe = 24, .sky_radiance = .{ 0.2, 0.4, 0.6 } };
    const stats = helios.dynamic_gi.update(&grid, &bvh, &.{}, &.{}, null, cfg, &cursor, 0);
    try testing.expectEqual(@as(u64, 64 * (24 + 6)), stats.rays_cast);
    const result = helios.dynamic_gi.sample(&grid, .{ 1.5, 1.5, 1.5 }, .{ 0, 1, 0 });
    try testing.expectApproxEqAbs(@as(f32, 1), result.confidence, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.4), result.rgb[1], 1e-5);
}

test "Dynamic GI: unmeasured visibility and invalid normal fall back" {
    var grid = helios.dynamic_gi.Grid{};
    grid.origin_enabled[3] = 1;
    grid.probes[0].offset_validity[3] = 1;
    const unknown = helios.dynamic_gi.sample(&grid, .{ 0, 0, 0 }, .{ 0, 1, 0 });
    try testing.expectEqual(@as(f32, 0), unknown.confidence);
    grid.probes[0].moments[0] = .{ 1, 1, 0, 0 };
    const zero_normal = helios.dynamic_gi.sample(&grid, .{ 0, 0, 0 }, .{ 0, 0, 0 });
    try testing.expectEqual(@as(f32, 0), zero_normal.confidence);
    var bvh = helios.ray_query.Bvh.init(testing.allocator);
    defer bvh.deinit();
    var cursor: usize = 0;
    const stats = helios.dynamic_gi.update(&grid, &bvh, &.{}, &.{}, null, .{ .rays_per_probe = 0 }, &cursor, 0);
    try testing.expectEqual(@as(u64, 0), stats.rays_cast);
    try testing.expectEqual(@as(usize, 0), cursor);
}


test "SSGI trace and resolve use the same texel addressing" {
    var hiz = prism.HiZPyramid.init(testing.allocator);
    defer hiz.deinit();
    const depth = [_]f32{ 0.95, 0.95, 0.45, 0.95 };
    try hiz.buildFromDepth(&depth, 4, 1);
    const trace = helios.ssgi.traceHiZScreenSpace(&hiz, .{ 0.49, 0.5 }, 0.40, .{ 0.11, 0, 0.06 }, 1, 0.05);
    try testing.expect(trace.hit);
    const rgb = [_][3]f32{ .{0,0,0}, .{1,0,0}, .{0,1,0}, .{0,0,1} };
    const resolved = helios.ssgi.resolveRadiance(&hiz, &rgb, trace, .{ 0, 0, 0 });
    try testing.expect(resolved[1] > 0 and resolved[0] == 0);
}


test "MIS and light sampling remain finite at extreme intensities" {
    const a = helios.light_sampling.misPowerHeuristic(1e30, 1e30);
    try testing.expectApproxEqAbs(@as(f32, 0.5), a, 1e-5);
    var table = try helios.light_sampling.AliasTable.build(testing.allocator, &.{ 1e38, 1e38, 1e38, 1e38 });
    defer table.deinit();
    try testing.expectApproxEqAbs(@as(f32, 0.25), table.sample(100, 0.5).pdf, 1e-5);
}

test "reservoir rejects invalid updates and retains valid zero samples" {
    var reservoir = helios.light_sampling.Reservoir{};
    try testing.expect(!reservoir.update(1, std.math.nan(f32), 1, 0.5));
    try testing.expectEqual(@as(u32, 0), reservoir.sample_count);
    try testing.expect(!reservoir.update(2, 0, 1, 0.5));
    try testing.expectEqual(@as(u32, 1), reservoir.sample_count);
    try testing.expect(reservoir.update(3, 1, 2, 0.5));
    reservoir.finalize();
    try testing.expectEqual(@as(f32, 1), reservoir.unbiased_weight);
}


test "dynamic GI invalidation preserves distant probe history" {
    var grid=helios.dynamic_gi.Grid{};
    grid.origin_enabled[3]=1;
    for(&grid.probes) |*probe| probe.offset_validity[3]=1;
    const nearest=helios.dynamic_gi.invalidateNear(&grid,.{0,0,0},0.5);
    try testing.expectEqual(@as(usize,0),nearest);
    try testing.expectEqual(@as(f32,0),grid.probes[0].offset_validity[3]);
    try testing.expectEqual(@as(f32,1),grid.probes[63].offset_validity[3]);
}

test "BVH rejects non-finite public rays" {
    var bvh=helios.ray_query.Bvh.init(testing.allocator);
    defer bvh.deinit();
    const t=helios.ray_query.BvhTriangle{.v0=.{0,0,-1},.v1=.{1,0,-1},.v2=.{0,1,-1}};
    try bvh.build(&.{t});
    const ray=helios.ray_query.Ray{.origin=.{std.math.nan(f32),0,0},.direction=.{0,0,-1}};
    try testing.expect(!bvh.traceClosest(ray,null).hit);
    try testing.expect(!bvh.traceAnyHit(ray,null));
}


test "dynamic GI hard ray budget includes relocation and visibility" {
    var bvh=helios.ray_query.Bvh.init(testing.allocator);defer bvh.deinit();
    var grid=helios.dynamic_gi.Grid{};grid.origin_enabled[3]=1;
    var cursor:usize=0;
    const stats=helios.dynamic_gi.update(&grid,&bvh,&.{},&.{},null,.{.probes_per_frame=64,.rays_per_probe=64,.max_ray_queries=100},&cursor,0);
    try testing.expect(stats.rays_cast<=100);
    try testing.expect(cursor>0);
}
