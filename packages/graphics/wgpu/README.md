# graphics-wgpu (`official.graphics.wgpu`)

The engine's graphics provider, built on [wgpu-native](https://github.com/gfx-rs/wgpu-native) (pinned `v27.0.4.1`).
It implements the neutral `graphics.gpu.GpuDevice` contract and the `engine.graphics.device/1` capability; SDL3 only
supplies the window and the native surface.

- `src/bridge.c` / `bridge.h`: the thin C layer that talks to wgpu-native (instance, adapter, device, surface,
  swapchain, validation error capture). Real adapter features and limits are read here; nothing is hard-coded.
- `src/gpu_device.zig`: `GpuDevice` implementation (generational handles, buffers, textures, samplers, pipelines,
  bind groups, command replay, async readback, timestamp queries).
- `src/graphics_wgpu.zig`: the engine module: surface lifecycle, per-frame renderer list, `requestCapture` /
  `takeCapture`, `GpuConfig`, `driverName`.
- `tests/`: real-adapter tests (`zig build test-wgpu-gpu`); they skip cleanly when no adapter exists.

Install the SDK with `python tools/wgpu/install_wgpu.py --output .deps/wgpu-native` (no Vulkan SDK needed). See
[docs/migration/wgpu.md](../../../docs/migration/wgpu.md) for the architecture, verification and known limits.
