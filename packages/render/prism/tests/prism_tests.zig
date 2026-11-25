//! Prism Stage 01 Foundation Tests (`packages/render/prism/tests/prism_tests.zig`).

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const prism = @import("prism");

test "ViewRegistry generational handles, resize invalidation, and capability fallback" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(prism.module());
    try app.initialize();

    const svc = app.resources.get(prism.PrismService).?;
    const v1 = try svc.views.createView(1280, 720, .{
        .lighting = .ray_traced,
        .anti_aliasing = .taa,
        .resolution_scale = 1.0,
        .allow_fallback = true,
    });
    try testing.expect(v1.isValid());
    try testing.expectEqual(@as(usize, 1), svc.views.activeCount());

    // Default headless capabilities have no RT/hybrid/TAA -> graceful fallback
    const eff = try svc.resolveView(v1);
    try testing.expectEqual(prism.LightingMode.rasterized, eff.lighting);
    try testing.expectEqual(prism.AntiAliasingMode.fxaa, eff.anti_aliasing);
    try testing.expect(eff.fallback_reason != .none);

    // Strict mode rejects unsupported features
    const strict_v = try svc.views.createView(800, 600, .{
        .lighting = .ray_traced,
        .allow_fallback = false,
    });
    try testing.expectError(error.UnsupportedRenderFeature, svc.resolveView(strict_v));

    // Resize invalidates temporal history
    svc.views.getView(v1).?.history_valid = true;
    try testing.expect(svc.views.resizeView(v1, 1920, 1080));
    try testing.expect(!svc.views.getView(v1).?.history_valid);

    // Destroy invalidates old handle and bumps generation on reuse
    try testing.expect(svc.views.destroyView(v1));
    try testing.expect(svc.views.getView(v1) == null);
    const v1_reused = try svc.views.createView(640, 480, .{});
    try testing.expectEqual(v1.index, v1_reused.index);
    try testing.expect(v1_reused.generation != v1.generation);
}

test "PassGraph compiles Forward+ schedule via RecordingBackend and rejects invalid graphs" {
    var svc = prism.PrismService.init(testing.allocator);
    defer svc.deinit();

    var rec = prism.RecordingBackend.init(testing.allocator, .{});
    defer rec.deinit();
    svc.setBackend(rec.vtable());

    const view = try svc.views.createView(1280, 720, .{});
    var graph = try prism.buildDefaultForwardPlusGraph(testing.allocator, .{
        .enable_shadows = true,
        .enable_ssao = true,
        .enable_volumetric = true,
        .enable_bloom = true,
    });
    defer graph.deinit();

    try svc.executeGraphForView(view, &graph);
    try testing.expectEqual(@as(u64, 1), rec.frames_begun);
    try testing.expectEqual(@as(u64, 1), rec.frames_ended);
    try testing.expectEqual(@as(usize, 6), rec.recorded_passes.items.len);
    try testing.expectEqualStrings("Shadow", rec.recorded_passes.items[0].pass_name);
    try testing.expectEqualStrings("SSAO", rec.recorded_passes.items[1].pass_name);
    try testing.expectEqualStrings("Forward+", rec.recorded_passes.items[2].pass_name);
    try testing.expectEqualStrings("Volumetric", rec.recorded_passes.items[3].pass_name);
    try testing.expectEqualStrings("Bloom", rec.recorded_passes.items[4].pass_name);
    try testing.expectEqualStrings("PostFX", rec.recorded_passes.items[5].pass_name);

    // Read-before-write rejection
    var bad_rbw = prism.PassGraph.init(testing.allocator);
    defer bad_rbw.deinit();
    const r0 = try bad_rbw.declareResource(.{ .name = "uninit_hdr" });
    const acc_read = [_]prism.pass_graph.PassResourceAccess{.{ .resource = r0, .usage = .read }};
    _ = try bad_rbw.addPass(.{ .name = "BadReader", .accesses = &acc_read });
    try testing.expectError(prism.pass_graph.GraphError.ReadBeforeWrite, bad_rbw.compile(testing.allocator));

    // Cycle rejection
    var bad_cyc = prism.PassGraph.init(testing.allocator);
    defer bad_cyc.deinit();
    const dep_1 = [_]usize{1};
    const dep_0 = [_]usize{0};
    _ = try bad_cyc.addPass(.{ .name = "A", .explicit_deps = &dep_1 });
    _ = try bad_cyc.addPass(.{ .name = "B", .explicit_deps = &dep_0 });
    try testing.expectError(prism.pass_graph.GraphError.CyclicPassDependency, bad_cyc.compile(testing.allocator));
}

