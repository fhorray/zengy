# Zengy — Prism & Helios Rendering Roadmap

**Status:** Proposed architecture and implementation plan  
**Baseline:** `fhorray/zengy`, `feat/pbr-lighting-and-postfx`, commit `94b7716b848830ee066c1a809f1734b4ea5caa18` (2026-11-24)  
**Scope:** Optional rendering framework, rasterization quality, hybrid illumination and eventual ray tracing  
**Primary language:** Zig; existing GLSL/SPIR-V shader pipeline  
**Primary backend:** SDL3 GPU  
**Naming:** Prism = rendering framework; Helios = optional advanced lighting subsystem; Plume = existing editor/tooling UI kit.

> **Update:** the graphics provider referenced below (SDL GPU, `packages/graphics/sdlgpu`) has been replaced by wgpu-native; see [docs/migration/wgpu.md](../migration/wgpu.md). Paths and shader notes in this roadmap describe the plan as written against the old baseline.

> This is an engineering proposal, not a description of features already shipped. Preserve Zengy's existing module, service, ECS, ownership and headless contracts. Every new capability must earn its complexity through measurable results.

## Contents

1. Baseline and architectural constraints
2. Target architecture and public contracts
3. Performance and quality policies
4. Stage 00 — Stabilize existing rendering
5. Stage 01 — Prism foundation
6. Stage 02 — Render world and submission scalability
7. Stage 03 — Shared rendering infrastructure
8. Stage 04 — Shadows
9. Stage 05 — Physical lighting and materials
10. Stage 06 — Ambient occlusion, reflections and image stability
11. Stage 07 — Atmosphere and volumetrics
12. Stage 08 — Baked illumination and probe volumes
13. Stage 09 — Helios hybrid lighting
14. Stage 10 — Extensibility, editor and production readiness
15. Stage 11 — Helios software ray queries (experimental)
16. Stage 12 — Native backend and hardware ray tracing (experimental)
17. Stage 13 — Helios real-time ray-traced lighting and reference path tracer
18. Release gates, budgets, validation and risks

---

## 1. Baseline and architectural constraints

### 1.1 Observed repository structure

| Existing location | Current responsibility | Migration intent |
|---|---|---|
| `src/core/` | App lifecycle, ECS facade, scheduler, resources, commands, events, service registry, diagnostics, ABI | Keep GPU-free; no Prism dependency |
| `packages/graphics/core/src/graphics.zig` | `GraphicsDeviceService`, surface handles, `DrawCommand`, backend hooks, capabilities, headless command path | Preserve public service; extend with separate optional low-level GPU capability |
| `packages/graphics/sdlgpu/src/graphics_sdlgpu.zig` | SDL GPU device, surfaces, presentation, UI/2D and mesh submission, texture creation | Retain provider; move rendering policy out incrementally |
| `packages/graphics/sdlgpu/src/gpu_resources.zig` | GPU resource handles/storage | Reuse and evolve ownership contracts |
| `packages/graphics/sdlgpu/src/pbr_backend.zig` | PBR pipelines, HDR targets, shadow atlases, clusters, IBL, SSAO, fog, exposure, bloom | Split by responsibility using vertical slices |
| `packages/render/3d/src/render_3d.zig` | Components, render extraction, camera selection, frustum culling | Preserve facade; feed Prism snapshots |
| `packages/render/3d/src/pbr.zig` | Material, lighting and environment contracts | Keep canonical scene-facing data |
| `packages/render/3d/src/cluster.zig` | CPU cluster building | Move implementation only after parity; retain tests |
| `packages/render/3d/src/ibl.zig` | Environment processing | Evolve into shared environment service |
| `packages/render/3d/src/gltf.zig` | Initial glTF import | Improve independently of GPU backend |
| `packages/scene/src/incremental.zig` | Incremental global transforms | Reuse as extraction input; do not create competing transform graph |
| `packages/render/2d`, `packages/render/text` | 2D and text rendering | Preserve compatibility; optional shared batching later |
| `official.ui.core`, `official.ui.widgets`, `official.ui.plume`, `official.ui.markup` | Layered UI stack | Continue emitting existing backend-neutral draw commands |

Existing graphics service exposes `engine.graphics.device/1`; render-3d exposes `engine.render.3d/1`. The graphics vtable currently centers around surface creation, resize, destruction and presentation; it is not yet a general resource/command abstraction. Its command storage is shared across surfaces, a concrete multi-view migration concern. The current renderer is already custom Zengy code; Prism is an evolution and naming of that code, not a replacement engine.

### 1.2 Non-negotiable existing ADRs

- ADR-001: minimal core, no mandatory GPU, window, audio or scripting dependencies.
- ADR-002: topological module resolution; `build`, `start`, `stop`; deterministic rollback and reverse shutdown; scoped ownership.
- ADR-003: versioned semantic capabilities, explicit exclusive provider selection, deterministic missing/ambiguous provider errors.
- ADR-005: generational handles, world identity, persistent GUIDs, explicit cross-ABI ownership and plugin revocation.
- ADR-006: existing stages (`startup`, `pre_update`, `fixed_update`, `update`, `post_update`, `render_extract`, `shutdown`), read/write declarations, deferred ECS commands, thread affinity and opt-in parallelism.
- ADR-007: preserve ECS facade; do not expose a private ECS implementation or raw storage pointers.
- ADR-0001: preserve `UiTree` and `graphics.DrawCommand` as the shared UI IR. Plume remains an opinionated tooling skin, not the sole UI renderer.
- ADR-004 (dual ABI): review existing ABI contract before exposing any Prism functionality to external plugins; do not export Zig layout as a stable C ABI.

### 1.3 Baseline findings to close or revalidate

The audited commit added bounded cluster indices, per-stream SDL audio pause, mipmaps, an sRGB upload API, normal matrices, alpha pipelines, FXAA, depth-weighted AO blur, safer HDR resize and improved IBL invalidation. These are source-level observations, not proof of runtime correctness.

Remaining rendering risks include unsorted transparency, missing alpha-aware depth/shadow variants, inactive cascade selection, cluster budget starvation, fixed camera depth bounds, offscreen light culling, shared anisotropic clamp sampler, non-linear depth AO filtering, full-resolution 64-step volumetrics, incomplete volumetric visibility, approximate fog composition, incomplete IBL invalidation and frame/view ownership. Revalidate each item at Stage 00; do not reopen an already fixed issue without evidence.

## 2. Target architecture and public contracts

### 2.1 Dependency direction

```text
Game / editor / optional packages
  | scene components + assets + view requests
  v
render-3d facade / render-2d / UI core
  | incremental extraction; existing module lifecycle
  v
Prism render world -> prepare -> visibility -> queues -> pass schedule
  |                       |                         |
  |                       +-- Forward+ (default)    +-- post-processing
  |                       +-- Helios (optional)     +-- UI composition
  v
Optional GPU command/resource capability
  v
SDL GPU provider (first) / native providers (future)

Core ECS and services have no dependency on any of these optional packages.
```

Use logical modules before creating physical packages. Suggested package names are provisional and must follow the repository's existing build and module conventions:

```text
packages/
  graphics/core/             # Existing service and UI command contract
  graphics/sdlgpu/           # SDL provider and platform integration
  graphics/gpu/              # Proposed optional GPU contract, if justified
  render/3d/                 # Existing canonical scene-facing facade
  render/2d/                 # Existing 2D facade
  render/text/               # Existing text facade
  render/prism/              # Proposed orchestration and raster implementation
    src/core/                # Render world, views, scheduling, extraction
    src/resources/           # GPU caches, frame pools, shader interfaces
    src/passes/              # Depth, shadows, opaque, transparent, post
    src/lighting/            # Clusters, environment, probes, materials
    src/features/            # AO, reflections, atmosphere, AA
  render/helios/             # Proposed optional advanced illumination
    src/hybrid/
    src/ray_query/           # Only when a prototype justifies it
    src/reconstruction/
```

