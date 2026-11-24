# `window` (`official.window`)

Optional headless window and input contract package (`engine.window/1`, `engine.input/1`).

## Features

- **Window lifecycle**: Generational `WindowHandle` management (`create`, `resize`, `requestClose`, `destroy`).
- **Input tracking**: Per-frame mouse position, button clicks, keyboard presses, and text input via `InputService`.
- **Event integration**: Emits `window.resized` and `window.close_requested` events via `EventBus`.
- **Headless-first**: Compiles without any OS windowing or SDL dependencies; swap with [`window-sdl3`](../window-sdl3/README.md) for native windows.