const TestCounter = struct { destroyed: usize = 0 };
fn countDestroy(ctx: ?*anyopaque, _: u64) void {
    const c: *TestCounter = @ptrCast(@alignCast(ctx.?));
    c.destroyed += 1;
}

test "PipelineCacheKey hashing, ShaderInterfaceDesc layout check, and RetirementQueue epochs" {
    const SampleUniform = extern struct { mvp: [16]f32 };
    const desc = prism.manifest.ShaderInterfaceDesc{
        .name = "pbr.vert",
        .stage = .vertex,
        .uniform_bytes = 64,
        .vertex_stride = 32,
    };
    try testing.expect(prism.manifest.validateUniformLayout(SampleUniform, desc));

    const k1 = prism.PipelineCacheKey{ .vertex_shader_hash = 11, .fragment_shader_hash = 22, .double_sided = false };
    const k2 = prism.PipelineCacheKey{ .vertex_shader_hash = 11, .fragment_shader_hash = 22, .double_sided = true };
    try testing.expect(k1.hash() != k2.hash());

    var svc = prism.PrismService.init(testing.allocator);
    defer svc.deinit();

    var counter = TestCounter{};
    try svc.retirement.retire(101, 2, &counter, countDestroy);
    try svc.retirement.retire(102, 4, &counter, countDestroy);
    try testing.expectEqual(@as(usize, 2), svc.retirement.pendingCount());

    try testing.expectEqual(@as(usize, 0), svc.notifyFrameCompleted(1));
    try testing.expectEqual(@as(usize, 1), svc.notifyFrameCompleted(2));
    try testing.expectEqual(@as(usize, 1), counter.destroyed);
    try testing.expectEqual(@as(usize, 1), svc.notifyFrameCompleted(4));
    try testing.expectEqual(@as(usize, 2), counter.destroyed);
    try testing.expectEqual(@as(usize, 0), svc.retirement.pendingCount());
}

test "RenderWorld dense upsert, prev_model tracking, culling, opaque batching, and transparent sorting" {
    var rw = prism.RenderWorld.init(testing.allocator);
    defer rw.deinit();

    const id_mat = [16]f32{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    };
    const moved_mat = [16]f32{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        3, 0, 0, 1,
    };

    const e1 = engine.EntityHandle{ .index = 1, .generation = 1 };
    const e2 = engine.EntityHandle{ .index = 2, .generation = 1 };
    const e3 = engine.EntityHandle{ .index = 3, .generation = 1 };
    const e4 = engine.EntityHandle{ .index = 4, .generation = 1 };

    rw.beginSync();
    try rw.upsert(e1, 10, 1, 100, id_mat, .{ 0, 0, 0 }, 1.0, false);
    try rw.upsert(e2, 10, 1, 100, id_mat, .{ 2, 0, 0 }, 1.0, false); // Same state -> batches with e1
    try rw.upsert(e3, 20, 2, 100, id_mat, .{ 0, 0, -5 }, 1.0, true); // Closer transparent
    try rw.upsert(e4, 20, 2, 100, id_mat, .{ 0, 0, -15 }, 1.0, true); // Farther transparent

    // Update e1 to verify prev_model keeps old transform
    rw.beginSync();
    try rw.upsert(e1, 10, 1, 100, moved_mat, .{ 3, 0, 0 }, 1.0, false);
    try rw.upsert(e2, 10, 1, 100, id_mat, .{ 2, 0, 0 }, 1.0, false);
    try rw.upsert(e3, 20, 2, 100, id_mat, .{ 0, 0, -5 }, 1.0, true);
    try rw.upsert(e4, 20, 2, 100, id_mat, .{ 0, 0, -15 }, 1.0, true);
    try testing.expectEqual(@as(usize, 0), rw.pruneUnseen());
    try testing.expectApproxEqAbs(@as(f32, 0.0), rw.get(e1).?.prev_model[12], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 3.0), rw.get(e1).?.curr_model[12], 1e-5);

    // Wide box frustum containing all 4 instances
    const wide_planes = [6][4]f32{
        .{ 1, 0, 0, 100 },  .{ -1, 0, 0, 100 },
        .{ 0, 1, 0, 100 },  .{ 0, -1, 0, 100 },
        .{ 0, 0, 1, 100 },  .{ 0, 0, -1, 100 },
    };
    var opq = std.ArrayList(prism.QueueEntry).empty;
    defer opq.deinit(testing.allocator);
    var trn = std.ArrayList(prism.QueueEntry).empty;
    defer trn.deinit(testing.allocator);
    var batches = std.ArrayList(prism.DrawBatch).empty;
    defer batches.deinit(testing.allocator);

    const stats = try rw.cullAndQueue(wide_planes, .{ 0, 0, 5 }, &opq, &trn, &batches, testing.allocator);
    try testing.expectEqual(@as(usize, 4), stats.total_instances);
    try testing.expectEqual(@as(usize, 2), stats.visible_opaque);
    try testing.expectEqual(@as(usize, 2), stats.visible_transparent);
    try testing.expectEqual(@as(usize, 0), stats.culled_count);
    try testing.expectEqual(@as(usize, 1), stats.opaque_batches);
    try testing.expectEqual(@as(u32, 2), batches.items[0].instance_count);

    // Transparent sorted back-to-front: e4 (z=-15) before e3 (z=-5)
    try testing.expectEqual(@as(u64, @bitCast(e4)), trn.items[0].entity_bits);
    try testing.expectEqual(@as(u64, @bitCast(e3)), trn.items[1].entity_bits);

    // Removal compaction
    try testing.expect(rw.remove(e1));
    try testing.expectEqual(@as(usize, 3), rw.count());
    try testing.expect(rw.get(e1) == null);
    try testing.expect(rw.get(e4) != null);
}

