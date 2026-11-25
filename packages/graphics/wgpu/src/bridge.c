/* Thin C bridge between SDL3 and wgpu-native.
 *
 * Responsibilities: create the instance/adapter/device, create a surface from an SDL window, manage the
 * swapchain frame, and queue WebGPU validation errors for the Zig layer. Everything else (resources,
 * pipelines, command encoding) lives in Zig behind the neutral `graphics.gpu` contract. */
#include "bridge.h"
#include <SDL3/SDL.h>
#ifdef __APPLE__
#include <SDL3/SDL_metal.h>
#endif
#include <webgpu/webgpu.h>
#include <webgpu/wgpu.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>

struct ZWgpu {
    SDL_Window *window;
#ifdef __APPLE__
    SDL_MetalView metal_view;
#endif
    WGPUInstance instance;
    WGPUSurface surface;
    WGPUAdapter adapter;
    WGPUDevice device;
    WGPUQueue queue;
    WGPUSurfaceConfiguration config;
    WGPUTexture frame_texture;
    WGPUTextureView frame_view;
    int configured;
    atomic_bool failed;
    /* When capture is on, validation errors are queued for the Zig layer instead of latching `failed`. */
    atomic_int capture;
    atomic_int validation_pending;
    SDL_Mutex *validation_mutex;
    char validation[512];
};
static _Thread_local char last_error[512];
static void fail(const char *message) { snprintf(last_error,sizeof last_error,"%s",message); }
const char *zwgpu_error(void) { return last_error; }

/* The callback mode is AllowProcessEvents: callback storage stays alive until completion. */
typedef struct { WGPUAdapter adapter; WGPUDevice device; int done; } Request;
static void adapter_cb(WGPURequestAdapterStatus status,WGPUAdapter adapter,WGPUStringView message,void *p,void *unused) {
    (void)unused; (void)message;
    Request *r=p;
    if (status==WGPURequestAdapterStatus_Success) r->adapter=adapter;
    else if (adapter) wgpuAdapterRelease(adapter);
    r->done=1;
}
static void device_cb(WGPURequestDeviceStatus status,WGPUDevice device,WGPUStringView message,void *p,void *unused) {
    (void)unused; (void)message;
    Request *r=p;
    if (status==WGPURequestDeviceStatus_Success) r->device=device;
    else if (device) wgpuDeviceRelease(device);
    r->done=1;
}
static void await_request(WGPUInstance instance, Request *request) {
    /* v27.0.4.1 completes these requests synchronously. Keep processing events
       for compatible builds that defer AllowProcessEvents callbacks. */
    while (!request->done) { wgpuInstanceProcessEvents(instance); if (!request->done) SDL_Delay(1); }
}
/* Do not retain a pointer into the Zig resource in asynchronous callbacks. */
static void error_cb(WGPUDevice const *device,WGPUErrorType type,WGPUStringView message,void *p,void *unused) {
    (void)device; (void)unused;
    ZWgpu *g=p;
    size_t n=message.length>sizeof g->validation-1?sizeof g->validation-1:message.length;
    if (type==WGPUErrorType_Validation && atomic_load(&g->capture)) {
        SDL_LockMutex(g->validation_mutex);
        if (!atomic_load(&g->validation_pending)) {
            if (message.data) memcpy(g->validation,message.data,n);
            else n=0;
            g->validation[n]=0;
            atomic_store(&g->validation_pending,1);
        }
        SDL_UnlockMutex(g->validation_mutex);
    } else atomic_store(&g->failed,1);
    SDL_LogError(SDL_LOG_CATEGORY_RENDER,"WebGPU error: %.*s",(int)n,message.data?message.data:"");
}
static void lost_cb(WGPUDevice const *device,WGPUDeviceLostReason reason,WGPUStringView message,void *p,void *unused) {
    (void)device; (void)unused;
    ZWgpu *g=p;
    if (reason==WGPUDeviceLostReason_Destroyed) return;
    atomic_store(&g->failed,1);
    size_t n=message.length>511?511:message.length;
    SDL_LogError(SDL_LOG_CATEGORY_RENDER,"WebGPU device lost: %.*s",(int)n,message.data?message.data:"");
}

