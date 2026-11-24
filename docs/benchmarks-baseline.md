# Benchmark baselines

"Before" numbers come from `zig test -OReleaseFast` probes written against the original code;
"After" numbers come from `zig build run-bench -Doptimize=ReleaseFast` (`benchmarks/main.zig`,
sections 7-9) on a shared cloud container. Single runs, noisy: compare only on the same machine.

| Scenario | Before | After |
|---|---|---|
| `World.despawn`, 8 registered types | 18 ns/entity | 12.8 ns/entity |
| `World.despawn`, 100 registered types | 102 ns/entity | 11.4 ns/entity |
| `World.despawn`, 400 registered types | 1287 ns/entity | 13.9 ns/entity |
| Scene2D propagate, chain depth 2000 | 38 ms | 0.15 ms |
| Scene2D propagate, chain depth 8000 | 563 ms | 0.23 ms |
| `World.query` creation (3 pools) | - | 14 ns |
| Query iteration, 1 write + 2 read pools | - | 7 ns/entity |
| Query iteration with change-tracked write | - | 4.0 ns/entity |
| `CommandBuffer.apply`, spawn + 2 sets (10k) | - | 126 ns/entity |
| `World` spawn + set (10k) | - | 116 ns/entity |
| Query iteration, 1M updates | - | 2 ns/update |

| Incremental Local/Global propagate, 10,101 nodes: first pass | - | 1.49 ms |
| same, idle frame (nothing changed) | - | 0.023 ms |
| same, one dirty subtree of 101 nodes | - | 0.035 ms |

| Parallel scheduler, 4 independent systems x 100k entities (4 cores) | 8.75 ms/frame serial | 3.47 ms/frame (2.52x) |

Query plan caching was evaluated and rejected: creating a query costs 14 ns, so a cache would
add invalidation complexity for no measurable gain.

## Re-running

```sh
zig build run-bench -Doptimize=ReleaseFast
```

A regression is a >20% slowdown of any row on the same machine and build mode.
