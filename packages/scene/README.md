# `scene` (`official.scene`)

Optional 2D scene hierarchy and transform propagation package.

## Features

- **Spatial components**: `Transform2D` (local + computed world-space coordinates) and `Parent` hierarchy links.
- **Automatic propagation**: Updates world transforms during `.post_update`.
- **Scene graph v1** (`scene.graph`): optional `HierarchyLinks` child lists with `reparent` (cycle rejection, `preserve_world`), `despawnNode` policies (`cascade`, `orphan`, `reparent_to_parent`), `children`/`childCount`, and `rebuildLinks` for code that sets `Parent` directly. Entities outside the graph are unaffected.
- **O(N) propagation**: each node is resolved once per pass (parents first); entities in a parent cycle fall back to local values.
- **Headless snapshots**: Supports `SceneSnapshot` serialization/restore without any GPU or editor dependencies.
