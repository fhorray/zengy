# `testing` (`official.testing`)

Optional deterministic testing and offscreen visual capture package (`engine.testing.capture/1`).

## Features

- **Software framebuffer**: Deterministic RGBA8 rasterizer over `graphics.DrawCommand` lists (`clear`, `rect`) without requiring an OS window or GPU.
- **Pixel & hash assertions**: `readPixel(x, y)` and `computeHash()` for golden-frame regression checks.
- **PPM export**: `encodePpm()` outputs standard P6 PPM images for visual inspection.
- **Scenario driver**: Deterministic TOML-driven test execution used by `zigeng test-scenario`.
