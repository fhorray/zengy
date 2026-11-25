# `official.log` (`packages/log`)

Configurable logging, subsystem filtering, and pluggable sinks for `zengy` (`engine.log/1`).

## Features

- **Subsystem & level filtering (`LogConfig`):** Set global `level` and comma-separated `filter` rules (e.g. `"wgpu=warn,picking=debug,info"`).
- **Pluggable sinks (`LogSinkVTable`):** Built-in ANSI console output, custom sinks (file, UI console, telemetry), and a recent-record ring buffer for editor tooling and `remote` (`zengy/get_logs`).
- **`Diagnostics` & `std.log` integration:** Automatically mirrors `App.diagnostics` entries during `.post_update` and provides `stdLogBridge` for `std.Options.logFn`.

## Usage

```zig
try app.resources.insert(log.LogConfig, .{
    .level = .info,
    .filter = "wgpu=warn,picking=debug",
});
try app.registerModule(log.module());
```
