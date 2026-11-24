# `audio-sdl3` (`official.audio.sdl3`)

SDL3 `SDL_AudioStream` & `SDL_LoadWAV_IO` provider implementing `AudioBackendVTable` for `official.audio` (`engine.audio/1`).

Supports WAV and raw `pcm_f32` streams with per-playback volume, pause, speed/pitch, looping, and spatial attenuation. For compressed formats like `.ogg`/`.mp3`/`.flac`, a `miniaudio` (`zig-gamedev/zaudio`) backend can plug into the same `AudioBackendVTable`.
