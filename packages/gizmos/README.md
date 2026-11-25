# `official.gizmos` (`packages/gizmos`)

Immediate-mode 3D debug and editor gizmos for `zengy` (`engine.gizmos/1`).

## Features

- **Backend-agnostic & headless-first:** `GizmoService` records per-frame 3D line and solid-overlay primitives (`GizmoVertex`) and runs deterministically without a GPU backend.
- **Configurable Styling (`GizmoConfig`):**
  - `line.width` (screen-space quad expansion on GPU for `width > 1.25px`) and `line.style` (`.solid`, `.dotted`, `.dashed`).
  - `arrow.style` (`.chevron`, `.cone`, `.diamond`), `arrow.tip_length`, `arrow.double_ended`, plus per-call `arrowWith()`.
  - `pushConfig()` / `popConfig()` stack for scoped styling across helper functions or groups.
- **Depth-tested & X-ray layers:**
  - Depth-tested: `line`, `ray`, `arrow`, `cuboid`, `roundedCuboid`, `axes`, `circle`, `sphere`, `rect`, `cross`, `grid`, `gridOriented`.
  - X-ray (always on top, modulated by `config.xray_alpha`): `lineXray`, `arrowXray`, `cuboidXray`, `circleXray`, `coneSolidXray`, `cuboidSolidXray`, `transformGizmo`.
- **Automatic `.render_extract` submission:** Reads the primary `camera.CameraService` `clip_from_world` matrix and dispatches queued vertices to the registered `GizmoBackendVTable` (implemented by `official.render.3d.gpu`).

---

## Quick Start

### 1. Register the module

Register `gizmos.module()` alongside `camera.module()` (and `graphics_wgpu.module()` and `gpu_3d.module()` for visual rendering):

```zig
const engine = @import("engine");
const camera = @import("camera");
const gizmos = @import("gizmos");

pub fn main(init: std.process.Init) !void {
    var app = engine.App.init(init.gpa, .{});
    defer app.deinit();

    // ... window, graphics, input ...
    try app.registerModule(camera.module());
    try app.registerModule(gizmos.module());

    try app.addSystem(.{ .name = "my_game.debug_gizmos", .stage = .update, .run = drawGizmos });
    try app.initialize();
    // ...
}
```

### 2. Draw gizmos in any `.update` system

Fetch `*gizmos.GizmoService` from `ctx.resources` and emit primitives every frame. Buffers are cleared automatically after `.render_extract`:

```zig
fn drawGizmos(ctx: *engine.SystemContext) !void {
    const giz = ctx.resources.get(gizmos.GizmoService) orelse return;

    // Ground grid & origin axes
    giz.grid(.{ 0, 0, 0 }, .{ 20, 20 }, .{ 1.0, 1.0 }, .{ 0.45, 0.48, 0.52, 0.5 });
    giz.axes(.{ 0, 0.02, 0 }, 1.2);

    // Wireframe bounding box & sphere
    giz.cuboid(.{ 0, 1.0, 0 }, .{ 2.0, 2.0, 2.0 }, .{ 0.2, 0.9, 1.0, 1.0 });
    giz.sphere(.{ 3.0, 1.0, 0 }, 0.75, 24, .{ 1.0, 0.3, 0.3, 1.0 });

    // Always-on-top X-ray marker inside geometry
    giz.lineXray(.{ -0.25, 1.0, 0 }, .{ 0.25, 1.0, 0 }, .{ 1.0, 1.0, 0.2, 1.0 });
}
```

---

## Styling (`GizmoConfig`, `pushConfig`, `popConfig`)

Mutate `giz.config` globally or isolate styles for a block using `pushConfig` / `popConfig`:

```zig
const prev = giz.config;
giz.pushConfig(.{
    .line = .{
        .width = 3.0,
        .style = .{ .dashed = .{ .gap_scale = 1.5, .line_scale = 2.5 } },
    },
    .arrow = .{
        .style = .diamond,
        .tip_length = 0.25,
        .double_ended = false,
    },
    .xray_alpha = 0.9,
    .enabled = prev.enabled,
});
defer giz.popConfig();

giz.arrow(.{ 0, 1, 0 }, .{ 2, 0, 0 }, .{ 1.0, 0.85, 0.2, 1.0 });
giz.roundedCuboid(.{ 0, 1, 0 }, .{ 1.8, 1.8, 1.8 }, 0.25, .{ 0.4, 0.9, 1.0, 1.0 });
```

