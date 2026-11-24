# `official.physics.jolt` (`packages/physics/jolt`)

Jolt Physics (v5.7.0, C++17) backend for `official.physics` (`packages/physics/core`).

## Features

- Implements `PhysicsBackendVTable` (`create_body`, `destroy_body`, `set_transform`, `get_transform`, `set_velocity`, `get_velocity`, `apply_force`, `apply_impulse`, `step`, `raycast`).
- Compiles Jolt Physics directly from source using `zig c++` (supports both Linux and Windows x64 cross-compilation).
- Attaches automatically to `PhysicsService` when registered via `physics_jolt.module()`.
