# `sdl3`

Vendored SDL 3.4.20 headers and Windows x64 import library (`SDL3.lib`) used by [`window-sdl3`](../window-sdl3/README.md) and [`graphics-sdlgpu`](../graphics-sdlgpu/README.md).

## Notes

- For Windows x64 visual builds, place `SDL3.dll` in `packages/sdl3/bin/x64/SDL3.dll` (or next to the executable in `zig-out/bin/`).
- On Linux/macOS, native visual builds link against the system SDL3 library.
- See `LICENSE.txt` and `VERSION.txt` in this directory for licensing and version details.
