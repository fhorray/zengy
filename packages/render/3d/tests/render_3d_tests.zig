//! 3D Renderer Foundation Tests (`packages/render/3d/tests/render_3d_tests.zig`).
//!
//! Validates Phase 13 `official.render.3d`: `.render_extract` mesh draw extraction
//! when an active `Camera3D` exists, and zero extraction when no camera is active.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const window = @import("window");
const graphics = @import("graphics");
const scene = @import("scene");
const camera = @import("camera");
const render_3d = @import("render_3d");

test "Render3DService extracts meshes during render_extract when camera is active" {
    var app = engine.App.init(testing.allocator, .{ .max_frames = 1 });
    defer app.deinit();

    try app.registerModule(window.module());
    try app.registerModule(graphics.module());
    try app.registerModule(camera.module());
    try app.registerModule(render_3d.module());

    const cam = try app.world.spawn();
    try app.world.set(cam, camera.Camera, .{});
    try app.world.set(cam, camera.Projection, .{ .perspective = .{ .fov_rad = 75.0 * (std.math.pi / 180.0) } });

    const mesh1 = try app.world.spawn();
    try app.world.set(mesh1, render_3d.Transform3D, .{ .position = .{ 1, 2, 3 } });
    try app.world.set(mesh1, render_3d.MeshRef, .{ .mesh_asset = 101, .material_id = 7 });

    const mesh2 = try app.world.spawn();
    try app.world.set(mesh2, render_3d.Transform3D, .{ .position = .{ -4, 0, 8 } });
    try app.world.set(mesh2, render_3d.MeshRef, .{ .mesh_asset = 202, .material_id = 9 });

    try app.initialize();
    try app.tick(1.0 / 60.0);

    const r3d = app.resources.get(render_3d.Render3DService).?;
    try testing.expectEqual(@as(usize, 1), r3d.active_cameras);
    try testing.expectEqual(@as(usize, 2), r3d.drawCount());

    app.shutdown();
}

test "Render3D frustum culling culls meshes behind Camera3D" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(window.module());
    try app.registerModule(graphics.module());
    try app.registerModule(camera.module());
    try app.registerModule(render_3d.module());

    const cam = try app.world.spawn();
    try app.world.set(cam, camera.Camera, .{});
    try app.world.set(cam, camera.Projection, .{ .perspective = .{} });
    try app.world.set(cam, camera.CameraPose, camera.CameraPose.lookAt(.{ 0, 0, 5 }, .{ 0, 0, 0 }, .{ 0, 1, 0 }));

    const visible_e = try app.world.spawn();
    try app.world.set(visible_e, render_3d.Transform3D, .{ .position = .{ 0, 0, 0 } });
    try app.world.set(visible_e, render_3d.MeshRef, .{ .mesh_asset = 1, .bounds_radius = 1.0 });

    const behind_e = try app.world.spawn();
    try app.world.set(behind_e, render_3d.Transform3D, .{ .position = .{ 0, 0, 20 } });
    try app.world.set(behind_e, render_3d.MeshRef, .{ .mesh_asset = 2, .bounds_radius = 1.0 });

    try app.initialize();
    try app.tick(1.0 / 60.0);

    const r3d = app.resources.get(render_3d.Render3DService).?;
    try testing.expectEqual(@as(usize, 1), r3d.drawCount());
    try testing.expectEqual(@as(usize, 1), r3d.culled_count);
}

