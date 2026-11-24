# `formats/json` (`official.format.json`)

Optional JSON format adapter (`engine.format.json/1`).

## Features

- **Dual backend support**:
  - `std_json`: Native Zig `std.json` parser with zero external C code (ideal for small configs).
  - `yyjson`: High-throughput `yyjson` C parser (ideal for large 100 KB–100 MB scene/asset payloads).
- **Core isolation**: Keeps JSON dependencies out of `src/core/`.
