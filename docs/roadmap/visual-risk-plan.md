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

