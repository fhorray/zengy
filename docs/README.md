# Zig Modular Engine (`zigeng`) Documentation

Welcome to the `zigeng` documentation. This engine is built around a **minimal headless Zig core** (`src/core/`) with zero mandatory dependencies on windowing, GPUs, UI, or scripting VMs. Every higher-level feature is an optional package composed through capabilities and services.

## Documentation Index

- **API Reference & User Guides**
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
# Run all 12 per-module test suites (Debug)
zig build test --summary all

# Run all tests in ReleaseSafe mode
zig build test -Doptimize=ReleaseSafe --summary all

# Run the integrated playground (composes all optional packages + C plugin)
zig build run-playground

# Run the standalone 1,000-entity headless ECS example
zig build run-headless

# Run the diagnostic CLI
zig build run-cli
zig build run-cli -Dcli-cmd=packages
```
