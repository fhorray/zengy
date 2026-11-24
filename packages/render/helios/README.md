# `official.render.helios` (`packages/render/helios`)

Optional hybrid indirect illumination subsystem for `zengy` (`engine.render.helios/1`, Stage 09 — consumes `engine.render.prism/1`).

## Features

- **`hybrid/lighting_contract.zig`:** `HeliosQualityTier`, `HeliosDebugMode`, `HeliosViewSettings`, `IndirectLightingOutput`, and energy-conserving `combineIndirectDiffuse` (confidence-weighted replacement with zero double-counting between SSGI, probes, and sky IBL).
- **`hybrid/ssgi.zig`:** Bounded Hi-Z screen-space traversal (`traceHiZScreenSpace`) consuming Prism's `HiZPyramid`, plus `cosineHemisphereSample`.
- **`hybrid/radiance_cache.zig`:** Bounded spatial hash-grid `WorldRadianceCache` with age-based eviction, confidence weighting, and occupancy telemetry.
- **`ray_query/bvh.zig`:** Stage 11 experimental geometry query contract (`Ray`, `RayHit`, `QueryStats`), flat GPU-packable `BvhNode` / `Bvh`, and bounded iterative `traceClosest` / `traceAnyHit` with Moller-Trumbore triangle intersection.
- **`ray_query/hw_rt.zig`:** Stage 12 versioned hardware RT acceleration structure contract (`RtAccelerationVTable`, `BlasHandle`, `TlasHandle`, `BlasCache`) with explicit `UNSUPPORTED_RT_VTABLE` fallback for portable SDL GPU.
- **`ray_query/light_sampling.zig`:** Stage 13.1 Vose `AliasTable` (O(1) importance light sampling), `misPowerHeuristic`, and ReSTIR DI `Reservoir` streaming/merging.
- **`reconstruction/path_tracer.zig`:** Stage 13.2/13.3 deterministic CPU progressive `ReferencePathTracer` and edge-stopping `atrousDenoisePass` wavelet spatial denoiser.
- **Strictly optional:** Disabling or omitting `official.render.helios` leaves Prism Forward+ rasterization untouched.
