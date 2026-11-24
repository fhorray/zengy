# Render regression harness

Catches visual regressions that compile cleanly and pass unit tests (speckled silhouettes, washed-out fog,
noisy AO). It renders fixed scenarios of `examples/visual-pbr`, reads the frame back from the GPU, measures it,
and compares it with golden images.

## Running

```sh
zig build capture-check     # render the scenarios, compare with tests/golden/visual-pbr, exit non-zero on regression
zig build capture-update    # render the scenarios and overwrite the goldens (review the diff before committing)
```

Both need a GPU and a window (the demo runs a normal visual loop). Outputs go to `zig-out/capture/`:

| File | Content |
|---|---|
| `<scenario>.png` | Final frame without the 2D overlay (HUD), as displayed |
| `<scenario>.hdr.png` | Scene-linear HDR target, Reinhard preview. NaN pixels are magenta, Inf pixels cyan |
| `<scenario>.stats.txt` | `key=value` metrics (see below) |
| `<scenario>.diff.png` | Written only on failure: red where the frame differs from the golden |

Environment variables read by the demo: `ZENGY_CAPTURE_DIR` (enables capture mode), `ZENGY_CAPTURE_GOLDEN`
(default `tests/golden/visual-pbr`), `ZENGY_CAPTURE_UPDATE=1` (write goldens instead of comparing).

## What is checked

Per scenario, after 90 warm-up frames (auto exposure and the IBL cache settle):

1. **Image diff**: a pixel differs when any channel changes by more than 8/255. More than 0.2% differing pixels fails.
2. **NaN / Inf** in the HDR target: any fails.
3. **Speckle count** (isolated pixels brighter than all 8 neighbours by 40 luma): fails above
   `max(1.5 x golden, golden + 50)`. This is the metric for dotted silhouettes and leaked NaN.
4. **Contrast spread** (p95 - p5 luma): fails below 85% of the golden (washed-out frame).
5. **Mean HDR luminance**: fails when more than 25% away from the golden.

Scenarios (`SCENARIOS` in `examples/visual-pbr/main.zig`): gallery, close-up and dark volumetric room with
fog / SSAO / shadows / bloom / FXAA on and off, a dusk sky, and a materials pose with an alpha-masked
double-sided panel and an alpha-blended pane.

Scenarios with `golden_of` own no golden: they must match another scenario within the normal tolerances. They guard
switches that may not change the picture: `*_reuse_depth` (`quality.reuse_depth_prepass`) and
`gallery_dusk_sliced_ibl` (`quality.ibl_rebuild_budget = .sliced`).

## Reading a failure

Open `<scenario>.diff.png` next to `<scenario>.png`, then the matching `.hdr.png` to tell a post-process problem
(the HDR preview is clean) from a scene problem (the HDR preview shows it too). Toggling the feature's scenario
(`*_fog_off`, `*_ssao_off`, `gallery_aa_off`, ...) isolates the pass: a clean `_off` scenario names the culprit.

## Limits to keep in mind

- **Goldens are tied to the GPU and driver that produced them.** Regenerate them on the machine that runs the
  check; do not compare across vendors. A software Vulkan driver (see `docs/headless-gpu-testing.md`) would give
  a vendor-independent baseline but is not wired up yet.
- The capture size is the window pixel size (1280x720 by default); a different DPI scale fails the size check
  instead of being silently rescaled.
- Auto exposure leaves a delta of about 1/255 between identical runs, hence the per-pixel threshold.
- Frame and pass times are not gated: frame pacing caps the frame time and GPU pass timing needs timestamp queries.

## Code map

- `packages/graphics/sdlgpu/src/capture.zig`: PNG codec (8-bit RGB, zlib), HDR statistics, speckle and contrast
  metrics, image comparison. Pure Zig, unit tested without a GPU.
- `graphics_sdlgpu.requestCapture` / `takeCapture`: read back `final`, `hdr`, or `ssao`.
  `final` renders the post-process pass a second time into an offscreen texture, so the capture never contains
  the HUD and never reads the swapchain.
- `examples/visual-pbr/main.zig`: the scenario runner (`CaptureRunner`).
