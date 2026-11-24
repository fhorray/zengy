# `window-sdl3` (`official.window.sdl3`)

Native window and input provider backed by **SDL 3.4.20** (`official.window.sdl3`), implementing `engine.window/1` and `engine.input/1`.

## Features

- **Drop-in visual counterpart**: Uses the exact same `WindowService` and `InputService` contracts as [`window`](../core/README.md).
- **OS event loop**: `pollEvents` drains SDL's event queue once per frame; `runVisualLoop(&app)` drives poll -> tick -> frame pacing until window close.
- **Core isolation**: SDL is linked only by this package (and [`graphics-sdlgpu`](../../graphics/sdlgpu/README.md)); `src/core/` never imports SDL.

> Note: Only one of `window` and `window-sdl3` may be registered in an `App` (both are exclusive providers).
