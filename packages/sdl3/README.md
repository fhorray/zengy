# `sdl3`

Vendored SDL 3.4.20 headers and Windows x64 import library (`SDL3.lib`) used by [`window-sdl3`](../window-sdl3/README.md) and [`graphics-sdlgpu`](../graphics-sdlgpu/README.md).

## Notes

- On Windows x64, `zigeng add window-sdl3` / `graphics-sdlgpu` runs the install flow in [`zigeng.toml`](zigeng.toml) inside *your* project: `zig fetch --save` of the official SDL release (hash verified by Zig) and a `// zigeng:begin sdl3` hook block in your `build.zig` that installs `SDL3.dll` into `zig-out/bin`. No binaries are stored in this repository. `game.toml` projects (`zigeng run`) need nothing: `zigeng-runtime` ships `SDL3.dll`.
- On Linux/macOS, native visual builds link against the system SDL3 library.
- See `LICENSE.txt` and `VERSION.txt` in this directory for licensing and version details.
