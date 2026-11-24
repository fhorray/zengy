# `ui-markup` (`official.ui.markup`)

Optional HTML-like UI markup frontend for **in-game UIs** (HUDs, menus, inventories) that compiles into [`ui-core`](../core/README.md) (`UiTree`).

See [ADR-0001: Layered UI Architecture](../../../docs/adr/0001-layered-ui-architecture.md) for how `ui-markup` compares to [`ui-plume`](../plume/README.md) (editor/tooling UI) on top of the shared `ui-core` + [`ui-widgets`](../widgets/README.md) foundation.

## Features

- **Declarative syntax**: Parses `<ui-document>`, `<panel>`, `<label>`, `<button>`, `<text-input>`, and `<virtual-list>` tags into `UiTree` nodes.
- **Replaceable frontend**: `ui-core` and `src/core/` have zero knowledge of HTML or markup syntax — games and community packages can swap in any custom DSL or styling system while targeting the same `UiTree`.