Do not duplicate `PbrMaterial`, scene transforms, asset registries or graphics handles under new brand names. Keep compatibility exports while moving implementation. No separate Prism UI tree. No mandatory Helios dependency for Forward+.

### 2.2 Service and module model

Keep `engine.graphics.device/1` and `engine.render.3d/1` compatible. Consider new proposed capabilities `engine.graphics.gpu/1` (resource/command operations), `engine.render.prism/1` (render orchestration) and `engine.render.helios/1` (advanced illumination). Names and versions require an ADR; avoid registering two exclusive providers for the same capability. Explicit provider choice must use the existing service resolution rules. Helios consumes Prism, not vice versa; Prism can resolve optional lighting providers without forcing them into every application.

A headless app may use scene data and the existing command-recording path without initializing a GPU. A recording/mock provider can validate pass ordering and resource usage; it is not a software rasterizer.

### 2.3 Proposed API shape (illustrative, not compilable against today's SDK)

```zig
pub const LightingMode = enum { rasterized, hybrid, ray_traced };
pub const AntiAliasingMode = enum { none, fxaa, taa };
pub const RenderViewSettings = struct {
    lighting: LightingMode = .rasterized,
    anti_aliasing: AntiAliasingMode = .fxaa,
    resolution_scale: f32 = 1.0,
    allow_fallback: bool = true,
};
pub const RenderViewId = packed struct(u64) {
    index: u32,
    generation: u32,
};
```

Use existing `ModuleDescriptor` and app registration API rather than inventing a parallel plugin lifecycle. Reflect configuration through the existing schema registry. Persistent scene data stores logical assets and GUIDs, not device handles. Unsupported requested features produce structured diagnostics and a documented effective configuration. Strict mode may reject instead of falling back. Keep reference path tracing a distinct view/pipeline mode, not a synonym for hybrid lighting.

### 2.4 Render scheduling and pass contracts

Use the existing `render_extract` stage to publish immutable frame input. Prism owns a private render schedule; do not add mandatory GPU stages to the minimal core. Start with explicit phases and deterministic dependency validation, then compile declared resource dependencies into execution order when necessary. CPU preparation may use worker systems with disjoint access; GPU command recording/submission must obey provider affinity.

Each pass declares name, scope (frame/view/light), inputs, outputs, usage, load/store intent, feature predicate, dependencies and failure policy. Reject reads of uninitialized resources, incompatible usages and cycles. Keep persistent histories distinct from transient targets. SDL handles its own synchronization; do not pretend native explicit barriers or memory aliasing are available through it. Native providers may later use richer synchronization internally.

### 2.5 Data and lifetime rules

- Render snapshot carries world identity, frame epoch, view IDs, asset versions and previous/current transforms. Never retain borrowed ECS pointers across stages.
- Generational mapping from entity/world to dense render instance; remove stale instances on destruction and world unload. GUIDs are for persistent references, not dense indexing.
- Frame contexts own temporary allocations, upload regions and retirement lists; GPU objects are retired only after completion or a documented safe provider mechanism.
- History is per view, invalidated on camera cuts, size/format changes, world switches and relevant feature changes.
- Resource scopes align with existing lifecycle: application/device, world/scene, window/surface, plugin and frame. Stop in reverse order; rollback partial initialization.

## 3. Performance and quality policies

Performance is measured in CPU and GPU milliseconds, frame-time percentiles, memory, upload bytes and draw/dispatch counts. FPS alone is insufficient. Aim for no avoidable steady-state general allocator calls in extraction, clustering and submission after warm-up; bounded growth and exceptional allocation are acceptable and must be reported. Favor dense storage and contiguous iteration where measured; avoid unnecessary abstraction, virtual calls per pixel/draw and duplicating ECS storage.

Set feature budgets per view, not global unbounded work. Every expensive feature has an off switch, capability gate, quality tier and fallback. Never silently drop lights, shadow casters or instances: expose counts and reason codes. Use GPU timestamps only where genuinely supported; otherwise label measurements as CPU-side and use external captures.

Reference workloads: empty frame/UI, 1k/10k/50k instances, shared meshes vs unique materials, 32/128/512 lights, foliage, indoor scenes, two views, resize/minimize, HDRI changes and streaming. These are proposed workloads, not existing performance claims.

---
## 4. Stage 00 — Stabilize existing rendering (pre-Prism gate)

**Goal:** Establish a trustworthy, reproducible raster baseline before refactoring. Suggested branch: `fix/rendering-baseline`.

### Work packages

- [ ] Verify cluster offsets/counts against the actual uploaded index length; test zero lights, exact budget, overflow and per-type caps. Replace sequential starvation with deterministic relevance-based allocation; report discarded references including local caps. Reject offscreen bounds before clamping; use conservative projection and actual view near/far values. Reuse scratch arrays.
- [ ] Split opaque, masked and transparent queues. Render opaque/masked first; sort transparent back-to-front with deterministic ties; disable transparent depth writes. Respect single/double-sided raster state and orient backface normals. Document intersecting transparency limitations. Exclude blend surfaces from solid depth/shadow passes by default; alpha-mask variants share exact cutoff, texture and UV behavior.
- [ ] Send active cascade count to every shader; constrain selection, blending and fallback. Test 1–4 cascades. Apply declared normal/slope/depth bias consistently across directional and local shadows; prevent atlas edge bleed.
- [ ] Reuse prepass depth when the cost/benefit warrants it; use compatible depth comparison and identical alpha/vertex deformation. Avoid duplicate work for views that do not need a prepass.
- [ ] Complete texture color-space metadata from import to sampling; sRGB base color/emissive, linear data maps; verify output transfer exactly once. Split repeat/clamp, comparison and anisotropic samplers; avoid mip bleed in UI atlases. Validate dimensions, byte counts and device format support.
- [ ] Make FXAA optional, add perceptual contrast rejection, verify image sharpness. Linearize AO depth and implement bilateral upsampling; validate depth conventions and camera reconstruction.
- [ ] Reduce volumetric ray marching resolution, expose quality/step settings and early termination, use correct scattering/transmittance composition; honor density zero and start/end distances. Select relevant lights and respect point/spot shadow visibility; avoid sampling invalid atlas entries.
- [ ] Replace HDRI pointer-only invalidation with asset revisions and full parameter dependencies; verify exposure/rotation consistency, procedural/solid sky behavior, asynchronous or budgeted environment preprocessing, transactional replacement on failure.
- [ ] Verify auto-exposure histogram percentile accounting, black bins, time-step behavior, disabled-mode cost and camera cuts. Fix stale SPIR-V risk with reproducible shader build and interface checks.
- [ ] Audit frame consumption, failed submission, minimized surfaces, no-camera frames and multiple surfaces. Preserve resources on failed resize; ensure no stale draw queues or premature GPU destruction.
- [ ] Harden glTF import for accessor bounds/strides, multiple primitives, missing normals, invalid buffers and material/color-space semantics. Do not report unsupported features as imported successfully.

### Acceptance

All previous high-severity rendering issues are fixed or explicitly deferred with reproducible evidence. Existing 2D, UI and 3D demos work. Capture representative images and CPU/GPU baseline on named hardware, driver, resolution, build mode and settings. Record exact commit and shader hashes. No new feature work blocks the baseline. Audio lifecycle fixes from prior audits remain a separate audio workstream, not a Prism dependency.

## 5. Stage 01 — Prism foundation (0.1)

