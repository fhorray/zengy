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
#include <math.h>
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
    WGPURenderPipeline pipeline;
    WGPUBuffer vertices;
    uint64_t capacity;
    WGPUSurfaceConfiguration config;
    WGPUTexture frame_texture;
    WGPUTextureView frame_view;
    int configured;
    atomic_bool failed;
    /* When capture is on, validation errors are queued for the Zig layer instead of latching `failed`. */
    atomic_int capture;
    atomic_int validation_pending;
    char validation[512];
    const char *backend;
};
static _Thread_local char last_error[512];
static void fail(const char *message) { snprintf(last_error,sizeof last_error,"%s",message); }
const char *zwgpu_error(void) { return last_error; }
const char *zwgpu_backend(const ZWgpu *g) { return g ? g->backend : "unavailable"; }
static WGPUStringView sv(const char *s) { return (WGPUStringView){s,strlen(s)}; }

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
        if (!atomic_load(&g->validation_pending)) {
            if (message.data) memcpy(g->validation,message.data,n);
            g->validation[n]=0;
            atomic_store(&g->validation_pending,1);
        }
    } else atomic_store(&g->failed,1);
    SDL_LogError(SDL_LOG_CATEGORY_RENDER,"WebGPU error: %.*s",(int)n,message.data?message.data:"");
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
    return caps->formats[0];
}
static int make_pipeline(ZWgpu *g,const char *source,size_t length) {
    WGPUShaderSourceWGSL wgsl={0}; wgsl.chain.sType=WGPUSType_ShaderSourceWGSL;
    wgsl.code=(WGPUStringView){source,length};
    WGPUShaderModule shader=wgpuDeviceCreateShaderModule(g->device,&(WGPUShaderModuleDescriptor){.nextInChain=&wgsl.chain});
    if (!shader) return 0;
    WGPUVertexAttribute attrs[2]={ {.format=WGPUVertexFormat_Float32x2,.offset=0,.shaderLocation=0}, {.format=WGPUVertexFormat_Float32x4,.offset=8,.shaderLocation=1} };
    WGPUVertexBufferLayout vb={.arrayStride=sizeof(ZWgpuVertex),.stepMode=WGPUVertexStepMode_Vertex,.attributeCount=2,.attributes=attrs};
    WGPUBlendState blend={.color={.operation=WGPUBlendOperation_Add,.srcFactor=WGPUBlendFactor_SrcAlpha,.dstFactor=WGPUBlendFactor_OneMinusSrcAlpha},.alpha={.operation=WGPUBlendOperation_Add,.srcFactor=WGPUBlendFactor_One,.dstFactor=WGPUBlendFactor_OneMinusSrcAlpha}};
    WGPUColorTargetState target={.format=g->config.format,.blend=&blend,.writeMask=WGPUColorWriteMask_All};
    WGPUFragmentState fs={.module=shader,.entryPoint=sv("fs_main"),.targetCount=1,.targets=&target};
    WGPURenderPipelineDescriptor desc={0}; desc.label=sv("zengy color pipeline");
    desc.vertex=(WGPUVertexState){.module=shader,.entryPoint=sv("vs_main"),.bufferCount=1,.buffers=&vb};
    desc.fragment=&fs; desc.primitive.topology=WGPUPrimitiveTopology_TriangleList;
    desc.primitive.frontFace=WGPUFrontFace_CCW; desc.primitive.cullMode=WGPUCullMode_None;
    desc.multisample.count=1; desc.multisample.mask=UINT32_MAX;
    g->pipeline=wgpuDeviceCreateRenderPipeline(g->device,&desc);
    wgpuShaderModuleRelease(shader);
    wgpuDevicePoll(g->device,0,NULL);
    return g->pipeline && !atomic_load(&g->failed) && !atomic_load(&g->validation_pending);
}
void zwgpu_destroy(ZWgpu *g);
/* Optional features the engine can use. Only those the adapter reports are requested. */
static const WGPUFeatureName wanted_features[] = {
    WGPUFeatureName_TimestampQuery, WGPUFeatureName_Float32Filterable, WGPUFeatureName_Float32Blendable,
    WGPUFeatureName_RG11B10UfloatRenderable, WGPUFeatureName_Depth32FloatStencil8, WGPUFeatureName_ShaderF16,
    WGPUFeatureName_Subgroups, WGPUFeatureName_IndirectFirstInstance, WGPUFeatureName_BGRA8UnormStorage,
    WGPUFeatureName_DualSourceBlending, WGPUFeatureName_TextureCompressionBC, WGPUFeatureName_TextureCompressionETC2,
    WGPUFeatureName_TextureCompressionASTC,
};
static ZWgpu *create_impl(void *window,const char *source,size_t length,int headless) {
    if (!headless && (!window || !source || !length)) { fail("Missing window or WGSL source"); return NULL; }
    ZWgpu *g=calloc(1,sizeof *g); if (!g) { fail("Out of memory"); return NULL; }
    atomic_init(&g->failed,0); g->window=window; g->backend="wgpu";
    g->instance=wgpuCreateInstance(NULL); if (!g->instance) { fail("wgpuCreateInstance failed"); goto bad; }
    if (!headless) { g->surface=make_surface(g); if (!g->surface) { fail("Unsupported SDL native window or surface creation failed"); goto bad; } }
    Request req={0};
    WGPURequestAdapterOptions adapter_options={.compatibleSurface=g->surface,.powerPreference=WGPUPowerPreference_HighPerformance};
    wgpuInstanceRequestAdapter(g->instance,&adapter_options,(WGPURequestAdapterCallbackInfo){.mode=WGPUCallbackMode_AllowProcessEvents,.callback=adapter_cb,.userdata1=&req});
    await_request(g->instance,&req); g->adapter=req.adapter;
    if (!g->adapter) { fail("No compatible WebGPU adapter"); goto bad; }
    WGPUAdapterInfo info={0};
    if (wgpuAdapterGetInfo(g->adapter,&info)==WGPUStatus_Success) {
        switch (info.backendType) { case WGPUBackendType_Vulkan:g->backend="vulkan";break;case WGPUBackendType_D3D12:g->backend="dx12";break;case WGPUBackendType_Metal:g->backend="metal";break;case WGPUBackendType_OpenGL:g->backend="opengl";break;default:break; }
        wgpuAdapterInfoFreeMembers(info);
    }
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
    wgpuAdapterRequestDevice(g->adapter,&device_desc,(WGPURequestDeviceCallbackInfo){.mode=WGPUCallbackMode_AllowProcessEvents,.callback=device_cb,.userdata1=&req});
    await_request(g->instance,&req); g->device=req.device;
    if (!g->device) { fail("wgpuAdapterRequestDevice failed"); goto bad; }
    g->queue=wgpuDeviceGetQueue(g->device); if (!g->queue) { fail("Missing queue"); goto bad; }
    if (headless) return g;
    WGPUSurfaceCapabilities caps={0};
    if (wgpuSurfaceGetCapabilities(g->surface,g->adapter,&caps)!=WGPUStatus_Success) { fail("Surface capabilities unavailable"); goto bad; }
    if (!caps.formatCount || !caps.alphaModeCount || !(caps.usages&WGPUTextureUsage_RenderAttachment)) { wgpuSurfaceCapabilitiesFreeMembers(caps); fail("Unsupported surface capabilities"); goto bad; }
    g->config=(WGPUSurfaceConfiguration){.device=g->device,.format=choose_format(&caps),.usage=WGPUTextureUsage_RenderAttachment|WGPUTextureUsage_CopySrc,.presentMode=WGPUPresentMode_Fifo,.alphaMode=caps.alphaModes[0]};
    wgpuSurfaceCapabilitiesFreeMembers(caps);
    if (!make_pipeline(g,source,length)) { fail("WGSL pipeline creation failed"); goto bad; }
    return g;
bad: zwgpu_destroy(g); return NULL;
}
ZWgpu *zwgpu_create(void *window,const char *source,size_t length) { return create_impl(window,source,length,0); }
ZWgpu *zwgpu_create_headless(void) { return create_impl(NULL,NULL,0,1); }
void *zwgpu_native_device(ZWgpu *g) { return g?(void*)g->device:NULL; }
void *zwgpu_native_queue(ZWgpu *g) { return g?(void*)g->queue:NULL; }
void *zwgpu_native_adapter(ZWgpu *g) { return g?(void*)g->adapter:NULL; }
void *zwgpu_native_instance(ZWgpu *g) { return g?(void*)g->instance:NULL; }
uint32_t zwgpu_surface_format(ZWgpu *g) { return g?(uint32_t)g->config.format:0; }
int zwgpu_failed(ZWgpu *g) { return !g || atomic_load(&g->failed); }
void zwgpu_destroy(ZWgpu *g) {
    if (!g) return;
    if (g->device) wgpuDevicePoll(g->device,1,NULL);
    if (g->frame_view) wgpuTextureViewRelease(g->frame_view);
    if (g->frame_texture) wgpuTextureRelease(g->frame_texture);
    if (g->configured) wgpuSurfaceUnconfigure(g->surface);
    if (g->vertices) wgpuBufferRelease(g->vertices);
    if (g->pipeline) wgpuRenderPipelineRelease(g->pipeline);
    if (g->queue) wgpuQueueRelease(g->queue);
    if (g->device) { wgpuDeviceDestroy(g->device); wgpuDevicePoll(g->device,0,NULL); wgpuDeviceRelease(g->device); }
    if (g->adapter) wgpuAdapterRelease(g->adapter);
    if (g->surface) wgpuSurfaceRelease(g->surface);
#ifdef __APPLE__
    if (g->metal_view) SDL_Metal_DestroyView(g->metal_view);
#endif
    if (g->instance) wgpuInstanceRelease(g->instance);
    free(g);
}
void zwgpu_logical_size(ZWgpu *g,int *w,int *h) { *w=0;*h=0; if(g) SDL_GetWindowSize(g->window,w,h); }
static int ensure_buffer(ZWgpu *g,uint64_t bytes) {
    if (bytes<=g->capacity) return 1;
    /* Bound memory and retain the old buffer on failure. */
    const uint64_t max_bytes=64u*1024u*1024u;
    if (bytes>max_bytes) { fail("Vertex upload exceeds 64 MiB limit"); return 0; }
    uint64_t cap=g->capacity?g->capacity:65536;
    while(cap<bytes) cap*=2;
    WGPUBuffer next=wgpuDeviceCreateBuffer(g->device,&(WGPUBufferDescriptor){.size=cap,.usage=WGPUBufferUsage_Vertex|WGPUBufferUsage_CopyDst});
    if (!next || atomic_load(&g->failed)) { if(next) wgpuBufferRelease(next);fail("Vertex allocation failed");return 0; }
    if(g->vertices) wgpuBufferRelease(g->vertices);
    g->vertices=next;g->capacity=cap;return 1;
}
int zwgpu_draw(ZWgpu *g,const ZWgpuVertex *vertices,size_t count,const float clear[4]) {
    if (!g || atomic_load(&g->failed) || !clear || (count && !vertices) || count%3 || count>UINT32_MAX || count>SIZE_MAX/sizeof(ZWgpuVertex)) { fail("Invalid frame or device error"); return 0; }
    for(unsigned i=0;i<4;i++) if(!isfinite(clear[i])) { fail("Invalid clear color");return 0; }
    wgpuDevicePoll(g->device,0,NULL);
    int w=0,h=0; if (!SDL_GetWindowSizeInPixels(g->window,&w,&h)) {fail("Could not query drawable size");return 0;}
    if(w<=0 || h<=0 || (SDL_GetWindowFlags(g->window)&SDL_WINDOW_MINIMIZED)) return 2;
    if (!g->configured || g->config.width!=(uint32_t)w || g->config.height!=(uint32_t)h) {
        g->config.width=(uint32_t)w;g->config.height=(uint32_t)h;
        wgpuSurfaceConfigure(g->surface,&g->config);g->configured=1;
        if(atomic_load(&g->failed)){fail("Surface configuration failed");return 0;}
    }
    if(count && !ensure_buffer(g,count*sizeof(ZWgpuVertex))) return 0;
    WGPUSurfaceTexture surface={0}; wgpuSurfaceGetCurrentTexture(g->surface,&surface);
    if(surface.status!=WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal && surface.status!=WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal) {
        if(surface.texture) wgpuTextureRelease(surface.texture);
        if(surface.status==WGPUSurfaceGetCurrentTextureStatus_Timeout) return 2;
        if(surface.status==WGPUSurfaceGetCurrentTextureStatus_Outdated || surface.status==WGPUSurfaceGetCurrentTextureStatus_Lost) {wgpuSurfaceUnconfigure(g->surface);g->configured=0;return 2;}
        fail("Surface acquisition failed");return 0;
    }
    if(!surface.texture){fail("Missing surface texture");return 0;}
    int result=0;
    WGPUTextureView view=wgpuTextureCreateView(surface.texture,NULL);
    WGPUCommandEncoder encoder=NULL; WGPUCommandBuffer commands=NULL;
    if(!view) goto done;
    if(count) wgpuQueueWriteBuffer(g->queue,g->vertices,0,vertices,count*sizeof(ZWgpuVertex));
    encoder=wgpuDeviceCreateCommandEncoder(g->device,NULL); if(!encoder) goto done;
    WGPURenderPassColorAttachment color={.view=view,.depthSlice=WGPU_DEPTH_SLICE_UNDEFINED,.loadOp=WGPULoadOp_Clear,.storeOp=WGPUStoreOp_Store,.clearValue={clear[0],clear[1],clear[2],clear[3]}};
    WGPURenderPassEncoder pass=wgpuCommandEncoderBeginRenderPass(encoder,&(WGPURenderPassDescriptor){.colorAttachmentCount=1,.colorAttachments=&color});
    if(!pass) goto done;
    if(count){wgpuRenderPassEncoderSetPipeline(pass,g->pipeline);wgpuRenderPassEncoderSetVertexBuffer(pass,0,g->vertices,0,count*sizeof(ZWgpuVertex));wgpuRenderPassEncoderDraw(pass,(uint32_t)count,1,0,0);}
    wgpuRenderPassEncoderEnd(pass);wgpuRenderPassEncoderRelease(pass);
    commands=wgpuCommandEncoderFinish(encoder,NULL);if(!commands) goto done;
    wgpuQueueSubmit(g->queue,1,&commands);
    result=(wgpuSurfacePresent(g->surface)==WGPUStatus_Success && !atomic_load(&g->failed))?1:0;
done:
    if(commands)wgpuCommandBufferRelease(commands);
    if(encoder)wgpuCommandEncoderRelease(encoder);
    if(view)wgpuTextureViewRelease(view);
    wgpuTextureRelease(surface.texture);
    if(atomic_exchange(&g->validation_pending,0)) result=0;
    if(!result)fail("WebGPU frame encoding or submission failed");
    return result;
}

