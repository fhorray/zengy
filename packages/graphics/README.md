# `graphics` (`official.graphics`)

Optional agnostic graphics device contract (`engine.graphics.device/1`) depending on `engine.window/1`.

## Features

- **Render target lifecycle**: Manages generational `RenderTargetHandle` surfaces bound to window handles.
- **Command recording**: Records `DrawCommand` lists (`clear`, `rect`, `text`) per frame and tracks `present()`.
- **Render stage control**: Enables `scheduler.render_extract_enabled` only while this module is active.
- **Headless & swap-ready**: Runs headless out of the box or delegates to a concrete backend such as [`graphics-sdlgpu`](../graphics-sdlgpu/README.md).
