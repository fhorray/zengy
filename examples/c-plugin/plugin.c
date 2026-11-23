/**
 * @file plugin.c
 * @brief Phase 3 & Phase B C11 shared library plugin against `engine_extension.h`.
 *
 * Demonstrates real two-way C <-> Zig ABI interoperability:
 * - Validates `AEHostApi.struct_size` and `AEHostApi.abi_major` on `load()`.
 * - Resolves `engine.world/1` (`AEWorldApiV1`) and `engine.events/1` (`AEEventsApiV1`).
 * - Spawns a real ECS entity and posts an event in `start()`, and despawns it in `stop()`.
 * - Frees plugin-owned state in `unload()`.
 */

#include "engine_extension.h"
#include <stdlib.h>
#include <string.h>

typedef struct ExamplePluginState {
    const AEHostApi *host;
    const AEWorldApiV1 *world_api;
    const AEEventsApiV1 *events_api;
    AEHandle spawned_entity;
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
    state->world_api = NULL;
    state->events_api = NULL;
    state->spawned_entity = 0;
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

    if (state->host && state->host->get_service) {
        const void *svc_api = NULL;
        uint32_t svc_size = 0;

        /* Resolve engine.world/1 and spawn an entity */
        AEStringView world_id = { "engine.world", 12 };
        if (state->host->get_service(state->host->host_context, world_id, 1, &svc_api, &svc_size) == AE_OK &&
            svc_size >= sizeof(AEWorldApiV1)) {
            const AEWorldApiV1 *w = (const AEWorldApiV1 *)svc_api;
            if (w->abi_major == AE_ABI_MAJOR && w->spawn) {
                state->world_api = w;
                if (w->spawn(w->world_context, &state->spawned_entity) == AE_OK) {
                    log_msg(state->host, 1, "c-plugin: spawned ECS entity");
                }
            }
        }

        /* Resolve engine.events/1 and post an event */
        AEStringView events_id = { "engine.events", 13 };
        if (state->host->get_service(state->host->host_context, events_id, 1, &svc_api, &svc_size) == AE_OK &&
            svc_size >= sizeof(AEEventsApiV1)) {
            const AEEventsApiV1 *ev = (const AEEventsApiV1 *)svc_api;
            if (ev->abi_major == AE_ABI_MAJOR && ev->post) {
                state->events_api = ev;
                AEStringView ev_name = { "c_plugin.entity_spawned", 23 };
                AEStringView ev_payload = { "from_c11", 8 };
                ev->post(ev->events_context, ev_name, ev_payload, state->spawned_entity);
            }
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
    if (state->world_api && state->world_api->despawn && state->spawned_entity != 0) {
        state->world_api->despawn(state->world_api->world_context, state->spawned_entity);
        state->spawned_entity = 0;
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
