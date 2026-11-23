# `render-2d` (`official.render.2d`)

2D sprite extraction and camera projection package providing `engine.render.2d/1`.

## Components & Systems

- `Camera2D` (`x`, `y`, `zoom`, `active`)
- `Sprite` (`width`, `height`, `color`, `texture_id`, `uv_min`, `uv_max`, `layer`)
- `Visibility` (`visible`)
- `extract2DSystem` (`.render_extract`): projects `scene.Transform2D` + `Sprite` through the active `Camera2D` and sorts `Render2DFrame.items` by `(layer, texture_id)` for batched GPU rendering.

## Examples

- `zig build run-visual-2d` ([`examples/visual-2d/main.zig`](../../examples/visual-2d/main.zig))
- `zig build run-visual-playground` ([`examples/visual-playground/main.zig`](../../examples/visual-playground/main.zig))
