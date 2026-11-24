# `scene` (`official.scene`)

Optional 2D scene hierarchy and transform propagation package.

## Features

- **Spatial components**: `Transform2D` (local + computed world-space coordinates) and `Parent` hierarchy links.
- **Automatic propagation**: Updates world transforms during `.post_update`.
- **Headless snapshots**: Supports `SceneSnapshot` serialization/restore without any GPU or editor dependencies.
