# `ui-widgets` (`official.ui.widgets`)

Visual-agnostic interactive widget runtime (`engine.ui.widgets/1`) layered on top of [`ui-core`](../core/README.md).

See [ADR-0001: Layered UI Architecture](../../../docs/adr/0001-layered-ui-architecture.md) for how `ui-widgets` sits between `ui-core` and frontends like `ui-plume` or custom in-game UIs.

## Features

- **Visual-agnostic `WidgetManager`**: Attaches interactive behaviors (`button`, `checkbox`, `radio`, `slider`, `range_slider`, `text_input`, `number_input`, `keybind_input`, `disclosure`, `list_item`, `menu_item`, `menu_trigger`, `popover`, `tooltip`, `scrollbar`, `tabs`) to any `UiTree` node without imposing colors or layout.
- **Shared `TextEditState`**: Unified text editing across single-line inputs, multiline textareas, and inline `NumberInput` editing (`Ctrl+A/C/X/V/Z/Y`, `Ctrl+Shift+Z`, `Left`/`Right`/`Up`/`Down`/`Home`/`End`, `Backspace`/`Delete`).
- **Extensible `UndoHistory`**: Built-in widget undo/redo plus `pushCustom` hooks so editors and custom tools can share one unified undo/redo stack.
- **Headless-first**: Deterministic frame processing (`processFrame` / `processFrameWithDt`) with typed `WidgetEvent` queues.
