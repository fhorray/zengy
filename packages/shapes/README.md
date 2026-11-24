# `official.shapes` (`packages/shapes`)

Procedural 3D mesh primitives for prototyping and debug rendering (`engine.shapes/1`).

## Primitives

- `Plane` (`size`, `subdivisions`)
- `Cuboid` (`size`)
- `Sphere` (`radius`, `rings`, `sectors`)
- `Capsule` (`radius`, `half_length`, `rings`, `sectors`)
- `Cylinder` (`radius`, `height`, `radial_segments`, `cap_top`, `cap_bottom`)
- `Torus` (`major_radius`, `minor_radius`, `major_segments`, `minor_segments`)
- `Cone` (`radius`, `height`, `radial_segments`, `cap_bottom`)

Each primitive `.mesh(allocator)` returns a `ShapeMesh` containing:
- `vertices: []render_3d.gltf.Vertex3D` (positions, normals, `[0..1]` UVs)
- `tangents: [][4]f32` (orthogonalized `(tx, ty, tz, handedness)` computed via `computeTangents`)
- `indices: []u32`, `bounds_center`, `bounds_radius`
- `toMeshData(allocator)` for direct use with `render_3d` / `graphics_sdlgpu.createMesh3D`.

## Example

```zig
var torus = try (shapes.Torus{ .major_radius = 0.6, .minor_radius = 0.2 }).mesh(allocator);
defer torus.deinit();

const gpu_mesh = try graphics_sdlgpu.createMesh3D(&app, std.mem.sliceAsBytes(torus.vertices), torus.indices);
```
