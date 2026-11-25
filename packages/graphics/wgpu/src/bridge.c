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
    int configured;
    atomic_bool failed;
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
    (void)device; (void)unused; (void)type;
    ZWgpu *g=p;
    atomic_store(&g->failed,1);
    SDL_LogError(SDL_LOG_CATEGORY_RENDER,"WebGPU error: %.*s",(int)(message.length>4096?4096:message.length),message.data?message.data:"");
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
    return g->pipeline && !atomic_load(&g->failed);
}
ZWgpu *zwgpu_create(void *window,const char *source,size_t length) {
    if (!window || !source || !length) { fail("Missing window or WGSL source"); return NULL; }
    ZWgpu *g=calloc(1,sizeof *g); if (!g) { fail("Out of memory"); return NULL; }
    atomic_init(&g->failed,0); g->window=window; g->backend="wgpu";
    g->instance=wgpuCreateInstance(NULL); if (!g->instance) { fail("wgpuCreateInstance failed"); goto bad; }
    g->surface=make_surface(g); if (!g->surface) { fail("Unsupported SDL native window or surface creation failed"); goto bad; }
    Request req={0};
    wgpuInstanceRequestAdapter(g->instance,&(WGPURequestAdapterOptions){.compatibleSurface=g->surface,.powerPreference=WGPUPowerPreference_HighPerformance},(WGPURequestAdapterCallbackInfo){.mode=WGPUCallbackMode_AllowProcessEvents,.callback=adapter_cb,.userdata1=&req});
    await_request(g->instance,&req); g->adapter=req.adapter;
    if (!g->adapter) { fail("No compatible WebGPU adapter"); goto bad; }
    WGPUAdapterInfo info={0};
    if (wgpuAdapterGetInfo(g->adapter,&info)==WGPUStatus_Success) {
        switch (info.backendType) { case WGPUBackendType_Vulkan:g->backend="vulkan";break;case WGPUBackendType_D3D12:g->backend="dx12";break;case WGPUBackendType_Metal:g->backend="metal";break;case WGPUBackendType_OpenGL:g->backend="opengl";break;default:break; }
        wgpuAdapterInfoFreeMembers(info);
    }
    req=(Request){0}; WGPUDeviceDescriptor device_desc={0};
    device_desc.uncapturedErrorCallbackInfo=(WGPUUncapturedErrorCallbackInfo){.callback=error_cb,.userdata1=g};
    wgpuAdapterRequestDevice(g->adapter,&device_desc,(WGPURequestDeviceCallbackInfo){.mode=WGPUCallbackMode_AllowProcessEvents,.callback=device_cb,.userdata1=&req});
    await_request(g->instance,&req); g->device=req.device;
    if (!g->device) { fail("wgpuAdapterRequestDevice failed"); goto bad; }
    g->queue=wgpuDeviceGetQueue(g->device); if (!g->queue) { fail("Missing queue"); goto bad; }
    WGPUSurfaceCapabilities caps={0};
    if (wgpuSurfaceGetCapabilities(g->surface,g->adapter,&caps)!=WGPUStatus_Success) { fail("Surface capabilities unavailable"); goto bad; }
    if (!caps.formatCount || !caps.alphaModeCount || !(caps.usages&WGPUTextureUsage_RenderAttachment)) { wgpuSurfaceCapabilitiesFreeMembers(caps); fail("Unsupported surface capabilities"); goto bad; }
    g->config=(WGPUSurfaceConfiguration){.device=g->device,.format=choose_format(&caps),.usage=WGPUTextureUsage_RenderAttachment,.presentMode=WGPUPresentMode_Fifo,.alphaMode=caps.alphaModes[0]};
    wgpuSurfaceCapabilitiesFreeMembers(caps);
    if (!make_pipeline(g,source,length)) { fail("WGSL pipeline creation failed"); goto bad; }
    return g;
bad: zwgpu_destroy(g); return NULL;
}
void zwgpu_destroy(ZWgpu *g) {
    if (!g) return;
    if (g->device) wgpuDevicePoll(g->device,1,NULL);
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
    if(!result)fail("WebGPU frame encoding or submission failed");
    return result;
}
