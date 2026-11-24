# `graphics-sdlgpu` (`official.graphics.sdlgpu`)

Native GPU backend for `engine.graphics.device/1` powered by **SDL3 GPU** (Vulkan / SPIR-V).

## Responsibilities

- Implements `graphics.BackendVTable` on `GraphicsDeviceService`, keeping headless consumers (`ui_core`, `ui_immediate`, `render_3d`) compatible without code changes.
- **2D / UI Pipelines**: `pos_color` (NDC triangles) and `textured` (alpha-blended quads, rotation, `SDL_SetGPUScissor` clipping, DPI scaling, and built-in 1x1 white + `128x48` bitmap font atlas).
- **3D Pipeline (Phase E)**: `mesh_unlit` with automatic `D24_UNORM` / `D16_UNORM` depth texture management, back-face culling, `createMesh3D`, `destroyMesh3D`, and `queueMeshDraw`.
- **Diagnostics**: Records GPU driver, swapchain/depth formats, pipeline creation, and SDL errors into `app.diagnostics`.
- **Minimized Window Safety**: Submits an empty command buffer when the swapchain texture is `null` or `0x0`.
