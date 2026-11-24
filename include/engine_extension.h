/**
 * @file engine_extension.h
 * @brief Versioned C ABI boundary for external native plugins and scripting runtimes.
 *
 * This header defines the stable binary contract (Layer B) between the Zig engine host
 * and dynamically loaded shared libraries (.so, .dylib, .dll).
 *
 * ABI Rules:
 * 1. `struct_size` and `abi_major` MUST be validated before dereferencing fields beyond the prefix.
 * 2. `abi_minor` increments may only append fields at the end without altering existing semantics.
 * 3. `AEStringView` is NOT guaranteed to be NUL-terminated; always use `length`.
 * 4. Memory ownership never crosses the ABI implicitly: the host frees host allocations,
 *    and plugins allocate/free their own `state` inside `load()` and `unload()`.
 * 5. No C++ exceptions, Zig panics, or longjmp may cross this boundary.
 */

#ifndef ENGINE_EXTENSION_H
#define ENGINE_EXTENSION_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Current major ABI version. Mismatches are rejected before invoking any plugin callback. */
#define AE_ABI_MAJOR 1u
/** Current minor ABI version. Backward-compatible additions only. */
#define AE_ABI_MINOR 0u

/** Opaque generational handle used across the C ABI boundary. */
typedef uint64_t AEHandle;

/**
 * Fixed-width status code (int32_t) to avoid compiler-dependent C enum sizing
 * differences across toolchains and platforms.
 */
typedef int32_t AEStatus;
enum {
    AE_OK = 0,
    AE_ERROR = 1,
    AE_UNSUPPORTED_ABI = 2,
    AE_MISSING_SERVICE = 3,
    AE_INVALID_HANDLE = 4,
    AE_PERMISSION_DENIED = 5,
    AE_BUSY = 6
};

/**
 * Non-owning UTF-8 string slice passed across the C ABI.
 * Not guaranteed to be NUL-terminated; consumers must respect `length`.
 */
typedef struct AEStringView {
    const char *data;
    size_t length;
} AEStringView;

/**
 * Stable C ABI v1 function table for ECS World operations (`engine.world/1`).
 */
typedef struct AEWorldApiV1 {
    uint32_t struct_size;
    uint32_t abi_major;
    void *world_context;
    AEStatus (*spawn)(void *world_context, AEHandle *out_entity);
    AEStatus (*despawn)(void *world_context, AEHandle entity);
    uint32_t (*is_alive)(void *world_context, AEHandle entity);
    size_t (*entity_count)(void *world_context);
} AEWorldApiV1;

/**
 * Stable C ABI v1 function table for EventBus operations (`engine.events/1`).
 */
typedef struct AEEventsApiV1 {
    uint32_t struct_size;
    uint32_t abi_major;
    void *events_context;
    AEStatus (*post)(void *events_context, AEStringView name, AEStringView payload, AEHandle entity);
} AEEventsApiV1;

/** Reflection field type tags matching `engine.reflection.FieldType`. */
enum {
    AE_FIELD_BOOL = 0,
    AE_FIELD_I32 = 1,
    AE_FIELD_I64 = 2,
    AE_FIELD_U32 = 3,
    AE_FIELD_U64 = 4,
    AE_FIELD_F32 = 5,
    AE_FIELD_F64 = 6,
    AE_FIELD_VEC2 = 7,
    AE_FIELD_VEC3 = 8,
    AE_FIELD_VEC4 = 9,
    AE_FIELD_ENUM_U32 = 10,
    AE_FIELD_ENTITY_REF = 11,
    AE_FIELD_ASSET_REF = 12,
    AE_FIELD_FIXED_STR64 = 13
};

/** Reflection storage policy tags matching `engine.reflection.StoragePolicy`. */
enum {
    AE_STORAGE_BLITTABLE = 0,
    AE_STORAGE_MANAGED_HANDLE = 1,
    AE_STORAGE_BLOB = 2
};

/** Field descriptor passed to `AEReflectionApiV1.register_component_schema`. */
typedef struct AEFieldDescriptor {
    AEStringView name;
    uint32_t field_type;
} AEFieldDescriptor;

/**
 * Stable C ABI v1 function table for component schema registration (`engine.reflection/1`).
 * Schemas registered with `owner_plugin_id` are automatically removed when that plugin unloads.
 */
typedef struct AEReflectionApiV1 {
    uint32_t struct_size;
    uint32_t abi_major;
    void *reflection_context;
    AEStatus (*register_component_schema)(
        void *reflection_context,
        AEStringView owner_plugin_id,
        AEStringView namespace_name,
        AEStringView type_name,
        uint32_t version,
        uint32_t storage_policy,
        const AEFieldDescriptor *fields,
        size_t field_count,
        uint64_t *out_schema_id
    );
} AEReflectionApiV1;

/**
 * Host capability table passed to `AEPluginApi.load()`.
 * Allows plugins to log diagnostics and resolve registered engine services.
 */
typedef struct AEHostApi {
    uint32_t struct_size;
    uint32_t abi_major;
    uint32_t abi_minor;
    void *host_context;
    /** Emits a structured log message into the host's Diagnostics ring buffer. */
    void (*log)(void *host_context, uint32_t level, AEStringView message);
    /** Resolves a service API pointer by capability ID and major version. */
    AEStatus (*get_service)(
        void *host_context,
        AEStringView service_id,
        uint32_t requested_major,
        const void **out_service_api,
        uint32_t *out_api_size
    );
} AEHostApi;

/**
 * Plugin entrypoint descriptor exported by external shared libraries.
 * Lifecycle order: load() -> start() -> stop() -> unload().
 */
typedef struct AEPluginApi {
    uint32_t struct_size;
    uint32_t abi_major;
    uint32_t abi_minor;
    AEStringView plugin_id;
    AEStatus (*load)(const AEHostApi *host, void **out_state);
    AEStatus (*start)(void *state);
    void (*stop)(void *state);
    void (*unload)(void *state);
} AEPluginApi;

#if defined(_WIN32) || defined(__CYGWIN__)
#define AE_EXPORT __declspec(dllexport)
#else
#define AE_EXPORT __attribute__((visibility("default")))
#endif

/** Function signature for the required shared library symbol `ae_plugin_entry`. */
typedef const AEPluginApi *(*AEPluginEntryFn)(void);
AE_EXPORT const AEPluginApi *ae_plugin_entry(void);

#ifdef __cplusplus
}
#endif

#endif /* ENGINE_EXTENSION_H */
