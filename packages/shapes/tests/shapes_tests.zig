//! Procedural 3D Shape Tests (`packages/shapes/tests/shapes_tests.zig`).

const std = @import("std");
const testing = std.testing;
const shapes = @import("shapes");

fn verifyShapeMesh(mesh: *const shapes.ShapeMesh) !void {
    try testing.expect(mesh.vertices.len > 0);
    try testing.expect(mesh.indices.len > 0);
    try testing.expectEqual(mesh.vertices.len, mesh.tangents.len);
    try testing.expectEqual(@as(usize, 0), mesh.indices.len % 3);

    for (mesh.indices) |idx| {
        try testing.expect(idx < mesh.vertices.len);
    }

    for (mesh.vertices, 0..) |v, i| {
        const n_len = @sqrt(v.nx * v.nx + v.ny * v.ny + v.nz * v.nz);
        try testing.expectApproxEqAbs(@as(f32, 1.0), n_len, 1e-3);

        const t = mesh.tangents[i];
        const t_len = @sqrt(t[0] * t[0] + t[1] * t[1] + t[2] * t[2]);
        try testing.expectApproxEqAbs(@as(f32, 1.0), t_len, 1e-3);
        try testing.expect(t[3] == 1.0 or t[3] == -1.0);

        const ndott = v.nx * t[0] + v.ny * t[1] + v.nz * t[2];
        try testing.expectApproxEqAbs(@as(f32, 0.0), ndott, 1e-3);

        try testing.expect(v.u >= -1e-4 and v.u <= 1.0 + 1e-4);
        try testing.expect(v.v >= -1e-4 and v.v <= 1.0 + 1e-4);
    }
}

test "Plane, Cuboid, Sphere, Capsule, Cylinder, Torus, and Cone generate valid UVs and tangents" {
    var plane = try (shapes.Plane{ .size = .{ 4.0, 4.0 }, .subdivisions = .{ 2, 2 } }).mesh(testing.allocator);
    defer plane.deinit();
    try verifyShapeMesh(&plane);

    var cuboid = try (shapes.Cuboid{ .size = .{ 1.5, 2.0, 1.0 } }).mesh(testing.allocator);
    defer cuboid.deinit();
    try testing.expectEqual(@as(usize, 24), cuboid.vertices.len);
    try testing.expectEqual(@as(usize, 36), cuboid.indices.len);
    try verifyShapeMesh(&cuboid);

    var sphere = try (shapes.Sphere{ .radius = 0.75, .rings = 10, .sectors = 16 }).mesh(testing.allocator);
    defer sphere.deinit();
    try verifyShapeMesh(&sphere);

    var capsule = try (shapes.Capsule{ .radius = 0.3, .half_length = 0.6, .rings = 6, .sectors = 16 }).mesh(testing.allocator);
    defer capsule.deinit();
    try verifyShapeMesh(&capsule);

    var cylinder = try (shapes.Cylinder{ .radius = 0.5, .height = 1.5, .radial_segments = 16 }).mesh(testing.allocator);
    defer cylinder.deinit();
    try verifyShapeMesh(&cylinder);

    var torus = try (shapes.Torus{ .major_radius = 0.6, .minor_radius = 0.2, .major_segments = 16, .minor_segments = 10 }).mesh(testing.allocator);
    defer torus.deinit();
    try verifyShapeMesh(&torus);

    var cone = try (shapes.Cone{ .radius = 0.5, .height = 1.2, .radial_segments = 16 }).mesh(testing.allocator);
    defer cone.deinit();
    try verifyShapeMesh(&cone);

    var md = try torus.toMeshData(testing.allocator);
    defer md.deinit();
    try testing.expectEqual(torus.vertices.len, md.vertices.len);
}