/* Swapchain frame API used by the neutral command submission path. */
int zwgpu_swapchain_acquire(ZWgpu *g,void **view_out,uint32_t *width,uint32_t *height) {
    if (!g || !g->surface || !view_out || atomic_load(&g->failed)) { fail("Invalid swapchain request"); return 0; }
    if (g->frame_texture) { fail("Previous swapchain frame was not presented"); return 0; }
    wgpuDevicePoll(g->device,0,NULL);
    int w=0,h=0; if (!SDL_GetWindowSizeInPixels(g->window,&w,&h)) { fail("Could not query drawable size"); return 0; }
    if (w<=0 || h<=0 || (SDL_GetWindowFlags(g->window)&SDL_WINDOW_MINIMIZED)) return 2;
    if (!g->configured || g->config.width!=(uint32_t)w || g->config.height!=(uint32_t)h) {
        g->config.width=(uint32_t)w; g->config.height=(uint32_t)h;
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
/* Flushes pending device callbacks, then returns 1 and copies the message if a validation error is queued. */
int zwgpu_take_validation(ZWgpu *g,char *out,size_t capacity,int flush) {
    if (!g || !out || !capacity) return 0;
    if (flush && g->device) wgpuDevicePoll(g->device,0,NULL);
    if (!atomic_exchange(&g->validation_pending,0)) return 0;
    snprintf(out,capacity,"%s",g->validation);
    return 1;
}
