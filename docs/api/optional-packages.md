# Optional Packages, Playground & CLI Reference

All packages under `packages/` are optional `engine.Module` implementations that depend only on the public SDK (`@import("engine")`) or other optional packages — never modifying `src/core/`.

---

## 1. Window & Input (`official.window` — `packages/window/core/src/window.zig`)

- **Provides:** `engine.window/1` (`WindowService`), `engine.input/1` (`InputService`)
- **Key APIs:**
  - `WindowService`: `createWindow(desc)`, `getSize(handle)`, `resize(handle, w, h)`, `requestClose(handle)`, `shouldClose(handle)`, `destroyWindow(handle)`.
  - `InputService`: `beginFrame()`, `injectMouseMove(x, y)`, `injectMouseButton(btn, down)`, `injectKey(code, down)`, `isMouseDown(btn)`, `wasMouseClicked(btn)`, `isKeyDown(code)`, `wasKeyPressed(code)`.

## 2. Graphics Device (`official.graphics` — `packages/graphics/core/src/graphics.zig`)

- **Requires:** `engine.window/1`
- **Provides:** `engine.graphics.device/1` (`GraphicsDeviceService`)
- **Behavior:** Automatically sets `app.scheduler.render_extract_enabled = true` while active.
- **Key APIs:** `createSurface(window_handle, w, h)`, `resizeSurface(target, w, h)`, `beginFrame(target)`, `submitDrawCommands(target, cmds)`, `present(target)`, `setDeviceAvailable(bool)` (returns `error.DeviceUnavailable` when lost).

## 3. Retained UI Core (`official.ui.core` — `packages/ui/core/src/ui_core.zig`)

- **Requires:** `engine.graphics.device/1`
- **Provides:** `engine.ui.tree/1` (`UiTree`)
- **Key APIs:**
  - `tree.createNode(parent, UiNodeDescriptor)` (`panel`, `label`, `button`, `textbox`, `virtual_list`)
  - `tree.layoutTree(viewport_w, viewport_h)` (flex `column`/`row` layout)
  - `tree.hitTest(x, y)` and `tree.handlePointerClick(x, y, &app.events)` (sets focus + emits `ui.action`)
  - `tree.paint(allocator, &out_cmds)` (generates `graphics.DrawCommand` list)

## 4. UI Markup Frontend

- **HTML-like Markup (`official.ui.markup` — `packages/ui/markup/src/ui_markup.zig`):**
  `ui_markup.parseIntoTree(allocator, html_src, &ui_tree)` — compiles declarative markup into `UiTree` IR.

## 5. Scripting Host Protocol (`official.script.host` — `packages/scripting/host/src/scripting_host.zig`)

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
  - `svc.reload(handle, new_source) !void` / `svc.reloadAndInvalidate(handle, new_source)` (bumps version in place and invalidates dependents)
  - `svc.unload(handle) bool` / `svc.unloadIfUnreferenced(handle)` (bumps generation, invalidating stale handles)
  - `svc.addDependency(parent, dep)` / `svc.dependentsOf(handle)` (dependency graph with cycle detection)

## 7. Scene & Transform Graph (`official.scene` — `packages/scene/src/scene.zig`)

- **Provides:** `engine.scene.2d/1`
- **Components:** `Transform2D`, `Parent`, `HierarchyLinks`, `LocalTransform2D`, `GlobalTransform2D`, `LocalTransform3D`, `GlobalTransform3D`
- **Systems:** `propagateTransformsSystem` (O(N) `Transform2D` propagation) and incremental change-tracked `scene.propagate_local_2d` / `scene.propagate_local_3d` (`.thread_affinity = .any`).
- **Graph APIs (`graph.zig`):** `reparent` (cycle rejection + `preserve_world`), `despawnNode` (`cascade`, `orphan`, `reparent_to_parent`), `rebuildLinks`.
- **Serialization:** `SceneSnapshot.capture(allocator, &world)` and `snap.restore(&target_world)`.

## 8. Prefabs & Cell Streaming (`official.prefab` — `packages/prefab/src/prefab.zig`)

- **Provides:** `engine.prefab/1` (`PrefabLibrary`)
- **Key APIs:**
  - Portable `Prefab` definitions (local IDs, hierarchy, versioned component blobs, field overrides, nested prefabs)
  - Two-phase atomic instantiation (`prepare` + `commit`) and `reinstantiate` hot reload
  - Strict JSON loader, TOML bridge (`toml_format.tableToJsonValue`), and CRC-32 binary cooked format
  - `CellStreamer` with per-frame entity budget, cancellation, and cell unloading

## 9. Camera & Input (`official.camera`, `official.input`, `official.input.haptics`, `official.input.sdl3`)

- **`official.camera` (`packages/camera/src/camera.zig`):** `Camera`, `Projection`, `CameraPose`, `CameraService` driving `render-2d` and `render-3d` view/projection matrices.
- **`official.input` (`packages/input/core/src/input.zig`):** `KeyInput`, `MouseInput`, `Gamepads` (sticks, triggers, buttons, DualSense `TouchpadFinger` tracking), and `InputMap` action bindings.
- **`official.input.haptics` / `official.input.sdl3`:** `HapticService` for dual-motor rumble and DualSense adaptive triggers (`feedback`, `weapon`, `vibration`).

## 10. Editor Shell (`app.editor.shell` — `apps/editor/src/shell.zig`)

Owned by the editor application, not an installable package (see the classification table in `packages/README.md`). Attach `apps/editor/src/remote_adapter.zig` to route `official.remote` edits and panel listing through it.

- **Requires:** `engine.ui.tree/1`
- **Provides:** `editor.shell/1` (`EditorShellService`)
- **Key APIs:** `registerPanel(desc)`, `setInspectedField(&world, &types, entity, schema_id, field, val)`, `undo(&world, &types)`, `redo(&world, &types)`.

## 11. 3D Renderer Foundation (`official.render.3d` — `packages/render/3d/src/render_3d.zig`)

- **Requires:** `engine.graphics.device/1`
- **Provides:** `engine.render.3d/1` (`Render3DService`)
- **Components:** `Transform3D`, `Camera3D`, `MeshRef`
- **System:** `extract3DSystem` in `.render_extract` populates `extracted_draws` when an active `Camera3D` exists.

## 12. Playground & CLI

- **Playground (`examples/playground/main.zig`):** `zig build run-playground` — end-to-end sandbox composing all optional packages and `libc_plugin.so`.
- **Diagnostic CLI (`tools/cli/main.zig`):**
  - `zig build run-cli` (`doctor`) — checks ABI version, module resolution, and service count.
  - `zig build run-cli -Dcli-cmd=packages` — prints resolved topological module order and registered providers.
