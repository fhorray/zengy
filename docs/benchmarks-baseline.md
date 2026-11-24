# Benchmark baselines

Numbers measured with `zig test -OReleaseFast` probes on a shared cloud container (single run,
noisy; treat as order-of-magnitude, compare only on the same machine). `zig build run-bench`
prints the same scenarios (`benchmarks/main.zig`, sections 7-9).

| Scenario | Before | After |
|---|---|---|
| `World.despawn`, 8 registered types | 18 ns/entity | 14 ns/entity |
| `World.despawn`, 100 registered types | 102 ns/entity | 16 ns/entity |
| `World.despawn`, 400 registered types | 1287 ns/entity | 27 ns/entity |
| Scene2D propagate, chain depth 2000 | 38 ms | 0.15 ms |
| Scene2D propagate, chain depth 8000 | 563 ms | 1.7 ms |
| `World.query` creation (3 pools) | - | 14 ns |
| Query iteration, 1 write + 2 read pools | - | 7 ns/entity |
| Query iteration with change-tracked write | - | 4 ns/entity |
| `CommandBuffer.apply`, spawn + 2 sets | - | ~275 ns/entity (1k-10k) |

Query plan caching was evaluated and rejected: creating a query costs 14 ns, so a cache would
add invalidation complexity for no measurable gain.

## Re-running

```sh
zig build run-bench -Doptimize=ReleaseFast
```

A regression is a >20% slowdown of any row on the same machine and build mode.
