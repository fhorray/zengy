# ADR-001: Minimal Core Scope

- **Status:** Accepted
- **Date:** 2026-11-23

## Context
To support headless simulations, custom UI backends, multiple scripting runtimes, and replaceable renderers without coupling, the core library must have zero mandatory dependencies on windowing, GPU APIs, audio, physics, or scripting VMs.

## Decision
`src/core/` contains exclusively:
1. Application lifecycle (`app.zig`)
2. ECS facade & generational entities (`world.zig`)
3. Deterministic stage scheduler (`scheduler.zig`)
4. Deferred command buffers (`commands.zig`)
5. Bounded event bus (`events.zig`)
6. Scoped resources (`resources.zig`)
7. Capability/provider service registry (`service_registry.zig`)
8. Topological module registry (`module_registry.zig`)
9. Runtime reflection & schemas (`reflection.zig`)
10. Structured diagnostics (`diagnostics.zig`)
11. Versioned C ABI host (`abi.zig`)

## Consequences
All optional capabilities (Window, Graphics, UI Core, Markup/CSS, Lua/Python/JS scripting, Assets, Editor) must be implemented outside `src/core/` and depend only on the public SDK or C ABI.