### One-off arrow overrides (`arrowWith`)

Use `arrowWith` when you want custom tip styling for a single call without pushing a config:

```zig
giz.arrowWith(
    .{ 0, 0.5, 0 },
    .{ 0, 2.0, 0 },
    .{ 0.2, 1.0, 0.4, 1.0 },
    .{
        .style = .chevron,
        .tip_length = 0.2,
        .double_ended = true,
        .xray = true,
    },
);
```

---

## Built-in Primitives Reference

| Method | Layer | Description |
| :--- | :--- | :--- |
| `line(start, end, color)` / `lineXray(...)` | Depth / X-ray | Line segment respecting `config.line.style` |
| `ray(origin, vector, color)` | Depth | Line from `origin` to `origin + vector` |
| `arrow(origin, vector, color)` / `arrowXray(...)` | Depth / X-ray | Line with tip using `config.arrow` |
| `arrowWith(origin, vector, color, opts)` | Configurable | Per-call arrow override (`ArrowOptions`) |
| `cuboid(center, size, color)` / `cuboidXray(...)` | Depth / X-ray | Wireframe axis-aligned box |
| `roundedCuboid(center, size, radius, color)` | Depth | Wireframe box with rounded corners/edges |
| `coneSolidXray(tip, dir, length, radius, segs, color)` | X-ray Solid | Filled triangle cone (used by `.translate` handles) |
| `cuboidSolidXray(center, size, color)` | X-ray Solid | Filled triangle cube (used by `.scale` handles) |
| `axes(origin, scale)` | Depth | RGB X/Y/Z coordinate arrows |
| `circle(center, normal, radius, segs, color)` / `circleXray(...)` | Depth / X-ray | Oriented 3D circle |
| `sphere(center, radius, segs, color)` | Depth | 3-ring wireframe sphere |
| `rect(center, normal, size, color)` | Depth | Oriented 2D rectangle in 3D |
| `cross(center, size, color)` | Depth | 3D crosshair |
| `grid(center, cell_count, spacing, color)` | Depth | XZ ground grid |
| `gridOriented(center, normal, cell_count, spacing, color)` | Depth | Arbitrarily oriented grid |
| `transformGizmo(center, mode, size, active_axis)` | X-ray | Interactive `.translate`, `.rotate`, or `.scale` handle set (`active_axis`: `0=none, 1=X, 2=Y, 3=Z`) |

---

## Writing Custom Gizmos

Because `GizmoService` is immediate-mode, any custom gizmo is just a helper function that composes existing primitives:

```zig
fn drawDirectionalLightGizmo(
    giz: *gizmos.GizmoService,
    pos: [3]f32,
    dir: [3]f32,
    color: [4]f32,
) void {
    giz.circle(pos, dir, 0.35, 20, color);
    for (0..8) |i| {
        const a = @as(f32, @floatFromInt(i)) * (2.0 * std.math.pi / 8.0);
        const offset = [3]f32{ @cos(a) * 0.30, 0.0, @sin(a) * 0.30 };
        giz.ray(
            .{ pos[0] + offset[0], pos[1] + offset[1], pos[2] + offset[2] },
            .{ dir[0] * 1.4, dir[1] * 1.4, dir[2] * 1.4 },
            color,
        );
    }
}
```

For an interactive editor gizmo example (ray picking, DPI-aware hover highlighting, translate/rotate/scale handles), see `examples/visual-gizmos/main.zig`.

---

## Custom Render Backends (`GizmoBackendVTable`)

To render gizmos in a custom graphics package without touching `packages/gizmos`, register a `GizmoBackendVTable` via `giz.setBackend(...)`:

- `depth_vertices` / `xray_vertices`: `LINELIST` vertices (`position: [3]f32`, `color: [4]f32`).
- `solid_xray_vertices`: `TRIANGLELIST` vertices for filled X-ray handles (`coneSolidXray`, `cuboidSolidXray`).
- `clip_from_world`: Column-major 4x4 matrix from the active primary camera.

---

## Verification & Showcase

```bash
# Run interactive 3D gizmos showcase
zig build run-visual-gizmos

# Run unit tests (including gizmos tests)
zig build test --summary all
```
