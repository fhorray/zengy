# `audio` (`official.audio`)

Agnostic audio playback contract (`engine.audio/1`) for `zengy`.

- `AudioService`: source loading (`loadFromBytes`, `loadFromFile`), generational `AudioSourceHandle` & `AudioPlaybackHandle`, volume/pause/speed control.
- `AudioPlayer` & `SpatialListener`: ECS components processed in `.post_update` with distance attenuation and `.once`/`.loop`/`.despawn`/`.remove_component` lifecycle modes.
- Backends implement `AudioBackendVTable` (for example `official.audio.sdl3`).
