# `render-3d` (`official.render.3d`)

3D foundation and glTF 2.0 asset pipeline providing `engine.render.3d/1`.

## Modules

- [`src/math3d.zig`](src/math3d.zig): `Vec3`, column-major `Mat4`, `lookAt`, `[0..1]` `perspective` projection, and 6-plane `Frustum` (`intersectsSphere`).
- [`src/gltf.zig`](src/gltf.zig): `loadGltfFromMemory` (glTF 2.0 JSON + embedded base64 or external `.bin` buffers) and `createCubeMesh`, with bounding sphere calculation.
- [`src/render_3d.zig`](src/render_3d.zig): `Transform3D`, `Camera3D`, `MeshRef`, and `.render_extract` system with frustum culling (`culled_count`), off-frustum shadow-caster forwarding, and precomputed `mvp_matrix`.
- [`src/pbr.zig`](src/pbr.zig): Backend-agnostic `StandardMaterial`, `MaterialRegistry`, `DirectionalLight` (exponential `CascadeShadowConfig`, PCSS), `PointLight`, `SpotLight`, `RectLight` (area light), `ReflectionProbe`, `AmbientLight`, `SkyEnvironment`, `FogSettings` (distance + volumetric), `PostProcessSettings` (Auto-Exposure, Bloom, Tonemapping, SSAO, Contact Shadows), and `PbrBackendVTable`.
- [`src/ibl.zig`](src/ibl.zig): Band 0–2 Spherical Harmonics (`SkyDiffuseSH`), procedural equirectangular HDR sky generation, GGX prefiltered specular mip chains, and 2D GGX BRDF LUT.
- [`src/cluster.zig`](src/cluster.zig): Agnostic `16 x 9 x 24` Clustered Forward+ light assignment with logarithmic Z slicing for `PointLight`, `SpotLight`, and `RectLight`.

## Examples

```bash
zig build run-visual-3d
zig build run-visual-pbr
```