**Goal:** Extract a modular renderer from the working code without a visual redesign. Suggested branch: `feat/prism-renderer-foundation`.

### 5.1 Architectural decisions

- [x] Write ADRs for package boundaries, graphics provider contract, render world, frame ownership, pass scheduling and compatibility. Use existing module descriptors and scopes; review service exclusivity and ABI implications. (`docs/adr/ADR-008-prism-helios-rendering.md`)
- [ ] Inventory all SDL-specific types and calls in `pbr_backend.zig` and public graphics helpers. Classify resource creation, recording, presentation, feature policy and scene data.
- [ ] Initially split code inside existing packages if that avoids build churn. Move pure policy first, then shader-independent passes; migrate one pass end-to-end at a time. Avoid a permanent second implementation.
- [x] Define a narrow GPU interface driven by existing passes: buffer/texture/sampler/shader/pipeline handles, upload, render/compute/copy recording, submission/completion, format/capability queries. Explicit ownership, errors, usage flags and thread affinity. Avoid abstracting native features not yet needed. (`PrismBackendVTable` + `RecordingBackend` in `packages/render/prism`)
- [x] Adapt SDL provider behind that interface; preserve `GraphicsDeviceService` and existing UI command semantics. Provide a recording backend for contract tests. No mandatory native Vulkan backend. (`graphics_sdlgpu.startModule` registers `PrismBackendVTable` + `RecordingBackend`)

### 5.2 Shader and resource infrastructure

- [x] Centralize shader manifest, entry points, binding layouts, stage visibility and required capabilities. Validate CPU extern struct sizes/offsets against shader layouts. Compile GLSL to SPIR-V reproducibly; fail CI on stale generated output or interface mismatch. (`CANONICAL_SHADERS` & `validateCatalog` in `packages/render/prism/src/resources/shader_catalog.zig`)
- [x] Add pipeline cache keys covering shader version, vertex layout, target/depth formats, sample count, blend, raster/depth state and feature masks. Bound variant growth and avoid per-frame pipeline creation. (`PipelineCacheKey` + `ShaderInterfaceDesc` in `packages/render/prism/src/resources/manifest.zig`)
- [x] Introduce frame contexts, reusable upload buffers and completion-aware retirement. Add transactional target recreation, resource labels and debug validation. Maintain existing generational handle rules and provider-owned native pointers. (`RetirementQueue` & `frame_epoch` in `packages/render/prism`)
- [x] Define per-view target set and explicit clear/load/store policy. Separate frame-global resources (geometry/materials) from view-local targets (depth/HDR/history). Add structured capability and fallback reports. (`ViewRegistry`, `resolveViewConfig`, `FallbackReason`)

### 5.3 Migration order

1. Isolate texture/buffer creation and lifetime; retain SDL presentation.
2. Move pure cluster/environment math without changing algorithms.
3. Move HDR/post-processing pass ownership and target allocation.
4. Move shadow/depth and opaque PBR passes; then transparent and volumetric passes.
5. Route `render_3d` extraction into Prism; leave legacy API adapters in place.
6. Remove obsolete paths only after equivalent images and behavior are demonstrated.

### Acceptance

Existing examples compile with their original public API or documented compatibility shim. No mandatory GPU dependency in `src/core`. Headless and UI-only apps still run. Every module start failure rolls back resources. New renderer and baseline output match within documented numerical/image tolerances. Compare CPU/GPU cost before/after; investigate regressions above agreed thresholds. No new ray tracing or major effect in this stage.

## 6. Stage 02 — Render world and submission scalability (0.2)

**Depends on:** Stage 01. **Goal:** Make rendering scale with visible work and changed data rather than total world size.

- [x] Build dense persistent instance, light, mesh, material and view stores. Map generational world/entity identity to slots; support removal, compaction and stale handle rejection. Keep render asset generations separate from ECS generations. (`RenderWorld` in `packages/render/prism/src/core/render_world.zig`)
- [x] Extract from existing `render_extract` and incremental scene transform propagation; track component/asset changes, removals, visibility and hierarchy revisions. Implement full resync fallback and measure incremental vs full extraction. If the ECS lacks suitable change ticks, add optional tracking at the facade boundary or use a versioned render adapter; do not force a new ECS backend. (`IncrementalExtractor` in `packages/render/prism/src/core/snapshot.zig`)
- [x] Publish immutable snapshots with explicit ownership; double/triple buffering only if measured throughput benefits exceed latency/memory cost. Separate previous-rendered transforms from previous-simulation transforms. Handle skipped frames and teleports. (`FrameSnapshot`)
- [x] Implement per-view frustum culling with conservative bounds, shadow caster culling per light/cascade, light bounds and spatial acceleration where justified. Track visible/culled counts. Add LOD selection with hysteresis and conservative animation bounds once animation is available. (`extractFrustumPlanes`, `cullAndQueue`, `VisibilityStats`)
- [x] Build render phases with stable sort keys: pipeline/material/mesh for opaque batches, depth-aware ordering where beneficial, back-to-front for transparent. Batch identical geometry/material states and implement instanced draw data with correct per-instance transforms and IDs. (`QueueEntry`, `DrawBatch`)
- [ ] Move repeated uniforms to frame/view/material blocks; use storage buffers for instance data where supported. Cache descriptor-equivalent bindings and avoid redundant uploads/state changes. Keep an explicit compatibility path for limited providers.
- [ ] Implement bounded cluster scratch/storage, relevance prioritization and diagnostics. Prototype GPU cluster construction only after CPU measurements; avoid GPU readback in the hot path.
- [ ] Add indirect draw support only if the provider exposes it and measurements justify it. Start CPU-generated indirect commands, then evaluate GPU culling/compaction. Do not require bindless descriptors.
- [x] Support multiple cameras and render targets, including offscreen views and editor preview. Frame ownership must not depend on the first `present()`. Separate each view's exposure and history; share immutable geometry/material resources. (`MultiViewSet` + per-view `TemporalHistoryManager`)

### Acceptance

No duplicate/stale instances after entity reuse, scene unload or material changes. Static scenes show near-zero redundant uploads after warm-up. Multi-view rendering works independently. Benchmark 1k/10k/50k instances and light stress cases; report extraction, queue, submission, GPU time and memory. Demonstrate improved workload scaling without sacrificing correctness. Keep CPU preparation and GPU submission affinity explicit.

## 7. Stage 03 — Shared rendering infrastructure (0.3 foundation)

**Goal:** Build reusable screen-space and temporal data before individual advanced effects.

- [x] Introduce pass/resource declarations and deterministic dependency compilation. Support optional passes, per-view resource descriptors, lifetime analysis and safe pool reuse. Track actual SDL restrictions; do not emulate unsupported aliasing/barrier semantics. Reject cycles, read-before-write, illegal simultaneous usage and incompatible formats. (`PassGraph` in `packages/render/prism/src/core/pass_graph.zig`)
- [x] Establish one documented coordinate convention: clip/depth range, UV origin, matrix layout, winding, world/view spaces, jitter and motion-vector sign. Validate orthographic/perspective reconstruction, near/far and optional reversed-Z via separate capability/format investigation. (`packages/render/prism/src/core/coordinates.zig`)
- [x] Build depth pyramid (Hi-Z) with reduction appropriate to the depth convention and intended ray traversal. Handle odd dimensions, mip levels and conservative sampling. Reuse for contact shadows, SSR, SSGI and future occlusion culling. (`HiZPyramid` in `packages/render/prism/src/features/temporal.zig`)
- [ ] Add optional normal/roughness and velocity targets without forcing a full deferred G-buffer. Ensure alpha masking and deformation match color passes. Include camera and object motion; handle missing previous poses, skinned geometry when available and camera cuts.
- [x] Introduce shared temporal history manager, reprojection, disocclusion tests (depth/normal), history clamping, reactive masks, exposure compensation and resolution-change policies. Specify whether histories are pre-exposed or scene-linear. (`TemporalHistoryManager`, `isDisoccluded`, `clampHistoryRgb`)
- [x] Provide blue-noise sequences, deterministic seeds for captures, bilateral filters and edge-aware upsampling. Separate shared utilities from effect-specific tuning. (`interleavedGradientNoise`)
- [ ] Add GPU debug markers, pass counters, timing where available, capture labels, debug views for depth/normals/velocity/Hi-Z/history rejection, and per-view resource memory accounting.

