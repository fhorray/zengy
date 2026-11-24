# Phased plan: high-visual-risk rendering work

Scope: the audit items that can change the picture in ways unit tests cannot see. Each phase ships behind a
switch, is validated by captured images or frame statistics, and only becomes the default after the
acceptance criteria below pass. Lesson that motivates this plan: several regressions (speckled silhouettes
from FXAA derivatives, washed-out fog, noisy SSAO) were found by eye after compiling cleanly.

Items covered: depth prepass reuse, IBL rebuild cost, volumetric fog temporal stability, shadow scalability
(static cache, PCSS, normal bias, light prioritisation, adaptive atlas).

## Phase 0 - Capture and comparison harness (prerequisite)

Goal: any change can be judged without a human looking at a window.

- **Capture API**: a debug capability on `graphics-sdlgpu` that reads back a named target
  (`final`, `hdr`, `ssao`, `volumetric`, `shadow_atlas`) with `SDL_DownloadFromGPUTexture` and writes PNG
  (tonemapped targets) or raw `f16`/`f32` (HDR targets). Provider-agnostic contract; no backend types leak.
- **Deterministic scene mode**: fixed camera poses, fixed time, no auto exposure adaptation lag (or a warm-up
  of N frames), a seeded variant of any per-frame noise. The spatial IGN noise is already deterministic.
- **Runner**: an example or `zengy` CLI command (`run-cli -Dcli-cmd=capture-scenario`) that renders a scenario
  list and writes captures to a directory. Runs under lavapipe with `SDL_VIDEODRIVER=offscreen`
  (see `docs/headless-gpu-testing.md`).
- **Comparator** (pure Zig, unit tested): per-pixel absolute difference, percent of pixels over a threshold,
  max luminance delta, and a diff image. Goldens are produced only on the software driver, so GPU vendor
  differences never cause failures.
- **Statistics checks** that catch the bug classes seen so far, independent of goldens:
  NaN/Inf scan of the HDR target; edge-speckle metric (isolated pixels brighter than all 8 neighbours by a
  margin, counted per frame); mean/percentile luminance and a haze metric (contrast drop vs. baseline).
- **Scenarios**: `visual-pbr` fixed poses (spheres + rect light, fog on/off, SSAO on/off, HDRI sky, alpha-mask
  foliage, double-sided plane, point and spot in a dark room).

Acceptance: harness runs in CI on lavapipe, produces deterministic output (two runs are byte-identical), and a
deliberately broken shader (e.g. FXAA reading with implicit derivatives) fails the speckle check.

Storage: small PNG goldens under `tests/golden/`, reviewed in PRs; if size becomes a problem, move to Git LFS.

## Phase 1 - Baselines and guard rails

- Capture goldens for the current default configuration and for each switchable feature on and off.
- Record frame-time and pass-time numbers on the software driver only as a trend, never as a pass/fail gate.
- Add the statistics checks to the normal test run so they guard every later phase.

Acceptance: goldens reviewed by a human once; all later phases must keep them within tolerance or update them
explicitly in the same PR with the diff images attached.

## Phase 2 - Depth prepass reuse (low risk)

- Re-introduce loading the prepass depth into the lit pass, behind `RenderQuality.reuse_depth_prepass`
  (default off).
- Risk: silhouette pixels failing the equal-depth test and letting the sky show through.
- Tests: silhouette integrity metric (count of sky-coloured pixels on object boundaries must equal the
  no-reuse run); golden diff between reuse on and off must be below a tiny tolerance.
- Fallback: the switch. Default turns on only after the metric is clean on lavapipe and one real GPU run.

## Phase 3 - IBL rebuild budget (medium risk)

- Move the CPU rebuild to a time-sliced job: process N rows or one mip per frame, double-buffer the
  environment textures, swap when complete. Cache key already includes sun size/disk, rotation and a content hash.
- Risk: visible pop when swapping; stale reflections for a few frames.
- Tests: frame-time spike metric (max frame cost while the sky changes) must drop; after the rebuild settles,
  the capture must equal the synchronous result (golden equality); no leak/ordering errors in the allocator
  check.
- Fallback: `ibl_rebuild_budget = .unlimited` restores the synchronous path.

## Phase 4 - Volumetric fog temporal stability (high risk)

Sub-steps, each with its own switch and goldens:

1. **Blue-noise jitter + per-frame index** (no history): measure noise energy; expect higher frame-to-frame
   variance, so this step ships only together with step 2.
2. **History buffer + reprojection**: previous-frame scatter reprojected with the previous view-projection,
   neighbourhood clamping and depth/distance rejection, exponential blend (alpha around 0.1).
3. **Quality knobs**: half resolution (already available) + temporal as the cheap profile.
- Risks: ghosting on camera motion, lag when lights change, history invalidation on resize or teleport.
- Tests (scripted camera path, N frames): static camera variance must fall below a threshold versus the
  no-history run; moving camera ghosting metric (difference between temporal and ground-truth supersampled
  frame) bounded; first frame after a cut equals the non-temporal result; resize clears history.
