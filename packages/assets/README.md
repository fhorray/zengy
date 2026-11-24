# `assets` (`official.assets`)

Optional asset management and importer registry package (`engine.assets/1`).

## Features

- **URI-based resolution**: Supports `project://`, `engine://`, and `package://` URIs without coupling `src/core/` to filesystem or asset formats.
- **Extensible importers**: `ImporterDescriptor` registry with extension matching and priority selection.
- **Generational handles**: `AssetHandle` prevents dangling raw pointers across plugins.
- **Deduplication & hot reload**: Content/URI cache with safe `reload()` swap.