### Acceptance

Depth and motion reconstruction validated with analytic scenes and moving camera/object tests. History reset produces no stale image after teleport/resize. Optional buffers are absent when unused. Pass schedule can be inspected and invalid declarations fail deterministically. Measure memory bandwidth and storage costs before enabling every buffer by default.

## 8. Stage 04 — Advanced shadows (0.3)

**Goal:** Stable, sharp contact shadows and believable softness with bounded cost.

### 8.1 Directional shadows

- [x] Fit cascades to actual view frusta, support practical split schemes and explicit shadow distance. Stabilize projection with texel snapping and stable extents; avoid unnecessary matrix changes. Implement consistent cascade transitions and active count across PBR/fog. (`computeCascadeSplits`, `snapCascadeOrigin` in `packages/render/prism/src/passes/shadows.zig`)
- [x] Add slope-scaled and normal offset bias expressed in appropriate units; expose per-light controls and debug acne/peter-panning. Clamp PCF sampling to guarded tiles. (`computeNormalOffsetBias`, `computeGuardedTileUv`)
- [x] Implement actual PCSS: blocker search, blocker depth estimate, penumbra size based on light angular size and receiver distance, variable filter radius. Use a non-comparison depth sampling path for blocker search where supported. Bound samples and radius; use PCF fallback. (Done in the `graphics-sdlgpu` backend: `pbr.frag` blocker search through a non-comparison view of the cascade and local-atlas depth, penumbra from `DirectionalLight.pcss_light_size` / the light `radius`, 12-16 bounded taps with the PCF path as fallback; switch `ShadowQuality.pcss`.)
- [ ] Use rotated sample patterns and optional temporal reconstruction, with a stable spatial-only mode for low quality. Avoid temporal smearing on moving casters. *(Rotated Vogel patterns with per-pixel interleaved-gradient noise are in place; temporal reconstruction is not.)*

### 8.2 Local shadows

- [x] Replace fixed tile assignment with deterministic atlas allocation (buddy/quadtree or measured alternative), guard bands, importance scores, hysteresis and per-frame update budgets. Track point-light six-face cost; do not starve spotlights arbitrarily. (`planLocalShadowAtlas`, `ShadowCacheTable`)
- [x] Support different tile resolutions and safe eviction. Cache static light/caster results; invalidate on light/transform/material/geometry changes and atlas moves. Initially cache whole light maps; split static/dynamic layers only if useful. (`shadow_plan.zig`: 256-1024 tiles from apparent size, buddy-style cell packing, deterministic eviction; per-cascade and per-tile caches keyed by the casters that reach each map, its matrix and its atlas rect, so a moved, re-materialled or removed caster invalidates only the maps it touches. Mesh data replaced under the same handle is not tracked.)
- [ ] Cull casters against each spot frustum, point face and cascade. Preserve offscreen casters that can shadow visible receivers. Handle alpha-mask foliage, two-sided shadow policy, deformation and negative scale/winding. *(Sphere-vs-frustum culling per spot, point face and cascade, off-screen casters kept, alpha-mask and two-sided shadow pipelines are done; deformation and negative-scale winding are not.)*
- [ ] Improve screen-space contact shadows with Hi-Z, thickness control, fade, temporal filtering and depth-aware sampling; combine with map visibility without double darkening. Document offscreen limitations.
- [ ] Explore area-light shadow approximations separately from LTC lighting. Do not promise arbitrary soft shadows from a single center shadow map. Provide a low-cost approximation and later ray-query option if validated.

### Acceptance

Camera pan does not cause unacceptable cascade swimming; correct 1–4 cascade behavior; leaf cutouts match silhouettes; contact hardening visible in reference scene; atlas overflow degrades deterministically; static scene shadow updates reduce measurably. Profile PCF/PCSS and atlas sizes on target GPUs. No default use of virtual shadow maps until provider and memory tradeoffs justify them.

## 9. Stage 05 — Physical lighting and materials (0.4)

**Goal:** Consistent, physically meaningful lighting and richer surface response.

- [x] Document scene scale (meters), light color conventions, photometric units and exposure calibration. Directional lux; point candela or lumens converted by emission solid angle; spot flux normalized by angular distribution; area luminance/flux with explicit emitting area; emissive luminance; EV100 exposure. Remove arbitrary shader divisors through a versioned migration preserving old scenes where possible. (`packages/render/prism/src/lighting/photometry.zig`)
- [x] Correct inverse-square attenuation with smooth finite range windows, spot inner/outer cone and direction handling independent of unintended scale. Define physically meaningful limits and finite-value validation. Share light evaluation conventions with fog and Helios. (`smoothDistanceAttenuation`, `spotAngularAttenuation`, `specularAaRoughness`)
- [ ] Add LTC area light diffuse/specular integration using validated LUTs and license-compatible generation/data. Support orientation, dimensions, one/two-sided emission; compare to reference integrator. Keep shadow visibility a separate problem.
- [ ] Import IES photometric profiles with validated angular interpolation and normalization. Implement cookies for spot/directional and optionally point lights, bounded atlas/array allocation, correct transforms, color-space and fallback; support volumetric use later.
- [x] Add light and shadow masks/layers with documented receiver/caster behavior. Keep cluster assignment conservative; only optimize layer-specific lists if profiling supports it. (`pbr.RenderLayers`, `layers` on every light component: a light affects, and is shadowed by, only meshes that share a layer; default lights use every layer. Cluster assignment is unchanged. Layers do not mask fog scattering, probes or the sky. Visual-prism uses it to keep the unshadowed bounce lights of the dark room off the ground outside.)
- [ ] Extend glTF/material import for color spaces, UV sets, sampler modes, texture transforms, metallic/roughness channel packing, tangent generation and handedness. Use MikkTSpace-compatible tangents where justified; preserve derivative fallback for simple assets. Add specular antialiasing via normal variance and roughness filtering.
- [ ] Extend canonical PBR material with versioned optional features: clearcoat, sheen, anisotropy, IOR/specular, thin transmission, detail maps, parallax, thickness/refraction and subsurface approximations. Implement in that order after basic material parity. Gate expensive lobes by feature masks and limit variants. Validate energy conservation, Fresnel, white-furnace behavior and grazing angles. Transparent transmission requires separate composition semantics; do not treat ordinary alpha blending as refraction.
- [ ] Introduce mesh decals first; evaluate clustered projected decals/DBuffer for Forward+ using optional auxiliary targets. Support base color, normals, roughness, metallic and emissive; depth/angle fade, order and receiver masks. Avoid unsupported read/write feedback.

### Acceptance

Photometric reference scenes and gray-card exposure produce predictable values. Roughness/metallic sweeps, mirrored UVs, non-uniform transforms and color charts render correctly. IES/cookies remain optional. Simple materials do not incur mandatory cost for advanced features. Versioned migration documented for old light/material settings.

## 10. Stage 06 — AO, reflections and image stability (0.5)

**Depends on:** shared depth/normal/velocity infrastructure.