- Fallback: `volumetric.temporal = false` (default until all of the above pass).

## Phase 5 - Shadow scalability (high risk, split into independent items)

Order chosen so that each item is verifiable alone:

1. **Normal-offset bias, configurable** (`shadow_normal_bias` already extracted): acne/peter-panning metrics on
   a floor + sphere scene across a bias sweep; pick defaults from the sweep.
2. **Priority selection of shadowed local lights**: deterministic ranking (same score as volumetric
   selection), cap by atlas tiles. Test: with more shadowed lights than tiles, the nearest/brightest keep
   shadows; ordering stable across frames.
3. **Static shadow cache** for directional cascades and local tiles: re-render only when a caster moves or the
   light/cascade frustum changes. Tests: pixel-identical output versus the uncached run in a static scene;
   cache invalidates when a caster is moved (capture differs and then matches the uncached result).
4. **Adaptive atlas resolution** per light by screen-space size: golden comparison against fixed resolution
   with a tolerance and a seam check at tile borders (the cubemap seam bug fixed earlier).
5. **PCSS**: contact-hardening penumbra from a blocker search. Highest cost and visual change: separate
   switch (`pcss_enabled` already in the light), goldens per light size, noise metric on the penumbra.

Each item: switch default off, goldens + metrics added in the same PR, default flipped in a follow-up PR once
reviewed.

## Process rules for every phase

1. Land the capture scenario and its failing/ passing expectation before the feature.
2. Feature behind a switch; default unchanged in the feature PR.
3. PR description lists the captures (before/after/diff) and the measured metrics.
4. Shader changes: recompile SPIR-V with glslang, keep derivative-dependent calls (`texture`, `dFdx`)
   out of non-uniform control flow (use `textureLod`/`texelFetch`).
5. Run `zig build test` in Debug and ReleaseSafe plus the capture suite before merging.

## Status

- **Phase 0 - done.** Harness in `docs/visual-regression-testing.md`. Acceptance verified: the FXAA derivative
  bug (taps read with implicit derivatives inside a branch) was reintroduced on purpose and failed 12 checks
  (image diff in 9 scenarios, speckle count in 5), while `gallery_aa_off` stayed clean. Two runs on the same
  machine differ by at most 1/255. Deviations from the plan: it runs on the real GPU, not lavapipe, so goldens
  are machine-specific; the capture goes through a dedicated API (`requestCapture`/`takeCapture`) and the
  comparator lives in `capture.zig` instead of a CLI command; `zig build capture-check` / `capture-update`
  replace a separate runner.
- **Phase 1 - done.** 14 scenarios and their goldens in `tests/golden/visual-pbr` (8.6 MB, zlib PNG). The
  statistics checks (NaN/Inf, speckle, contrast, mean luminance) run in every capture. Not done: frame/pass
  time trends (see limits in the harness doc), and the capture suite is not part of `zig build test` because it
  needs a GPU and a window.
- **Phase 2 - done, default off.** `PostProcessSettings.quality.reuse_depth_prepass` loads the prepass depth in the
  lit pass and uses less-or-equal opaque pipelines (blend pipeline unchanged). Scenarios `*_reuse_depth` are
  compared with the golden of the matching default scenario: max channel delta 2/255 and no speckle change on
  the real GPU. Acceptance check: forcing the equal-depth pipelines back to less-than fails all four scenarios
  (88-99% of pixels differ), so the check does see a broken silhouette. Not yet run on a second GPU or lavapipe,
  so the default stays off.
- **Phase 3 - done, default `.unlimited`.** `quality.ibl_rebuild_budget = .sliced` turns the rebuild into a job:
  HDRI half-float conversion in 256k-texel slices into a staging texture, then the sky, one prefiltered mip per
  frame, and a single-frame swap of the mips, diffuse SH and sky texture. The first build is always synchronous.
  Independent of the budget, rotation, exposure and sun changes no longer re-upload an unchanged HDRI (it is keyed
  by pointer, sampled hash and size), which was the largest per-change cost. `gallery_dusk_sliced_ibl` matches
  the synchronous golden (max delta 7/255, under 0.0001% of pixels). Not measured: frame-time spike (no
  frame-time capture yet), and the sliced HDRI conversion path is covered by code review only because the demo
  keeps one resident HDRI.
- **Harness fix found while doing Phases 4-5.** The free-camera controller rebuilds the pose orientation from its own
  yaw/pitch every frame, so the Phase 1 scenarios applied the right position but kept the initial view direction.
  `resetFreeCamera` now makes the controller re-read each scenario pose, and the closeup, vol_room and materials
  goldens were regenerated (gallery goldens were unaffected). Earlier numbers for those scenarios described the
  wrong view.
