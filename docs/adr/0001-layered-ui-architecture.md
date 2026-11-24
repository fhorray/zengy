# ADR-0001: Layered UI Architecture (`ui-core` as Universal UI IR)

- **Status:** Accepted
- **Date:** 2026-11-24
- **Packages:** `official.ui.core`, `official.ui.widgets`, `official.ui.plume`, `official.ui.markup`

## Context

A game engine needs two fundamentally different kinds of user interfaces:

1. **Editor & Developer Tooling UIs** — dense property inspectors, scene trees, color pickers, command palettes, menubars, and debug overlays that benefit from an opinionated, consistent dark-mode kit.
2. **In-Game UIs** — HUDs, title screens, inventories, and dialog boxes that require bespoke visual identity, custom themes/fonts, declarative layouts, and game-specific styling.

If editor widgets baked in their own layout/rendering engine, or if `ui-core` assumed HTML markup or editor styling, third-party packages could not cleanly share layout, input, focus, or rendering pipelines.

## Decision

`zengy` adopts a **strictly layered UI architecture** where `ui-core` (`UiTree`) is the single, syntax-agnostic, visual-agnostic foundation for **all** UIs (both in-game and editor/tooling):

```text
  Editor / Tooling UI                 In-Game UI (HUD, Menus, Inventory)
  [ ui-plume ]                        [ ui-markup ] (or XML/JSON/Lua/custom DSL)
         \                                   /
          v                                 v
      [ ui-widgets ]   +   [ ui-core (UiTree) ]   <-- shared by all UIs
                   \           /
                    v         v
             [ graphics (GPU / headless) ]
```

### Layer Responsibilities

- **`ui-core` (`official.ui.core`)**: Retained UI tree IR (`UiTree`, `UiNode`), flex-like `row`/`column` layout (`grow`, `percent`, `absolute`), clipping, scrolling, spatial hit-testing, `Tab` focus traversal, text caret/selection rendering, and backend-neutral `graphics.DrawCommand` emission.
- **`ui-widgets` (`official.ui.widgets`)**: Visual-agnostic interactive behavior (`WidgetManager`) attached to `UiTree` nodes — clicks, hover, sliders, drag-to-scrub, shared `TextEditState` (`Ctrl+A/C/X/V/Z`), extensible `UndoHistory` (`pushCustom`), popovers, tooltips, and scrollbars.
- **`ui-plume` (`official.ui.plume`)**: Opinionated dark-mode widget kit for **editors and tooling**, built on top of `ui-core` and `ui-widgets`.
- **`ui-markup` (`official.ui.markup`) & Community Frontends**: Declarative, stylable frontends for **in-game UIs** that compile directly into `ui-core` (`UiTree`) nodes (and optionally bind `ui-widgets` behaviors).

## Consequences

- **One layout, focus, and render pipeline:** Both in-game UIs and editor tools run deterministically in headless tests and render through the same `graphics.DrawCommand` backend.
- **No lock-in:** Games can replace or bypass `ui-plume` and `ui-markup` with any custom frontend (HTML/CSS, XML, JSON, Lua UI, immediate-mode builders) as long as it emits `UiTree` nodes.
- **Shared interaction & undo:** Custom game widgets and future editor panels can share `WidgetManager`, `TextEditState`, and `UndoHistory` without duplicating input or shortcut logic.
