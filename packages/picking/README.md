# `official.picking` (`packages/picking`)

Unified pointer picking and input focus for `zengy` (`engine.picking/1`, `engine.input_focus/1`).

## Features

- **Unified pointer events (`engine.EventBus`):** `PointerEnter`, `PointerLeave`, `PointerDown`, `PointerUp`, and `PointerDrag`.
- **Input Focus (`InputFocus`):** Tracks `focused_entity` and `hovered_entity`, automatically updating focus on `PointerDown` (configurable via `auto_focus_on_press`).
- **Pluggable Backends (`PickingBackendVTable`):**
  - Built-in **UI** (`PickableUi`, priority 300)
  - Built-in **2D** (`Pickable2D`, priority 200)
  - Built-in **3D AABB Raycast** (`Pickable3D` + `render_3d.Transform3D`, priority 100)
  - Register custom backends (e.g., mesh triangle raycasts or gizmo handles) with `PickingService.registerBackend(...)`.