test "Stage 03 coordinates, Halton jitter, motion vectors, odd-dim Hi-Z pyramid, and TemporalHistoryManager" {
    // Halton jitter within [-0.5, +0.5] pixels
    for (0..16) |f| {
        const j = prism.coordinates.haltonJitter(f, 1280, 720);
        try testing.expect(j.px[0] >= -0.5 and j.px[0] <= 0.5);
        try testing.expect(j.px[1] >= -0.5 and j.px[1] <= 0.5);
    }

    // Linear depth reconstruction at near (0.0) and far (1.0)
    try testing.expectApproxEqAbs(@as(f32, 0.2), prism.coordinates.linearizeDepth(0.0, 0.2, 100.0), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 100.0), prism.coordinates.linearizeDepth(1.0, 0.2, 100.0), 1e-3);

    // Analytic motion vector for an object translating +0.5 in X under identity clip_from_world
    const id_m = [16]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    var moved_m = id_m;
    moved_m[12] = 0.5;
    const mv = prism.coordinates.computeMotionVector(id_m, id_m, moved_m, id_m, .{ 0, 0, 0 }).?;
    try testing.expectApproxEqAbs(@as(f32, 0.25), mv[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.0), mv[1], 1e-5);

    // Odd-dimension (5x3) Hi-Z pyramid preserves minimum depth at boundary texel (4, 2)
    var depth: [15]f32 = @splat(0.9);
    depth[2 * 5 + 4] = 0.15;
    var hiz = prism.HiZPyramid.init(testing.allocator);
    defer hiz.deinit();
    try hiz.buildFromDepth(&depth, 5, 3);
    try testing.expect(hiz.mipCount() >= 3);
    try testing.expectApproxEqAbs(@as(f32, 0.15), hiz.sampleMip(hiz.mipCount() - 1, 0, 0).?, 1e-5);

    // IGN determinism & range
    const n0 = prism.temporal.interleavedGradientNoise(12, 34, 0);
    try testing.expect(n0 >= 0.0 and n0 < 1.0);
    try testing.expectEqual(n0, prism.temporal.interleavedGradientNoise(12, 34, 0));

    // Disocclusion & RGB clamp
    try testing.expect(!prism.temporal.isDisoccluded(10.0, 10.1, .{ 0, 1, 0 }, .{ 0, 1, 0 }, 0.05, 0.9));
    try testing.expect(prism.temporal.isDisoccluded(10.0, 15.0, .{ 0, 1, 0 }, .{ 0, 1, 0 }, 0.05, 0.9));
    const cl = prism.temporal.clampHistoryRgb(.{ 2.0, -0.5, 0.4 }, .{ 0.1, 0.1, 0.1 }, .{ 1.0, 1.0, 1.0 });
    try testing.expectApproxEqAbs(@as(f32, 1.0), cl[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.1), cl[1], 1e-5);

    // TemporalHistoryManager resize + camera-cut invalidation
    var thm = prism.TemporalHistoryManager.init(testing.allocator);
    defer thm.deinit();
    const vid = prism.RenderViewId{ .index = 0, .generation = 1 };
    const s1 = try thm.updateView(vid, 1280, 720, id_m, .{ 0, 0, 0 }, .{ 0, 0 }, 1.0, false);
    try testing.expect(s1.cut_detected);
    const s2 = try thm.updateView(vid, 1280, 720, id_m, .{ 0.1, 0, 0 }, .{ 0, 0 }, 1.0, false);
    try testing.expect(!s2.cut_detected);
    try testing.expectEqual(@as(u64, 2), s2.valid_frames);
    // Teleport > camera_cut_distance resets history
    const s3 = try thm.updateView(vid, 1280, 720, id_m, .{ 25.0, 0, 0 }, .{ 0, 0 }, 1.0, false);
    try testing.expect(s3.cut_detected);
    try testing.expectEqual(@as(u64, 1), s3.valid_frames);
}

