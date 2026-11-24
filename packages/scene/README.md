# `scene` (`official.scene`)

Optional 2D scene hierarchy and transform propagation package.

## Features

- **Spatial components**: `Transform2D` (local + computed world-space coordinates) and `Parent` hierarchy links.
- **Automatic propagation**: Updates world transforms during `.post_update`.
- **Scene graph v1** (`scene.graph`): optional `HierarchyLinks` child lists with `reparent` (cycle rejection, `preserve_world`), `despawnNode` policies (`cascade`, `orphan`, `reparent_to_parent`), `children`/`childCount`, and `rebuildLinks` for code that sets `Parent` directly. Entities outside the graph are unaffected.
- **Local/Global transforms** (`scene.incremental`): editable `LocalTransform2D/3D` and derived `GlobalTransform2D/3D` (2D affine, 3D column-major TRS with quaternion). Propagation systems run in `.post_update` and recompute only entities whose `Local*` or `Parent` changed (ECS change tracking) plus their descendants, rewriting a global only when its value changes, so `.changed = .{GlobalTransform2D}` lists exactly what moved and an idle frame does no transform work. Descendants are found through `HierarchyLinks`: edit hierarchy via `scene.graph` (or call `rebuildLinks` after raw `Parent` writes). `reparent(.{ .preserve_world = true })` understands both the legacy `Transform2D` and the new components.
- **O(N) propagation (legacy `Transform2D`)**: each node is resolved once per pass (parents first); entities in a parent cycle fall back to local values.
- **Headless snapshots**: Supports `SceneSnapshot` serialization/restore without any GPU or editor dependencies.
