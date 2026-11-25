# Zengy graphics migration: wgpu-native as the only graphics foundation

Status: **done on Windows x64 / Vulkan; unverified elsewhere** (see [Verification](#verification) and [Known limits](#known-limits)).

`zengy` renders through one graphics foundation, wgpu-native (pinned `v27.0.4.1`). SDL3 only provides the window,
input and the native surface. SDL_GPU, SPIR-V and GLSL are gone from the build; shaders are checked-in WGSL.

## Layout

```
packages/graphics/core    neutral contract: GpuDevice vtable, handles, descriptors, CommandRecorder,
                          FrameRenderer list, TextureStore, capture types (no backend types)
packages/graphics/wgpu    provider: wgpu-native bridge (C), GpuDevice implementation, surface/swapchain, capture
packages/render/2d        draw-command renderer (tessellation, batching, text/icons, clipping)
packages/render/3d        unlit meshes + gizmos, PBR Forward+ renderer (src/gpu), WGSL in src/gpu/shaders
packages/render/prism     orchestration/capabilities (the PBR renderer executes the passes)
packages/render/helios    CPU BVH + solver; GPU probe update runs in render/3d (dynamic_gi_cs.wgsl)
```

Renderers never talk to wgpu: each registers a `FrameRenderer` with `GraphicsDeviceService`, records neutral
commands into a shared `CommandRecorder`, and the provider submits once per frame. Replacing the provider does not
touch a renderer. There is no custom Vulkan/DX12/Metal backend and none is planned.

## Install and run

```powershell
py -3 tools/wgpu/install_wgpu.py --output .deps/wgpu-native      # pinned SDK, SHA-256 verified; no Vulkan SDK needed
zig build                       # headless parts always build; visual targets need the SDK above
zig build build-wgpu-examples   # every example + runtime DLLs
zig build run-visual-pbr        # or run-visual-prism, run-visual-inspector, ...
zig build test                  # headless suite (no GPU)
zig build test-wgpu-gpu         # real-adapter tests (skips cleanly without an adapter)
```

`-Dwgpu-root=<path>` points at another SDK copy. A plain `zig build` without the SDK still succeeds: the visual
executables are simply not installed, and `run-*` steps fail with one clear message.

## What runs on wgpu

| Area | Status |
|---|---|
| 2D/UI (`visual-gpu`, `-2d`, `-ui`, `-plume`, `-playground`, `-python`) | ported, real-GPU tested |
| Unlit meshes, gizmos (`visual-3d`, `-camera`, `-gamepad`, `-audio`, `-gizmos`) | ported, real-GPU tested |
| PBR Forward+ (`visual-pbr`, `visual-inspector`): shadows (cascades + local atlas), clusters, SSAO/contact shadows, sky/HDRI, IBL, LTC area lights, probes, auto exposure, bloom, tonemapping | ported, real-GPU tested |
| Volumetric fog (ray march or froxels, temporal resolve, composite) | ported, real-GPU tested |
| Screen-space transport (Hi-Z, SSR/SSGI) | ported, real-GPU tested; needs 40 colour bytes per sample, else falls back to IBL |
| Helios GPU GI (BVH snapshot, probe history, reservoirs) | ported; verified with `visual-prism` (`ZENGY_GPU_GI=1`) |
| `hdr` / `ssao` / `final` captures, `zengy-runtime` | ported |
| GPU pass timing (timestamp queries) feeding `dev_tools.FrameProfilerService` | ported, async (2-3 frames late) |

Persistent resources only: uniform ring + bind-group cache, growing draw buffers, retained targets; no steady-state
allocation in the render path. Pipelines are created once per variant.

## Shaders

WGSL is the source of truth (`packages/render/3d/src/gpu/shaders/*.wgsl`, plus hand-written WGSL next to each
renderer). The PBR set was produced from the former GLSL with `tools/wgpu/port_shaders.py` (Naga 27.0.0 + a sampler
splitter + bind-group remap) and then **validated by creating the pipelines on a real device**, which catches
problems Naga's CLI does not (for example `subgroupBarrier` needing an optional feature, empty bind-group layouts
that still need an empty group). The auto-exposure histogram was ported by hand. The GLSL sources were deleted with
`packages/graphics/sdlgpu`; the port script documents the process and reads them from the commit before the removal
(`git show eeaf386:packages/graphics/sdlgpu/src/shaders`).

Layout checks: every uniform block has a `comptime` size assertion against its extern struct; bindings are listed in
`shaders/bindings.json`.

## Verification

Hardware used: AMD Radeon(TM) Graphics (integrated), Vulkan, Windows 11, wgpu-native 27.0.4.1.

- `zig build test`: 110/110 steps (headless). `zig build test -Doptimize=ReleaseSafe` and a Windows cross build are
  part of the gate.
- `zig build test-wgpu-gpu`: 37 real-GPU tests (device capabilities, buffers/textures/readback, render/compute
  pipelines, depth, timestamp queries, Render2D pixels, unlit/gizmo pixels, PBR lit scene, auto exposure, volumetric
  fog in three modes, screen transport, GPU timing, windowed swapchain).
- Regression harness (`examples/visual-pbr`, `ZENGY_CAPTURE_DIR`): the 49 scenarios were rendered by the wgpu stack
  and compared with the goldens recorded by the **SDL_GPU renderer** on the same machine. 42 of 49 scenarios are within
  the harness tolerances (most differ in under 0.01 % of pixels, max channel delta about 11). The seven failures are
  all in the `vol_room_*` family (0.24-0.49 % of pixels differ against a 0.2 % limit; the temporal scenario also has a
  max channel delta of 24 against 16). The amplified difference image shows one-pixel lines on wall and floor edges only
  (rasterisation/depth-edge differences), not lighting differences. The goldens in `tests/golden/visual-pbr` are
  therefore regenerated on wgpu in the same change that removes SDL_GPU, since SDL_GPU can no longer produce them.
- Real-GPU image checks read back the application's own offscreen/swapchain textures; nothing captures the desktop.

## Known limits

- **Hardware ray tracing is not available.** wgpu-native 27 exposes the `RayQuery` feature but no BLAS/TLAS API, so
  `Capabilities.acceleration_structures` is false and Helios keeps its CPU BVH + GPU compute GI path. Nothing
  advertises hardware RT.
- **Platforms:** only Windows x64 (Vulkan) was run. Linux (X11/Wayland) and macOS (Metal) surface code and the CI
  smoke job (Xvfb + lavapipe) are written but unverified. Web needs a separate host and is not done.
- One native window per provider instance.
- GPU GI converges over several frames (two probes per frame by default); early frames show blocky probe cells.
- Pre-existing and preserved: rounded-corner gradients on non-affine paths use centre-fan tessellation (colour bleed).
- Prism's pass hooks are no-ops by design: the PBR renderer executes its own passes and Prism acts as the
  capability/orchestration registry with truthful capabilities (hybrid lighting, compute; no RT, no TAA).
- `include/engine_extension.h` and the C ABI are unchanged.
