#ifndef ZENGY_WGPU_BRIDGE_H
#define ZENGY_WGPU_BRIDGE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct ZWgpu ZWgpu;

/* Windowed device: instance, adapter, device, queue and an SDL surface. Returns NULL on failure (see zwgpu_error). */
ZWgpu *zwgpu_create(void *sdl_window);
/* Device without a window or surface: used by GPU tests and tools. Never presents. */
ZWgpu *zwgpu_create_headless(void);
void zwgpu_destroy(ZWgpu *gpu);
const char *zwgpu_error(void);

/* Native handles for the Zig resource layer. Ownership stays with the bridge. */
void *zwgpu_native_device(ZWgpu *gpu);
void *zwgpu_native_queue(ZWgpu *gpu);
void *zwgpu_native_adapter(ZWgpu *gpu);
void *zwgpu_native_instance(ZWgpu *gpu);
/* WGPUTextureFormat of the configured surface (0 for headless). */
uint32_t zwgpu_surface_format(ZWgpu *gpu);
int zwgpu_failed(ZWgpu *gpu);
int zwgpu_surface_copy_src(ZWgpu *gpu);

/* Drawable size in physical pixels. Returns 0 when minimized or headless. */
int zwgpu_drawable_size(ZWgpu *gpu, uint32_t *width, uint32_t *height);
/* Swapchain frame: acquire returns 0 failure, 1 acquired, 2 skip this frame (minimized/outdated). */
int zwgpu_swapchain_acquire(ZWgpu *gpu, void **texture_view, uint32_t *width, uint32_t *height);
int zwgpu_swapchain_present(ZWgpu *gpu, int present);
/* Texture of the acquired frame (NULL if none), with its size. Valid until the frame is presented. */
void *zwgpu_frame_texture(ZWgpu *gpu, uint32_t *width, uint32_t *height);

/* While enabled, validation errors are queued (see zwgpu_take_validation) instead of failing the device. */
void zwgpu_set_validation_capture(ZWgpu *gpu, int enabled);
/* `flush` polls the device first so asynchronous errors are visible; skip it on hot paths. */
int zwgpu_take_validation(ZWgpu *gpu, char *out, size_t capacity, int flush);

#ifdef __cplusplus
}
#endif
#endif
