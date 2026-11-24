# `default-plugins` (`official.default_modules`)

Optional convenience bundle that registers the standard headless module stack (`window`, `graphics`, `ui-core`, `assets`, `scene`, `scripting-host`, `toml_format`, `json_format`) via `registerDefaultModules(app)`.

## Design

- Keeps `src/core/` completely free of optional dependencies.
- Intended for applications that want an ergonomic one-call setup while retaining full modularity.
