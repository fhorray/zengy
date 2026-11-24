# `editor-shell` (`official.tools.editor_shell`)

Optional modular editor tooling package built on top of `TypeRegistry` and `CommandBuffer`.

## Features

- **Panel registry**: Dockable editor panels registered as modules without core coupling.
- **Undo/redo history**: Command-based undo/redo stack.
- **Schema-driven inspector**: Inspects ECS components dynamically using `TypeRegistry` reflection metadata.
- **Zero runtime overhead**: Never imported by `src/core/` or standalone exported games.