static WGPUSurface make_surface(ZWgpu *g) {
    SDL_PropertiesID props=SDL_GetWindowProperties(g->window);
#if defined(_WIN32)
    WGPUSurfaceSourceWindowsHWND src={0};
    src.chain.sType=WGPUSType_SurfaceSourceWindowsHWND;
    src.hwnd=SDL_GetPointerProperty(props,SDL_PROP_WINDOW_WIN32_HWND_POINTER,NULL);
    src.hinstance=SDL_GetPointerProperty(props,SDL_PROP_WINDOW_WIN32_INSTANCE_POINTER,NULL);
    if (!src.hwnd || !src.hinstance) return NULL;
    return wgpuInstanceCreateSurface(g->instance,&(WGPUSurfaceDescriptor){.nextInChain=&src.chain});
#elif defined(__APPLE__)
    (void)props;
    g->metal_view=SDL_Metal_CreateView(g->window);
    if (!g->metal_view) return NULL;
    WGPUSurfaceSourceMetalLayer src={0};
    src.chain.sType=WGPUSType_SurfaceSourceMetalLayer;
    src.layer=SDL_Metal_GetLayer(g->metal_view);
    if (!src.layer) return NULL;
    return wgpuInstanceCreateSurface(g->instance,&(WGPUSurfaceDescriptor){.nextInChain=&src.chain});
#elif defined(__linux__)
    void *display=SDL_GetPointerProperty(props,SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER,NULL);
    void *surface=SDL_GetPointerProperty(props,SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER,NULL);
    if (display && surface) {
        WGPUSurfaceSourceWaylandSurface src={0}; src.chain.sType=WGPUSType_SurfaceSourceWaylandSurface;
        src.display=display; src.surface=surface;
        return wgpuInstanceCreateSurface(g->instance,&(WGPUSurfaceDescriptor){.nextInChain=&src.chain});
    }
    display=SDL_GetPointerProperty(props,SDL_PROP_WINDOW_X11_DISPLAY_POINTER,NULL);
    int64_t window=SDL_GetNumberProperty(props,SDL_PROP_WINDOW_X11_WINDOW_NUMBER,0);
    if (display && window>0) {
        WGPUSurfaceSourceXlibWindow src={0}; src.chain.sType=WGPUSType_SurfaceSourceXlibWindow;
        src.display=display; src.window=(uint64_t)window;
        return wgpuInstanceCreateSurface(g->instance,&(WGPUSurfaceDescriptor){.nextInChain=&src.chain});
    }
    return NULL;
#else
    (void)props; return NULL;
#endif
}
static WGPUTextureFormat choose_format(const WGPUSurfaceCapabilities *caps) {
    /* Prefer non-sRGB to preserve the legacy 2D color contract. */
    for (size_t i=0;i<caps->formatCount;i++) if (caps->formats[i]==WGPUTextureFormat_BGRA8Unorm || caps->formats[i]==WGPUTextureFormat_RGBA8Unorm) return caps->formats[i];
    for (size_t i=0;i<caps->formatCount;i++) if (caps->formats[i]==WGPUTextureFormat_BGRA8UnormSrgb || caps->formats[i]==WGPUTextureFormat_RGBA8UnormSrgb) return caps->formats[i];
    return WGPUTextureFormat_Undefined;
}

/* Optional features the engine can use. Only those the adapter reports are requested. */
static const WGPUFeatureName wanted_features[] = {
    WGPUFeatureName_TimestampQuery, WGPUFeatureName_Float32Filterable, WGPUFeatureName_Float32Blendable,
    WGPUFeatureName_RG11B10UfloatRenderable, WGPUFeatureName_Depth32FloatStencil8, WGPUFeatureName_ShaderF16,
    WGPUFeatureName_Subgroups, WGPUFeatureName_IndirectFirstInstance, WGPUFeatureName_BGRA8UnormStorage,
    WGPUFeatureName_DualSourceBlending, WGPUFeatureName_TextureCompressionBC, WGPUFeatureName_TextureCompressionETC2,
    WGPUFeatureName_TextureCompressionASTC,
};