- [ ] Add GTAO as an optional higher-quality AO mode; use view-space horizon search, depth-aware filtering, optional bent normals and temporal accumulation. Retain SSAO fallback. Apply AO primarily to indirect diffuse, with a separate specular occlusion model; avoid darkening direct light indiscriminately.
- [ ] Implement real local cubemap reflection probes: capture six faces through Prism with exclusion masks, budget updates, generate GGX mip chain, box projection/parallax correction, influence shapes and blending. Use high-enough HDR formats and correct environment orientation. Prevent recursive probe captures and self-sampling. Maintain global sky fallback.
- [ ] Implement hierarchical SSR using Hi-Z, thickness checks, roughness-dependent tracing/filtering, hit confidence, edge fade and temporal denoising. Source radiance from a defined scene buffer that avoids recursive reflection feedback. Blend with probes based on confidence; do not add full reflection twice.
- [ ] Add selective planar reflections after multi-view support, mirrored camera and clip plane, resolution/visibility budget, recursion prevention and fallback. Use only for designated surfaces.
- [ ] Implement TAA: jitter sequence, velocity reprojection, neighborhood/variance clamp, disocclusion rejection, reactive masks and optional sharpening. Handle transparent objects and UI separately; keep UI at native output resolution after scene AA. Retain FXAA/none; evaluate SMAA or MSAA only where compatible and justified.
- [ ] Improve HDR post-processing: exposure adaptation, bloom threshold/energy behavior, filmic/AgX/ACES-like tone curves with accurate labeling, 3D LUT grading and output gamut/transfer handling. Add optional DoF, motion blur and lens effects after motion/depth stability. Avoid presenting SDR tone mapping as HDR display support.
- [x] Introduce dynamic resolution with hysteresis and per-view timing; spatial upscale first if useful, temporal upscale later. Investigate external FSR integration only after backend, shader and license feasibility is verified. (`DynamicResolutionController` + `ReflectionProbe` / `computeSsrConfidence` / `computeSpecularOcclusion` in `packages/render/prism/src/features/reflections.zig`)

### Acceptance

AO does not leak across major depth discontinuities; SSR fades to probes rather than black; box-projected probes maintain plausible indoor perspective; moving-camera tests show limited shimmer and ghosting; resize/camera cuts reset histories. Publish quality presets and measured GPU deltas, not assumed gains.

## 11. Stage 07 — Atmosphere and volumetrics (0.6)

**Goal:** Physically coherent sky, fog and light shafts with scalable budgets.

- [ ] Replace ad hoc sky with optional atmosphere model (Rayleigh/Mie scattering, absorption/ozone, ground albedo, sun disk and aerial perspective). Precompute transmittance/multiple-scattering LUTs where practical; update only dependent LUTs when parameters change. Keep solid sky and HDRI paths.
- [x] Unify environment lighting and sky rendering: consistent sun direction, energy, rotation and exposure; avoid double-counting sun disk in direct/IBL lighting; use radiance/irradiance preprocessing with budgeted asynchronous CPU work or GPU compute where appropriate. (Rotation and exposure are shared with the sky pass, the CPU rebuild is time-sliced and the HDRI upload is cached; the sun disc and halo are left out of the diffuse SH9 of procedural skies when a directional light exists, `RenderQuality.sun_in_ibl_diffuse` restores the old behaviour. HDRI skies cannot be separated.)
- [ ] Improve existing ray-marched fog first; then prototype froxel volume with view-space grid and logarithmic depth slices, clustered light injection, density/extinction/scattering, anisotropy and shadow visibility. Integrate along depth to produce radiance and transmittance. Use `L_out = T * L_scene + L_scatter` consistently, including sky and transparent surfaces at their own depth. *(The ray march, `L_out = T * L_scene + L_scatter` composition and half-resolution mode are improved; the froxel prototype and the half-resolution comparison are not.)*
- [x] Add local fog volumes (box/sphere, density/color/noise, height falloff, blend/priority), spatial culling and deterministic overlapping behavior. Define units and validate zero-density identity. (`packages/render/prism/src/features/atmosphere.zig`: `LocalFogVolume`, `evaluateSkyRadiance`, `froxelSliceDepth`, `composeFogRadiance`)
- [x] Add temporal reprojection with moving-light/density invalidation, noise, bilateral upsampling and early-out. Avoid lighting leakage through walls; evaluate shadow filtering cost and select lights by relevance. (`fog.volumetric.temporal`: golden-ratio jitter, reprojection with variance clipping, history dropped on density, scattering, sun or light-slot changes, resize and camera cuts; bilateral upsampling in the composite; zero-density early-out; local-light shadows in the volume; relevance-ranked light slots.)
- [ ] Prototype volumetric clouds only after fog budgets are met: weather/density maps, low-resolution ray marching, temporal filtering, atmosphere integration and optional cloud shadow maps. Keep a cheap sky/cloud alternative.

### Acceptance

Indoor flashlight and sun-through-window scenes show occluded light shafts, no artificial full-room washout, stable motion and correct density controls. Compare half-resolution ray march against froxel prototype in GPU time, VRAM and image error; ship the better default. Cloud rendering remains opt-in.

## 12. Stage 08 — Baked GI and irradiance volumes (0.7)

**Goal:** High-quality indirect light on modest hardware; reusable foundation for Helios.

- [x] Define persistent baked-light asset schema: scene/material/light revisions, UV charts, atlas metadata, coordinate conventions, compression, probe data and bake settings. Use existing asset identities/serialization; no GPU pointers in files. (`BakedLightAssetHeader` in `packages/render/prism/src/lighting/baked_gi.zig`)
- [ ] Generate or import secondary lightmap UVs; evaluate xatlas or another compatible unwrapper. Validate overlap, padding, seams, texel density and atlas allocation. Distinguish static bake geometry from dynamic receivers.
- [ ] Implement offline reference CPU/GPU baker with deterministic seeds, direct/indirect transport, multi-bounce sampling, emissive contribution, progress/cancellation and resumable jobs. Choose integration after licensing and build feasibility; no requirement for hardware RT on target runtime.
- [ ] Store HDR irradiance lightmaps with appropriate directional information if needed; support dilation, filtering, compression and mip-safe padding. Define whether direct static light is baked or evaluated dynamically to prevent double lighting. Keep mixed-light shadow policy explicit.
- [x] Create irradiance probe volumes using SH or another measured representation, visibility moments/validity and normal-aware interpolation. Add probe placement, relocation, invalid-probe handling, leak mitigation, debug visualization and volume blending. Dynamic objects sample probes; static geometry uses configured lightmaps. (`Sh9Irradiance`, `IrradianceProbeVolume`, `dilateLightmapRgba`)
- [ ] Provide incremental invalidation and bake cache; changes to geometry, light or material mark relevant outputs stale. Runtime loads baked assets asynchronously with deterministic fallback. Define memory/streaming budgets for large scenes.
- [ ] Implement tooling as optional modules/CLI; future editor may expose bake controls through Plume but the baker must run without editor UI.

### Acceptance

Cornell box shows diffuse color bleeding; static interior has plausible indirect light; dynamic object traversing room boundaries changes ambient light without obvious leaks. Bake results are reproducible within tolerance; stale assets detectable; runtime cost measured independently of baking cost. No mandatory editor or GPU ray tracing requirement.

## 13. Stage 09 — Helios hybrid lighting (0.1)

**Goal:** Optional unified indirect-lighting provider using the existing SDL GPU backend. Helios consumes Prism's data rather than owning another renderer.

