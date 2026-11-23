# Optional Packages, Playground & CLI Reference

All packages under `packages/` are optional `engine.Module` implementations that depend only on the public SDK (`@import("engine")`) or other optional packages — never modifying `src/core/`.

---

## 1. Window & Input (`official.window` — `packages/window/src/window.zig`)

- **Provides:** `engine.window/1` (`WindowService`), `engine.input/1` (`InputService`)
- **Key APIs:**
  - `WindowService`: `createWindow(desc)`, `getSize(handle)`, `resize(handle, w, h)`, `requestClose(handle)`, `shouldClose(handle)`, `destroyWindow(handle)`.
  - `InputService`: `beginFrame()`, `injectMouseMove(x, y)`, `injectMouseButton(btn, down)`, `injectKey(code, down)`, `isMouseDown(btn)`, `wasMouseClicked(btn)`, `isKeyDown(code)`, `wasKeyPressed(code)`.

## 2. Graphics Device (`official.graphics` — `packages/graphics/src/graphics.zig`)

- **Requires:** `engine.window/1`
- **Provides:** `engine.graphics.device/1` (`GraphicsDeviceService`)
- **Behavior:** Automatically sets `app.scheduler.render_extract_enabled = true` while active.
- **Key APIs:** `createSurface(window_handle, w, h)`, `resizeSurface(target, w, h)`, `beginFrame(target)`, `submitDrawCommands(target, cmds)`, `present(target)`, `setDeviceAvailable(bool)` (returns `error.DeviceUnavailable` when lost).

## 3. Retained UI Core (`official.ui.core` — `packages/ui-core/src/ui_core.zig`)

- **Requires:** `engine.graphics.device/1`
- **Provides:** `engine.ui.tree/1` (`UiTree`)
- **Key APIs:**
  - `tree.createNode(parent, UiNodeDescriptor)` (`panel`, `label`, `button`, `textbox`, `virtual_list`)
  - `tree.layoutTree(viewport_w, viewport_h)` (flex `column`/`row` layout)
  - `tree.hitTest(x, y)` and `tree.handlePointerClick(x, y, &app.events)` (sets focus + emits `ui.action`)
  - `tree.paint(allocator, &out_cmds)` (generates `graphics.DrawCommand` list)

## 4. UI Frontends & Alternative Backends

- **HTML-like Markup (`official.ui.markup` — `packages/ui-markup/src/ui_markup.zig`):**
  `ui_markup.parseIntoTree(allocator, html_src, &ui_tree)`
- **Community NovaUI DSL (`community.ui.novaui` — `packages/ui-novaui/src/novaui.zig`):**
  `ui_novaui.parseIntoTree(allocator, nova_src, &ui_tree)` — produces the exact same `UiTree` IR.
- **Immediate-Mode UI Backend (`community.ui.immediate` — `packages/ui-immediate/src/ui_immediate.zig`):**
  Provides `engine.ui.backend.immediate/1` (`ImmediateUiService`). Consumes `window`, `input`, and `graphics` directly **without** `official.ui.core`.

## 5. Scripting Host Protocol (`official.script.host` — `packages/scripting-host/src/scripting_host.zig`)

- **Provides:** `engine.script.host/1` (`ScriptingHost`)
- **Key APIs:**
  - `host.registerRuntime(RuntimeDescriptor, RuntimeProviderVTable) !u16`
  - `host.loadScript(runtime_idx, name, source) !ScriptModuleHandle`
  - `host.invokeScript(handle, fn_name, arg) ScriptResult`
  - `host.unloadScript(handle)` / `host.destroyRuntime(runtime_idx)` (automatically revokes owned `EventBus` subscriptions and invalidates handles).
- Scripts interact with the engine safely through `ScriptEngineBridge` (`spawnEntity`, `isEntityAlive`, `postEvent`, `subscribeEvent`, `log`).

## 6. Asset Service (`official.assets` — `packages/assets/src/assets.zig`)

- **Provides:** `engine.assets/1` (`AssetService`)
- **Key APIs:**
  - `svc.registerImporter(ImporterDescriptor)` (resolved by extension and highest `priority`)
  - `svc.loadFromBytes(uri, raw_source) !AssetHandle` (URI-cached)
  - `svc.reload(handle, new_source) !void` (bumps version in place)
  - `svc.unload(handle) bool` (bumps generation, invalidating stale handles)

## 7. 2D Scene & Transform Graph (`official.scene` — `packages/scene/src/scene.zig`)

- **Provides:** `engine.scene.2d/1`
- **Components:** `Transform2D`, `Parent`
- **System:** `propagateTransformsSystem` in `.post_update` (supports arbitrary-depth parent chains).
- **Serialization:** `SceneSnapshot.capture(allocator, &world)` and `snap.restore(&target_world)`.

## 8. Modular Editor Shell (`official.tools.editor_shell` — `packages/editor-shell/src/editor_shell.zig`)

- **Requires:** `engine.ui.tree/1`
- **Provides:** `engine.tools.editor_shell/1` (`EditorShellService`)
- **Key APIs:** `registerPanel(desc)`, `setInspectedField(&world, &types, entity, schema_id, field, val)`, `undo(&world, &types)`, `redo(&world, &types)`.

## 9. 3D Renderer Foundation (`official.render.3d` — `packages/render-3d/src/render_3d.zig`)

- **Requires:** `engine.graphics.device/1`
- **Provides:** `engine.render.3d/1` (`Render3DService`)
- **Components:** `Transform3D`, `Camera3D`, `MeshRef`
- **System:** `extract3DSystem` in `.render_extract` populates `extracted_draws` when an active `Camera3D` exists.

## 10. Playground & CLI

- **Playground (`projects/playground/main.zig`):** `zig build run-playground` — end-to-end sandbox composing all optional packages and `libc_plugin.so`.
- **Diagnostic CLI (`tools/cli/main.zig`):**
  - `zig build run-cli` (`doctor`) — checks ABI version, module resolution, and service count.
  - `zig build run-cli -Dcli-cmd=packages` — prints resolved topological module order and registered providers.
