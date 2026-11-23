# Zig Modular Engine (`zigeng`)

A modular, extensible game & application engine written in Zig with a minimal headless core, capability-based `ModuleRegistry` & `ServiceRegistry`, generational ECS facade, deterministic `Scheduler`, reflection schemas, and a versioned C ABI (`include/engine_extension.h`) for external plugins.

> **Architecture Specification:** See [zig_modular_engine_architecture_plan.md](docs/architecture/zig_modular_engine_architecture_plan.md) and [Architecture Decision Records](docs/adr/).

## Current MVP Status (Phases 0–4)

- **Phase 0 (Contracts & ADRs):** ADRs 001–007, repository structure, CI workflow, Zig 0.17.1 pinned.
- **Phase 1 (Core Headless):** `App`, `World` (generational `EntityHandle`, `EntityGuid`, `WorldId`), `Scheduler` (stages, topological ordering, conflict/cycle detection, `fixed_update` accumulator), `CommandBuffer`, `EventBus` (bounded queues, owner-scoped subscriptions), `ResourceRegistry`, `Diagnostics`.
- **Phase 2 (Module & Service Registry):** Topological module resolution, `ProviderNotFound`, `VersionMismatch`, `AmbiguousProvider`, `DependencyCycle`, init rollback, reverse-order teardown.
- **Phase 3 (Extension SDK & C ABI):** `include/engine_extension.h` (`AEHostApi`, `AEPluginApi`), `DynLib` plugin loader, `struct_size` and `abi_major` validation, safe lifecycle (`load -> start -> stop -> unload`), cross-language C `.so` smoke plugin.
- **Phase 4 (Reflection & Dynamic Schemas):** `TypeRegistry`, `ComponentSchema`, `FieldDescriptor`, `SchemaId` hashing, dynamic `getField` / `setField`.

## Quick Start

```bash
# Run all unit, integration, and C ABI tests
zig build test

# Run the headless ECS example (1000 entities, movement system, events)
zig build run-headless
```

## Repository Layout

```text
.
├── build.zig
├── build.zig.zon
├── include/
│   └── engine_extension.h      # Stable C ABI boundary for external plugins
├── src/
│   ├── engine.zig              # Public Zig SDK entrypoint
│   └── core/                   # Minimal headless core (zero UI/GPU/VM deps)
│       ├── app.zig
│       ├── world.zig
│       ├── scheduler.zig
│       ├── commands.zig
│       ├── events.zig
│       ├── resources.zig
│       ├── service_registry.zig
│       ├── module_registry.zig
│       ├── reflection.zig
│       ├── diagnostics.zig
│       └── abi.zig
├── examples/
│   ├── headless-ecs/           # Phase 1 gate: 1000-entity headless ECS app
│   └── c-plugin/               # Phase 3 gate: pure C shared library plugin
├── tests/                      # Unit, integration, and ABI compatibility tests
├── docs/
│   ├── architecture/           # Full architecture & roadmap
│   └── adr/                    # ADR-001 through ADR-007
└── .github/workflows/          # CI build & test workflow
```
