# Runtime application (`apps/runtime`)

Manifest-driven game runtime built as the `zengy-runtime` executable (`zig build`, installed to `zig-out/bin`).

- Reads `game.toml` from the current working directory, composes the declared modules and providers, loads native plugins (`plugin_paths.zig`), tracks script hooks (`hook_tracker.zig`) and runs Lua/Python scripts.
- `--headless` runs without a window; `--ticks <n>` bounds the number of ticks.
- The `zengy` CLI launches this executable as a process (`zengy run`); it does not import these sources.
