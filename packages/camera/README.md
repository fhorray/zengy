# `camera` (`official.camera`)

Agnostic, headless-first Camera & Projection module (`engine.camera/1`) inspired by `bevy_camera`.

## Features

- **Unified `Camera` component**: Supports `order` priority, `is_active`, `Viewport` sub-regions, `RenderTarget` (`.primary_window`, `.window`, or offscreen `.image`), and `ClearColorConfig`.
- **Projections**: `Projection` union with `PerspectiveProjection` and `OrthographicProjection` (`window_size`, `fixed_horizontal`, `fixed_vertical`, `auto_min`, `auto_max`).
- **Visibility & Culling**: 32-bit `RenderLayers` bitmask and 6-plane `Frustum` extraction (`containsSphere`).
- **Coordinate Conversion & Ray Picking**: `Camera.worldToViewport` and `Camera.viewportToWorld` (`Ray3D`).
- **`CameraService` & `cameraUpdateSystem`**: Updates `Camera.computed` in `.post_update` and maintains `sortedActiveCameras()`.

## Usage

```zig
const camera = @import("camera");

try app.registerModule(camera.module());

const cam_ent = try app.world.spawn();
try app.world.set(cam_ent, camera.Camera, .{ .order = 0 });
try app.world.set(cam_ent, camera.Projection, .{ .perspective = .{} });
try app.world.set(cam_ent, camera.CameraPose, camera.CameraPose.lookAt(.{ 0, 2, 6 }, .{ 0, 0, 0 }, .{ 0, 1, 0 }));
```

## Example

Run the headless camera example ([examples/camera/main.zig](../../examples/camera/main.zig)):

```sh
zig build run-camera
```

Run the interactive 3D visual camera & input demo ([examples/visual-camera/main.zig](../../examples/visual-camera/main.zig)):

```sh
zig build run-visual-camera
```
