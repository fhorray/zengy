# `audio-zaudio` (`official.audio.zaudio`)

`zig-gamedev/zaudio` (`miniaudio`) provider implementing `AudioBackendVTable` for `official.audio` (`engine.audio/1`).

Supports decoding and playing WAV, OGG Vorbis, FLAC, and MP3 audio buffers from memory on top of `audio-core` without leaking `miniaudio` types into `src/core/`.
