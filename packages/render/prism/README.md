# `official.render.prism` (`packages/render/prism`)

Modular rendering orchestration foundation for `zengy` (`engine.render.prism/1`, Stage 01 — see [ADR-008](../../../docs/adr/ADR-008-prism-helios-rendering.md) and [Prism & Helios Roadmap](../../../docs/roadmap/prism-helios.md)).

## Stage 01 Foundation

- **`core/types.zig`:** `LightingMode`, `AntiAliasingMode`, `RenderViewSettings`, generational `RenderViewId`, `ViewRegistry` (per-view resize & temporal history invalidation), and `resolveViewConfig` (capability fallback / strict validation).
- **`core/pass_graph.zig`:** Declarative `PassGraph` with `PassDesc`, `ResourceDesc`, read-before-write validation, cycle detection, and deterministic topological compilation (`CompiledSchedule`).
- **`core/render_world.zig`:** Stage 02 persistent dense `RenderWorld` with O(1) swap-remove compaction, `prev_model` vs `curr_model` tracking, per-view frustum culling (`extractFrustumPlanes`), stable opaque/transparent sort keys, and contiguous `DrawBatch` grouping.
- **`core/coordinates.zig`:** Stage 03 canonical coordinate convention (`[0..1]` depth), Halton (2,3) sub-pixel jitter (`haltonJitter`, `applyProjectionJitter`), `linearizeDepth`, and UV-space `computeMotionVector`.
- **`core/extensions.zig`:** Stage 10 versioned third-party `ExtensionRegistry` (`before_opaque`, `after_opaque`, `before_tonemap`, `after_tonemap`, owner revocation) and `QualityPreset` / `presetConfig` matrix (`low`, `medium`, `high`, `ultra`).
- **`features/temporal.zig`:** Stage 03 conservative odd-dimension `HiZPyramid`, deterministic `interleavedGradientNoise`, disocclusion / RGB neighborhood clamp helpers, and `TemporalHistoryManager` (per-view resize and camera-cut resets).
- **`passes/shadows.zig`:** Stage 04 PSSM cascade splits (`computeCascadeSplits`), texel snapping (`snapCascadeOrigin`), normal-offset bias, bounded PCSS penumbra estimation, importance-ranked `planLocalShadowAtlas` with guarded UVs, and `ShadowCacheTable`.
- **`lighting/photometry.zig`:** Stage 05 SI photometric units (`ev100FromCamera`, `exposureFromEv100`, `pointLuminousIntensity`, `spotLuminousIntensity`), smooth finite-range inverse-square attenuation, cone falloff, and `specularAaRoughness`.
- **`features/reflections.zig`:** Stage 06 box-projected `ReflectionProbe` parallax correction & influence blending, SSR confidence/probe blending, Lagarde `computeSpecularOcclusion`, and `DynamicResolutionController`.
- **`features/atmosphere.zig`:** Stage 07 Rayleigh/Mie `evaluateSkyRadiance`, logarithmic froxel depth slicing, `composeFogRadiance`, and `LocalFogVolume` evaluation.
- **`lighting/baked_gi.zig`:** Stage 08 `BakedLightAssetHeader` staleness tracking, `Sh9Irradiance`, normal-aware `IrradianceProbeVolume`, and `dilateLightmapRgba` seam dilation.
- **`resources/manifest.zig`:** `ShaderInterfaceDesc`, `validateUniformLayout`, deterministic `PipelineCacheKey`, and completion-aware `RetirementQueue`.
- **`resources/recording_backend.zig`:** `PrismBackendVTable` and headless `RecordingBackend` for contract testing without SDL or a GPU.
- **`prism.zig`:** `PrismService`, `buildDefaultForwardPlusGraph` (`Shadow -> SSAO -> Forward+ -> Volumetric -> Bloom -> PostFX`), and `module()`.

## Visual Showcase

```bash
zig build run-visual-prism
```
