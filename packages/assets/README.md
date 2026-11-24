# `assets` (`official.assets`)

Optional asset management and importer registry package (`engine.assets/1`).

## Features

- **URI-based resolution**: Supports `project://`, `engine://`, and `package://` URIs without coupling `src/core/` to filesystem or asset formats.
- **Extensible importers**: `ImporterDescriptor` registry with extension matching and priority selection.
- **Generational handles**: `AssetHandle` prevents dangling raw pointers across plugins.
- **Deduplication & hot reload**: Content/URI cache with safe `reload()` swap.
- **Dependency graph**: `addDependency` (cycle-checked), `dependenciesOf`, `dependentsOf`, `unloadIfUnreferenced`, and `reloadAndInvalidate` (bumps the version of every transitive dependent after a reload).
- **Allocation-failure safety**: `loadFromBytes`, `reload`, and `unload` reserve capacity before mutating state, so an out-of-memory error never double-frees, leaks a slot, or drops the previous payload. `unload` returns `false` (asset stays loaded) if bookkeeping cannot be reserved; retired payloads stay valid until `collectGarbage()`.
