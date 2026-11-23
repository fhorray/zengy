# ADR-004: Dual Strategy — Zig Native SDK vs Dynamic C ABI

- **Status:** Accepted
- **Date:** 2026-11-23

## Decision
1. **Layer A (Zig-native):** Modules compiled together with the application use ergonomic Zig types and `comptime` without cross-compiler ABI guarantees.
2. **Layer B (C ABI):** External shared libraries (`.dll`, `.so`, `.dylib`) and scripting runtimes interact through `include/engine_extension.h` (`AEHostApi`, `AEPluginApi`).
3. Both layers resolve into the exact same `ServiceRegistry` and `World`.
4. All C ABI structs carry `struct_size`, `abi_major`, and `abi_minor` validated before dereferencing fields beyond the prefix.
5. Status codes use fixed-width `int32_t` (`AEStatus`) to avoid compiler-dependent enum sizes.
