# `official.remote` (`packages/remote`)

JSON-RPC 2.0 remote inspector for live ECS inspection, component editing, profiler telemetry, and editor-shell panels (`engine.remote/1`).

## Supported Methods

- `zengy/list_entities`: Lists alive entities and attached reflected component schemas.
- `zengy/get_entity`: Inspects all reflected fields of an entity (`index`, `generation`).
- `zengy/set_component_field`: Mutates a component field live (routed through `EditorShellService` undo/redo when available).
- `zengy/get_profiler`: Returns per-pass timings (`Shadow`, `SSAO`, `Forward+`, `Volumetric`, `Bloom`, `PostFX`), total frame time, and FPS from `FrameProfilerService`.
- `zengy/list_panels`: Lists registered `EditorShellService` panels.
- `zengy/get_focus`: Returns `focused` and `hovered` entities from `InputFocus`.
- `zengy/get_logs`: Returns buffered log records from `LogService` (or `App.diagnostics`).
