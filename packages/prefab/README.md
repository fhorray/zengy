# `prefab` (`official.prefab`)

Optional prefab package (`engine.prefab/1`): reusable entity trees that instantiate in one atomic batch.

## Features

- **Portable data**: a `Prefab` stores entities (`local_id`, optional parent) and components as `TypeRegistry.encodeComponent` blobs, so it is independent of host layout and Zig type names. Stored older component versions are migrated (`TypeRegistry.registerMigration`) on instantiation.
- **Overrides**: `Override{ local_id, stable_id, field, value }` addresses a field by stable type id and field name, never by offset.
- **Atomic `instantiate`**: decodes, migrates, overrides, and registers everything first, then spawns and fills entities; any error despawns what was created (`UnknownOverrideTarget`, `UnknownSchema`, `MissingMigration`, `FieldNotFound`, `OutOfMemory`, ...).
- **Hot reload**: `reinstantiate` builds and validates the new instance before despawning the old one, so a failed reload leaves the running instance untouched.
- **Hierarchy-agnostic**: parents are attached through an optional `LinkFn` (for example one that calls `scene.graph.reparent`), so any hierarchy implementation works. Parents must be declared before children, which keeps prefabs acyclic.
- **JSON authoring** (`prefab.json.parsePrefab` / `parseOverrides`, built on `std.json`): strict loader that targets the latest registered schema of each `namespace.name` component and rejects unknown types/fields and out-of-range values. `parsePrefabValue` accepts any tree converted to `std.json.Value`, so TOML or editor adapters can reuse it.
- **`PrefabLibrary`**: named prefab store registered as a resource and as `engine.prefab/1`.

Not implemented yet: a TOML adapter, nested prefabs, prefab diff/hot reload, cooked binary scene format, and streaming.