test "Stage 04 shadows (PSSM cascades, texel snapping, PCSS, local atlas, cache) and Stage 05 photometry" {
    // PSSM cascades strictly increasing and bounded by max_shadow_distance
    const splits = prism.shadows.computeCascadeSplits(0.2, 200.0, 120.0, 4, 0.75);
    try testing.expect(splits[0] > 0.2 and splits[0] < splits[1]);
    try testing.expect(splits[1] < splits[2] and splits[2] < splits[3]);
    try testing.expectApproxEqAbs(@as(f32, 120.0), splits[3], 1e-3);

    // Texel snapping stabilizes origin
    const snapped = prism.shadows.snapCascadeOrigin(.{ 1.37, -2.12 }, 0.25);
    try testing.expectApproxEqAbs(@as(f32, 1.25), snapped[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, -2.25), snapped[1], 1e-5);

    // PCSS contact hardening: further blocker-to-receiver distance widens penumbra
    const p_close = prism.shadows.estimatePcssPenumbra(10.2, 10.0, 0.04, 1.0, 16.0);
    const p_far = prism.shadows.estimatePcssPenumbra(20.0, 10.0, 0.04, 1.0, 16.0);
    try testing.expect(p_far >= p_close);

    // Guarded tile UVs stay strictly inside tile bounds
    const uv = prism.shadows.computeGuardedTileUv(1, 1, 512, 2048, 2.0);
    try testing.expect(uv[0] > 0.25 and uv[2] < 0.5);

    // Importance-ranked local shadow atlas with overflow reporting
    const cands = [_]prism.shadows.ShadowLightCandidate{
        .{ .light_id = 1, .is_point = true, .distance_to_camera = 5.0, .intensity_lumens = 2000.0, .range = 12.0 },
        .{ .light_id = 2, .is_point = false, .distance_to_camera = 3.0, .intensity_lumens = 1500.0, .range = 10.0 },
        .{ .light_id = 3, .is_point = true, .distance_to_camera = 40.0, .intensity_lumens = 500.0, .range = 8.0 },
    };
    var allocs = std.ArrayList(prism.shadows.AtlasTileAllocation).empty;
    defer allocs.deinit(testing.allocator);
    const astats = try prism.shadows.planLocalShadowAtlas(testing.allocator, &cands, 8, 512, &allocs);
    try testing.expectEqual(@as(usize, 2), astats.allocated_lights);
    try testing.expectEqual(@as(usize, 1), astats.evicted_lights);
    try testing.expectEqual(@as(u32, 7), astats.used_tiles);

    // Static shadow cache reuse & invalidation
    var cache = prism.shadows.ShadowCacheTable.init(testing.allocator);
    defer cache.deinit();
    try testing.expect(!(try cache.canReuse(1, 0xABCD)));
    try testing.expect(try cache.canReuse(1, 0xABCD));
    try testing.expect(!(try cache.canReuse(1, 0xABCE)));

    // Stage 05 photometry: Sunny 16 rule (f/16, 1/100s, ISO 100 -> EV100 ~= 14.64)
    const ev = prism.photometry.ev100FromCamera(16.0, 1.0 / 100.0, 100.0);
    try testing.expect(ev > 14.0 and ev < 15.0);
    try testing.expect(prism.photometry.exposureFromEv100(ev) > 0.0);
    try testing.expectApproxEqAbs(@as(f32, 0.0), prism.photometry.smoothDistanceAttenuation(10.0, 10.0), 1e-6);
    try testing.expect(prism.photometry.smoothDistanceAttenuation(2.0, 10.0) > 0.2);
    try testing.expect(prism.photometry.specularAaRoughness(0.1, 0.05, 0.18) > 0.1);
}