test "gltf.loadGltfFromMemory parses embedded base64 glTF 2.0 triangle" {
    // 3 vertices (vec3 f32) = 36 bytes + 3 u16 indices = 6 bytes -> 42 bytes total.
    var raw: [42]u8 = @splat(0);
    const coords = [_]f32{ 0, 1, 0, -1, -1, 0, 1, -1, 0 };
    for (coords, 0..) |f, i| {
        std.mem.writeInt(u32, raw[i * 4 ..][0..4], @bitCast(f), .little);
    }
    std.mem.writeInt(u16, raw[36..38], 0, .little);
    std.mem.writeInt(u16, raw[38..40], 1, .little);
    std.mem.writeInt(u16, raw[40..42], 2, .little);

    var b64_buf: [128]u8 = undefined;
    const b64 = std.base64.standard.Encoder.encode(&b64_buf, &raw);

    const gltf_json = try std.fmt.allocPrint(testing.allocator,
        \\{{
        \\  "asset": {{ "version": "2.0" }},
        \\  "buffers": [{{ "uri": "data:application/octet-stream;base64,{s}", "byteLength": 42 }}],
        \\  "bufferViews": [
        \\    {{ "buffer": 0, "byteOffset": 0, "byteLength": 36 }},
        \\    {{ "buffer": 0, "byteOffset": 36, "byteLength": 6 }}
        \\  ],
        \\  "accessors": [
        \\    {{ "bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3" }},
        \\    {{ "bufferView": 1, "componentType": 5123, "count": 3, "type": "SCALAR" }}
        \\  ],
        \\  "meshes": [{{ "primitives": [{{ "attributes": {{ "POSITION": 0 }}, "indices": 1 }}] }}]
        \\}}
    , .{b64});
    defer testing.allocator.free(gltf_json);

    var mesh = try render_3d.gltf.loadGltfFromMemory(testing.allocator, gltf_json, null);
    defer mesh.deinit();

    try testing.expectEqual(@as(usize, 3), mesh.vertices.len);
    try testing.expectEqual(@as(usize, 3), mesh.indices.len);
    try testing.expectEqual(@as(f32, 1.0), mesh.vertices[0].y);
    try testing.expect(mesh.bounds_radius > 1.0);
}

test "Render3D selects highest-priority Camera3D and applies bounds_offset during culling" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(window.module());
    try app.registerModule(graphics.module());
    try app.registerModule(camera.module());
    try app.registerModule(render_3d.module());

    const low_cam = try app.world.spawn();
    try app.world.set(low_cam, camera.Camera, .{ .order = 1 });
    try app.world.set(low_cam, camera.Projection, .{ .perspective = .{} });
    try app.world.set(low_cam, camera.CameraPose, camera.CameraPose.lookAt(.{ 0, 0, 500 }, .{ 0, 0, 490 }, .{ 0, 1, 0 }));
    const high_cam = try app.world.spawn();
    try app.world.set(high_cam, camera.Camera, .{ .order = 10 });
    try app.world.set(high_cam, camera.Projection, .{ .perspective = .{} });
    try app.world.set(high_cam, camera.CameraPose, camera.CameraPose.lookAt(.{ 0, 0, 5 }, .{ 0, 0, 0 }, .{ 0, 1, 0 }));

    // Pivot is behind the camera (+20), but bounds_offset places sphere at origin (0,0,0) -> visible!
    const offset_mesh = try app.world.spawn();
    try app.world.set(offset_mesh, render_3d.Transform3D, .{ .position = .{ 0, 0, 20 } });
    try app.world.set(offset_mesh, render_3d.MeshRef, .{
        .mesh_asset = 1,
        .bounds_radius = 1.0,
        .bounds_offset = .{ 0, 0, -20 },
    });

    try app.initialize();
    try app.tick(1.0 / 60.0);

    const r3d = app.resources.get(render_3d.Render3DService).?;
    try testing.expectEqual(@as(usize, 2), r3d.active_cameras);
    try testing.expectEqual(@as(usize, 1), r3d.drawCount());
    try testing.expectEqual(@as(usize, 0), r3d.culled_count);
}

