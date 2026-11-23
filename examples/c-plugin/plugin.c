/**
 * @file plugin.c
 * @brief Phase 3 Gate Example: Pure C11 shared library plugin against `engine_extension.h`.
 *
 * Demonstrates two-way C <-> Zig ABI interoperability:
 * - Validates `AEHostApi.struct_size` and `AEHostApi.abi_major` on `load()`.
 * - Allocates plugin-owned state in `load()` and frees it in `unload()`.
 * - Logs to the Zig host via `host->log()` and probes services via `host->get_service()`.
 */

#include "engine_extension.h"
#include <stdlib.h>
#include <string.h>

typedef struct ExamplePluginState {
    const AEHostApi *host;
    int started;
    int stopped;
    uint32_t magic;
} ExamplePluginState;

static void log_msg(const AEHostApi *host, uint32_t level, const char *msg) {
    if (host && host->log) {
        AEStringView sv = { msg, strlen(msg) };
        host->log(host->host_context, level, sv);
    }
}

static AEStatus plugin_load(const AEHostApi *host, void **out_state) {
    if (!host || !out_state) {
        return AE_ERROR;
    }
    if (host->struct_size < sizeof(AEHostApi) || host->abi_major != AE_ABI_MAJOR) {
        return AE_UNSUPPORTED_ABI;
    }

    ExamplePluginState *state = (ExamplePluginState *)malloc(sizeof(ExamplePluginState));
    if (!state) {
        return AE_ERROR;
    }
    state->host = host;
    state->started = 0;
    state->stopped = 0;
    state->magic = 0x43504C47u; /* "CPLG" */

    *out_state = state;
    log_msg(host, 1, "c-plugin: loaded");
    return AE_OK;
}

static AEStatus plugin_start(void *raw_state) {
    ExamplePluginState *state = (ExamplePluginState *)raw_state;
    if (!state || state->magic != 0x43504C47u) {
        return AE_INVALID_HANDLE;
    }
    state->started = 1;

    /* Probe optional host service to verify two-way service lookup across C ABI */
    if (state->host && state->host->get_service) {
        const void *svc_api = NULL;
        uint32_t svc_size = 0;
        const char *svc_name = "engine.diagnostics";
        AEStringView id = { svc_name, strlen(svc_name) };
        AEStatus st = state->host->get_service(
            state->host->host_context,
            id,
            1,
            &svc_api,
            &svc_size
        );
        if (st == AE_OK) {
            log_msg(state->host, 1, "c-plugin: resolved engine.diagnostics/1");
        } else {
            log_msg(state->host, 1, "c-plugin: engine.diagnostics/1 not registered (ok)");
        }
    }

    log_msg(state->host, 1, "c-plugin: started");
    return AE_OK;
}

static void plugin_stop(void *raw_state) {
    ExamplePluginState *state = (ExamplePluginState *)raw_state;
    if (!state || state->magic != 0x43504C47u) {
        return;
    }
    state->stopped = 1;
    log_msg(state->host, 1, "c-plugin: stopped");
}

static void plugin_unload(void *raw_state) {
    ExamplePluginState *state = (ExamplePluginState *)raw_state;
    if (!state || state->magic != 0x43504C47u) {
        return;
    }
    log_msg(state->host, 1, "c-plugin: unloading");
    state->magic = 0;
    free(state);
}

static const AEPluginApi g_plugin_api = {
    sizeof(AEPluginApi),
    AE_ABI_MAJOR,
    AE_ABI_MINOR,
    { "community.example.c_plugin", 26 },
    plugin_load,
    plugin_start,
    plugin_stop,
    plugin_unload
};

const AEPluginApi *ae_plugin_entry(void) {
    return &g_plugin_api;
}
