# ADR-005: IDs, Generations, and Ownership

- **Status:** Accepted
- **Date:** 2026-11-23

## Decision
- `EntityHandle`: 64-bit packed `(index: u32, generation: u32)`. Stale handles are rejected deterministically.
- `EntityGuid`: 128-bit persistent identifier for serialization/scene references.
- `WorldId`: generational handle preventing access to destroyed worlds.
- `AEHandle`: 64-bit opaque handle with generation/owner tagging across the C ABI.
- Memory ownership never crosses the ABI implicitly: host allocates/frees host memory, plugins allocate/free plugin state in `unload()`.
