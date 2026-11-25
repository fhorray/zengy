# ADR-008: Application and Package Boundaries

- **Status:** Accepted
- **Date:** 2026-11-25

## Context
`packages/` had grown to hold more than reusable capabilities. The manifest-driven runtime lived under `tools/runtime`, the editor shell (panel registry, undo/redo policy) was an installable package, and `remote` imported `editor_shell` directly, so a generic inspection package knew about one application's state.

## Decision
Ownership is decided by layer:

| Layer | Location | Owns |
|---|---|---|
| Engine SDK | `src/engine.zig`, `src/core/` | Minimal headless infrastructure. |
| Packages | `packages/` | Optional, reusable capabilities and providers with application-independent semantics. |
| Applications | `apps/` | Product-specific composition, lifecycle, policies and workflows (`apps/runtime`, `apps/editor`). |
| Tools | `tools/` | Developer automation (`cli`, `ci`). |
| Examples / projects / tests | `examples/`, `projects/`, `tests/` | Demonstrations, integration sandboxes and fixtures. |

Dependency direction: core imports nothing above it; packages may import core and other packages (acyclic) but never applications, tools, examples or tests; applications may import core and packages; tools may import core and packages. Launching an executable (the CLI starting `zengy-runtime`) is not a source dependency. `tools/ci/check_architecture.py` enforces these rules.

Concrete changes:
- `tools/runtime` moved to `apps/runtime/src`; the `zengy-runtime` binary name and launch contract are unchanged.
- `packages/editor-shell` moved to `apps/editor` (`src/shell.zig`). It is an application-local build module, no longer a public SDK module or CLI package. Module ID `app.editor.shell` and capability `editor.shell/1` use the application namespace instead of `official.*`/`engine.*`.
- `remote` defines a small optional `RemoteIntegration` (edit hook and panel visitor). `apps/editor/src/remote_adapter.zig` implements it on top of the shell; compositions call `remote_adapter.attach(&app)` after `app.initialize()`.

## Alternatives considered
- Keep all tooling as packages: leaves reverse dependencies and ships product policy as public API.
- Move reusable tooling (remote, gizmos, testing, file watching) into apps: these are application-independent capabilities and stay packages.
- Regroup `packages/` into new categories: churn that breaks public names and paths for no boundary benefit.

## Consequences
- `editor-shell` is not a public module or CLI package. No compatibility layer, deprecation period or migration path is provided.
- Remote edits enter undo history only when the application attaches the adapter. Without one, `set_component_field` writes directly and `list_panels` returns `{"panels":[]}`.
- An adapter error is returned to the caller; Remote never retries it as a direct write.

## Exceptions
Vendored SDL3 SDK files and their provisioning manifest live in `third_party/sdl3` (moved from `packages/sdl3`), since they are infrastructure, not a feature package. The build, CLI installer and `.paths` use the new location.

## Out of scope
Scene documents, editor selection, document history, panels and the editor executable belong to `apps/editor` when they are built. Nothing here creates them.
