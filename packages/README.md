# Optional Engine Packages (`packages/`)

`packages/` contains all **optional, modular capabilities** built on top of the minimal headless core (`@import("engine")`).

**Architectural Rule:** `src/core/` **never** imports anything from `packages/`. Applications and games opt into only the capabilities they need via `app.registerModule(...)`, and any community package can replace an official provider by implementing the same capability contract.

## Layout

Related packages are grouped by category; the public package name used by `zengy add` is unchanged (for example `zengy add physics-jolt` installs `packages/physics/jolt/`).

| Category | Directories |
|---|---|
| `physics/` | `core` (contract), `jolt`, `rapier` |
| `ui/` | `core`, `markup` |
| `window/` | `core`, `sdl3` |
| `graphics/` | `core`, `sdlgpu` |
| `scripting/` | `host`, `lua`, `python` |
| `render/` | `2d`, `3d`, `text` |
| `formats/`, `tooling/` | format adapters and file watcher |
| `flat` | `assets`, `scene`, `prefab`, `gizmos`, `shapes`, `dev-tools`, `picking`, `remote`, `log`, `editor-shell`, `testing`, `default-plugins`, `sdl3` (third-party SDK) |

## Package Catalog

| Package | Module ID | Capability Provided | Description |
|---|---|---|---|
| [`window/core/`](window/core/src/window.zig) | `official.window` | `engine.window/1`, `engine.input/1` | Window lifecycle, DPI/resize events, and keyboard/mouse input state. |
| [`window/sdl3/`](window/sdl3/src/window_sdl3.zig) | `official.window.sdl3` | `engine.window/1`, `engine.input/1` | Native SDL3 window, OS event loop, DPI scaling, and keyboard/mouse input. |
| [`graphics/core/`](graphics/core/src/graphics.zig) | `official.graphics` | `engine.graphics.device/1` | Render targets, draw command lists (`clear`, `rect`, `text`), and `present()`. |
| [`graphics/sdlgpu/`](graphics/sdlgpu/src/graphics_sdlgpu.zig) | `official.graphics.sdlgpu` | `engine.graphics.device/1` | Native SDL_GPU backend (Vulkan/SPIR-V), swapchain, pipelines, and Diagnostics logging. |
| [`render/text/`](render/text/src/text.zig) | `official.text` | — | Embedded 8x8 ASCII bitmap font atlas, glyph UVs, text measurement, and quad emission. |
| [`render/2d/`](render/2d/src/render_2d.zig) | `official.render.2d` | `engine.render.2d/1` | `Sprite`, `Visibility`, and `.render_extract` 2D batch extraction (powered by `official.camera`). |
| [`camera/`](camera/src/camera.zig) | `official.camera` | `engine.camera/1` | Unified 2D/3D `Camera`, `Projection`, `Viewport`, `RenderTarget`, `RenderLayers`, `Frustum`, `FreeCamera`, and `viewportToWorld` ray picking. |
| [`input/core/`](input/core/src/input.zig) | `official.input` | `engine.input.state/1` | Bevy-style `KeyCode`, `ButtonInput(T)`, `GamepadButton` (D-Pad/face/touchpad), `GamepadAxis`, `Gamepads`, `AccumulatedMouseMotion`, and `AccumulatedMouseScroll`. |
| [`input/haptics/`](input/haptics/src/haptics.zig) | `official.input.haptics` | `engine.input.haptics/1` | Agnostic controller dual-motor rumble and L2/R2 trigger haptics contract (`HapticService`). |
| [`input/sdl3/`](input/sdl3/src/input_sdl3.zig) | `official.input.sdl3` | `engine.input.gamepad_provider/1` | SDL3 `SDL_Gamepad` & PS5 DualSense rumble/trigger hardware provider. |
| [`ui/core/`](ui/core/src/ui_core.zig) | `official.ui.core` | `engine.ui.tree/1` | Syntax-agnostic retained `UiTree`, flex layout, O(1) ID index, focus, and hit testing. |
| [`ui/markup/`](ui/markup/src/ui_markup.zig) | `official.ui.markup` | — | Official HTML-like markup parser compiling into `UiTree` IR. |
| [`scripting/host/`](scripting/host/src/scripting_host.zig) | `official.script.host` | `engine.script.host/1` | Language-agnostic Scripting Host Protocol (SHP) and handle-based `ScriptEngineBridge`. |
| [`scripting/lua/`](scripting/lua/src/scripting_lua.zig) | `official.script.lua` | `engine.script.runtime.lua/1` | Real embedded **Lua 5.5** VM (`zlua`) registered with `ScriptingHost`. |
| [`scripting/python/`](scripting/python/src/scripting_python.zig) | `official.script.python` | `engine.script.runtime.python/1` | **PocketPy v2.2.0** (Python subset, vendored in `packages/scripting/python/third_party/pocketpy`) runtime, one VM per `ScriptingHost` runtime, registered with `ScriptingHost`. |
| [`assets/`](assets/src/assets.zig) | `official.assets` | `engine.assets/1` | URI-cached asset registry, priority-ordered importers, and owner-scoped unload. |
| [`scene/`](scene/src/scene.zig) | `official.scene` | `engine.scene.2d/1` | 2D transform hierarchy (`Transform2D`, `Parent`), O(N) `.post_update` propagation, scene graph v1 (`scene.graph`: child lists, `reparent`, despawn policies), and `SceneSnapshot`. |
| [`prefab/`](prefab/src/prefab.zig) | `official.prefab` | `engine.prefab/1` | Portable `Prefab` entity trees (stable type ids, versioned encoded components), field overrides, atomic batch `instantiate`, and a `PrefabLibrary` resource. |
| [`editor-shell/`](editor-shell/src/editor_shell.zig) | `official.tools.editor_shell` | `engine.tools.editor_shell/1` | Optional dockable panel registry, schema-driven inspector, and transactional undo/redo. |
| [`render/3d/`](render/3d/src/render_3d.zig) | `official.render.3d` | `engine.render.3d/1` | 3D transform/mesh components (`Transform3D`, `MeshRef`) and `.render_extract` draw extraction (powered by `official.camera`). |
| [`render/prism/`](render/prism/src/prism.zig) | `official.render.prism` | `engine.render.prism/1` | Prism modular rendering orchestration: `ViewRegistry`, `PassGraph`, `PipelineCacheKey`, `RetirementQueue`, and headless `RecordingBackend`. |
| [`render/helios/`](render/helios/src/helios.zig) | `official.render.helios` | `engine.render.helios/1` | Helios optional hybrid indirect illumination: SSGI Hi-Z traversal, `WorldRadianceCache`, and energy-conserving probe/sky fallback. |
| [`gizmos/`](gizmos/src/gizmos.zig) | `official.gizmos` | `engine.gizmos/1` | Immediate-mode 3D debug & editor gizmos (`line`, `ray`, `arrow`, `cuboid`, `axes`, `circle`, `sphere`, `grid`) with depth-tested and X-ray layers. |
| [`shapes/`](shapes/src/shapes.zig) | `official.shapes` | `engine.shapes/1` | Procedural 3D mesh primitives (`Plane`, `Cuboid`, `Sphere`, `Capsule`, `Cylinder`, `Torus`, `Cone`) with UVs and tangents. |
| [`dev-tools/`](dev-tools/src/dev_tools.zig) | `official.dev_tools` | `engine.dev_tools.profiler/1` | Per-pass frame profiler (`Shadow`, `SSAO`, `Volumetric`, `Forward+`, `Bloom`, `PostFX`) and rolling FPS metrics. |
| [`picking/`](picking/src/picking.zig) | `official.picking` | `engine.picking/1`, `engine.input_focus/1` | Unified UI/2D/3D pointer picking (`PointerEnter`, `PointerLeave`, `PointerDown`, `PointerUp`, `PointerDrag`) and `InputFocus`. |
| [`remote/`](remote/src/remote.zig) | `official.remote` | `engine.remote/1` | JSON-RPC 2.0 remote inspector for live ECS inspection, field mutation, and profiler telemetry. |
| [`log/`](log/src/log.zig) | `official.log` | `engine.log/1` | Configurable subsystem log filtering, ANSI console sink, `std.log` bridge, and pluggable `LogSinkVTable`. |
| [`formats/toml/`](formats/toml/src/toml_format.zig) | `official.format.toml` | `engine.format.toml/1` | TOML v1.1.0 adapter over `z-toml` for manifests and test scenarios. |
| [`formats/json/`](formats/json/src/json_format.zig) | `official.format.json` | `engine.format.json/1` | Dual JSON adapter (`std.json` for small configs, `yyjson` C11 for high-volume payloads). |
| [`tooling/file-watcher/`](tooling/file-watcher/src/file_watcher.zig) | `official.tooling.file_watcher` | `engine.tooling.file_watcher/1` | Filesystem watching adapter over `lookout` for hot reload. |
| [`testing/`](testing/src/testing_sdk.zig) | `official.testing` | `engine.testing.driver/1`, `engine.testing.capture/1` | Deterministic `TestDriver`, strict TOML `Scenario` runner, and offscreen RGBA8 `CaptureService`. |