test "Stage 06 reflections, Stage 07 atmosphere/froxels, and Stage 08 baked GI/SH9 probe volumes" {
    // Stage 06: box-projected reflection probe, SSR confidence blend, specular occlusion, dynamic res
    const probe = prism.reflections.ReflectionProbe{
        .id = 1,
        .position = .{ 0, 2, 0 },
        .box_min = .{ -5, 0, -5 },
        .box_max = .{ 5, 4, 5 },
        .blend_distance = 1.0,
    };
    const proj_r = prism.reflections.boxProjectReflection(.{ 2, 1, 0 }, .{ 1, 0, 0 }, probe.box_min, probe.box_max, probe.position);
    const plen = @sqrt(proj_r[0] * proj_r[0] + proj_r[1] * proj_r[1] + proj_r[2] * proj_r[2]);
    try testing.expectApproxEqAbs(@as(f32, 1.0), plen, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1.0), prism.reflections.probeInfluenceWeight(probe, .{ 0, 2, 0 }), 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.0), prism.reflections.probeInfluenceWeight(probe, .{ 10, 2, 0 }), 1e-5);

    const ssr_c = prism.reflections.computeSsrConfidence(.{ 0.5, 0.5 }, 0.2, 0.8, 0.1);
    try testing.expect(ssr_c > 0.5 and ssr_c < 1.0);
    const blended = prism.reflections.blendSsrWithProbe(.{ 1, 0, 0 }, .{ 0, 0, 1 }, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), blended[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), blended[2], 1e-5);
    try testing.expect(prism.reflections.computeSpecularOcclusion(0.5, 0.8, 0.2) > 0.4);

    var dyn = prism.reflections.DynamicResolutionController{};
    try testing.expect(dyn.update(16.5) < 1.0); // Exceeds target+hysteresis -> scales down

    // Stage 07: Rayleigh/Mie sky, froxel depth slicing, fog zero-density identity, local fog volumes
    const sky_rad = prism.atmosphere.evaluateSkyRadiance(.{}, .{ 0, 1, 0 }, .{ 0, 0.8, 0.6 });
    try testing.expect(sky_rad[2] > sky_rad[0]); // Blue Rayleigh zenith scatter > red
    const d0 = prism.atmosphere.froxelSliceDepth(0, 64, 0.2, 120.0);
    const d64 = prism.atmosphere.froxelSliceDepth(64, 64, 0.2, 120.0);
    try testing.expectApproxEqAbs(@as(f32, 0.2), d0, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 120.0), d64, 1e-2);
    const fog_id = prism.atmosphere.composeFogRadiance(.{ 0.4, 0.5, 0.6 }, .{ 0, 0, 0 }, 1.0);
    try testing.expectApproxEqAbs(@as(f32, 0.4), fog_id[0], 1e-6);
    const fog_vol = prism.atmosphere.LocalFogVolume{ .shape = .box, .center = .{ 0, 2, 0 }, .half_extents = .{ 4, 2, 4 }, .density = 0.2 };
    try testing.expect(prism.atmosphere.evaluateLocalFogDensity(fog_vol, .{ 0, 2, 0 }) > 0.15);
    try testing.expectApproxEqAbs(@as(f32, 0.0), prism.atmosphere.evaluateLocalFogDensity(fog_vol, .{ 20, 2, 0 }), 1e-6);

    // Stage 08: BakedLightAssetHeader staleness, SH9 irradiance, ProbeVolume sampling, lightmap dilation
    const hdr = prism.baked_gi.BakedLightAssetHeader{ .scene_revision = 10, .light_revision = 20, .material_revision = 30 };
    try testing.expect(!hdr.isStale(10, 20, 30));
    try testing.expect(hdr.isStale(10, 21, 30));

    var vol = try prism.baked_gi.IrradianceProbeVolume.init(testing.allocator, .{ 0, 0, 0 }, .{ 2, 2, 2 }, .{ 2, 2, 2 });
    defer vol.deinit();
    for (vol.probes) |*p| {
        p.sh.addDirectional(.{ 0, 1, 0 }, .{ 1.0, 0.8, 0.6 }, 1.0);
    }
    const irr_up = vol.sampleIrradiance(.{ 1, 1, 1 }, .{ 0, 1, 0 });
    try testing.expect(irr_up[0] > 0.5 and irr_up[0] > irr_up[2]);

    var lm = [_][4]f32{
        .{ 1, 0, 0, 1 }, .{ 0, 0, 0, 0 },
        .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 },
    };
    try prism.baked_gi.dilateLightmapRgba(testing.allocator, &lm, 2, 2, 2);
    try testing.expectApproxEqAbs(@as(f32, 1.0), lm[3][0], 1e-5);
}

