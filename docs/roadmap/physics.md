# Agnostic Physics Roadmap (`zigeng`)

This document outlines how the `zigeng` physics subsystem will be implemented using an **ECS-first + Plugin** developer experience backed by a **pluggable `PhysicsBackendVTable`** (matching the pattern already used in `packages/graphics/`).

## 1. Architecture Principles

1. **Single ECS Contract:**
   - Game code (Zig, Lua, or Python) **never** touches raw solver handles or backend-specific types (Jolt, Box2D, etc.).
   - Developers attach standard ECS components to entities:
     - `RigidBody` (`dynamic`, `static`, `kinematic`, mass, damping)
     - `Collider` (`box`, `sphere`, `capsule`, friction, restitution, `is_sensor`, `layer_mask`)
     - `Velocity`, `ExternalForce`, `GravityScale`
     - `Transform2D` (from `official.scene`) or `Transform3D` (future 3D scene component)
2. **Decoupled via `PhysicsBackendVTable`:**
   - `packages/physics/` (`official.physics`, capability `engine.physics/1`) defines the public components, events (`CollisionEvent`), spatial queries (`RaycastDesc` / `RaycastHit`), and `PhysicsBackendVTable`.
   - Solver backends only implement `PhysicsBackendVTable` and register with `PhysicsService`.
3. **Deterministic `.fixed_update` Execution:**
   - The core scheduler (`src/core/scheduler.zig`) already provides a `.fixed_update` stage with a fixed-timestep accumulator (`fixed_dt`).
   - All physics stepping runs in `.fixed_update`, decoupled from rendering frame rate.
4. **Headless-First:**
   - Without an attached backend, `packages/physics/` compiles with zero C/C++ dependencies and runs as a deterministic no-op for CI and headless simulations.

---

## 2. Package Layout

```text
packages/
├── physics/          # Public ECS contract, events, PhysicsService, and PhysicsBackendVTable
├── physics-simple/   # (Phase P2) Lightweight 100% Zig solver (AABB / Sphere / Raycast) for 2D/arcade & CI
├── physics-box2d/    # (Phase P3) Optional 2D backend using Box2D v3 (C99)
└── physics-jolt/     # (Phase P3) Optional 3D backend using Jolt Physics
```

---

## 3. Fixed-Step Pipeline (`.fixed_update`)

Each physics tick will execute 4 ordered stages using scheduler `before` / `after` constraints:

1. **`physics.sync_in` (ECS -> Backend):**
   - Newly spawned entities with `RigidBody` + `Collider` receive a `PhysicsBodyHandle` via `backend.create_body(...)`.
   - Removed entities or entities missing `RigidBody` have their backend body destroyed via `backend.destroy_body(...)`.
   - `kinematic` or manually moved bodies push their `Transform` and `ExternalForce` into the backend.
2. **`physics.fixed_step` (Simulation):**
   - Calls `backend.step(fixed_dt, gravity)`.
3. **`physics.sync_out` (Backend -> ECS):**
   - `dynamic` bodies write updated positions, rotations, and `Velocity` back to ECS components.
   - Non-persistent `ExternalForce` components are cleared.
4. **`physics.emit_events` (Events):**
   - Contact start/end transitions are pushed to `EventBus` as `CollisionEvent` (`.started` / `.ended`).

---

## 4. Backend Portability Rules

To ensure swapping `physics-simple` for `physics-box2d` or `physics-jolt` does not break game logic:
- **Opaque handles:** only `u64` (`PhysicsBodyHandle`) is exposed in the public API.
- **Consistent units:** `1.0` unit = `1 meter`, `Y-up` coordinate convention, default gravity `(0, -9.81, 0)`.
- **Optional extensions:** specialized features (e.g., joints, character controllers) belong in optional sub-vtables (`?*const CharacterControllerVTable`) so lightweight backends are not forced to implement everything.

---

## 5. Implementation Phases

- **Phase P1 (Preparation — `feat/physics` branch):**
  - `packages/physics/` skeleton with ECS components, `CollisionEvent`, `RaycastDesc` / `RaycastHit`, `PhysicsBackendVTable`, `PhysicsService`, `module()`, and headless unit tests.
- **Phase P2 (Pure Zig Solver — `physics-simple`):**
  - Pure Zig AABB / Sphere / Raycast solver.
  - Automatic `Transform2D` (`packages/scene/`) synchronization.
  - `visual-physics` demo (falling boxes, ground collision, mouse raycast).
- **Phase P3 (Optional Native Backends):**
  - `packages/physics-box2d` (full 2D: polygons, joints, continuous rotation).
  - `packages/physics-jolt` (full 3D: meshes, capsules, character controller).
- **Phase P4 (Scripting & CLI):**
  - Bindings in `scripting-host` / `scripting-python` / `scripting-lua` (`add_force`, `apply_impulse`, `raycast`, `on_collision` callbacks).
  - CLI catalog integration (`zigeng add physics`, `zigeng add physics-simple`) and `plugins = ["physics"]` in `game.toml`.
