# `official.physics` (`packages/physics/core`)

Agnostic, ECS-first physics contract for `zengy`.

## Design

- **Body lifecycle:** `PhysicsService` tracks every body it creates and destroys it (via `destroy_body`) when the entity despawns, loses `RigidBody`, or the backend is replaced (`PhysicsBodyHandle.epoch` invalidates old ids). Failed creates store `PhysicsBodyHandle.failed_id` and are not retried until that component is removed. The full initial pose (including rotation) is pushed after creation.
- **ECS-first API:** Games attach `RigidBody`, `Collider`, `Velocity`, `ExternalForce`, and `GravityScale` to entities.
- **Deterministic `.fixed_update`:** `physics.module()` registers `physics.fixed_step` in the scheduler's `.fixed_update` stage.
- **Pluggable backends (`PhysicsBackendVTable`):** Backends (such as `physics-simple`, `physics-box2d`, or `physics-jolt`) implement `PhysicsBackendVTable` and attach to `PhysicsService` (`engine.physics/1`) without changing game code.
- **Headless-safe:** When no backend is attached, `PhysicsService` operates as a deterministic no-op with zero external dependencies.

See [docs/roadmap/physics.md](../../../docs/roadmap/physics.md) for the full implementation roadmap.
