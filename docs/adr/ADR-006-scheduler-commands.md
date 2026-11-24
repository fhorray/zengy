# ADR-006: Scheduler, Commands, Borrows, and Thread Affinity

- **Status:** Accepted
- **Date:** 2026-11-23

## Decision
- Execution stages: `startup`, `pre_update`, `fixed_update`, `update`, `post_update`, `render_extract`, `shutdown`.
- Systems declare `reads`, `writes`, `before`, `after`, `exclusive`, and `thread_affinity` (`.main`, `.worker`, `.any`).
- `fixed_update` uses a deterministic accumulator with validated `fixed_dt` (rejects zero/negative/NaN/inf via `error.InvalidFixedTimestep`) and `max_fixed_steps`.
- Structural ECS mutations during iteration are deferred via `CommandBuffer` and flushed transactionally at stage barriers (`applyCommands`).
- Opt-in parallel execution (`Scheduler.setParallel(io)` / `AppConfig.enable_parallel`): `Scheduler.parallelBatches` groups conflict-free `.worker`/`.any` systems into concurrent batches on `std.Io.Threaded`. Each task receives its own tick and `CommandBuffer`, which are merged deterministically in schedule order; direct `World` mutations during a parallel phase fail with `error.MutationDuringParallelPhase`.
- Conflicting read/write or cyclic `before`/`after` constraints are rejected at build/schedule time.
