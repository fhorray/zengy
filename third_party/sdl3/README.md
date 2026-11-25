# `sdl3`

Vendored SDL 3.4.20 headers and Windows x64 import library (`SDL3.lib`) used by [`window-sdl3`](../../packages/window/sdl3/README.md) and [`graphics-wgpu`](../../packages/graphics/wgpu/README.md) (surface creation only).

## Notes

- On Windows x64, `zengy add window-sdl3` / `graphics-wgpu` runs the install flow in [`zengy.toml`](zengy.toml) inside *your* project: `zig fetch --save` of the official SDL release (hash verified by Zig) and a `// zengy:begin sdl3` hook block in your `build.zig` that installs `SDL3.dll` into `zig-out/bin`. No binaries are stored in this repository. `game.toml` projects (`zengy run`) need nothing: the Windows release ships `SDL3.dll`.
- On macOS arm64, the GitHub Release bundle (`zengy-<tag>-arm64-macos.tar.gz`) ships `libSDL3.0.dylib` beside `zengy-runtime` (rewired to `@executable_path/libSDL3.0.dylib` and ad-hoc signed), so `game.toml` end users do not need Homebrew SDL3. Native Zig `build.zig` compilation on macOS/Linux still links the system SDL3 library (`brew install sdl3` on macOS, distro dev package on Linux) because upstream SDL3 only ships macOS binaries inside a `.dmg` that `zig fetch` cannot unpack.
- See `LICENSE.txt` and `VERSION.txt` in this directory for licensing and version details.
