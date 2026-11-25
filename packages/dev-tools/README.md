# `official.dev_tools` (`packages/dev-tools`)

Per-pass frame profiler and developer telemetry for `zengy` (`engine.dev_tools.profiler/1`).

## Features

- `FrameProfilerService`: Records per-pass timings (`Shadow`, `SSAO`, `Volumetric`, `Forward+`, `Bloom`, `PostFX`, `Gizmos`, `UI`) with smoothed EMA durations, 120-frame rolling history, and FPS estimation.
- Backend-agnostic: Works headlessly in tests and integrates automatically with `official.render.3d.gpu` PBR passes (GPU timestamp queries).

## Usage

```zig
try app.registerModule(dev_tools.module());
```

Read live timings in any system or inspector:

```zig
if (ctx.resources.get(dev_tools.FrameProfilerService)) |prof| {
    for (prof.latestPasses()) |pass| {
        std.debug.print("{s}: {d:.2} ms\n", .{ pass.nameSlice(), pass.ema_ms });
    }
}
```
