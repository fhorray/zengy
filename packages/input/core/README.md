# `input` (`official.input`)

Bevy-inspired ergonomic input contract (`engine.input.state/1`) built on top of [`window`](../../window/core/README.md) (`engine.input/1`).

## Features

- **`KeyCode` & `MouseButton`**: Typed keyboard scancodes (`key_a`..`key_z`, `digit_0`..`digit_9`, `f1`..`f12`, arrows, modifiers) and mouse buttons.
- **`ButtonInput(T)` (`KeyInput`, `MouseInput`, `GamepadButtonInput`)**: `.pressed()`, `.justPressed()`, `.justReleased()`, `.anyPressed()`, `.anyJustPressed()`.
- **`GamepadButton` & `GamepadAxis`**: Agnostic D-Pad, face buttons (`south`/`east`/`west`/`north`), bumpers, analog/digital triggers, thumbsticks, DualSense `touchpad`, and deadzone-filtered `leftStick()`/`rightStick()`/`dpad()`.
- **`Gamepads` & `GamepadBackendVTable`**: Up to 4 simultaneous gamepads populated by any optional hardware provider (such as `input-sdl3`).
- **`AccumulatedMouseMotion` & `AccumulatedMouseScroll`**: Per-frame pointer delta and scroll wheel delta resources updated in `.pre_update`.
