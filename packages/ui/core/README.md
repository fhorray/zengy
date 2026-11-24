# `ui-core` (`official.ui.core`)

Universal, syntax-agnostic retained UI core (`engine.ui.tree/1`) serving as the **shared foundation for both in-game UIs and editor/tooling UIs** in `zengy`.

See [ADR-0001: Layered UI Architecture](../../../docs/adr/0001-layered-ui-architecture.md) for the full design rationale.

## How the UI Stack Fits Together

- **`ui-core` (this package)**: Retained `UiTree` IR, layout, clipping, scroll, focus, and `DrawCommand` emission. Knows nothing about HTML, markup, or editor themes.
- **[`ui-widgets`](../widgets/README.md)**: Visual-agnostic interactive behaviors (`WidgetManager`, `TextEditState`, `UndoHistory`, popovers, scrollbars) attached to `UiTree` nodes.
- **[`ui-plume`](../plume/README.md)**: Opinionated dark-mode widget kit for **editors, inspectors, and tooling**.
- **[`ui-markup`](../markup/README.md)** (or any custom/community frontend): Declarative, stylable frontend for **in-game UIs** (HUDs, menus, inventories) compiling into `UiTree`.

## Features

- **Retained `UiTree` IR**: Decoupled from any markup parser or scripting runtime (`Frontend -> UiTree -> layoutTree() -> paint() -> GraphicsDeviceService`).
- **Layout & Interaction**: Flex-like `column`/`row` layout (`grow`, `percent`, `absolute`), overflow clipping & scrollbars, spatial `hitTest()`, `Tab` focus tracking, caret/placeholder/selection rendering, and `ui.action` event emission.
- **Stable node identity**: destroyed slots are reused with a bumped generation, and `clear()` keeps old `UiNodeId`s invalid; text editing (`handleTextInput`/`handleBackspace`/`handleDelete`/`moveTextCursor`) works on whole UTF-8 code points and rejects invalid UTF-8 (`utf8Floor`/`utf8Prev`/`utf8Next` helpers). Caret blinking advances by `frame_dt_s`, not by frame count.
- **Backend-Neutral Output**: Emits standard `graphics.DrawCommand` lists, running identically in headless tests and GPU-backed windows.
