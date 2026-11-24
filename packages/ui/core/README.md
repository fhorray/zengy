# `ui-core` (`official.ui.core`)

Optional syntax-agnostic retained UI core (`engine.ui.tree/1`).

## Features

- **Retained `UiTree` IR**: Decoupled from any markup parser or scripting runtime (`Frontend -> UiTree -> layoutTree() -> paint() -> GraphicsDeviceService`).
- **Layout & interaction**: Flex-like `column`/`row` layout, spatial `hitTest()`, focus tracking, text input, and `ui.action` event emission.
- **Backend-neutral output**: Emits standard `graphics.DrawCommand` lists.