void zwgpu_destroy(ZWgpu *g);

static ZWgpu *create_impl(void *window,int headless) {
    if (!headless && !window) { fail("Missing window"); return NULL; }
    ZWgpu *g=calloc(1,sizeof *g); if (!g) { fail("Out of memory"); return NULL; }
    atomic_init(&g->failed,0); atomic_init(&g->capture,0); atomic_init(&g->validation_pending,0); g->window=window;
    g->validation_mutex=SDL_CreateMutex();
    if (!g->validation_mutex) { fail("Validation mutex creation failed"); goto bad; }
    g->instance=wgpuCreateInstance(NULL); if (!g->instance) { fail("wgpuCreateInstance failed"); goto bad; }
    if (!headless) { g->surface=make_surface(g); if (!g->surface) { fail("Unsupported SDL native window or surface creation failed"); goto bad; } }
    Request req={0};
    WGPURequestAdapterOptions adapter_options={.compatibleSurface=g->surface,.powerPreference=WGPUPowerPreference_HighPerformance};
    const char *backend=getenv("ZENGY_WGPU_BACKEND");
    if (backend && *backend) {
        if (!strcmp(backend,"vulkan")) adapter_options.backendType=WGPUBackendType_Vulkan;
        else if (!strcmp(backend,"dx12")) adapter_options.backendType=WGPUBackendType_D3D12;
        else if (!strcmp(backend,"metal")) adapter_options.backendType=WGPUBackendType_Metal;
        else if (strcmp(backend,"auto")) { fail("Invalid ZENGY_WGPU_BACKEND"); goto bad; }
    }
    wgpuInstanceRequestAdapter(g->instance,&adapter_options,(WGPURequestAdapterCallbackInfo){.mode=WGPUCallbackMode_AllowProcessEvents,.callback=adapter_cb,.userdata1=&req});
    await_request(g->instance,&req); g->adapter=req.adapter;
    if (!g->adapter) { fail("No compatible WebGPU adapter"); goto bad; }
    /* Request every optional feature the adapter has and the adapter's own limits, so the
       engine can query real capabilities from the device instead of assuming defaults. */
    WGPUFeatureName enabled[sizeof wanted_features/sizeof wanted_features[0]]; size_t enabled_count=0;
    for (size_t i=0;i<sizeof wanted_features/sizeof wanted_features[0];i++) if (wgpuAdapterHasFeature(g->adapter,wanted_features[i])) enabled[enabled_count++]=wanted_features[i];
    WGPULimits limits={0};
    int have_limits=wgpuAdapterGetLimits(g->adapter,&limits)==WGPUStatus_Success;
    req=(Request){0}; WGPUDeviceDescriptor device_desc={0};
    device_desc.requiredFeatureCount=enabled_count; device_desc.requiredFeatures=enabled;
    if (have_limits) device_desc.requiredLimits=&limits;
    device_desc.uncapturedErrorCallbackInfo=(WGPUUncapturedErrorCallbackInfo){.callback=error_cb,.userdata1=g};
    device_desc.deviceLostCallbackInfo=(WGPUDeviceLostCallbackInfo){.mode=WGPUCallbackMode_AllowProcessEvents,.callback=lost_cb,.userdata1=g};
    wgpuAdapterRequestDevice(g->adapter,&device_desc,(WGPURequestDeviceCallbackInfo){.mode=WGPUCallbackMode_AllowProcessEvents,.callback=device_cb,.userdata1=&req});
    await_request(g->instance,&req); g->device=req.device;
    if (!g->device) { fail("wgpuAdapterRequestDevice failed"); goto bad; }
    g->queue=wgpuDeviceGetQueue(g->device); if (!g->queue) { fail("Missing queue"); goto bad; }
    if (headless) return g;
    WGPUSurfaceCapabilities caps={0};
    if (wgpuSurfaceGetCapabilities(g->surface,g->adapter,&caps)!=WGPUStatus_Success) { fail("Surface capabilities unavailable"); goto bad; }
    if (!caps.formatCount || !caps.alphaModeCount || !(caps.usages&WGPUTextureUsage_RenderAttachment)) { wgpuSurfaceCapabilitiesFreeMembers(caps); fail("Unsupported surface capabilities"); goto bad; }
    WGPUTextureFormat format=choose_format(&caps);
    if (format==WGPUTextureFormat_Undefined) { wgpuSurfaceCapabilitiesFreeMembers(caps); fail("No supported 8-bit surface format"); goto bad; }
    WGPUTextureUsage usage=WGPUTextureUsage_RenderAttachment;
    if (caps.usages&WGPUTextureUsage_CopySrc) usage|=WGPUTextureUsage_CopySrc;
    g->config=(WGPUSurfaceConfiguration){.device=g->device,.format=format,.usage=usage,.presentMode=WGPUPresentMode_Fifo,.alphaMode=caps.alphaModes[0]};
    wgpuSurfaceCapabilitiesFreeMembers(caps);
    return g;
bad: zwgpu_destroy(g); return NULL;
}
ZWgpu *zwgpu_create(void *window) { return create_impl(window,0); }
ZWgpu *zwgpu_create_headless(void) { return create_impl(NULL,1); }

