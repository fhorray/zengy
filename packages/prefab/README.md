# `prefab` (`official.prefab`)

Optional prefab package (`engine.prefab/1`): reusable, nestable entity trees that instantiate in one atomic batch.

## Features

- **Portable data**: a `Prefab` stores entities (`local_id`, optional parent) and components as `TypeRegistry.encodeComponent` blobs, so it is independent of host layout and Zig type names. Stored older component versions are migrated (`TypeRegistry.registerMigration`) on instantiation.
- **Overrides**: `Override{ local_id, stable_id, field, value }` addresses a field by stable type id and field name, never by offset.
- **Atomic `instantiate`**: decodes, migrates, overrides, and registers everything first, then spawns and fills entities; any error despawns what was created (`UnknownOverrideTarget`, `UnknownSchema`, `MissingMigration`, `FieldNotFound`, `OutOfMemory`, ...).
- **Hot reload**: `reinstantiate` builds and validates the new instance before despawning the old one, so a failed reload leaves the running instance untouched.
- **Hierarchy-agnostic**: parents are attached through an optional `LinkFn` (for example one that calls `scene.graph.reparent`), so any hierarchy implementation works. Parents must be declared before children, which keeps prefabs acyclic.
- **JSON authoring** (`prefab.json.parsePrefab` / `parseOverrides`, built on `std.json`): strict loader that targets the latest registered schema of each `namespace.name` component and rejects unknown types/fields and out-of-range values. `parsePrefabValue` accepts any tree converted to `std.json.Value`, so TOML or editor adapters can reuse it.
- **`PrefabLibrary`**: named prefab store registered as a resource and as `engine.prefab/1`.

- **Nested prefabs**: `Prefab.addNested` makes an anchor entity whose children come from another prefab (resolved by name through a `Resolver`, e.g. `PrefabLibrary.resolver()`), with overrides addressed by the nested prefab's own ids. Cycles (`NestedPrefabCycle`), unknown names (`UnknownPrefab`), and depth beyond `max_nesting_depth` are errors. Top-level entities always come first in `Instance.handles`.
- **Two-phase instantiation**: `prepare` (decode, migrate, override, expand nesting; never touches a `World`, safe on a worker thread) and `commit` (register, spawn, link; atomic). `instantiate` is both.
- **Cooked binary** (`prefab.cooked.cook` / `load`): versioned format with a CRC-32 trailer; `load` rejects corruption, truncation, and malformed structure without reading out of bounds.
- **Cell streaming** (`prefab.streaming.CellStreamer`): queue prepared cells, commit them within a per-frame entity budget (`update`), cancel, and unload a whole cell.
- **TOML**: use `toml_format.tableToJsonValue` with `prefab.json.parsePrefabValue`.

Not implemented yet: prefab diff/merge on hot reload (`reinstantiate` replaces the whole instance) and spatial cell selection (the caller decides which cells to request).
