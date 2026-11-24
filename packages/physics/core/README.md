# `official.physics` (`packages/physics/core`)

Agnostic, ECS-first physics contract for `zigeng`.

## Design

- **ECS-first API:** Games attach `RigidBody`, `Collider`, `Velocity`, `ExternalForce`, and `GravityScale` to entities.
- **Deterministic `.fixed_update`:** `physics.module()` registers `physics.fixed_step` in the scheduler's `.fixed_update` stage.
- **Pluggable backends (`PhysicsBackendVTable`):** Backends (such as `physics-simple`, `physics-box2d`, or `physics-jolt`) implement `PhysicsBackendVTable` and attach to `PhysicsService` (`engine.physics/1`) without changing game code.
- **Headless-safe:** When no backend is attached, `PhysicsService` operates as a deterministic no-op with zero external dependencies.

See [docs/roadmap/physics.md](../../../docs/roadmap/physics.md) for the full implementation roadmap.