- **Phase 4 - done, default off.** `fog.volumetric.temporal` (+ `temporal_blend`, default 0.1): golden-ratio jitter per
  frame, a resolve pass (`volumetric_resolve.frag`) that reprojects the previous result with the previous
  view-projection, rejects it when the marched distance changed by more than 20%, clips it to the 3x3 mean +- 1.5
  sigma and blends. History is dropped on resize, toggle, fog off and camera cuts (`historyUsable`: more than 4 m or
  45 degrees in one frame). Scenarios: `vol_room_temporal` and `gallery_temporal` must match the single-frame
  goldens and not flicker between consecutive frames; `gallery_temporal_shake` moves the camera and settles for 4
  frames, so ghosts show. Replacing the previous view-projection with the current one (no reprojection) makes the
  shake scenario fail on the max-delta check (32 vs the 16 limit) while the pixel-fraction limit alone does not see it.
  Not covered: first-frame-after-cut equality (only the pure `historyUsable` test) and half-resolution temporal.
- **Phase 5 - done, every item default off** (`quality.shadows`):
  1. `normal_offset`: receiver offset along the normal in the vertex shader, `shadow_normal_bias * 50` texels times
     the slope. Changes 1.4% of the gallery pixels; owns golden `gallery_normal_offset`. No bias sweep with an acne
     metric yet, so the default strength is not tuned.
  2. `prioritize_local_lights`: `shadow_plan.plan` ranks shadowed lights by intensity attenuated by camera distance
     to the range sphere. Unit tested (stable, nearest/brightest keep tiles when over budget).
  3. `static_cache`: cascades and the local atlas re-render only when the caster hash, light matrices or tile rects
     change (`hashCasters`). Verified live: one miss then 92 hits in a static scene, output identical to uncached.
     Granularity is whole passes: any moved caster re-renders the whole map. Unit test: moving a caster or changing
     its material changes the key.
  4. `adaptive_atlas`: tile edge 256/512/1024 from apparent size (point cube faces capped at 512), buddy-style cell
     packing in the 2048 atlas, filter radius scaled with tile size. `vol_room_shadow_adaptive` matches the fixed
     result (max delta 7). The 16 tile-entry limit is unchanged.
  5. `pcss`: blocker search through a second, non-comparison view of the cascade depth, penumbra from the
     receiver-blocker gap, 16 taps; used when the light sets `pcss_enabled`. Changes 2.4% of the gallery pixels;
     owns golden `gallery_pcss`. The light size is a shader constant (0.03).
- **Follow-up pass over the open items.**
  - *Temporal fog:* `gallery_temporal_cut` alternates the camera between two poses 8 m apart so the captured frame
    follows a cut; it must match the single-frame golden. Forcing `historyUsable` to always accept history makes it
    fail (max delta 28 vs limit 16). `gallery_half_res` (own golden) and `gallery_temporal_half` cover half
    resolution with temporal.
  - *Normal offset:* sweep scenarios `bias_sweep_005/020/080/300` (strength = bias x 50 texels). The demo scene shows
    no acne to begin with (high-frequency energy stays within 1% of the plain render at every value), so the sweep only
    bounds peter-panning: mean luma moves at most 0.1% and 0.04% / 1% / 2% of the pixels change at 0.02 / 0.08 / 0.3.
    The default 0.02 stays; 005 and 020 are gated (luma within 2%, high-frequency energy within 15%), 080 and 300 are
    informational. A real acne calibration needs a scene that produces acne, which the 0.055 m floor on the cascade
    depth bias currently prevents.
  - *Shadow cache:* invalidation is now per cascade and per local tile. A key hashes only the casters that survive
    the same frustum cull used for drawing (plus caster-only meshes, which the first version missed), the light matrix
    and the atlas rect. A kept atlas is reused with LOAD and each missed region is reset by a depth-clear triangle.
    `materials_nudge_cache` moves the panel mid warm-up and must match the uncached `materials_nudge`; dropping the
    caster hash makes it fail (3% of pixels, max delta 82).
  - *PCSS:* the light size is `DirectionalLight.pcss_light_size` (default 0.03, unchanged picture).
  - *HDRI slices:* `gallery_hdri_swap_sliced` switches to an identical copy at another address, which forces the sliced
    conversion and upload path, and must match the original sky (max delta 2).
  - *Harness:* `zig build test -Dcapture=true` also runs `capture-check`. Each scenario writes `<name>.timing.txt` with
    the mean and maximum CPU frame delta (trend only; the first frame of a scenario is skipped because it absorbs the
    previous readback). With vsync pacing the maximum is about 17 ms for both the synchronous and the sliced IBL
    rebuild, so this demo does not show a rebuild spike; the HDRI is small and the engine clamps long frames.
  - Still open: acne calibration (above), per-light penumbra size beyond the sun, and goldens that do not depend on the
    GPU (no software Vulkan driver on this machine).
