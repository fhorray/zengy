# `tooling/file-watcher` (`official.tooling.file_watcher`)

Optional filesystem watcher adapter (`engine.tooling.file_watcher/1`) wrapping the `lookout` library.

## Features

- **Hot reload support**: Watches scripts, UI markup, and asset directories for changes without adding OS watcher code to `src/core/`.
- **Modular isolation**: Only compiled and active when explicitly registered by tooling or development builds.
