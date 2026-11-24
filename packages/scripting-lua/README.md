# `scripting-lua` (`official.script.lua`)

Optional **Lua 5.4.7** scripting runtime registered with `official.script.host` (`engine.script.host/1`).

## Features

- **Pure C99/C11 compilation**: Compiles official Lua 5.4.7 sources natively for Linux, Windows, and macOS via Zig.
- **Core isolation**: `src/core/` has zero references to Lua; scripts interact exclusively through `ScriptEngineBridge`.
- **Safe error capture**: Syntax and runtime errors are caught via `lua_pcall` and returned in `ScriptResult`.