- [x] Define a lighting-provider contract with explicit direct/indirect diffuse/specular outputs, confidence, visibility and units. Decide integration points to avoid double-counting sky IBL, AO, baked GI and SSR. Rasterized direct lighting remains default. (`packages/render/helios`, `engine.render.helios/1`, `combineIndirectDiffuse`)
- [ ] Implement SSGI using Hi-Z traversal, cosine/importance sampling, surface normals, scene radiance, thickness and hit confidence. Begin at half resolution with bounded rays/steps; avoid self-feedback by defining source buffers/history precisely. Support emissive contribution visible to screen-space rays. *(CPU reference Hi-Z tracer & cosine sampling implemented in `packages/render/helios/src/hybrid/ssgi.zig`; GPU shader pass pending)*
- [ ] Combine SSGI with baked irradiance/probe fallback: use confidence-weighted replacement or residual correction, not uncontrolled additive energy. Account for missing offscreen data and prevent over-darkening.
- [ ] Integrate SSR and reflection probes behind the shared lighting contract. Add common reprojection, spatial filtering, disocclusion rejection and reactive handling; keep separate diffuse/specular history tuning.
- [x] Prototype world-space irradiance/radiance cache with spatial keys, bounded capacity, invalidation, update priority, age/confidence and leak mitigation. Initially populate from available probes/screen-space samples; explicitly document that this cannot provide reliable unseen dynamic transport without a geometry query source. (`WorldRadianceCache` in `packages/render/helios/src/hybrid/radiance_cache.zig`)
- [x] Implement per-view quality settings and capability fallback to standard Prism. Expose debug modes: hit confidence, ray steps, cache occupancy, probe contribution, temporal history and indirect-only render. (`HeliosViewSettings`, `HeliosQualityTier`, `HeliosDebugMode`)

### Acceptance

Helios can be disabled without changes to scene components or raster output. Cornell/interior and moving emissive demos show useful dynamic indirect response while documenting offscreen limitations. GPU cost bounded; no mandatory native backend. Compare against baked/reference results and publish errors and failure modes. Release as hybrid lighting, not full ray tracing or a Lumen equivalent.

## 14. Stage 10 — Extensibility, editor and production readiness (Prism 1.0 candidate)

This work can begin earlier in parallel with feature stages; public contracts stabilize only after real usage.

- [x] Expose versioned render extension hooks with declared resources and ordering (`before_opaque`, `after_opaque`, `before_tonemap`, `after_tonemap`, etc. as proposed names). Validate ownership, thread affinity, conflicts and capability requirements. No raw SDL pointers in portable plugin contracts; optional native interop must be explicitly scoped. (`ExtensionRegistry` in `packages/render/prism/src/core/extensions.zig`)
- [ ] Support custom materials/shaders through validated manifests, parameter reflection, feature masks, fallback shader and pipeline cache. Hot reload transactionally: retain last good pipeline on failure and defer destruction until safe. Bound shader variant compilation and show diagnostics.
- [ ] Expose renderer settings via existing reflection; serialize versions, defaults and migrations. Add CLI/headless validation and offscreen rendering only where provider supports it; distinguish no-window GPU execution from no-GPU operation.
- [ ] Provide editor-facing APIs for viewport textures, picking/object IDs, debug lines/gizmos, selection outlines, camera controls and render statistics. Plume uses shared UI IR; Prism must not depend on Plume. UI draws after scene tone mapping by default, with intentional world-space UI paths later.
- [ ] Support world switching, editor play/stop, multiple viewport sizes, minimized windows and resource cleanup. Document device loss behavior and recovery strategy; never silently present corrupted output.
- [x] Implement quality presets, feature diagnostics, memory budget controls, asset streaming hooks and profiling. Provide shader warm-up and pipeline compilation strategy to limit hitches. (`QualityPreset` / `presetConfig` in `packages/render/prism/src/core/extensions.zig` + `FrameProfilerService` in `packages/dev-tools`)
- [ ] Publish examples and migration docs using actual Zengy module registration syntax. Add external plugin example for a custom post effect and a custom material. Keep C ABI surface minimal and versioned; validate plugin unload and callback revocation.

### Acceptance

A third-party pass can be registered and removed without patching the renderer; invalid dependencies are rejected. UI-only, headless, Forward+ and Helios apps resolve correct modules. Two editor-style viewports can coexist. Public API reviewed for ownership and compatibility; release notes include unsupported capabilities and fallback behavior.

## 15. Stage 11 — Helios software ray queries (0.2, experimental)

**Goal:** Determine whether compute-based geometry queries provide useful quality at an acceptable cost on SDL GPU. This is a decision gate, not a guaranteed shipping feature.

- [x] Define geometry query contract independent of traversal implementation: ray origin/direction/range/mask, hit distance, instance/primitive IDs, barycentrics and material lookup. Support any-hit visibility and closest-hit queries; document precision and self-intersection policy. (`Ray`, `RayHit`, `QueryStats` in `packages/render/helios/src/ray_query/bvh.zig`)
- [x] Prototype CPU BVH build with surface-area heuristics or measured alternative; pack nodes/triangles into GPU-friendly buffers. Share immutable mesh structures across instances; top-level instance bounds and transforms updated incrementally. Respect non-uniform scale and ray parameterization. (`Bvh`, `BvhNode` flat array)
- [x] Implement bounded iterative GPU traversal with robust slab/triangle intersection, near-first traversal, explicit stack overflow handling and finite-value checks. Evaluate wide nodes, quantization, coherent ray ordering and divergence only after profiling. *(CPU bounded iterative `traceClosest` / `traceAnyHit` with `MAX_STACK = 64` & `stack_overflows` counter; GPU compute shader pass pending)*
- [ ] Define update policies: static BLAS reuse, TLAS refit/rebuild thresholds, asset unload, instance movement, optional deforming geometry later. Avoid full-scene rebuild every frame. Document alpha-mask handling; unsupported geometry must be excluded with diagnostics or represented conservatively.
- [x] Build CPU reference intersection tests and randomized differential checks. Add BVH visualizations, rays-per-frame, node visits, overflow counters, build/update time and memory measurements. (`packages/render/helios/tests/helios_tests.zig`)
- [ ] Implement isolated ray-traced AO or selected shadow visibility first; then evaluate offscreen reflection hits and probe updates. Integrate with existing denoising and confidence-based fallbacks. Do not attempt full path tracing as the initial runtime feature.

### Go/no-go gate

Compare software ray queries against rasterized/hybrid equivalents on low/mid/high target GPUs. Proceed only if the quality improvement is clear and time/memory fit the agreed budget. Otherwise retain the query interface and experimental prototype, and prioritize baked/hybrid lighting or native RT. SDL compute support alone does not imply practical ray tracing performance.

## 16. Stage 12 — Native graphics backend and hardware RT (experimental)

**Goal:** Add hardware acceleration only after a provider feasibility spike. Prefer one native backend first, not simultaneous Vulkan/D3D12 development.

- [ ] Evaluate Vulkan bindings for Zig, window/surface integration, shader toolchain, device feature/extension discovery, licensing, supported platforms and maintenance burden. Evaluate D3D12 only if target platform needs justify it. SDL GPU remains the default portable provider.
- [ ] Verify required features on real hardware: acceleration structures, ray queries, descriptor/resource limits, buffer device addresses where required, synchronization and shader formats. Detect optional features individually; do not infer them solely from GPU brand.
- [ ] Implement minimum native provider for existing resource/command contract: device/queues, swapchain or offscreen targets, buffers/textures/samplers, pipelines, compute, upload, fences, barriers, retirement, format and capability reporting. Add validation layers and debug names. Avoid sharing native GPU resources across providers without explicit supported interop.
- [ ] Achieve raster parity with Prism Forward+ before adding RT. Verify surface resize, UI composition, shader bindings, memory and frame pacing. Keep one selected graphics provider per app/device unless multi-device support is deliberately designed.
- [x] Extend GPU capability with acceleration structure resources, build/update commands, scratch alignment, completion semantics and ray-query shader support. Keep optional extension contract versioned; SDL provider returns unsupported rather than pretending to implement it. (`RtAccelerationVTable`, `UNSUPPORTED_RT_VTABLE` in `packages/render/helios/src/ray_query/hw_rt.zig`)
- [x] Implement BLAS cache per mesh and TLAS per relevant scene/view policy; batching builds, compaction where supported, update/refit, deferred release and memory budgets. Handle instance masks, transforms, alpha-tested materials, asset revisions and unsupported deformations. (`BlasCache`, `TlasInstanceDesc`)
- [ ] Validate native query results against software/CPU reference. Start with ray-traced shadow for one light; then reflection and diffuse probes. Profile build/update and tracing separately. Design fallback when hardware, driver or feature support is missing.

