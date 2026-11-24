# `official.gizmos` (`packages/gizmos`)

Immediate-mode 3D debug & editor gizmos for `zengy` (`engine.gizmos/1`).

## Features

- **Backend-agnostic & headless-first:** `GizmoService` records per-frame 3D line primitives (`GizmoVertex`) and runs deterministically without a GPU backend.
- **Configurable Styling (`GizmoConfig`):**
  - `line.width` (portable GPU screen-space quad expansion for `width > 1.25px`) and `line.style` (`.solid`, `.dotted`, `.dashed`).
  - `arrow.style` (`.chevron`, `.cone`, `.diamond`), `arrow.tip_length`, `arrow.double_ended`, plus per-call `arrowWith()`.
  - `pushConfig()` / `popConfig()` stack for scoped group styling.
- **Depth-tested & X-ray layers:** `line`, `ray`, `arrow`, `cuboid`, `axes`, `circle`, `sphere`, `rect`, `cross`, `grid`, `gridOriented` (depth-tested) and `lineXray` / `arrowXray` (always-on-top overlay).
- **Automatic `.render_extract` submission:** reads the active primary `camera.CameraService` `clip_from_world` matrix and dispatches queued vertices to the registered `GizmoBackendVTable` (implemented by `official.graphics.sdlgpu`).
