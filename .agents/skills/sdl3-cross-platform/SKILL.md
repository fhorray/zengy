---
name: sdl3-cross-platform
description: >-
  Documents how SDL3 is provisioned, linked, and packaged across Windows, macOS,
  and Linux in zengy. Use when modifying SDL3 dependencies, build.zig,
  third_party/sdl3/zengy.toml, visual targets, or release packaging.
---

# SDL3 Cross-Platform Packaging & Linking

`zengy` never stores prebuilt SDL3 binaries in git. Follow the platform rules below so end users and contributors do not hit missing-library errors.

## Platform Matrix

1. **Windows x64 (`windows-x86_64`)**
   - `build.zig.zon` pins `sdl3_win64` (`SDL3-3.4.20-win32-x64.zip`).
   - `build.zig` installs `SDL3.dll` into `zig-out/bin/` when building for `windows` + `x86_64`.
   - `third_party/sdl3/zengy.toml` runs `zig fetch --save=sdl3_win64` and installs `SDL3.dll` via a `// zengy:begin sdl3` block in user `build.zig` files.
   - `.github/workflows/release.yml` (`build-windows`) bundles `zengy.exe`, `zengy-runtime.exe`, and `SDL3.dll`.

2. **macOS arm64 (`macos-aarch64`)**
   - Upstream `libsdl-org/SDL` releases macOS binaries only as `.dmg` (`SDL3-3.4.20.dmg`), which `zig fetch` cannot extract. Therefore `third_party/sdl3/zengy.toml` does not have a `macos-aarch64` `[[dependency]]` entry.
   - **Release bundle (`build-macos` in `.github/workflows/release.yml`)**: builds with `brew install sdl3`, copies `libSDL3.0.dylib` beside `zengy-runtime`, rewrites its install path to `@executable_path/libSDL3.0.dylib` via `install_name_tool`, and **must** re-sign both binaries with `codesign --force --sign -` (Apple Silicon kills Mach-O binaries with invalidated ad-hoc signatures). End users using the macOS release archive do **not** need Homebrew SDL3.
   - **Native `zig build` of visual targets on macOS**: requires system SDL3 (`brew install sdl3`) for linking `zengy-runtime` and `examples/visual-*`.

3. **Linux x64 (`linux-x86_64`)**
   - `build-linux` in `.github/workflows/release.yml` ships only the `zengy` CLI (`zig build cli`), which does not link SDL3. Visual builds on Linux link the distro's system SDL3 package.

## Rules & Pitfalls

- **Do not use `macos-14` in GitHub Actions**: GitHub retired `macos-14` on November 2, 2026 (`The configuration 'macos-14-arm64-us-default' is not supported`). Always use `macos-15` (or newer supported macOS arm64 runners).
- **Never skip `codesign --force --sign -` after `install_name_tool`** in macOS packaging scripts.
- **Verify `otool -L`** on staged macOS binaries to confirm no `/opt/homebrew/...` dylib reference remains on `zengy-runtime`.