### Acceptance

Native provider runs current visual examples and has measurable raster parity, stable lifetimes and validation-clean representative captures. Supported RT hardware executes correct queries; unsupported hardware selects raster/hybrid without crashes. Do not market hardware RT until both provider and lighting paths pass production gates.

## 17. Stage 13 — Helios real-time ray-traced lighting (1.0 candidate)

**Depends on:** Stage 03 temporal infrastructure, Stage 09 lighting contract, validated geometry queries and Stage 12 hardware provider for hardware mode.

### 17.1 Direct illumination

- [x] Create unified light sampling representation for analytic lights, emissive triangles and environment. Build weighted distributions (alias table or hierarchy) with correct PDFs, updates and stable IDs. Support delta and non-delta distributions consistently. (`SampleableLight`, `AliasTable` in `packages/render/helios/src/ray_query/light_sampling.zig`)
- [x] Implement next-event estimation, visibility queries and multiple importance sampling where appropriate. Begin with a small light set and deterministic reference tests; expand to many lights without biased shortcuts. (`misPowerHeuristic` + `Bvh.traceAnyHit`)
- [x] Evaluate ReSTIR DI only after baseline sampling: reservoir weight normalization, candidate generation, temporal/spatial reuse, visibility validation, disocclusion and moving-light invalidation. Compare quality/time against simpler sampling; retain an off switch and non-reservoir path. (`Reservoir` streaming, finalize & merge in `light_sampling.zig`)

### 17.2 Indirect illumination and reflections

- [ ] Implement one-bounce diffuse and specular queries with physically consistent BRDF/PDF, environment misses and material hit evaluation. Use proper ray offset, roughness-aware sampling and maximum distance; avoid double-counting direct/IBL contributions.
- [ ] Add radiance/irradiance cache populated by traced samples; bounded world-space storage, spatial interpolation, probe visibility, invalidation and update budgets. Validate color bleeding and offscreen transport, thin-wall leaks and moving emissives.
- [ ] Evaluate multi-bounce approximations, Russian roulette for reference paths, and ReSTIR GI only if measured improvement justifies memory and complexity. Keep cache bias and temporal lag documented. Support transparent/refractive paths only after material and visibility correctness.
- [ ] Integrate ray-traced shadows and reflections selectively per light/material/view; combine confidence-weighted results with raster/probe fallbacks. Preserve a hybrid mode in which primary visibility remains rasterized.

### 17.3 Reconstruction and reference renderer

- [x] Output noisy diffuse/specular radiance, hit distance, normals, roughness, velocity and confidence. Implement temporal accumulation, disocclusion, variance estimation and edge-aware spatial filtering (e.g., an A-trous-style prototype). Treat specular motion separately where necessary. (`atrousDenoisePass` in `packages/render/helios/src/reconstruction/path_tracer.zig`)
- [ ] Evaluate external denoisers/reconstruction (NRD or vendor-specific SDKs) only after integration/license/capability review. Keep a vendor-neutral fallback; do not make DLSS mandatory. Control exposure, fireflies, ghosting and history resets.
- [x] Implement a separate progressive reference path-traced view for stationary comparisons and bake validation: explicit samples per pixel, bounce limits, deterministic seeds, convergence reset and physically based sampling. Do not promise real-time performance for the reference mode. Use it to compare hybrid/raster lighting and quantify bias. (`ReferencePathTracer` in `packages/render/helios/src/reconstruction/path_tracer.zig`)
- [ ] Add scalable quality controls (rays/pixel, light candidates, update budget, resolution, bounce policy, denoiser). Integrate with per-view settings and runtime capability fallback.

### Acceptance

Direct and indirect light respond to moving scene geometry and emissives, including offscreen contributors. Compare reference images with numerical and visual tolerances; report noise, ghosting, energy error, GPU cost and acceleration structure memory. Hardware fallback works. ReSTIR and external denoisers remain optional if not proven beneficial. Helios is not declared equivalent to Solari or Lumen merely because it traces rays.

---

## 18. Release gates, budgets, validation and risks

### 18.1 Proposed execution sequence

| Milestone | Primary outcome | Dependency / gate |
|---|---|---|
| Stage 00 | Reliable current Forward+ | Source audit + runtime baseline |
| Stage 01 / Prism 0.1 | Modular renderer with SDL parity | Stage 00 |
| Stage 02 / 0.2 | Persistent render world, queues, multi-view | Stage 01 |
| Stage 03 | Shared depth/velocity/history/pass infrastructure | Stage 02 |
| Stage 04 / 0.3 | Stable and scalable shadows | Stages 02–03 |
| Stage 05 / 0.4 | Physical lighting and materials | Stage 03; shadow contract |
| Stage 06 / 0.5 | AO, probes, reflections and AA | Stages 03–05 |
| Stage 07 / 0.6 | Atmosphere and scalable fog | Shared infrastructure, lighting |
| Stage 08 / 0.7 | Baked GI and probe volumes | Materials, assets, probes |
| Stage 09 / Helios 0.1 | Optional hybrid illumination | Stages 03, 06, 08 |
| Stage 10 / Prism 1.0 candidate | Stable extension and editor contracts | Cross-cutting production gates |
| Stage 11 / Helios 0.2 experiment | Software query feasibility | Stage 09 and measured go/no-go |
| Stage 12 experiment | Native provider + hardware queries | Stage 01 HAL; raster parity gate |
| Stage 13 / Helios 1.0 candidate | Real-time RT + reference path tracing | Stage 12 and shared Helios infrastructure |

Version labels are planning labels, not dates or commitments. Work streams may overlap where dependencies are satisfied. Stage 11 is not a mandatory prerequisite for Stage 12 if software tracing fails feasibility. Do not create one giant feature branch; use small vertical slices, each with a working demo and measurable acceptance.

### 18.2 Proposed quality matrix

| Feature | Low | Medium | High | Ultra / experimental |
|---|---|---|---|---|
| Directional shadows | 2 cascades PCF | 3 cascades PCF | 4 cascades PCSS | Higher budget PCSS / optional RT |
| Local shadows | Few cached tiles | Importance atlas | More tiles + PCSS as supported | Selected RT visibility |
| AO | SSAO / off | GTAO low | GTAO temporal | Optional RT AO |
| Indirect diffuse | Sky / baked | Baked + probes | Helios SSGI + probes | Traced GI where supported |
| Reflections | Sky IBL | Local probes | SSR + probes | Ray queries + fallback |
| Fog | Off / simple | Half-res low | Froxel or half-res high | Higher budget |
| AA | FXAA / none | TAA | TAA / temporal upscale | Higher-quality reconstruction |
| Materials | Standard | Standard + selected lobes | Advanced | Advanced, bounded cost |

Presets are initial policies, not guarantees of frame rate. Provide per-feature overrides; unsupported options downgrade deterministically. A baked lightmap may be memory-heavy even when its runtime computation is inexpensive.

### 18.3 Performance budgets

