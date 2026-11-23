# Zig Modular Engine (`zigeng`) Documentation

Welcome to the `zigeng` documentation. This engine is built around a **minimal headless Zig core** (`src/core/`) with zero mandatory dependencies on windowing, GPUs, UI, or scripting VMs. Every higher-level feature is an optional package composed through capabilities and services.

## Documentation Index

- **Guides & Workflows**
  - [Getting Started](getting-started.md) — setup, first app, and running headless/visual examples
  - [AI Agent Test Project Guide](ai-test-project-guide.md) — standalone test project with modules + PocketPy scripting
  - [Releasing, CI/CD & Distribution](releasing.md) — merging to `main`, tagging releases, and `engine-cli` scope
  - [Package Catalog](../packages/README.md) — all optional packages, including [PocketPy Python](../packages/scripting-python/README.md), [SDL_GPU](../packages/graphics-sdlgpu/README.md), [2D](../packages/render-2d/README.md), and [3D](../packages/render-3d/README.md)
- **API Reference**
  - [Core App, ECS, Scheduler, Commands, Events & Diagnostics](api/core-app-and-ecs.md)
  - [Modules, Services & Runtime Reflection](api/modules-services-and-reflection.md)
  - [C ABI Extensions & Native Plugins](api/c-abi-extensions.md)
  - [Optional Packages, Playground & CLI](api/optional-packages.md)
- **Architecture & Decisions**
  - [Architecture Plan & Roadmap](architecture/zig_modular_engine_architecture_plan.md)
  - [ADR-001: Minimal Core Scope](adr/ADR-001-minimal-core.md)
  - [ADR-002: Module Contract, Lifecycle, and Scopes](adr/ADR-002-module-lifecycle.md)
  - [ADR-003: Capability and Provider Resolution](adr/ADR-003-service-resolution.md)
  - [ADR-004: Dual Strategy — Zig Native SDK vs Dynamic C ABI](adr/ADR-004-dual-abi.md)
  - [ADR-005: IDs, Generations, and Ownership](adr/ADR-005-ids-and-ownership.md)
  - [ADR-006: Scheduler, Commands, Borrows, and Thread Affinity](adr/ADR-006-scheduler-commands.md)
  - [ADR-007: ECS Backend Facade](adr/ADR-007-ecs-facade.md)

## Quickstart Commands

Requires **Zig `0.17.1`**:

```bash
# Run all 50 test steps (Debug / ReleaseSafe)
zig build test --summary all
zig build test -Doptimize=ReleaseSafe --summary all

# Headless & integrated playground
zig build run-headless
zig build run-playground

# Diagnostic CLI
zig build run-cli
zig build run-cli -Dcli-cmd=packages
zig build run-cli -Dcli-cmd=test-scenario

# Visual demos (Windows x64)
zig build run-visual-hello
zig build run-visual-gpu
zig build run-visual-2d
zig build run-visual-ui
zig build run-visual-playground
zig build run-visual-python
zig build run-visual-3d
```