test "Render3D extracts hierarchical LocalTransform3D / GlobalTransform3D meshes" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(window.module());
    try app.registerModule(graphics.module());
    try app.registerModule(scene.module());
    try app.registerModule(camera.module());
    try app.registerModule(render_3d.module());
    try app.initialize();

    const cam = try app.world.spawn();
    try app.world.set(cam, camera.Camera, .{});
    try app.world.set(cam, camera.Projection, .{ .perspective = .{} });
    try app.world.set(cam, camera.CameraPose, camera.CameraPose.lookAt(.{ 0, 0, 10 }, .{ 0, 0, 0 }, .{ 0, 1, 0 }));

    const parent = try app.world.spawn();
    try app.world.set(parent, scene.incremental.LocalTransform3D, .{ .translation = .{ 2, 0, 0 } });
    try app.world.set(parent, scene.incremental.GlobalTransform3D, .{});

    const child = try app.world.spawn();
    try app.world.set(child, scene.incremental.LocalTransform3D, .{ .translation = .{ 1, 3, -2 } });
    try app.world.set(child, scene.incremental.GlobalTransform3D, .{});
    try app.world.set(child, render_3d.MeshRef, .{ .mesh_asset = 77, .bounds_radius = 1.0 });
    try scene.graph.reparent(&app.world, child, parent, .{});

    try app.tick(1.0 / 60.0);

    const r3d = app.resources.get(render_3d.Render3DService).?;
    try testing.expectEqual(@as(usize, 1), r3d.drawCount());
    const draw = r3d.extracted_draws.items[0];
    try testing.expectApproxEqAbs(@as(f32, 3.0), draw.position[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 3.0), draw.position[1], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -2.0), draw.position[2], 1e-4);
}

test "Phase 1 PBR: MaterialRegistry, lights, SkyEnvironment, PostProcessSettings, and mock PbrBackendVTable" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(window.module());
    try app.registerModule(graphics.module());
    try app.registerModule(camera.module());
    try app.registerModule(scene.module());
    try app.registerModule(render_3d.module());
    try app.initialize();

    const MockPbr = struct {
        began: bool = false,
        ended: bool = false,
        submitted: usize = 0,
        last_metallic: f32 = 0.0,
        last_dir_lights: usize = 0,
        last_point_lights: usize = 0,
        last_spot_lights: usize = 0,
        last_auto_exposure: bool = false,
        last_tonemap: render_3d.pbr.TonemapMode = .none,

        fn begin(raw: *anyopaque, frame: *const render_3d.pbr.ExtractedPbrFrame) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.began = true;
            self.last_dir_lights = frame.directional_lights.len;
            self.last_point_lights = frame.point_lights.len;
            self.last_spot_lights = frame.spot_lights.len;
            self.last_auto_exposure = frame.post_process.auto_exposure.enabled;
            self.last_tonemap = frame.post_process.tonemap_mode;
        }
        fn submit(
            raw: *anyopaque,
            _: u64,
            _: [16]f32,
            _: [16]f32,
            mat: render_3d.pbr.StandardMaterial,
            _: [4]f32,
        ) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.submitted += 1;
            self.last_metallic = mat.metallic;
        }
        fn end(raw: *anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.ended = true;
        }
    };

    var mock = MockPbr{};
    const r3d = app.resources.get(render_3d.Render3DService).?;
    r3d.setPbrBackend(.{
        .ctx = &mock,
        .beginPbrFrame = MockPbr.begin,
        .submitLitMesh = MockPbr.submit,
        .endPbrFrame = MockPbr.end,
    });

    const mats = app.resources.get(render_3d.pbr.MaterialRegistry).?;
    const gold = try mats.add(.{
        .base_color = .{ 1.0, 0.82, 0.35, 1.0 },
        .metallic = 0.95,
        .roughness = 0.2,
    });

    const cam = try app.world.spawn();
    try app.world.set(cam, camera.Camera, .{});
    try app.world.set(cam, camera.Projection, .{ .perspective = .{} });
    try app.world.set(cam, camera.CameraPose, camera.CameraPose.lookAt(.{ 0, 2, 6 }, .{ 0, 0, 0 }, .{ 0, 1, 0 }));
    try app.world.set(cam, render_3d.pbr.PostProcessSettings, .{
        .auto_exposure = .{ .enabled = true, .min_ev100 = -3.0, .max_ev100 = 7.0 },
        .tonemap_mode = .agx,
        .tonemap_look = .punchy,
    });

    const sun = try app.world.spawn();
    try app.world.set(sun, render_3d.pbr.DirectionalLight, .{ .illuminance_lux = 50_000.0 });

    const pt = try app.world.spawn();
    try app.world.set(pt, render_3d.Transform3D, .{ .position = .{ 2, 3, 1 } });
    try app.world.set(pt, render_3d.pbr.PointLight, .{ .intensity_lumens = 1500.0 });

    const sp = try app.world.spawn();
    try app.world.set(sp, render_3d.Transform3D, .{ .position = .{ -2, 4, 2 } });
    try app.world.set(sp, render_3d.pbr.SpotLight, .{});

    const mesh_e = try app.world.spawn();
    try app.world.set(mesh_e, render_3d.Transform3D, .{ .position = .{ 0, 0, 0 } });
    try app.world.set(mesh_e, render_3d.MeshRef, .{ .mesh_asset = 42, .material_handle = gold });

    try app.tick(1.0 / 60.0);

    try testing.expect(mock.began);
    try testing.expect(mock.ended);
    try testing.expectEqual(@as(usize, 1), mock.submitted);
    try testing.expectApproxEqAbs(@as(f32, 0.95), mock.last_metallic, 1e-5);
    try testing.expectEqual(@as(usize, 1), mock.last_dir_lights);
    try testing.expectEqual(@as(usize, 1), mock.last_point_lights);
    try testing.expectEqual(@as(usize, 1), mock.last_spot_lights);
    try testing.expect(mock.last_auto_exposure);
    try testing.expectEqual(render_3d.pbr.TonemapMode.agx, mock.last_tonemap);

    try testing.expect(mats.remove(gold));
    try testing.expect(mats.getConst(gold) == null);
}