const HookLog = struct { order: [2]u8 = .{ 0, 0 }, len: usize = 0 };
fn hookFirst(ctx: ?*anyopaque, _: prism.RenderViewId, _: u64) !void {
    const l: *HookLog = @ptrCast(@alignCast(ctx.?));
    l.order[l.len] = 1;
    l.len += 1;
}
fn hookSecond(ctx: ?*anyopaque, _: prism.RenderViewId, _: u64) !void {
    const l: *HookLog = @ptrCast(@alignCast(ctx.?));
    l.order[l.len] = 2;
    l.len += 1;
}

test "Stage 10 ExtensionRegistry ordering, owner revocation, and QualityPreset matrix" {
    var svc = prism.PrismService.init(testing.allocator);
    defer svc.deinit();

    var log_state = HookLog{};
    try svc.extensions.registerHook(.{ .id = "ext.b", .owner_id = 42, .point = .before_tonemap, .priority = 20, .ctx = &log_state, .execute = hookSecond });
    try svc.extensions.registerHook(.{ .id = "ext.a", .owner_id = 42, .point = .before_tonemap, .priority = 10, .ctx = &log_state, .execute = hookFirst });
    try testing.expectError(error.DuplicateRenderHook, svc.extensions.registerHook(.{ .id = "ext.a", .owner_id = 99, .point = .before_tonemap, .execute = hookFirst }));

    const ran = try svc.extensions.executePoint(.before_tonemap, .{ .index = 0, .generation = 1 }, 1);
    try testing.expectEqual(@as(usize, 2), ran);
    try testing.expectEqual(@as(u8, 1), log_state.order[0]);
    try testing.expectEqual(@as(u8, 2), log_state.order[1]);

    try testing.expectEqual(@as(usize, 2), svc.extensions.unregisterByOwner(42));
    try testing.expectEqual(@as(usize, 0), svc.extensions.count());

    const low = prism.extensions.presetConfig(.low);
    const high = prism.extensions.presetConfig(.high);
    try testing.expectEqual(@as(u32, 2), low.shadow_cascades);
    try testing.expect(!low.pcss_enabled);
    try testing.expectEqual(@as(u32, 4), high.shadow_cascades);
    try testing.expect(high.pcss_enabled);
}

