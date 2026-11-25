#ifndef ZENGY_WGPU_BRIDGE_H
#define ZENGY_WGPU_BRIDGE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct ZWgpu ZWgpu;
typedef struct { float x, y, r, g, b, a; } ZWgpuVertex;
/* Vertex coordinates are WebGPU NDC. Return 0 for failure, 1 for submitted, 2 for skipped. */
ZWgpu *zwgpu_create(void *sdl_window, const char *wgsl, size_t wgsl_size);
void zwgpu_destroy(ZWgpu *gpu);
int zwgpu_draw(ZWgpu *gpu, const ZWgpuVertex *vertices, size_t count, const float clear[4]);
void zwgpu_logical_size(ZWgpu *gpu, int *width, int *height);
const char *zwgpu_backend(const ZWgpu *gpu);
const char *zwgpu_error(void);
/* Device without a window or surface: used by GPU tests and tools. Never presents. */
ZWgpu *zwgpu_create_headless(void);
/* Native handles for the Zig resource layer. Ownership stays with the bridge. */
void *zwgpu_native_device(ZWgpu *gpu);
void *zwgpu_native_queue(ZWgpu *gpu);
void *zwgpu_native_adapter(ZWgpu *gpu);
void *zwgpu_native_instance(ZWgpu *gpu);
/* WGPUTextureFormat of the configured surface (0 for headless). */
uint32_t zwgpu_surface_format(ZWgpu *gpu);
int zwgpu_failed(ZWgpu *gpu);
/* While enabled, validation errors are queued (see zwgpu_take_validation) instead of failing the device. */
void zwgpu_set_validation_capture(ZWgpu *gpu, int enabled);
/* `flush` polls the device first so asynchronous errors are visible; skip it on hot paths. */
int zwgpu_take_validation(ZWgpu *gpu, char *out, size_t capacity, int flush);
/* Swapchain frame: acquire returns 0 failure, 1 acquired, 2 skip this frame (minimized/outdated). */
int zwgpu_swapchain_acquire(ZWgpu *gpu, void **texture_view, uint32_t *width, uint32_t *height);
int zwgpu_swapchain_present(ZWgpu *gpu, int present);
/* CPU helper used for rect clipping; returns 0 or 6 vertices. */
size_t zwgpu_rect(ZWgpuVertex out[6], const float rect[4], const float clip[4], const float color[4], float width, float height);
#ifdef __cplusplus
}
#endif
#endif