test "Phase 1 IBL: SH9 diffuse projection, prefiltered mip chain, and BRDF LUT" {
    const sky = render_3d.pbr.SkyEnvironment{};
    const env = try render_3d.ibl.generateProceduralEquirectSky(
        testing.allocator,
        sky,
        .{ 0.4, 0.8, 0.4 },
        .{ 1, 1, 1 },
        1.0,
        32,
        16,
    );
    defer testing.allocator.free(env);

    const sh = render_3d.ibl.projectSkyDiffuse(env, 32, 16);
    const up_irr = render_3d.ibl.evaluateSkyDiffuse(&sh, .{ 0, 1, 0 });
    const down_irr = render_3d.ibl.evaluateSkyDiffuse(&sh, .{ 0, -1, 0 });
    try testing.expect(up_irr[2] > down_irr[2]);

    const mips = try render_3d.ibl.buildPrefilteredEnvMips(testing.allocator, env, 32, 16, 4);
    defer {
        for (mips) |m| testing.allocator.free(m);
        testing.allocator.free(mips);
    }
    try testing.expectEqual(@as(usize, 4), mips.len);
    try testing.expectEqual(@as(usize, 32 * 16), mips[0].len);

    const lut = try render_3d.ibl.generateBrdfLutRgba8(testing.allocator, 32);
    defer testing.allocator.free(lut);
    try testing.expectEqual(@as(usize, 32 * 32 * 4), lut.len);
}

test "Phase 1 CSM: exponential cascade bounds" {
    const b = render_3d.pbr.calculateCascadeBounds(.{
        .cascade_count = 4,
        .first_cascade_far_bound = 10.0,
        .maximum_distance = 120.0,
    });
    try testing.expectApproxEqAbs(@as(f32, 10.0), b[0], 1e-4);
    try testing.expect(b[1] > b[0] and b[2] > b[1]);
    try testing.expectApproxEqAbs(@as(f32, 120.0), b[3], 1e-3);
}