void zwgpu_destroy(ZWgpu *g) {
    if (!g) return;
    if (g->device && !atomic_load(&g->failed)) wgpuDevicePoll(g->device,1,NULL);
    if (g->frame_view) wgpuTextureViewRelease(g->frame_view);
    if (g->frame_texture) wgpuTextureRelease(g->frame_texture);
    if (g->configured) wgpuSurfaceUnconfigure(g->surface);
    if (g->queue) wgpuQueueRelease(g->queue);
    if (g->device) { wgpuDeviceDestroy(g->device); wgpuDeviceRelease(g->device); }
    if (g->instance) wgpuInstanceProcessEvents(g->instance);
    if (g->adapter) wgpuAdapterRelease(g->adapter);
    if (g->surface) wgpuSurfaceRelease(g->surface);
#ifdef __APPLE__
    if (g->metal_view) SDL_Metal_DestroyView(g->metal_view);
#endif
    if (g->instance) wgpuInstanceRelease(g->instance);
    if (g->validation_mutex) SDL_DestroyMutex(g->validation_mutex);
    free(g);
}

void *zwgpu_native_device(ZWgpu *g) { return g?(void*)g->device:NULL; }
void *zwgpu_native_queue(ZWgpu *g) { return g?(void*)g->queue:NULL; }
void *zwgpu_native_adapter(ZWgpu *g) { return g?(void*)g->adapter:NULL; }
void *zwgpu_native_instance(ZWgpu *g) { return g?(void*)g->instance:NULL; }
uint32_t zwgpu_surface_format(ZWgpu *g) { return g?(uint32_t)g->config.format:0; }
int zwgpu_surface_copy_src(ZWgpu *g) { return g && (g->config.usage&WGPUTextureUsage_CopySrc)!=0; }
int zwgpu_failed(ZWgpu *g) { return !g || atomic_load(&g->failed); }

/* Drawable size in physical pixels, from the same SDL call the swapchain uses. Returns 0 when minimized. */
int zwgpu_drawable_size(ZWgpu *g,uint32_t *width,uint32_t *height) {
    *width=0; *height=0;
    if (!g || !g->window) return 0;
    int w=0,h=0;
    if (!SDL_GetWindowSizeInPixels(g->window,&w,&h) || w<=0 || h<=0 || (SDL_GetWindowFlags(g->window)&SDL_WINDOW_MINIMIZED)) return 0;
    *width=(uint32_t)w; *height=(uint32_t)h;
    return 1;
}

