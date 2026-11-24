---
name: zigeng-c-abi-and-ffi
description: >-
  Rules and verification steps for the versioned C ABI (include/engine_extension.h)
  and dynamic native plugins (.dll/.so/.dylib). Use when editing include/engine_extension.h,
  PluginHost, examples/c-plugin/, or native plugin boundaries.
---

# C ABI & Native Plugin Boundaries (`include/engine_extension.h`)

`include/engine_extension.h` defines the stable binary contract (`AE_ABI_MAJOR` = 1, `AE_ABI_MINOR` = 0) between the Zig host and dynamically loaded plugins (`.dll`, `.so`, `.dylib`).

## Mandatory ABI Rules

1. **Struct versioning**: Always check `struct_size` and `abi_major` before dereferencing fields beyond the prefix.
2. **Backward compatibility**: Minor bumps (`AE_ABI_MINOR`) may only append fields at the end of structs without changing existing field offsets or semantics.
3. **Strings (`AEStringView`)**: Not guaranteed to be NUL-terminated; always read `length` bytes.
4. **Strict ownership**: Memory ownership never crosses the ABI implicitly. The host frees host allocations; plugins allocate and free their own `state` inside `load()` and `unload()`.
5. **No unwinding across ABI**: Never allow C++ exceptions, Zig panics, or `longjmp` to cross a C ABI function boundary. Return `AEStatus` (`int32_t`) codes (`AE_OK`, `AE_ERROR`, `AE_UNSUPPORTED_ABI`, etc.) instead of C `enum` types whose ABI width varies by compiler.

## Verification

- `examples/c-plugin/plugin.c` is built as a C11 shared library with `-std=c11 -Wall -Wextra -Werror` in `build.zig` (`c_plugin`).
- After editing `include/engine_extension.h` or `PluginHost`, run `zig build test --summary all` (which exercises the C ABI and dynamic plugin tests) and confirm zero warnings/errors on `c_plugin`.
- Remember that `release.yml` bundles `include/engine_extension.h` into every platform release archive; keep the header self-contained with only `<stddef.h>` and `<stdint.h>`.
