# Optional Engine Packages (`packages/`)

`packages/` contains all **optional, modular capabilities** built on top of the minimal headless core (`@import("engine")`).

**Architectural Rule:** `src/core/` **never** imports anything from `packages/`. Applications and games opt into only the capabilities they need via `app.registerModule(...)`, and any community package can replace an official provider by implementing the same capability contract.

## Package Catalog

| Package | Module ID | Capability Provided | Description |
|---|---|---|---|
| [`window/`](window/src/window.zig) | `official.window` | `engine.window/1`, `engine.input/1` | Window lifecycle, DPI/resize events, and keyboard/mouse input state. |
| [`window-sdl3/`](window-sdl3/src/window_sdl3.zig) | `official.window.sdl3` | `engine.window/1`, `engine.input/1` | Native SDL3 window, OS event loop, DPI scaling, and keyboard/mouse input. |
| [`graphics/`](graphics/src/graphics.zig) | `official.graphics` | `engine.graphics.device/1` | Render targets, draw command lists (`clear`, `rect`, `text`), and `present()`. |
| [`graphics-sdlgpu/`](graphics-sdlgpu/src/graphics_sdlgpu.zig) | `official.graphics.sdlgpu` | `engine.graphics.device/1` | Native SDL_GPU backend (Vulkan/SPIR-V), swapchain, pipelines, and Diagnostics logging. |
| [`text/`](text/src/text.zig) | `official.text` | — | Embedded 8x8 ASCII bitmap font atlas, glyph UVs, text measurement, and quad emission. |
| [`render-2d/`](render-2d/src/render_2d.zig) | `official.render.2d` | `engine.render.2d/1` | `Camera2D`, `Sprite`, `Visibility`, and `.render_extract` 2D batch extraction. |
| [`ui-core/`](ui-core/src/ui_core.zig) | `official.ui.core` | `engine.ui.tree/1` | Syntax-agnostic retained `UiTree`, flex layout, O(1) ID index, focus, and hit testing. |
| [`ui-markup/`](ui-markup/src/ui_markup.zig) | `official.ui.markup` | — | Official HTML-like markup parser compiling into `UiTree` IR. |
| [`ui-novaui/`](ui-novaui/src/novaui.zig) | `community.ui.novaui` | — | Alternative community DSL (`NovaUI`) compiling into the same `UiTree` IR. |
| [`ui-immediate/`](ui-immediate/src/ui_immediate.zig) | `community.ui.immediate` | `engine.ui.backend.immediate/1` | Immediate-mode UI backend consuming `window`/`input`/`graphics` without `ui-core`. |
| [`scripting-host/`](scripting-host/src/scripting_host.zig) | `official.script.host` | `engine.script.host/1` | Language-agnostic Scripting Host Protocol (SHP) and handle-based `ScriptEngineBridge`. |
| [`scripting-lua/`](scripting-lua/src/scripting_lua.zig) | `official.script.lua` | `engine.script.runtime.lua/1` | Real embedded **Lua 5.5** VM (`zlua`) registered with `ScriptingHost`. |
| [`scripting-python/`](scripting-python/src/scripting_python.zig) | `official.script.python` | `engine.script.runtime.python/1` | **PocketPy v2.2.0** (Python subset, vendored in `third_party/pocketpy`) runtime, one VM per `ScriptingHost` runtime, registered with `ScriptingHost`. |
| [`assets/`](assets/src/assets.zig) | `official.assets` | `engine.assets/1` | URI-cached asset registry, priority-ordered importers, and owner-scoped unload. |
| [`scene/`](scene/src/scene.zig) | `official.scene` | `engine.scene.2d/1` | 2D transform hierarchy (`Transform2D`, `Parent`), `.post_update` propagation, and `SceneSnapshot`. |
| [`editor-shell/`](editor-shell/src/editor_shell.zig) | `official.tools.editor_shell` | `engine.tools.editor_shell/1` | Optional dockable panel registry, schema-driven inspector, and transactional undo/redo. |
| [`render-3d/`](render-3d/src/render_3d.zig) | `official.render.3d` | `engine.render.3d/1` | 3D transform/camera/mesh components and `.render_extract` draw extraction. |
| [`formats/toml/`](formats/toml/src/toml_format.zig) | `official.format.toml` | `engine.format.toml/1` | TOML v1.1.0 adapter over `z-toml` for manifests and test scenarios. |
| [`formats/json/`](formats/json/src/json_format.zig) | `official.format.json` | `engine.format.json/1` | Dual JSON adapter (`std.json` for small configs, `yyjson` C11 for high-volume payloads). |
| [`tooling/file-watcher/`](tooling/file-watcher/src/file_watcher.zig) | `official.tooling.file_watcher` | `engine.tooling.file_watcher/1` | Filesystem watching adapter over `lookout` for hot reload. |
| [`testing/`](testing/src/testing_sdk.zig) | `official.testing` | `engine.testing.driver/1`, `engine.testing.capture/1` | Deterministic `TestDriver`, strict TOML `Scenario` runner, and offscreen RGBA8 `CaptureService`. |
