# Zengy wgpu migration — foundation candidate

Base inspected: `fhorray/zengy`, `feat/prism-helios`, `741d8a3649c29e1449a66bad3f7f91c28bb0e1da`. The previous Production Overlay was not present on that remote HEAD. Do not reset or overwrite local lighting work. The two patched base files must match the recorded Git blobs.

## Delivered

- A new `official.graphics.wgpu` provider using the existing `GraphicsDeviceService`, not an SDL_GPU emulation layer. SDL3 remains responsible for window and input. A small C ABI bridge calls wgpu-native directly, while the module and frame construction remain Zig. One batched color pipeline, persistent vertex buffer with a 64 MiB cap, logical-pixel clipping, resize/minimize recovery, explicit failure on unported commands. One native window only. The existing default build and all SDL demos remain unchanged. `compute`, `storage_buffers`, `timestamp_queries` and depth texture sampling are deliberately not advertised through the Graphics service until its resource contracts are implemented.
- The `visual-wgpu` example, optional build switch, SDL window Metal opt-in (macOS), pinned wgpu-native installer with official release SHA-256s, GLSL-to-WGSL candidate converter and a dependency inventory scanner. No Vulkan SDK required for the new smoke demo. WGSL translation does not guarantee visual or host-layout parity; Naga may reject unsupported shaders.
- Platform targets: native Windows x64 first; Linux X11/Wayland and macOS Metal surface code is provided but not tested. Existing Zengy SDL packaging may itself need porting on non-Windows targets. SDL offscreen windows have no native surface and are not handled by this provider.

## Run (Windows x64, existing Zig/SDL dependencies)

```powershell
py -3 tools/wgpu/install_wgpu.py --output .deps/wgpu-native
$root = (Resolve-Path .deps/wgpu-native).Path
$env:Path = "$root\lib;$(Resolve-Path packages/sdl3/lib/x64);$env:Path"
zig build run-visual-wgpu "-Dwgpu-root=$root"
```

The wgpu-native and SDL dynamic libraries must be reachable by the OS loader. If the target ABI is MSVC, select `--target windows-x86_64-msvc`; the default is GNU x64 to match Zig's usual native Windows target. For Linux/macOS use appropriate native SDL3 headers/libs and configure the loader path (`LD_LIBRARY_PATH`/`DYLD_LIBRARY_PATH` or install/rpath). A real graphical desktop is needed for the example.

```powershell
cargo install naga-cli --version 27.0.3 --locked
py -3 tools/wgpu/convert_shaders.py --repo . --output .deps/wgsl-candidates
py -3 tools/wgpu/scan_dependencies.py --repo . --output .deps/wgpu-inventory.json
```

Candidate conversion may return nonzero and list per-shader errors. No generated candidate is wired into Prism automatically. Check layouts and shader resource reflection. Existing GLSL assets are not removed.

## Actual remaining code migration (not implemented in this overlay)

| Existing owner | Change required | Completion criterion |
|---|---|---|
| `packages/graphics/core/src/graphics.zig` | Add typed texture/buffer/sampler and render/compute pass contracts, stable handles, distinct frame token and explicit skipped status. Existing vtable only abstracts surface/present + 2D commands. | One API for renderer, UI and capture; no backend-specific handles exposed. |
| `packages/graphics/sdlgpu/src/gpu_resources.zig` | Extract reusable generational pools and neutral descriptions. Implement wgpu buffer/texture views and ownership, queue writes, device-loss handling, row alignment. | Resource lifecycle and stale-handle tests; no synchronous upload waits in steady state. |
| `packages/graphics/sdlgpu/src/graphics_sdlgpu.zig` | Port textured quad batching, text/icon atlases, rounded and gradient rectangles, clipping, glyphs, mesh creation/destruction, gizmos, offscreen targets, readback. Move CPU tessellation to shared code rather than duplicate. | Existing visual-gpu, visual-2d, visual-ui, visual-plume, visual-gizmos and visual-3d pass. |
| `packages/graphics/sdlgpu/src/pbr_backend.zig` | Separate pass orchestration from SDL calls. Port shadow atlas, depth prepass, sky, HDR target, PBR, IBL jobs, volumetrics, AO, exposure histogram/adapt, bloom and tonemap. | Existing capture-check and visual-prism pass against SDL reference on same GPU. |
| `packages/render/3d/src/pbr.zig`, `render_3d.zig` | Preserve extracted frame contracts; replace SDL-specific PBR submission with shared GPU handles and resource layout. | Same ECS-facing components and materials; identical scene behavior. |
| `packages/render/prism/src` | Wire pass graph, resource manifest, temporal histories, shader catalog and per-view data to actual wgpu passes. | Resource lifetimes and resize/device loss tests; no duplicate renderer. |
| `packages/render/helios/src` | Keep CPU BVH and solver. Port GPU probe updates if present locally, and storage buffers, counters and compute dispatch. Hardware RT remains capability-gated pending actual C API BLAS/TLAS support or small Rust bridge. | CPU/GPU probe parity and bounded ray budget. |
| `packages/graphics/sdlgpu/src/shaders/*` | Translate GLSL candidates to WGSL; split combined textures/samplers, preserve explicit group/binding, verify std140/std430 vs WGSL layouts, depth coordinates, texture comparison, atomics, derivatives and HDR formats. | Naga validation, shader reflection, GPU image comparisons. |
| `tools/runtime/main.zig`, all `examples/visual-*`, `build.zig`, plugin manifests/registry | Replace direct SDL GPU imports and module registration only after parity. Use local inventory scanner to find all callers including changes not yet on remote. | Full `zig build test` and native demo suite without SDL_GPU. |
| `packages/testing` and capture tooling | Port copy-to-buffer, padded row handling, asynchronous map/unmap and fences; compare with baseline. | Golden captures on actual adapters; no blocking frame readback. |
| CI and packaging | Add pinned dependency and native build matrix, real surface or headless device tests, adapter limits, WGSL shader validation. | Windows, Linux, macOS pass; remove SDL_GPU only after parity. |
| Web target | Separate platform host/surface integration for browser, JS WebGPU or WASM bindings; reuse WGSL and renderer logic. | Browser build and gameplay. Native wgpu binary cannot be linked into browser WASM unchanged. |

## Performance and correctness gates

Use shared pipeline and bind-group caches keyed by formats/layout/variant; retain buffers and grow geometrically; upload uniforms through aligned per-frame ring storage; avoid reading GPU resources back in the same frame; separate sampled and attachment resources; use queue order and explicit ownership rather than manual backend-specific barriers; check adapter feature/limit support; benchmark CPU encode, actual GPU timestamps and full frame latency. Keep one wgpu path at the end, use SDL GPU temporarily as an oracle only. Do not delete working code before passing parity.

## Validation status

Seven CPU clipping cases compiled and executed with GCC/UBSan. Six Python sampler-split tests passed. Actual Zig compilation, native wgpu linking, Naga conversion, SDL surface tests and GPU benchmarks not run in the generation environment (no Zig, Cargo, wgpu native SDK or repo checkout). C API symbols inspected against pinned upstream header; not a compiler check. This is a foundation candidate, NOT a complete migration. No remote changes.