/* Swapchain frame API used by the neutral command submission path. */
int zwgpu_swapchain_acquire(ZWgpu *g,void **view_out,uint32_t *width,uint32_t *height) {
    if (!g || !g->surface || !view_out || atomic_load(&g->failed)) { fail("Invalid swapchain request"); return 0; }
    if (g->frame_texture) { fail("Previous swapchain frame was not presented"); return 0; }
    wgpuDevicePoll(g->device,0,NULL);
    uint32_t w=0,h=0;
    if (!zwgpu_drawable_size(g,&w,&h)) return 2;
    if (!g->configured || g->config.width!=w || g->config.height!=h) {
        g->config.width=w; g->config.height=h;
        wgpuSurfaceConfigure(g->surface,&g->config); g->configured=1;
        if (atomic_load(&g->failed)) { fail("Surface configuration failed"); return 0; }
    }
    WGPUSurfaceTexture st={0}; wgpuSurfaceGetCurrentTexture(g->surface,&st);
    if (st.status!=WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal && st.status!=WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal) {
        if (st.texture) wgpuTextureRelease(st.texture);
        if (st.status==WGPUSurfaceGetCurrentTextureStatus_Timeout) return 2;
        if (st.status==WGPUSurfaceGetCurrentTextureStatus_Outdated || st.status==WGPUSurfaceGetCurrentTextureStatus_Lost) { wgpuSurfaceUnconfigure(g->surface); g->configured=0; return 2; }
        fail("Surface acquisition failed"); return 0;
    }
    if (!st.texture) { fail("Missing surface texture"); return 0; }
    WGPUTextureView view=wgpuTextureCreateView(st.texture,NULL);
    if (!view) { wgpuTextureRelease(st.texture); fail("Could not create swapchain view"); return 0; }
    g->frame_texture=st.texture; g->frame_view=view;
    *view_out=view; *width=g->config.width; *height=g->config.height;
    return 1;
}
/* Texture of the frame acquired by zwgpu_swapchain_acquire, or NULL. Valid until the frame is presented. */
void *zwgpu_frame_texture(ZWgpu *g,uint32_t *width,uint32_t *height) {
    if (!g || !g->frame_texture) { *width=0; *height=0; return NULL; }
    *width=g->config.width; *height=g->config.height;
    return g->frame_texture;
}
/* Presents (when `present` is non-zero) and releases the acquired frame. Safe when none is acquired. */
int zwgpu_swapchain_present(ZWgpu *g,int present) {
    if (!g || !g->frame_texture) return 1;
    int ok=1;
    if (present) ok=wgpuSurfacePresent(g->surface)==WGPUStatus_Success && !atomic_load(&g->failed);
    wgpuTextureViewRelease(g->frame_view); wgpuTextureRelease(g->frame_texture);
    g->frame_view=NULL; g->frame_texture=NULL;
    if (!ok) fail("Present failed");
    return ok;
}

/* Validation capture: lets the Zig resource layer turn WebGPU validation errors into per-call errors. */
void zwgpu_set_validation_capture(ZWgpu *g,int enabled) { if (g) atomic_store(&g->capture,enabled); }
/* Optionally polls the device, then returns 1 and copies the message if a validation error is queued. */
int zwgpu_take_validation(ZWgpu *g,char *out,size_t capacity,int flush) {
    if (!g || !out || !capacity) return 0;
    if (flush && g->device && !atomic_load(&g->failed)) wgpuDevicePoll(g->device,0,NULL);
    SDL_LockMutex(g->validation_mutex);
    int pending=atomic_exchange(&g->validation_pending,0);
    if (pending) snprintf(out,capacity,"%s",g->validation);
    SDL_UnlockMutex(g->validation_mutex);
    return pending;
}
