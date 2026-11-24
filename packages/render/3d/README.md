# `render-3d` (`official.render.3d`)

3D foundation and glTF 2.0 asset pipeline providing `engine.render.3d/1`.

## Modules

- [`src/math3d.zig`](src/math3d.zig): `Vec3`, column-major `Mat4`, `lookAt`, `[0..1]` `perspective` projection, and 6-plane `Frustum` (`intersectsSphere`).
- [`src/gltf.zig`](src/gltf.zig): `loadGltfFromMemory` (glTF 2.0 JSON + embedded base64 or external `.bin` buffers) and `createCubeMesh`, with bounding sphere calculation.
- [`src/render_3d.zig`](src/render_3d.zig): `Transform3D`, `Camera3D`, `MeshRef`, and `.render_extract` system with frustum culling (`culled_count`) and precomputed `mvp_matrix`.

## Example

```bash
zig build run-visual-3d
```
