# `input-sdl3` (`official.input.sdl3`)

SDL3 hardware provider for `official.input` (`Gamepads`) and `official.input.haptics` (`HapticService`).

## Features

- Polls up to 4 connected gamepads via `SDL_Gamepad` (PS5 DualSense, Xbox, Switch, generic controllers), including D-Pad, face buttons, bumpers, analog triggers, thumbsticks, and DualSense touchpad click.
- Implements `HapticBackendVTable` with `SDL_RumbleGamepad` and `SDL_RumbleGamepadTriggers`.