test "Phase 2/3 Lighting: Clustered Forward+ assignment, RectLight, and ReflectionProbe" {
    const view = render_3d.math3d.Mat4.lookAt(.{ .x = 0, .y = 2, .z = 10 }, .{ .x = 0, .y = 2, .z = 0 }, .{ .x = 0, .y = 1, .z = 0 });
    const proj = render_3d.math3d.Mat4.perspective(std.math.pi / 3.0, 16.0 / 9.0, 0.1, 200.0);

    const pts = [_]render_3d.pbr.ExtractedPointLight{
        .{ .position = .{ 0, 2, 0 }, .color = .{ 1, 0.5, 0.2 }, .intensity_lumens = 1200, .range = 8, .radius = 0.1, .shadows_enabled = false },
    };
    const spots = [_]render_3d.pbr.ExtractedSpotLight{
        .{ .position = .{ -2, 4, 2 }, .direction = .{ 0, -1, 0 }, .color = .{ 0.3, 0.7, 1 }, .intensity_lumens = 1500, .range = 12, .inner_angle_rad = 0.3, .outer_angle_rad = 0.6, .shadows_enabled = true },
    };
    const rects = [_]render_3d.pbr.ExtractedRectLight{
        .{ .position = .{ 2, 2, 0 }, .direction = .{ 0, 0, 1 }, .right = .{ 1, 0, 0 }, .up = .{ 0, 1, 0 }, .color = .{ 1, 1, 1 }, .intensity_lumens = 1800, .half_extents = .{ 1.2, 0.6 }, .range = 10, .two_sided = false },
    };

    var built = try render_3d.cluster.buildClusters(
        testing.allocator,
        view.m,
        proj.m,
        0.1,
        200.0,
        &pts,
        &spots,
        &rects,
    );
    defer built.deinit(testing.allocator);

    try testing.expectEqual(render_3d.cluster.CLUSTER_COUNT, built.entries.len);
    var assigned_points: usize = 0;
    var assigned_rects: usize = 0;
    for (built.entries) |e| {
        assigned_points += e.point_packed & 0xFF;
        assigned_rects += e.rect_packed & 0xFF;
    }
    try testing.expect(assigned_points > 0);
    try testing.expect(assigned_rects > 0);
}

test "Forward+ perspectiveNearFar recovers the planes of a camera-layout projection" {
    // Same layout as camera.zig PerspectiveProjection: column-major, depth in [0, 1], -1 in row 3 col 2.
    const n: f32 = 0.5;
    const f: f32 = 50.0;
    const inv = 1.0 / (n - f);
    var m: [16]f32 = @splat(0);
    m[0] = 1.0;
    m[5] = 1.0;
    m[10] = f * inv;
    m[11] = -1.0;
    m[14] = n * f * inv;
    const nf = render_3d.cluster.perspectiveNearFar(m) orelse return error.TestUnexpectedResult;
    try testing.expectApproxEqRel(n, nf.near, 1e-4);
    try testing.expectApproxEqRel(f, nf.far, 1e-4);

    // Orthographic projections have no perspective row and must not be interpreted as one.
    m[11] = 0.0;
    try testing.expect(render_3d.cluster.perspectiveNearFar(m) == null);
}

test "Forward+ budget is shared fairly when every cluster is over the limit" {
    const view = render_3d.math3d.Mat4.identity();
    // A camera-layout perspective matrix (near 0.1, far 200) so the planes match the default range.
    const proj = render_3d.math3d.Mat4.perspective(std.math.pi / 3.0, 16.0 / 9.0, 0.1, 200.0);

    // Range 1000 around the camera: every light covers the whole frustum, so each cluster gets all 300 lights.
    var pts: [300]render_3d.pbr.ExtractedPointLight = undefined;
    for (&pts) |*p| p.* = .{ .position = .{ 0, 0, 0 }, .color = .{ 1, 1, 1 }, .intensity_lumens = 100, .range = 1000, .radius = 0.1, .shadows_enabled = false };

    var built = try render_3d.cluster.buildClusters(testing.allocator, view.m, proj.m, 0.1, 200.0, &pts, &.{}, &.{});
    defer built.deinit(testing.allocator);

    const cluster_count = render_3d.cluster.CLUSTER_COUNT;
    var min_count: u32 = std.math.maxInt(u32);
    var max_count: u32 = 0;
    for (built.entries) |e| {
        const count = e.point_packed & 0xFF;
        min_count = @min(min_count, count);
        max_count = @max(max_count, count);
    }
    // 65536 / 3456 = 18.96: every cluster keeps 18 or 19 refs, so no cluster is starved.
    try testing.expect(min_count >= 18);
    try testing.expect(max_count <= 19);
    try testing.expectEqual(@as(usize, render_3d.cluster.MAX_CLUSTER_INDICES), built.indices.len);
    // Every reference beyond the budget is reported, not silently discarded.
    const raw_refs: u32 = @intCast(cluster_count * 300);
    try testing.expectEqual(raw_refs - render_3d.cluster.MAX_CLUSTER_INDICES, built.dropped_refs);
}

