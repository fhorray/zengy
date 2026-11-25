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
/* CPU helper used for rect clipping; returns 0 or 6 vertices. */
size_t zwgpu_rect(ZWgpuVertex out[6], const float rect[4], const float clip[4], const float color[4], float width, float height);
#ifdef __cplusplus
}
#endif
#endif
