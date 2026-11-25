# Editor application (`apps/editor`)

The `zengy-editor` MVP scene editor (`zig build run-editor`, needs the wgpu-native SDK), the editor shell and its remote integration.

- `src/main.zig` — `zengy-editor` executable: 3D viewport with a hierarchy panel (left) and an inspector (right). Click a shape or a hierarchy row to select; arrows/PgUp/PgDn move the selection (Shift = coarse step), `R`/`F` scale, `N` adds a cube, `Delete` removes the selection (not undoable), `J`/`K` step through the hierarchy, `Tab` cycles the gizmo mode, `Ctrl+Z`/`Ctrl+Y` undo/redo, right-click drag + `WASD` flies the camera. Not implemented yet: saving/loading scenes, text-field editing, rotation editing, drag gizmos, undoable add/delete.
- `src/document.zig` — `EditorDocument` (module `document`): hierarchy entries, selection and a bounded transform undo/redo history over `engine.World`. Headless and unit-tested; the executable only adds presentation.
- `src/shell.zig` — `EditorShellService` (module `app.editor.shell`, capability `editor.shell/1`, requires `engine.ui.tree/1`): panel registry with five default panels (`editor.hierarchy`, `editor.inspector`, `editor.console`, `editor.profiler`, `editor.remote`), schema-driven `setInspectedField` through `TypeRegistry`, and field-edit `undo`/`redo`. Edits reserve history capacity before mutating, and redo is cleared on a new edit.
- `src/remote_adapter.zig` — implements `remote.RemoteIntegration` on top of the shell. Call `remote_adapter.attach(&app)` after `app.initialize()` (and `detach` if the shell is removed first). The shell is resolved through `app.resources` on every call.
- `examples/visual-inspector/` — picking, gizmo, profiler and remote showcase that composes the shell and adapter (`zig build run-visual-inspector`).
- `tests/` — document tests, shell tests and adapter integration tests (single undo transaction per remote edit, panel listing, no direct-write fallback on adapter error, detached behavior).

The shell is an application-local build module (`editor_shell`), not a public SDK module or CLI package. See [ADR-008](../../docs/adr/ADR-008-application-package-boundaries.md).