Proposed initial reference: 1080p, 60 FPS (16.67 ms total frame interval), on a documented midrange target GPU selected after baseline. Aim for GPU work below 13–14 ms to retain presentation/variance headroom; CPU critical path measured separately because CPU/GPU overlap is possible. These numbers are targets, not results.

| GPU category | Initial target ceiling (ms) |
|---|---:|
| Depth/visibility auxiliary work | 1.0 |
| Shadows | 2.5 |
| Opaque/transparent lighting | 4.0 |
| AO/reflections/indirect | 2.5 |
| Volumetrics | 1.0 |
| PostFX/AA/UI | 2.0 |
| Total illustrative GPU work | 13.0 |

Measure p50/p95/p99 frame times, worst-case hitches, GPU memory peak, resident resource count, CPU allocations, upload bytes, draw/dispatch counts and cache hit rates. Report warm-up separately. Use release builds and fixed deterministic camera paths; repeat measurements and compare same scene/settings/driver. Establish regression thresholds from measurement noise, e.g., investigate >5% repeatable CPU/GPU regression in unchanged workload. Do not sum independently overlapping CPU/GPU timings as if sequential.

### 18.4 Reference scenes and required validation

| Scene | Primary correctness/quality checks |
|---|---|
| Material lab | sRGB, BRDF, roughness, metallic, tangent, energy, emissive |
| Shadow lab | Cascade pan, bias, PCSS contact hardening, atlas stress, foliage |
| Cornell box | Indirect lighting, energy, color bleeding, reference comparison |
| Indoor dark room | Light leaks, IES/cookies, contact shadows, volumetric visibility |
| Wet industrial corridor | SSR, local probes, roughness, transparency, fog |
| Forest/outdoor | Cascade stability, alpha mask, atmospheric perspective, TAA |
| Many lights | Cluster bounds, budget overflow, atlas priority, temporal changes |
| Many instances | Extraction, culling, batching, upload, indirect draws |
| Multi-view/UI | Per-view history/exposure, resize, minimization, native-resolution UI |
| Lifecycle stress | Asset reload, entity deletion, world switch, device failure, module rollback |

Use existing repository test conventions and headless GPU testing guidance. Add focused pure Zig tests for math/ownership/queue/cluster invariants, mock backend tests for pass/resource contracts, GPU integration tests when hardware exists, and image comparisons with tolerance. Keep tests proportionate to feature work; functional demos and profiling are first-class deliverables. Use external GPU capture tools such as RenderDoc where compatible. No synthetic test count is a substitute for a rendered scene.

### 18.5 Risks and mitigations

| Risk | Mitigation |
|---|---|
| Rewriting working code under a new name | Vertical migration, compatibility wrappers, parity captures |
| Core polluted by renderer dependencies | Enforce ADR-001 and optional modules |
| HAL overengineering / lowest common denominator | Minimal operations driven by real passes; optional capability extensions |
| Excessive ECS copying | Persistent dense render stores, change tracking, full-resync fallback |
| GPU lifetime bugs | Completion-aware retirement, scoped ownership, failure injection |
| Shader variant explosion | Explicit feature masks, cache budget and warm-up |
| Bandwidth from auxiliary targets | Allocate per feature/view, measure formats and pass cost |
| Temporal ghosting or flicker | Correct motion vectors, history rejection, debug views, spatial fallback |
| Lighting double counting | Explicit transport contract and reference comparisons |
| Software RT too slow | Experimental gate; keep raster/hybrid shipping paths |
| Native backend maintenance | One provider first, feature gates, raster parity before RT |
| Scope creep | Stage acceptance, no mandatory advanced effects, deferred feature list |

### 18.6 Engineering definition of done for each work package

- [ ] Ownership, capability requirements, configuration, error/fallback behavior and dependency direction documented.
- [ ] Implementation integrated with actual Zengy module/service lifecycle and existing scene/asset contracts.
- [ ] Visual demonstration and focused regression coverage added; no new stale generated shader binaries.
- [ ] Performance/memory measured on appropriate workload; no unsupported performance claim.
- [ ] Existing default Forward+ and UI/headless paths verified or limitations explicitly documented.
- [ ] Debug diagnostics exposed; failure cases do not silently corrupt frame or leak resources.
- [ ] Compatibility/migration notes and ADR updates provided when contracts change.

## 19. Immediate implementation brief

Create `feat/prism-renderer-foundation` only after Stage 00 is complete or its remaining defects are explicitly scheduled. First PR: architecture ADR, baseline measurements, provider contract sketch and a small extraction of render target ownership. Second PR: frame/view lifetime, resource retirement and shader manifest. Third PR: move one existing post-processing pass through the new contract. Fourth PR: migrate depth/shadow/PBR in small independently reviewable changes. Fifth PR: persistent render extraction adapter. These are suggested slices; adjust to actual dependency order after inspecting the current code.

Do not begin with a new renderer that cannot render today's demos, a second ECS, a full deferred renderer, a complete Vulkan backend, virtual shadow maps, or a Solari clone. First establish Prism as the reusable home for the renderer Zengy already owns. Helios is a separate optional lighting evolution, beginning with techniques supported by current hardware abstraction and progressing only when evidence justifies new backends.

## 20. Source baseline and implementation references

Repository evidence (pinned to audited commit):

- [Zengy baseline tree](https://github.com/fhorray/zengy/tree/94b7716b848830ee066c1a809f1734b4ea5caa18)
- [Architecture decisions](https://github.com/fhorray/zengy/tree/94b7716b848830ee066c1a809f1734b4ea5caa18/docs/adr)
- [Graphics core](https://github.com/fhorray/zengy/blob/94b7716b848830ee066c1a809f1734b4ea5caa18/packages/graphics/core/src/graphics.zig)
- [SDL GPU PBR backend](https://github.com/fhorray/zengy/blob/94b7716b848830ee066c1a809f1734b4ea5caa18/packages/graphics/sdlgpu/src/pbr_backend.zig)
- [Render-3D package](https://github.com/fhorray/zengy/tree/94b7716b848830ee066c1a809f1734b4ea5caa18/packages/render/3d)

Suggested research references (evaluate current APIs, licenses and portability before adoption; these are algorithm/architecture references, not approved dependencies):

- [Bevy render architecture](https://github.com/bevyengine/bevy/tree/main/crates/bevy_render) and [Solari](https://github.com/bevyengine/bevy/tree/main/crates/bevy_solari)
- [Filament](https://github.com/google/filament) — physical shading and IBL
- [Godot rendering](https://github.com/godotengine/godot/tree/master/servers/rendering) — raster lighting and GI
- [SDL GPU](https://wiki.libsdl.org/SDL3/CategoryGPU) — current provider API limits
- [LTC](https://github.com/selfshadow/ltc_code), [XeGTAO](https://github.com/GameTechDev/XeGTAO), [xatlas](https://github.com/jpcy/xatlas)
- [Vulkan specification](https://registry.khronos.org/vulkan/specs/latest/html/vkspec.html) — optional hardware query provider
- [RTXDI](https://github.com/NVIDIA-RTX/RTXDI), [RTXGI-DDGI](https://github.com/NVIDIAGameWorks/RTXGI-DDGI), [NRD](https://github.com/NVIDIA-RTX/NRD) — sampling, probes and reconstruction research

**Limitations:** The branch HEAD, repository tree, core ADRs, graphics service and package documentation were checked for this roadmap. Detailed rendering findings derive from the preceding static audit of the same commit. No build, GPU capture, shader binary validation or benchmark was performed for this document. Proposed package names, APIs, phase versions, feature order and performance budgets require maintainer review; external projects are suggested references, not freshly audited integrations. Recheck the branch and close Stage 00 against the implementation before using the roadmap as an execution backlog.