test "ShaderCatalog validation, FrameSnapshot immutability, IncrementalExtractor, and MultiViewSet" {
    try testing.expect(prism.shader_catalog.validateCatalog());
    const pbr_vs = prism.shader_catalog.findShader("pbr.vert").?;
    try testing.expectEqual(@as(usize, 32), pbr_vs.interface.vertex_stride);
    const giz_vs = prism.shader_catalog.findShader("gizmo.vert").?;
    try testing.expectEqual(@as(usize, 28), giz_vs.interface.vertex_stride);

    var rw = prism.RenderWorld.init(testing.allocator);
    defer rw.deinit();
    const id_m = [16]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    const e1 = engine.EntityHandle{ .index = 1, .generation = 1 };
    const e2 = engine.EntityHandle{ .index = 2, .generation = 1 };
    rw.beginSync();
    try rw.upsert(e1, 1, 1, 1, id_m, .{ 0, 0, 0 }, 1.0, false);
    try rw.upsert(e2, 2, 2, 1, id_m, .{ 2, 0, 0 }, 1.0, false);

    // Immutable FrameSnapshot survives RenderWorld mutation
    var snap = try prism.snapshot.FrameSnapshot.publishFrom(testing.allocator, 7, 1, &rw);
    defer snap.deinit();
    try testing.expect(rw.remove(e1));
    try testing.expectEqual(@as(usize, 1), rw.count());
    try testing.expectEqual(@as(usize, 2), snap.instances.len);

    // IncrementalExtractor detects unchanged vs updated vs full-resync
    var ext = prism.snapshot.IncrementalExtractor.init(testing.allocator);
    defer ext.deinit();
    var st1 = prism.snapshot.ExtractionStats{};
    try testing.expect(try ext.shouldUpload(@bitCast(e1), 1, &st1));
    ext.finishPass(&st1);
    try testing.expect(st1.was_full_resync);

    var st2 = prism.snapshot.ExtractionStats{};
    try testing.expect(!(try ext.shouldUpload(@bitCast(e1), 1, &st2)));
    try testing.expect(try ext.shouldUpload(@bitCast(e1), 2, &st2));
    ext.finishPass(&st2);
    try testing.expect(!st2.was_full_resync);
    try testing.expectEqual(@as(usize, 1), st2.unchanged);
    try testing.expectEqual(@as(usize, 1), st2.updated);

    // MultiViewSet maintains independent exposure per view
    var mvs = prism.snapshot.MultiViewSet.init(testing.allocator);
    defer mvs.deinit();
    const v_main = prism.RenderViewId{ .index = 0, .generation = 1 };
    const v_pip = prism.RenderViewId{ .index = 1, .generation = 1 };
    try mvs.addView(.{ .view_id = v_main, .label = "main", .exposure_ev100 = 12.0 });
    try mvs.addView(.{ .view_id = v_pip, .label = "editor_preview", .exposure_ev100 = 10.0, .is_offscreen = true });
    try testing.expect(mvs.setViewExposure(v_pip, 14.5));
    try testing.expectApproxEqAbs(@as(f32, 12.0), mvs.views.items[0].exposure_ev100, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 14.5), mvs.views.items[1].exposure_ev100, 1e-5);
}

test "Phase C PCSS blocker search, shadow caster culling, area lights, IES, and material lobes" {
    // PCSS blocker search over a synthetic 8x8 depth map with a blocker at depth 0.3
    var depth_map: [64]f32 = @splat(0.9);
    depth_map[4 * 8 + 4] = 0.3;
    depth_map[4 * 8 + 3] = 0.35;
    const br = prism.shadows.pcssBlockerSearch(&depth_map, 8, 8, .{ 0.5, 0.5 }, 0.6, 2.0, 16, 0.5);
    try testing.expect(br.blocker_count > 0);
    try testing.expect(br.avg_blocker_depth < 0.4);

    // Shadow caster frustum culling (box [-10, 10]^3)
    const planes = [6][4]f32{
        .{ 1, 0, 0, 10 },  .{ -1, 0, 0, 10 },
        .{ 0, 1, 0, 10 },  .{ 0, -1, 0, 10 },
        .{ 0, 0, 1, 10 },  .{ 0, 0, -1, 10 },
    };
    const casters = [_]prism.shadows.ShadowCasterSphere{
        .{ .caster_id = 1, .center = .{ 0, 0, 0 }, .radius = 1.0 },
        .{ .caster_id = 2, .center = .{ 50, 0, 0 }, .radius = 1.0 },
        .{ .caster_id = 3, .center = .{ 0, 0, 0 }, .radius = 1.0, .casts_shadows = false },
    };
    var visible = std.ArrayList(usize).empty;
    defer visible.deinit(testing.allocator);
    const culled = try prism.shadows.cullShadowCasters(testing.allocator, &casters, planes, &visible);
    try testing.expectEqual(@as(usize, 2), culled);
    try testing.expectEqual(@as(usize, 1), visible.items.len);
    try testing.expectEqual(@as(usize, 0), visible.items[0]);

    // Stage 05: Rectangular area light diffuse/specular, IES profile, layer masks, clearcoat & sheen
    const area_l = prism.area_lights.RectAreaLight{
        .position = .{ 0, 3, 0 },
        .right = .{ 1, 0, 0 },
        .up = .{ 0, 0, 1 },
        .normal = .{ 0, -1, 0 },
        .half_width = 1.5,
        .half_height = 1.0,
        .luminance_nits = 800.0,
    };
    const diff = prism.area_lights.evaluateRectAreaLightDiffuse(area_l, .{ 0, 0, 0 }, .{ 0, 1, 0 });
    try testing.expect(diff[0] > 10.0);
    const spec = prism.area_lights.evaluateRectAreaLightSpecular(area_l, .{ 0, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 1, 0 }, 0.25);
    try testing.expect(spec[0] > 0.0);

    const ies = prism.area_lights.IesProfile{ .samples = &.{ 1.0, 0.5, 0.0 } };
    try testing.expectApproxEqAbs(@as(f32, 1.0), ies.sampleIntensity(1.0), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.5), ies.sampleIntensity(0.0), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.0), ies.sampleIntensity(-1.0), 1e-4);

    const m1 = prism.area_lights.LightLayerMask{ .bits = 0b0010 };
    const m2 = prism.area_lights.LightLayerMask{ .bits = 0b0100 };
    try testing.expect(!m1.overlaps(m2));
    try testing.expect(m1.overlaps(prism.area_lights.LightLayerMask.ALL));

    try testing.expect(prism.area_lights.evaluateClearcoatLobe(1.0, 0.1, 1.0, 1.0) > 0.0);
    const sheen = prism.area_lights.evaluateSheenLobe(.{ 1.0, 0.8, 0.6 }, 0.5, 0.3);
    try testing.expect(sheen[0] > 0.0);
}

