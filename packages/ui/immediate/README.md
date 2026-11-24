# `ui-immediate` (`community.ui.immediate`)

Alternative immediate-mode UI package demonstrating architectural independence from `ui-core`.

## Design

- Does **not** import `ui-core` or construct a retained `UiTree`.
- Consumes only `engine.window/1`, `engine.input/1`, and `engine.graphics.device/1` directly.
