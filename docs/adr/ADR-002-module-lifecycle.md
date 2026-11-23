# ADR-002: Module Contract, Lifecycle, and Scopes

- **Status:** Accepted
- **Date:** 2026-11-23

## Decision
- Every `Module` declares a `ModuleDescriptor` (`id`, `version`, `required_services`, `optional_services`) and lifecycle hooks (`build`, `start`, `stop`).
- `ModuleRegistry` resolves modules via topological sort independent of insertion order.
- Failure during `build` or `start` triggers deterministic rollback of already-initialized modules in reverse order.
- Shutdown executes `stop` in exact reverse topological order.
- Resource scopes (`Process`, `Application`, `World`, `Window`, `Plugin`, `Frame`) govern ownership and teardown boundaries.
