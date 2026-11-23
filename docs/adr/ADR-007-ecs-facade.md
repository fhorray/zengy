# ADR-007: ECS Backend Facade

- **Status:** Accepted
- **Date:** 2026-11-23

## Decision
- The public SDK exposes `World`, `EntityHandle`, `ComponentTypeId`, `Query`, and `CommandBuffer` without leaking any third-party ECS types or raw pointers.
- For the initial Zig 0.17.1 MVP, `src/core/world.zig` implements a self-contained generational-entity sparse-set ECS behind this public facade, guaranteeing zero external C dependency friction while preserving full API compatibility with a future `zflecs` backend swap.