test "Forward+ rejects lights whose footprint lies entirely off screen" {
    const view = render_3d.math3d.Mat4.lookAt(.{ .x = 0, .y = 2, .z = 10 }, .{ .x = 0, .y = 2, .z = 0 }, .{ .x = 0, .y = 1, .z = 0 });
    const proj = render_3d.math3d.Mat4.perspective(std.math.pi / 3.0, 16.0 / 9.0, 0.1, 200.0);

    // Far to the side of the frustum: the sphere is in front of the camera but well outside the screen.
    const pts = [_]render_3d.pbr.ExtractedPointLight{
        .{ .position = .{ 1000, 2, 0 }, .color = .{ 1, 1, 1 }, .intensity_lumens = 100, .range = 1, .radius = 0.1, .shadows_enabled = false },
    };
    var built = try render_3d.cluster.buildClusters(testing.allocator, view.m, proj.m, 0.1, 200.0, &pts, &.{}, &.{});
    defer built.deinit(testing.allocator);

    var refs: u32 = 0;
    for (built.entries) |e| refs += e.point_packed & 0xFF;
    try testing.expectEqual(@as(u32, 0), refs);
    try testing.expectEqual(@as(u32, 0), built.dropped_refs);
}

test "Forward+ scratch buffers are reused across frames with identical results" {
    const allocator = testing.allocator;
    const view = render_3d.math3d.Mat4.lookAt(.{ .x = 0, .y = 2, .z = 10 }, .{ .x = 0, .y = 2, .z = 0 }, .{ .x = 0, .y = 1, .z = 0 });
    const proj = render_3d.math3d.Mat4.perspective(std.math.pi / 3.0, 16.0 / 9.0, 0.1, 200.0);
    const pts = [_]render_3d.pbr.ExtractedPointLight{
        .{ .position = .{ 0, 2, 0 }, .color = .{ 1, 1, 1 }, .intensity_lumens = 100, .range = 8, .radius = 0.1, .shadows_enabled = false },
    };

    var scratch: render_3d.cluster.ClusterScratch = .{};
    defer scratch.deinit(allocator);
    const first = try render_3d.cluster.buildClustersInto(&scratch, allocator, view.m, proj.m, 0.1, 200.0, &pts, &.{}, &.{});
    const first_refs = first.indices.len;
    const second = try render_3d.cluster.buildClustersInto(&scratch, allocator, view.m, proj.m, 0.1, 200.0, &pts, &.{}, &.{});
    try testing.expectEqual(first_refs, second.indices.len);
    try testing.expectEqual(first.entries[100].point_packed, second.entries[100].point_packed);
}

test "IBL HDRI rotation shifts equirect columns along +u and wraps around" {
    var px = [_][4]f32{
        .{ 0, 0, 0, 1 }, .{ 1, 0, 0, 1 }, .{ 2, 0, 0, 1 }, .{ 3, 0, 0, 1 },
    };
    try render_3d.ibl.rotateEquirectColumns(testing.allocator, &px, 4, 1, 0.25);
    // out(u) = in(u + 0.25): one column to the left, wrapping the first column to the end.
    try testing.expectApproxEqAbs(@as(f32, 1), px[0][0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 2), px[1][0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 3), px[2][0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), px[3][0], 1e-6);

    // A full turn (or zero) leaves the image unchanged.
    try render_3d.ibl.rotateEquirectColumns(testing.allocator, &px, 4, 1, 1.0);
    try testing.expectApproxEqAbs(@as(f32, 1), px[0][0], 1e-6);
}
