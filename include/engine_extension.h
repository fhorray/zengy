#ifndef ENGINE_EXTENSION_H
#define ENGINE_EXTENSION_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define AE_ABI_MAJOR 1u
#define AE_ABI_MINOR 0u

typedef uint64_t AEHandle;

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

typedef struct AEStringView {
    const char *data;
    size_t length;
} AEStringView;

typedef struct AEHostApi {
    uint32_t struct_size;
    uint32_t abi_major;
    uint32_t abi_minor;
    void *host_context;
    void (*log)(void *host_context, uint32_t level, AEStringView message);
    AEStatus (*get_service)(
        void *host_context,
        AEStringView service_id,
        uint32_t requested_major,
        const void **out_service_api,
        uint32_t *out_api_size
    );
} AEHostApi;

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

/* Resolve this symbol from the shared library. */
typedef const AEPluginApi *(*AEPluginEntryFn)(void);
const AEPluginApi *ae_plugin_entry(void);

#ifdef __cplusplus
}
#endif

#endif /* ENGINE_EXTENSION_H */
