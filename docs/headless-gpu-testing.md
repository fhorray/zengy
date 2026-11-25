# Running the visual demos without a display or GPU

Useful in containers and CI to smoke-test `graphics-wgpu`, `window-sdl3`, and the visual examples.

1. Install SDL3 3.4.x (Ubuntu 24.04 has no `libsdl3-dev`): build `libsdl-org/SDL` at tag `release-3.4.20`
   with CMake and install it to `/usr/local` (needs the X11/Wayland/ALSA/Vulkan `-dev` packages).
2. Build natively: `zig build` (links SDL3 from the default search paths). `zig build` does not use pkg-config; for a private install prefix pass `--search-prefix /opt/sdl3` and set `LD_LIBRARY_PATH=/opt/sdl3/lib` when running.
3. Run with a software Vulkan driver (lavapipe/llvmpipe) and SDL's offscreen video driver:

```sh
export VK_ICD_FILENAMES=/path/to/lvp_icd.json   # Mesa lavapipe ICD
export SDL_VIDEODRIVER=offscreen
timeout 8 ./zig-out/bin/visual-plume             # exit 124 = ran until the timeout
```

`timeout` sends SIGTERM, which SDL turns into a quit event, so the demo shuts down gracefully and
its `DebugAllocator` reports leaks. A clean run prints nothing.
