# `formats/toml` (`official.format.toml`)

Optional TOML format adapter (`engine.format.toml/1`) wrapping `z-toml`.

## Features

- **Manifest parsing**: Parses `game.toml` and `engine.package.toml` manifests into structured Zig types (`GameManifest`, `PackageManifest`).
- **Core isolation**: Keeps TOML parsing dependencies out of `src/core/`.

- **JSON bridge**: `toJsonValue(arena, value)` converts a parsed TOML tree into `std.json.Value` (date/time values are rejected), so syntax-agnostic loaders such as `prefab.json.parsePrefabValue` accept TOML authoring files.