test "Phase D MaterialShaderRegistry hot-reload transactions, PickingTarget, SelectionSet, and ViewMemoryReport" {
    var reg = prism.editor_api.MaterialShaderRegistry.init(testing.allocator);
    defer reg.deinit();
    try reg.register(.{ .id = 7, .name = "custom_water", .active_pipeline = 100, .fallback_pipeline = 1 });
    try reg.beginHotReload(7, 200);
    // Rollback preserves last-good pipeline 100
    try reg.rollbackHotReload(7);
    try testing.expectEqual(@as(?u64, 100), reg.activePipeline(7));
    // Commit swaps to 201 and returns 100 for deferred retirement
    try reg.beginHotReload(7, 201);
    const commit = try reg.commitHotReload(7);
    try testing.expectEqual(@as(u64, 100), commit.superseded_pipeline);
    try testing.expectEqual(@as(u64, 2), commit.new_revision);
    try testing.expectEqual(@as(?u64, 201), reg.activePipeline(7));

    var pick = try prism.editor_api.PickingTarget.init(testing.allocator, 16, 16);
    defer pick.deinit();
    pick.writeEntityId(5, 6, 42);
    try testing.expectEqual(@as(?u64, 42), pick.pickEntityAt(5, 6));
    try testing.expectEqual(@as(?u64, null), pick.pickEntityAt(0, 0));

    var sel = prism.editor_api.SelectionSet.init(testing.allocator);
    defer sel.deinit();
    try sel.select(42);
    try testing.expect(sel.isSelected(42));
    try testing.expect(sel.deselect(42));
    try testing.expect(!sel.isSelected(42));

    const mem = prism.editor_api.estimateViewMemoryBytes(1920, 1080, true, true, true, true);
    try testing.expect(mem.totalBytes() > 40 * 1024 * 1024);
}

test "lighting hardening: probe directional visibility moments" {
    const near = prism.baked_gi.ProbeVisibilityMoments{
        .mean_distance = 1, .mean_distance_squared = 1, .valid = true,
    };
    try testing.expectApproxEqAbs(@as(f32, 1), near.weight(0.5), 1e-5);
    try testing.expect(near.weight(2) < 0.01);
    try testing.expectEqual(@as(usize, 0), prism.baked_gi.probeVisibilitySector(.{ 1, 0, 0 }));
    try testing.expectEqual(@as(usize, 1), prism.baked_gi.probeVisibilitySector(.{ -1, 0, 0 }));
    const unknown = prism.baked_gi.ProbeVisibilityMoments{};
    try testing.expectEqual(@as(f32, 1), unknown.weight(10));
}
