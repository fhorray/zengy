# `scripting-host` (`official.script.host`)

Optional language-agnostic scripting host protocol (`engine.script.host/1`).

## Features

- **Multi-runtime coexistence**: Allows multiple scripting VMs (Lua, Python, or custom runtimes) to register under a unified `ScriptingHost` interface without coupling `src/core/`.
- **Safe handle lifecycle**: `ScriptModuleHandle` carries runtime and module generations invalidated on unload.
- **Bridge & ownership**: Scripts interact with the engine via `ScriptEngineBridge`; destroying a runtime automatically revokes its `EventBus` subscriptions.
