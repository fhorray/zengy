# ADR-009: Prism & Helios Rendering Architecture

- **Status:** Accepted (Stage 01 Foundation)
- **Date:** 2026-11-24
- **Related:** ADR-001, ADR-002, ADR-003, ADR-005, ADR-006, ADR-007, ADR-008
- **Note:** Renumbered from a duplicate ADR-008 collision with application/package boundaries.

## Context

`zengy` has a working Forward+ PBR renderer in the former `packages/graphics/sdlgpu/src/pbr_backend.zig` (now `packages/render/3d/src/gpu/pbr/`) paired with scene extraction in `packages/render/3d/src/render_3d.zig`. As rendering features expand (multi-view rendering, temporal histories, advanced shadows, reflections, atmosphere, and optional hybrid/ray-traced lighting), monolithic backend policy in `pbr_backend.zig` becomes harder to validate headlessly, reuse across views, or extend from third-party packages.

## Decision

1. **Two optional rendering layers, zero core coupling (ADR-001):**
   - **Prism** (`packages/render/prism/`, module `official.render.prism`, capability `engine.render.prism/1`): backend-agnostic rendering orchestration, generational `RenderViewId` management, declarative `PassGraph` compilation, `ShaderManifest` / `PipelineCacheKey` contracts, and completion-aware `RetirementQueue`.
   - **Helios** (future `packages/render/helios/`, capability `engine.render.helios/1`): optional advanced lighting subsystem that consumes Prism contracts rather than owning a competing renderer. Forward+ rasterization never requires Helios.
2. **Preserve existing public contracts:**
   - `engine.graphics.device/1` (`packages/graphics/core`) and `engine.render.3d/1` (`packages/render/3d`) remain canonical and backward-compatible.
   - `UiTree` and `graphics.DrawCommand` remain the shared UI IR; Prism does not depend on Plume or any UI skin.
   - Canonical scene components (`Transform3D`, `PbrMaterial`, `DirectionalLight`, `PostProcessSettings`, `FogSettings`) are reused rather than duplicated under new names.
3. **Incremental vertical migration:**
   - Stage 01 establishes Prism's core contracts (`ViewRegistry`, `PassGraph`, `ShaderManifest`, `PipelineCacheKey`, `RetirementQueue`, and headless `RecordingBackend`) without breaking any existing example or test.
   - Subsequent stages migrate pass ownership from `pbr_backend.zig` vertically, one pass at a time, validated by the render regression harness.

## Consequences

- `src/core/` remains 100% GPU-free and headless-first.
- Pass ordering, read-before-write errors, cyclic dependencies, and view history invalidation can be verified deterministically in headless unit tests via `RecordingBackend`.
- Third-party packages can inspect or extend render passes through versioned capabilities without patching core or graphics provider internals.
