# ADR-006: Scheduler, Commands, Borrows, and Thread Affinity

- **Status:** Accepted
- **Date:** 2026-11-23

## Decision
- Execution stages: `startup`, `pre_update`, `fixed_update`, `update`, `post_update`, `render_extract`, `shutdown`.
- Systems declare `reads`, `writes`, `before`, `after`, `exclusive`, and `thread_affinity`.
- `fixed_update` uses a deterministic accumulator with configurable `fixed_dt` and `max_fixed_steps_per_frame`.
- Structural ECS mutations during iteration are deferred via `CommandBuffer` and flushed at stage barriers (`applyCommands`).
- Conflicting read/write or cyclic `before`/`after` constraints are rejected at build/schedule time.
