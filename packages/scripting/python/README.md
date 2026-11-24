# `scripting-python` (`official.script.python`)

Embedded **PocketPy v2.2.0** (Python subset, MIT) scripting runtime registered with `official.script.host` (`engine.script.host/1`).

## Features

- **Zero external Python install**: PocketPy is vendored in `packages/scripting/python/third_party/pocketpy/` and compiled as a single C11 unit (`-DPK_ENABLE_OS=0` sandboxed).
- **Isolated per-runtime VMs**: Each `ScriptingHost` Python runtime owns an independent PocketPy VM (`py_switchvm`, slots `1..15`).
- **Bound `zigeng` package**:
  - `zigeng.log(msg: str, level: str = "info")` → writes to `app.diagnostics` (`"debug"`, `"info"`, `"warn"`, `"error"`)
  - `zigeng.spawn_entity() -> int` → spawns an ECS entity and returns its handle
  - `zigeng.is_alive(entity: int) -> bool` → checks if an entity handle is alive
  - `zigeng.post_event(name: str, payload: str = "", entity: int = 0)` → emits an `EventBus` event via `CommandBuffer`
  - `zigeng.draw_rect(x, y, w, h, r=1, g=1, b=1, a=1)` / `zigeng.clear_draw_queue()` → manages `ScriptDrawQueue` rects for visual rendering
  - `zigeng.input` (`is_key_down(key)`, `mouse_x()`, `mouse_y()`, `is_mouse_down()`, `was_mouse_clicked()`)
  - `zigeng.Key` (`Key.A`..`Key.Z`, `Key.UP`/`DOWN`/`LEFT`/`RIGHT`, `Key.SPACE`, `Key.RETURN`, `Key.ESCAPE`, `Key.LSHIFT`, etc.)
- **IDE Type Stubs (`.pyi`)**: Type stubs live in [`typings/`](typings/) and are generated automatically into new projects by `zigeng new <name>` (or refreshed with `zigeng typings`).
- **Flexible Lifecycle Hooks**: Zero-arg hooks like `def start():` and `def destroy():` work without requiring a dummy parameter, alongside `def update(dt):` / `def fixed_update(dt):` / `def on_ui_action(payload):`.
- **Safe error capture**: Python exceptions are returned in `ScriptResult` without aborting the host.

## Visual Example

```bash
zig build run-visual-python
```

See [`examples/visual-python/main.zig`](../../../examples/visual-python/main.zig).

## Known Limitations

- Maximum **15** concurrent Python runtimes per process (PocketPy VM table limit).
- Unloading a script frees its host handle, but PocketPy has no module-delete API so the module remains in its VM until the runtime is destroyed.
