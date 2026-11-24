# `ui-markup` (`official.ui.markup`)

Optional HTML-like UI markup frontend that compiles into [`ui-core`](../core/README.md) (`UiTree`).

## Features

- **Declarative syntax**: Parses `<ui-document>`, `<panel>`, `<label>`, `<button>`, `<text-input>`, and `<virtual-list>` tags into `UiTree` nodes.
- **Replaceable frontend**: `ui-core` and `src/core/` have zero knowledge of HTML or markup syntax.
