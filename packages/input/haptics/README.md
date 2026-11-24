# `input-haptics` (`official.input.haptics`)

Agnostic controller rumble & trigger haptics contract (`engine.input.haptics/1`).

## Features

- **`HapticService`**: `playRumble(slot, low_freq, high_freq, duration_ms)`, `playTriggerRumble(slot, left_trigger, right_trigger, duration_ms)`, `setAdaptiveTrigger(slot, side, effect)` (`off`, `feedback`, `weapon`, `vibration`), and `stop(slot)`.
- **`HapticBackendVTable`**: Plugs in any concrete hardware backend (such as `official.input.sdl3` for PS5 DualSense / Xbox rumble) while running deterministically in headless tests.
