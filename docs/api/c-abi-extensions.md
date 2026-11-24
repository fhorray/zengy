# C ABI Extensions & Native Plugins (`include/engine_extension.h`)

External plugins compiled in C, C++, Rust, or Zig (as `.so`, `.dylib`, or `.dll`) interact with the host through the versioned C ABI in [`include/engine_extension.h`](../../include/engine_extension.h) and [`src/core/abi.zig`](../../src/core/abi.zig).

## 1. ABI Contract Overview

- **Current Version:** `AE_ABI_MAJOR = 1`, `AE_ABI_MINOR = 0`.
- **Status Codes (`AEStatus` = `int32_t`):**
  - `AE_OK = 0`
  - `AE_ERROR = 1`
  - `AE_UNSUPPORTED_ABI = 2`
  - `AE_MISSING_SERVICE = 3`
  - `AE_INVALID_HANDLE = 4`
  - `AE_PERMISSION_DENIED = 5`
  - `AE_BUSY = 6`
- **String Views (`AEStringView`):** `{ const char *data; size_t length; }` — **not** NUL-terminated.

## 2. Writing a C11 Plugin

Every shared library plugin must export `const AEPluginApi *ae_plugin_entry(void)`:

```c
#include "engine_extension.h"
#include <stdlib.h>

typedef struct MyState {
    const AEHostApi *host;
} MyState;

static AEStatus on_load(const AEHostApi *host, void **out_state) {
    if (!host || host->struct_size < sizeof(AEHostApi) || host->abi_major != AE_ABI_MAJOR) {
        return AE_UNSUPPORTED_ABI;
    }
    MyState *st = (MyState *)malloc(sizeof(MyState));
    if (!st) return AE_ERROR;
    st->host = host;
    *out_state = st;

    AEStringView msg = { "my_plugin: loaded", 17 };
    host->log(host->host_context, 1, msg);
    return AE_OK;
}

static AEStatus on_start(void *state) { (void)state; return AE_OK; }
static void on_stop(void *state) { (void)state; }
static void on_unload(void *state) { free(state); }

static const AEPluginApi g_api = {
    sizeof(AEPluginApi),
    AE_ABI_MAJOR,
    AE_ABI_MINOR,
    { "community.my_plugin", 19 },
    on_load,
    on_start,
    on_stop,
    on_unload
};

const AEPluginApi *ae_plugin_entry(void) {
    return &g_api;
}
```

## 3. Loading Plugins from the Zig Host

```zig
const host = try app.ensurePluginHost();
const handle = try host.loadSharedLibrary("zig-out/lib/libc_plugin.so");
try std.testing.expectEqual(engine.abi.AEStatus.ok, host.startPlugin(handle));

// Later, when unloading:
_ = host.unloadPlugin(handle);
// Any subsequent call with `handle` returns AEStatus.invalid_handle.
```

> **Important (Linux/POSIX):** Host executables that load `libc`-linked C shared libraries via `PluginHost.loadSharedLibrary()` must set `.link_libc = true` in `build.zig` so `dlopen` performs full dynamic relocations.

## 4. Reflection Schema Registration (`engine.reflection/1`)

Plugins can resolve `engine.reflection` (major `1`, `AEReflectionApiV1`) via `host->get_service` and call `register_component_schema` with `AEFieldDescriptor` entries (`AE_FIELD_*` and `AE_STORAGE_*`). Schemas registered with `owner_plugin_id` are automatically unregistered when `unloadPlugin()` runs.

## 5. Ownership & Safety Rules

1. `struct_size` and `abi_major` are validated before dereferencing any fields beyond the prefix.
2. Host allocations are freed only by the host; plugin `state` is allocated in `load()` and freed in `unload()`.
3. On `unloadPlugin()`, the host revokes all `EventBus` subscriptions, `ServiceRegistry` entries, and `TypeRegistry` schemas owned by that plugin before calling `stop() -> unload()` and closing the dynamic library.
4. `PluginHandle` includes a generation counter, preventing use-after-unload.
