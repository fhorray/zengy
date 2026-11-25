# `official.remote` (`packages/remote`)

JSON-RPC 2.0 remote inspector for live ECS inspection, component editing, profiler telemetry, and application-provided panels (`engine.remote/1`).

## Supported Methods

- `zengy/list_entities`: Lists alive entities and attached reflected component schemas.
- `zengy/get_entity`: Inspects all reflected fields of an entity (`index`, `generation`).
- `zengy/set_component_field`: Mutates a component field live (written directly, or routed through an attached `RemoteIntegration` such as the editor shell undo/redo).
- `zengy/get_profiler`: Returns per-pass timings (`Shadow`, `SSAO`, `Forward+`, `Volumetric`, `Bloom`, `PostFX`), total frame time, and FPS from `FrameProfilerService`.
- `zengy/list_panels`: Lists panels published by an attached `RemoteIntegration`; `{"panels":[]}` when none is attached.
- `zengy/get_focus`: Returns `focused` and `hovered` entities from `InputFocus`.
- `zengy/get_logs`: Returns buffered log records from `LogService` (or `App.diagnostics`).

## Optional application integration

`RemoteInspectorService.setIntegration(.{ .context, .edit_field, .visit_panels })` lets an application take over validated field edits (called exactly once; an error is returned and never retried as a direct write) and publish panels through a synchronous `PanelVisitor`. Callbacks run only for explicit RPC requests. `clearIntegration()` restores the default behavior. The editor application provides one in `apps/editor/src/remote_adapter.zig`.
