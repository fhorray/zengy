# Editor application (`apps/editor`)

Holds the existing editor shell and its remote integration. There is no editor executable yet.

- `src/shell.zig` — `EditorShellService` (module `app.editor.shell`, capability `editor.shell/1`, requires `engine.ui.tree/1`): panel registry with five default panels (`editor.hierarchy`, `editor.inspector`, `editor.console`, `editor.profiler`, `editor.remote`), schema-driven `setInspectedField` through `TypeRegistry`, and field-edit `undo`/`redo`. Edits reserve history capacity before mutating, and redo is cleared on a new edit.
- `src/remote_adapter.zig` — implements `remote.RemoteIntegration` on top of the shell. Call `remote_adapter.attach(&app)` after `app.initialize()` (and `detach` if the shell is removed first). The shell is resolved through `app.resources` on every call.
- `examples/visual-inspector/` — picking, gizmo, profiler and remote showcase that composes the shell and adapter (`zig build run-visual-inspector`).
- `tests/` — shell tests and adapter integration tests (single undo transaction per remote edit, panel listing, no direct-write fallback on adapter error, detached behavior).

The shell is an application-local build module (`editor_shell`), not a public SDK module or CLI package. See [ADR-008](../../docs/adr/ADR-008-application-package-boundaries.md).
