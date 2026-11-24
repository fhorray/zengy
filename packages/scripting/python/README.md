# `scripting-python` (`official.script.python`)

Embedded **PocketPy v2.2.0** (Python subset, MIT) scripting runtime registered with `official.script.host` (`engine.script.host/1`).

## Features

- **Zero external Python install**: PocketPy is vendored in `packages/scripting/python/third_party/pocketpy/` and compiled as a single C11 unit (`-DPK_ENABLE_OS=0` sandboxed).
- **Isolated per-runtime VMs**: Each `ScriptingHost` Python runtime owns an independent PocketPy VM (`py_switchvm`, slots `1..15`).
- **Bound `engine` module**:
  - `engine.log(msg: str)` → writes to `app.diagnostics`
  - `engine.spawn_entity() -> int` → spawns an ECS entity and returns its handle
  - `engine.post_event(name: str, payload: str = "")` → emits an `EventBus` event via `CommandBuffer`
  - `engine.draw_rect(x, y, w, h, r=1, g=1, b=1, a=1)` → appends to `ScriptDrawQueue` for visual rendering
- **Safe error capture**: Python exceptions are returned in `ScriptResult` without aborting the host.

## Visual Example

```bash
zig build run-visual-python
```

See [`examples/visual-python/main.zig`](../../../examples/visual-python/main.zig).

## Known Limitations

- Maximum **15** concurrent Python runtimes per process (PocketPy VM table limit).
- Unloading a script frees its host handle, but PocketPy has no module-delete API so the module remains in its VM until the runtime is destroyed.
