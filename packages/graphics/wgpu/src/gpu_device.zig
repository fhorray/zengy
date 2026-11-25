//! wgpu-native implementation of the backend-neutral `graphics.gpu.GpuDevice` contract.
//!
//! This is the only place that translates engine descriptors into WebGPU calls. Renderers never see
//! `WGPU*` types. Resources live in generational pools, so stale handles fail with `error.InvalidHandle`
//! instead of touching freed native objects.
const std = @import("std");
const graphics = @import("graphics");
const c = @import("wgpu_c");

pub const gpu = graphics.gpu;

extern fn zwgpu_create_headless() ?*anyopaque;
extern fn zwgpu_destroy(g: *anyopaque) void;
extern fn zwgpu_native_device(g: *anyopaque) ?*anyopaque;
extern fn zwgpu_native_queue(g: *anyopaque) ?*anyopaque;
extern fn zwgpu_native_adapter(g: *anyopaque) ?*anyopaque;
extern fn zwgpu_native_instance(g: *anyopaque) ?*anyopaque;
extern fn zwgpu_surface_format(g: *anyopaque) u32;
extern fn zwgpu_failed(g: *anyopaque) c_int;
extern fn zwgpu_set_validation_capture(g: *anyopaque, enabled: c_int) void;
extern fn zwgpu_take_validation(g: *anyopaque, out: [*]u8, capacity: usize, flush: c_int) c_int;
extern fn zwgpu_swapchain_acquire(g: *anyopaque, view: *?*anyopaque, width: *u32, height: *u32) c_int;
extern fn zwgpu_swapchain_present(g: *anyopaque, present: c_int) c_int;
extern fn zwgpu_frame_texture(g: *anyopaque, width: *u32, height: *u32) ?*anyopaque;
extern fn zwgpu_error() [*:0]const u8;

/// Non-optional native view pointer (translate-c types handles as optional pointers).
const TextureViewPtr = @typeInfo(c.WGPUTextureView).optional.child;

const undefined_u32: u32 = std.math.maxInt(u32);
const whole_size: u64 = std.math.maxInt(u64);
const strlen_marker: usize = std.math.maxInt(usize);

pub const Error = error{
    InvalidHandle,
    InvalidDescriptor,
    FeatureUnsupported,
    OutOfBounds,
    Unaligned,
    MissingUsage,
    GpuValidation,
    GpuFailure,
    ReadbackFailed,
    ReadbackTimeout,
    PassMismatch,
    SurfaceFailure,
};

const Buffer = struct { raw: c.WGPUBuffer, size: u64, usage: gpu.BufferUsage };
const Texture = struct {
    raw: c.WGPUTexture,
    width: u32,
    height: u32,
    depth_or_layers: u32,
    mip_levels: u32,
    sample_count: u32,
    format: gpu.TextureFormat,
    usage: gpu.TextureUsage,
};
const View = struct { raw: c.WGPUTextureView };
const Sampler = struct { raw: c.WGPUSampler };
const Shader = struct { raw: c.WGPUShaderModule };
const BindLayout = struct { raw: c.WGPUBindGroupLayout };
const BindGroup = struct { raw: c.WGPUBindGroup };
const PipelineLayout = struct { raw: c.WGPUPipelineLayout };
const RenderPipeline = struct { raw: c.WGPURenderPipeline };
const ComputePipeline = struct { raw: c.WGPUComputePipeline };
const QuerySet = struct { raw: c.WGPUQuerySet, count: u32 };

/// Heap-allocated so the asynchronous map callback keeps a stable address.
const ReadbackState = struct {
    buffer: c.WGPUBuffer,
    offset: u64,
    size: u64,
    /// 0 pending, 1 mapped, 2 failed.
    status: std.atomic.Value(u32) = .init(0),
};

pub const Device = struct {
    allocator: std.mem.Allocator,
    /// Bridge object that owns instance/adapter/device/queue lifetime.
    bridge: *anyopaque,
    owns_bridge: bool,
    instance: c.WGPUInstance,
    device: c.WGPUDevice,
    queue: c.WGPUQueue,
    caps: gpu.Capabilities = .{},
    frame_acquired: bool = false,
    /// Swapchain view of the current frame, shared by every pass that targets `.swapchain`.
    frame_view: ?TextureViewPtr = null,
    last_error: [512]u8 = @splat(0),
    last_error_len: usize = 0,

    buffers: gpu.HandlePool(Buffer, gpu.BufferHandle) = .{},
    textures: gpu.HandlePool(Texture, gpu.TextureHandle) = .{},
    views: gpu.HandlePool(View, gpu.TextureViewHandle) = .{},
    samplers: gpu.HandlePool(Sampler, gpu.SamplerHandle) = .{},
    shaders: gpu.HandlePool(Shader, gpu.ShaderModuleHandle) = .{},
    bind_layouts: gpu.HandlePool(BindLayout, gpu.BindGroupLayoutHandle) = .{},
    bind_groups: gpu.HandlePool(BindGroup, gpu.BindGroupHandle) = .{},
    pipeline_layouts: gpu.HandlePool(PipelineLayout, gpu.PipelineLayoutHandle) = .{},
    render_pipelines: gpu.HandlePool(RenderPipeline, gpu.RenderPipelineHandle) = .{},
    compute_pipelines: gpu.HandlePool(ComputePipeline, gpu.ComputePipelineHandle) = .{},
    query_sets: gpu.HandlePool(QuerySet, gpu.QuerySetHandle) = .{},
    readbacks: gpu.HandlePool(*ReadbackState, gpu.ReadbackHandle) = .{},

    /// Creates a windowless device for tests and tools.
    pub fn initHeadless(allocator: std.mem.Allocator) !*Device {
        const bridge = zwgpu_create_headless() orelse {
            std.debug.print("[wgpu] {s}\n", .{std.mem.span(zwgpu_error())});
            return error.GpuFailure;
        };
        errdefer zwgpu_destroy(bridge);
        return initFromBridge(allocator, bridge, true);
    }

    /// Wraps a bridge created elsewhere (the windowed provider). The bridge is not destroyed by `deinit`.
    pub fn initFromBridge(allocator: std.mem.Allocator, bridge: *anyopaque, owns_bridge: bool) !*Device {
        const self = try allocator.create(Device);
        errdefer allocator.destroy(self);
        const device: c.WGPUDevice = @ptrCast(zwgpu_native_device(bridge) orelse return error.GpuFailure);
        const queue: c.WGPUQueue = @ptrCast(zwgpu_native_queue(bridge) orelse return error.GpuFailure);
        const instance: c.WGPUInstance = @ptrCast(zwgpu_native_instance(bridge) orelse return error.GpuFailure);
        self.* = .{
            .allocator = allocator,
            .bridge = bridge,
            .owns_bridge = owns_bridge,
            .instance = instance,
            .device = device,
            .queue = queue,
        };
        self.caps = detectCapabilities(@ptrCast(zwgpu_native_adapter(bridge)), device, queue);
        zwgpu_set_validation_capture(bridge, 1);
        return self;
    }

    pub fn deinit(self: *Device) void {
        const allocator = self.allocator;
        self.releaseAll();
        if (self.owns_bridge) {
            zwgpu_destroy(self.bridge);
        } else {
            zwgpu_set_validation_capture(self.bridge, 0);
        }
        allocator.destroy(self);
    }

    /// Releases every resource still alive so a forgotten `destroy*` can never leak native memory.
    fn releaseAll(self: *Device) void {
        for (self.readbacks.slots.items) |slot| if (slot.alive) {
            c.wgpuBufferRelease(slot.value.buffer);
            self.allocator.destroy(slot.value);
        };
        for (self.render_pipelines.slots.items) |slot| if (slot.alive) c.wgpuRenderPipelineRelease(slot.value.raw);
        for (self.compute_pipelines.slots.items) |slot| if (slot.alive) c.wgpuComputePipelineRelease(slot.value.raw);
        for (self.bind_groups.slots.items) |slot| if (slot.alive) c.wgpuBindGroupRelease(slot.value.raw);
        for (self.pipeline_layouts.slots.items) |slot| if (slot.alive) c.wgpuPipelineLayoutRelease(slot.value.raw);
        for (self.bind_layouts.slots.items) |slot| if (slot.alive) c.wgpuBindGroupLayoutRelease(slot.value.raw);
        for (self.shaders.slots.items) |slot| if (slot.alive) c.wgpuShaderModuleRelease(slot.value.raw);
        for (self.samplers.slots.items) |slot| if (slot.alive) c.wgpuSamplerRelease(slot.value.raw);
        for (self.views.slots.items) |slot| if (slot.alive) c.wgpuTextureViewRelease(slot.value.raw);
        for (self.textures.slots.items) |slot| if (slot.alive) {
            c.wgpuTextureDestroy(slot.value.raw);
            c.wgpuTextureRelease(slot.value.raw);
        };
        for (self.buffers.slots.items) |slot| if (slot.alive) {
            c.wgpuBufferDestroy(slot.value.raw);
            c.wgpuBufferRelease(slot.value.raw);
        };
        for (self.query_sets.slots.items) |slot| if (slot.alive) c.wgpuQuerySetRelease(slot.value.raw);
        self.readbacks.deinit(self.allocator);
        self.render_pipelines.deinit(self.allocator);
        self.compute_pipelines.deinit(self.allocator);
        self.bind_groups.deinit(self.allocator);
        self.pipeline_layouts.deinit(self.allocator);
        self.bind_layouts.deinit(self.allocator);
        self.shaders.deinit(self.allocator);
        self.samplers.deinit(self.allocator);
        self.views.deinit(self.allocator);
        self.textures.deinit(self.allocator);
        self.buffers.deinit(self.allocator);
        self.query_sets.deinit(self.allocator);
    }

    pub fn gpuDevice(self: *Device) gpu.GpuDevice {
        return .{ .ctx = self, .vtable = &vtable };
    }

    /// Most recent validation message, valid until the next failing call.
    pub fn lastError(self: *const Device) []const u8 {
        return self.last_error[0..self.last_error_len];
    }

    pub fn surfaceFormat(self: *const Device) ?gpu.TextureFormat {
        return fromNativeFormat(zwgpu_surface_format(self.bridge));
    }

    /// Presents the swapchain frame acquired by `submit`, if any, and releases it.
    pub fn presentFrame(self: *Device) !void {
        const had_frame = self.frame_acquired;
        self.frame_acquired = false;
        self.frame_view = null;
        if (zwgpu_swapchain_present(self.bridge, @intFromBool(had_frame)) == 0) return error.SurfaceFailure;
    }

    /// Drops an acquired swapchain frame without presenting it (used when a submit fails).
    fn abortFrame(self: *Device) void {
        if (!self.frame_acquired) return;
        self.frame_acquired = false;
        self.frame_view = null;
        _ = zwgpu_swapchain_present(self.bridge, 0);
    }

    /// Turns a queued WebGPU validation error into `error.GpuValidation`. `flush` polls the device first,
    /// which is needed after resource creation but wasted work on hot paths like buffer writes.
    fn checkValidation(self: *Device, flush: bool) !void {
        var buf: [512]u8 = undefined;
        if (zwgpu_take_validation(self.bridge, &buf, buf.len, @intFromBool(flush)) != 0) {
            const len = std.mem.indexOfScalar(u8, &buf, 0) orelse buf.len;
            @memcpy(self.last_error[0..len], buf[0..len]);
            self.last_error_len = len;
            return error.GpuValidation;
        }
        if (zwgpu_failed(self.bridge) != 0) return error.GpuFailure;
    }
};

// ---------------------------------------------------------------------------------------------
// Conversions
// ---------------------------------------------------------------------------------------------

fn sv(text: ?[]const u8) c.WGPUStringView {
    if (text) |t| return .{ .data = t.ptr, .length = t.len };
    return .{ .data = null, .length = strlen_marker };
}

fn nativeFormat(f: gpu.TextureFormat) c.WGPUTextureFormat {
    return switch (f) {
        .r8_unorm => c.WGPUTextureFormat_R8Unorm,
        .rg8_unorm => c.WGPUTextureFormat_RG8Unorm,
        .rgba8_unorm => c.WGPUTextureFormat_RGBA8Unorm,
        .rgba8_unorm_srgb => c.WGPUTextureFormat_RGBA8UnormSrgb,
        .bgra8_unorm => c.WGPUTextureFormat_BGRA8Unorm,
        .bgra8_unorm_srgb => c.WGPUTextureFormat_BGRA8UnormSrgb,
        .r16_float => c.WGPUTextureFormat_R16Float,
        .rg16_float => c.WGPUTextureFormat_RG16Float,
        .rgba16_float => c.WGPUTextureFormat_RGBA16Float,
        .r32_float => c.WGPUTextureFormat_R32Float,
        .rg32_float => c.WGPUTextureFormat_RG32Float,
        .rgba32_float => c.WGPUTextureFormat_RGBA32Float,
        .r32_uint => c.WGPUTextureFormat_R32Uint,
        .rg11b10_ufloat => c.WGPUTextureFormat_RG11B10Ufloat,
        .rgb10a2_unorm => c.WGPUTextureFormat_RGB10A2Unorm,
        .depth16_unorm => c.WGPUTextureFormat_Depth16Unorm,
        .depth24_plus => c.WGPUTextureFormat_Depth24Plus,
        .depth24_plus_stencil8 => c.WGPUTextureFormat_Depth24PlusStencil8,
        .depth32_float => c.WGPUTextureFormat_Depth32Float,
    };
}

fn fromNativeFormat(raw: u32) ?gpu.TextureFormat {
    for (std.enums.values(gpu.TextureFormat)) |value| {
        if (@as(u32, @intCast(nativeFormat(value))) == raw) return value;
    }
    return null;
}

fn bufferUsage(u: gpu.BufferUsage) c.WGPUBufferUsage {
    var f: c.WGPUBufferUsage = 0;
    if (u.map_read) f |= c.WGPUBufferUsage_MapRead;
    if (u.map_write) f |= c.WGPUBufferUsage_MapWrite;
    if (u.copy_src) f |= c.WGPUBufferUsage_CopySrc;
    if (u.copy_dst) f |= c.WGPUBufferUsage_CopyDst;
    if (u.index) f |= c.WGPUBufferUsage_Index;
    if (u.vertex) f |= c.WGPUBufferUsage_Vertex;
    if (u.uniform) f |= c.WGPUBufferUsage_Uniform;
    if (u.storage) f |= c.WGPUBufferUsage_Storage;
    if (u.indirect) f |= c.WGPUBufferUsage_Indirect;
    if (u.query_resolve) f |= c.WGPUBufferUsage_QueryResolve;
    return f;
}

fn textureUsage(u: gpu.TextureUsage) c.WGPUTextureUsage {
    var f: c.WGPUTextureUsage = 0;
    if (u.copy_src) f |= c.WGPUTextureUsage_CopySrc;
    if (u.copy_dst) f |= c.WGPUTextureUsage_CopyDst;
    if (u.texture_binding) f |= c.WGPUTextureUsage_TextureBinding;
    if (u.storage_binding) f |= c.WGPUTextureUsage_StorageBinding;
    if (u.render_attachment) f |= c.WGPUTextureUsage_RenderAttachment;
    return f;
}

fn shaderStages(s: gpu.ShaderStages) c.WGPUShaderStage {
    var f: c.WGPUShaderStage = 0;
    if (s.vertex) f |= c.WGPUShaderStage_Vertex;
    if (s.fragment) f |= c.WGPUShaderStage_Fragment;
    if (s.compute) f |= c.WGPUShaderStage_Compute;
    return f;
}

fn viewDimension(d: gpu.ViewDimension) c.WGPUTextureViewDimension {
    return switch (d) {
        .d1 => c.WGPUTextureViewDimension_1D,
        .d2 => c.WGPUTextureViewDimension_2D,
        .d2_array => c.WGPUTextureViewDimension_2DArray,
        .cube => c.WGPUTextureViewDimension_Cube,
        .cube_array => c.WGPUTextureViewDimension_CubeArray,
        .d3 => c.WGPUTextureViewDimension_3D,
    };
}

fn textureDimension(d: gpu.TextureDimension) c.WGPUTextureDimension {
    return switch (d) {
        .d1 => c.WGPUTextureDimension_1D,
        .d2 => c.WGPUTextureDimension_2D,
        .d3 => c.WGPUTextureDimension_3D,
    };
}

fn aspect(a: gpu.TextureAspect) c.WGPUTextureAspect {
    return switch (a) {
        .all => c.WGPUTextureAspect_All,
        .depth_only => c.WGPUTextureAspect_DepthOnly,
        .stencil_only => c.WGPUTextureAspect_StencilOnly,
    };
}

fn addressMode(m: gpu.AddressMode) c.WGPUAddressMode {
    return switch (m) {
        .clamp_to_edge => c.WGPUAddressMode_ClampToEdge,
        .repeat => c.WGPUAddressMode_Repeat,
        .mirror_repeat => c.WGPUAddressMode_MirrorRepeat,
    };
}

fn filterMode(m: gpu.FilterMode) c.WGPUFilterMode {
    return switch (m) {
        .nearest => c.WGPUFilterMode_Nearest,
        .linear => c.WGPUFilterMode_Linear,
    };
}

fn mipmapFilter(m: gpu.FilterMode) c.WGPUMipmapFilterMode {
    return switch (m) {
        .nearest => c.WGPUMipmapFilterMode_Nearest,
        .linear => c.WGPUMipmapFilterMode_Linear,
    };
}

fn compareFunction(f: gpu.CompareFunction) c.WGPUCompareFunction {
    return switch (f) {
        .never => c.WGPUCompareFunction_Never,
        .less => c.WGPUCompareFunction_Less,
        .equal => c.WGPUCompareFunction_Equal,
        .less_equal => c.WGPUCompareFunction_LessEqual,
        .greater => c.WGPUCompareFunction_Greater,
        .not_equal => c.WGPUCompareFunction_NotEqual,
        .greater_equal => c.WGPUCompareFunction_GreaterEqual,
        .always => c.WGPUCompareFunction_Always,
    };
}

fn vertexFormat(f: gpu.VertexFormat) c.WGPUVertexFormat {
    return switch (f) {
        .float32 => c.WGPUVertexFormat_Float32,
        .float32x2 => c.WGPUVertexFormat_Float32x2,
        .float32x3 => c.WGPUVertexFormat_Float32x3,
        .float32x4 => c.WGPUVertexFormat_Float32x4,
        .uint32 => c.WGPUVertexFormat_Uint32,
        .uint32x2 => c.WGPUVertexFormat_Uint32x2,
        .uint32x3 => c.WGPUVertexFormat_Uint32x3,
        .uint32x4 => c.WGPUVertexFormat_Uint32x4,
        .sint32 => c.WGPUVertexFormat_Sint32,
        .unorm8x4 => c.WGPUVertexFormat_Unorm8x4,
        .float16x2 => c.WGPUVertexFormat_Float16x2,
        .float16x4 => c.WGPUVertexFormat_Float16x4,
    };
}

fn blendFactor(f: gpu.BlendFactor) c.WGPUBlendFactor {
    return switch (f) {
        .zero => c.WGPUBlendFactor_Zero,
        .one => c.WGPUBlendFactor_One,
        .src => c.WGPUBlendFactor_Src,
        .one_minus_src => c.WGPUBlendFactor_OneMinusSrc,
        .src_alpha => c.WGPUBlendFactor_SrcAlpha,
        .one_minus_src_alpha => c.WGPUBlendFactor_OneMinusSrcAlpha,
        .dst => c.WGPUBlendFactor_Dst,
        .one_minus_dst => c.WGPUBlendFactor_OneMinusDst,
        .dst_alpha => c.WGPUBlendFactor_DstAlpha,
        .one_minus_dst_alpha => c.WGPUBlendFactor_OneMinusDstAlpha,
        .constant => c.WGPUBlendFactor_Constant,
        .one_minus_constant => c.WGPUBlendFactor_OneMinusConstant,
    };
}

fn blendOperation(o: gpu.BlendOperation) c.WGPUBlendOperation {
    return switch (o) {
        .add => c.WGPUBlendOperation_Add,
        .subtract => c.WGPUBlendOperation_Subtract,
        .reverse_subtract => c.WGPUBlendOperation_ReverseSubtract,
        .min => c.WGPUBlendOperation_Min,
        .max => c.WGPUBlendOperation_Max,
    };
}

fn blendComponent(b: gpu.BlendComponent) c.WGPUBlendComponent {
    return .{ .operation = blendOperation(b.operation), .srcFactor = blendFactor(b.src_factor), .dstFactor = blendFactor(b.dst_factor) };
}

fn topology(t: gpu.PrimitiveTopology) c.WGPUPrimitiveTopology {
    return switch (t) {
        .point_list => c.WGPUPrimitiveTopology_PointList,
        .line_list => c.WGPUPrimitiveTopology_LineList,
        .line_strip => c.WGPUPrimitiveTopology_LineStrip,
        .triangle_list => c.WGPUPrimitiveTopology_TriangleList,
        .triangle_strip => c.WGPUPrimitiveTopology_TriangleStrip,
    };
}

fn cullMode(m: gpu.CullMode) c.WGPUCullMode {
    return switch (m) {
        .none => c.WGPUCullMode_None,
        .front => c.WGPUCullMode_Front,
        .back => c.WGPUCullMode_Back,
    };
}

fn frontFace(f: gpu.FrontFace) c.WGPUFrontFace {
    return switch (f) {
        .ccw => c.WGPUFrontFace_CCW,
        .cw => c.WGPUFrontFace_CW,
    };
}

fn loadOp(o: gpu.LoadOp) c.WGPULoadOp {
    return switch (o) {
        .clear => c.WGPULoadOp_Clear,
        .load => c.WGPULoadOp_Load,
    };
}

fn storeOp(o: gpu.StoreOp) c.WGPUStoreOp {
    return switch (o) {
        .store => c.WGPUStoreOp_Store,
        .discard => c.WGPUStoreOp_Discard,
    };
}

fn extent(e: gpu.Extent3D) c.WGPUExtent3D {
    return .{ .width = e.width, .height = e.height, .depthOrArrayLayers = e.depth_or_layers };
}

// ---------------------------------------------------------------------------------------------
// Capability detection
// ---------------------------------------------------------------------------------------------

fn detectCapabilities(adapter: c.WGPUAdapter, device: c.WGPUDevice, queue: c.WGPUQueue) gpu.Capabilities {
    var caps: gpu.Capabilities = .{};

    var info = std.mem.zeroes(c.WGPUAdapterInfo);
    if (c.wgpuAdapterGetInfo(adapter, &info) == c.WGPUStatus_Success) {
        if (info.device.data != null) {
            const len: usize = @min(info.device.length, caps.info.name_buf.len);
            @memcpy(caps.info.name_buf[0..len], info.device.data[0..len]);
            caps.info.name_len = @intCast(len);
        }
        caps.info.vendor_id = info.vendorID;
        caps.info.device_id = info.deviceID;
        caps.info.backend = switch (info.backendType) {
            c.WGPUBackendType_Vulkan => .vulkan,
            c.WGPUBackendType_D3D12 => .dx12,
            c.WGPUBackendType_Metal => .metal,
            c.WGPUBackendType_OpenGL, c.WGPUBackendType_OpenGLES => .opengl,
            c.WGPUBackendType_WebGPU => .webgpu_browser,
            else => .unknown,
        };
        caps.info.adapter_type = switch (info.adapterType) {
            c.WGPUAdapterType_DiscreteGPU => .discrete_gpu,
            c.WGPUAdapterType_IntegratedGPU => .integrated_gpu,
            c.WGPUAdapterType_CPU => .cpu,
            else => .unknown,
        };
        c.wgpuAdapterInfoFreeMembers(info);
    }

    const has = struct {
        fn f(d: c.WGPUDevice, name: c.WGPUFeatureName) bool {
            return c.wgpuDeviceHasFeature(d, name) != 0;
        }
    }.f;
    caps.features = .{
        .timestamp_query = has(device, c.WGPUFeatureName_TimestampQuery),
        .float32_filterable = has(device, c.WGPUFeatureName_Float32Filterable),
        .float32_blendable = has(device, c.WGPUFeatureName_Float32Blendable),
        .rg11b10_renderable = has(device, c.WGPUFeatureName_RG11B10UfloatRenderable),
        .depth32_stencil8 = has(device, c.WGPUFeatureName_Depth32FloatStencil8),
        .shader_f16 = has(device, c.WGPUFeatureName_ShaderF16),
        .subgroups = has(device, c.WGPUFeatureName_Subgroups),
        .indirect_first_instance = has(device, c.WGPUFeatureName_IndirectFirstInstance),
        .bgra8_storage = has(device, c.WGPUFeatureName_BGRA8UnormStorage),
        .dual_source_blending = has(device, c.WGPUFeatureName_DualSourceBlending),
        .texture_compression_bc = has(device, c.WGPUFeatureName_TextureCompressionBC),
        .texture_compression_etc2 = has(device, c.WGPUFeatureName_TextureCompressionETC2),
        .texture_compression_astc = has(device, c.WGPUFeatureName_TextureCompressionASTC),
        // Reported by the adapter only: the pinned wgpu-native has no acceleration-structure API.
        .ray_query = c.wgpuAdapterHasFeature(adapter, c.WGPUNativeFeature_RayQuery) != 0,
    };

    var l = std.mem.zeroes(c.WGPULimits);
    if (c.wgpuDeviceGetLimits(device, &l) == c.WGPUStatus_Success) {
        caps.limits = .{
            .max_texture_dimension_1d = l.maxTextureDimension1D,
            .max_texture_dimension_2d = l.maxTextureDimension2D,
            .max_texture_dimension_3d = l.maxTextureDimension3D,
            .max_texture_array_layers = l.maxTextureArrayLayers,
            .max_bind_groups = l.maxBindGroups,
            .max_bindings_per_bind_group = l.maxBindingsPerBindGroup,
            .max_uniform_buffer_binding_size = l.maxUniformBufferBindingSize,
            .max_storage_buffer_binding_size = l.maxStorageBufferBindingSize,
            .min_uniform_buffer_offset_alignment = l.minUniformBufferOffsetAlignment,
            .min_storage_buffer_offset_alignment = l.minStorageBufferOffsetAlignment,
            .max_vertex_buffers = l.maxVertexBuffers,
            .max_buffer_size = l.maxBufferSize,
            .max_color_attachments = l.maxColorAttachments,
            .max_color_attachment_bytes_per_sample = l.maxColorAttachmentBytesPerSample,
            .max_sampled_textures_per_shader_stage = l.maxSampledTexturesPerShaderStage,
            .max_storage_buffers_per_shader_stage = l.maxStorageBuffersPerShaderStage,
            .max_storage_textures_per_shader_stage = l.maxStorageTexturesPerShaderStage,
            .max_uniform_buffers_per_shader_stage = l.maxUniformBuffersPerShaderStage,
            .max_compute_workgroup_storage_size = l.maxComputeWorkgroupStorageSize,
            .max_compute_invocations_per_workgroup = l.maxComputeInvocationsPerWorkgroup,
            .max_compute_workgroup_size = .{ l.maxComputeWorkgroupSizeX, l.maxComputeWorkgroupSizeY, l.maxComputeWorkgroupSizeZ },
            .max_compute_workgroups_per_dimension = l.maxComputeWorkgroupsPerDimension,
        };
    }

    if (caps.features.timestamp_query) caps.timestamp_period_ns = c.wgpuQueueGetTimestampPeriod(queue);
    caps.acceleration_structures = false;
    return caps;
}

// ---------------------------------------------------------------------------------------------
// VTable implementation
// ---------------------------------------------------------------------------------------------

fn dev(ctx: *anyopaque) *Device {
    return @ptrCast(@alignCast(ctx));
}

fn getCapabilities(ctx: *anyopaque) *const gpu.Capabilities {
    return &dev(ctx).caps;
}

fn createBuffer(ctx: *anyopaque, desc: gpu.BufferDesc) anyerror!gpu.BufferHandle {
    const self = dev(ctx);
    if (desc.size == 0) return error.InvalidDescriptor;
    if (desc.size > self.caps.limits.max_buffer_size) return error.OutOfBounds;
    var native = std.mem.zeroes(c.WGPUBufferDescriptor);
    native.label = sv(desc.label);
    native.usage = bufferUsage(desc.usage);
    // WebGPU requires buffer sizes to be multiples of 4 for copies and clears.
    native.size = std.mem.alignForward(u64, desc.size, 4);
    if (native.usage == 0) return error.MissingUsage;
    const raw = c.wgpuDeviceCreateBuffer(self.device, &native) orelse return error.GpuFailure;
    errdefer {
        c.wgpuBufferDestroy(raw);
        c.wgpuBufferRelease(raw);
    }
    try self.checkValidation(true);
    return self.buffers.acquire(self.allocator, .{ .raw = raw, .size = native.size, .usage = desc.usage });
}

fn destroyBuffer(ctx: *anyopaque, handle: gpu.BufferHandle) void {
    const self = dev(ctx);
    const buffer = self.buffers.release(handle) orelse return;
    c.wgpuBufferDestroy(buffer.raw);
    c.wgpuBufferRelease(buffer.raw);
}

fn writeBuffer(ctx: *anyopaque, handle: gpu.BufferHandle, offset: u64, data: []const u8) anyerror!void {
    const self = dev(ctx);
    const buffer = self.buffers.get(handle) orelse return error.InvalidHandle;
    if (!buffer.usage.copy_dst) return error.MissingUsage;
    if (offset % 4 != 0 or data.len % 4 != 0) return error.Unaligned;
    if (offset > buffer.size or data.len > buffer.size - offset) return error.OutOfBounds;
    if (data.len == 0) return;
    c.wgpuQueueWriteBuffer(self.queue, buffer.raw, offset, data.ptr, data.len);
    try self.checkValidation(false);
}

fn createTexture(ctx: *anyopaque, desc: gpu.TextureDesc) anyerror!gpu.TextureHandle {
    const self = dev(ctx);
    if (desc.width == 0 or desc.height == 0 or desc.depth_or_layers == 0 or desc.mip_levels == 0) return error.InvalidDescriptor;
    var native = std.mem.zeroes(c.WGPUTextureDescriptor);
    native.label = sv(desc.label);
    native.usage = textureUsage(desc.usage);
    native.dimension = textureDimension(desc.dimension);
    native.size = .{ .width = desc.width, .height = desc.height, .depthOrArrayLayers = desc.depth_or_layers };
    native.format = nativeFormat(desc.format);
    native.mipLevelCount = desc.mip_levels;
    native.sampleCount = desc.sample_count;
    if (native.usage == 0) return error.MissingUsage;
    const raw = c.wgpuDeviceCreateTexture(self.device, &native) orelse return error.GpuFailure;
    errdefer {
        c.wgpuTextureDestroy(raw);
        c.wgpuTextureRelease(raw);
    }
    try self.checkValidation(true);
    return self.textures.acquire(self.allocator, .{
        .raw = raw,
        .width = desc.width,
        .height = desc.height,
        .depth_or_layers = desc.depth_or_layers,
        .mip_levels = desc.mip_levels,
        .sample_count = desc.sample_count,
        .format = desc.format,
        .usage = desc.usage,
    });
}

fn destroyTexture(ctx: *anyopaque, handle: gpu.TextureHandle) void {
    const self = dev(ctx);
    const texture = self.textures.release(handle) orelse return;
    c.wgpuTextureDestroy(texture.raw);
    c.wgpuTextureRelease(texture.raw);
}

fn writeTexture(ctx: *anyopaque, dst: gpu.TextureCopyLocation, data: []const u8, layout: gpu.BufferLayout, ext: gpu.Extent3D) anyerror!void {
    const self = dev(ctx);
    const texture = self.textures.get(dst.texture) orelse return error.InvalidHandle;
    if (!texture.usage.copy_dst) return error.MissingUsage;
    const bpt = texture.format.bytesPerTexel();
    if (bpt == 0) return error.InvalidDescriptor;
    const row_bytes: u32 = if (layout.bytes_per_row != 0) layout.bytes_per_row else ext.width * bpt;
    const rows: u32 = if (layout.rows_per_image != 0) layout.rows_per_image else ext.height;
    const needed: u64 = layout.offset + @as(u64, row_bytes) * rows * (ext.depth_or_layers -| 1) + @as(u64, row_bytes) * (ext.height -| 1) + @as(u64, ext.width) * bpt;
    if (needed > data.len) return error.OutOfBounds;
    var destination = std.mem.zeroes(c.WGPUTexelCopyTextureInfo);
    destination.texture = texture.raw;
    destination.mipLevel = dst.mip_level;
    destination.origin = .{ .x = dst.origin[0], .y = dst.origin[1], .z = dst.origin[2] };
    destination.aspect = aspect(dst.aspect);
    const native_layout: c.WGPUTexelCopyBufferLayout = .{ .offset = layout.offset, .bytesPerRow = row_bytes, .rowsPerImage = rows };
    const native_extent = extent(ext);
    c.wgpuQueueWriteTexture(self.queue, &destination, data.ptr, data.len, &native_layout, &native_extent);
    try self.checkValidation(false);
}

fn createTextureView(ctx: *anyopaque, desc: gpu.TextureViewDesc) anyerror!gpu.TextureViewHandle {
    const self = dev(ctx);
    const texture = self.textures.get(desc.texture) orelse return error.InvalidHandle;
    var native = std.mem.zeroes(c.WGPUTextureViewDescriptor);
    native.label = sv(desc.label);
    native.format = if (desc.format) |f| nativeFormat(f) else c.WGPUTextureFormat_Undefined;
    native.dimension = if (desc.dimension) |d| viewDimension(d) else c.WGPUTextureViewDimension_Undefined;
    native.baseMipLevel = desc.base_mip;
    native.mipLevelCount = if (desc.mip_count == 0) undefined_u32 else desc.mip_count;
    native.baseArrayLayer = desc.base_layer;
    native.arrayLayerCount = if (desc.layer_count == 0) undefined_u32 else desc.layer_count;
    native.aspect = aspect(desc.aspect);
    const raw = c.wgpuTextureCreateView(texture.raw, &native) orelse return error.GpuFailure;
    errdefer c.wgpuTextureViewRelease(raw);
    try self.checkValidation(true);
    return self.views.acquire(self.allocator, .{ .raw = raw });
}

fn destroyTextureView(ctx: *anyopaque, handle: gpu.TextureViewHandle) void {
    const self = dev(ctx);
    const view = self.views.release(handle) orelse return;
    c.wgpuTextureViewRelease(view.raw);
}

fn createSampler(ctx: *anyopaque, desc: gpu.SamplerDesc) anyerror!gpu.SamplerHandle {
    const self = dev(ctx);
    var native = std.mem.zeroes(c.WGPUSamplerDescriptor);
    native.label = sv(desc.label);
    native.addressModeU = addressMode(desc.address_u);
    native.addressModeV = addressMode(desc.address_v);
    native.addressModeW = addressMode(desc.address_w);
    native.magFilter = filterMode(desc.mag_filter);
    native.minFilter = filterMode(desc.min_filter);
    native.mipmapFilter = mipmapFilter(desc.mipmap_filter);
    native.lodMinClamp = desc.lod_min;
    native.lodMaxClamp = desc.lod_max;
    native.compare = if (desc.compare) |f| compareFunction(f) else c.WGPUCompareFunction_Undefined;
    native.maxAnisotropy = @max(desc.max_anisotropy, 1);
    const raw = c.wgpuDeviceCreateSampler(self.device, &native) orelse return error.GpuFailure;
    errdefer c.wgpuSamplerRelease(raw);
    try self.checkValidation(true);
    return self.samplers.acquire(self.allocator, .{ .raw = raw });
}

fn destroySampler(ctx: *anyopaque, handle: gpu.SamplerHandle) void {
    const self = dev(ctx);
    const sampler = self.samplers.release(handle) orelse return;
    c.wgpuSamplerRelease(sampler.raw);
}

fn createShaderModule(ctx: *anyopaque, desc: gpu.ShaderModuleDesc) anyerror!gpu.ShaderModuleHandle {
    const self = dev(ctx);
    if (desc.wgsl.len == 0) return error.InvalidDescriptor;
    var wgsl = std.mem.zeroes(c.WGPUShaderSourceWGSL);
    wgsl.chain.sType = c.WGPUSType_ShaderSourceWGSL;
    wgsl.code = .{ .data = desc.wgsl.ptr, .length = desc.wgsl.len };
    var native = std.mem.zeroes(c.WGPUShaderModuleDescriptor);
    native.nextInChain = &wgsl.chain;
    native.label = sv(desc.label);
    const raw = c.wgpuDeviceCreateShaderModule(self.device, &native) orelse return error.GpuFailure;
    errdefer c.wgpuShaderModuleRelease(raw);
    try self.checkValidation(true);
    return self.shaders.acquire(self.allocator, .{ .raw = raw });
}

fn destroyShaderModule(ctx: *anyopaque, handle: gpu.ShaderModuleHandle) void {
    const self = dev(ctx);
    const shader = self.shaders.release(handle) orelse return;
    c.wgpuShaderModuleRelease(shader.raw);
}

fn createBindGroupLayout(ctx: *anyopaque, desc: gpu.BindGroupLayoutDesc) anyerror!gpu.BindGroupLayoutHandle {
    const self = dev(ctx);
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const entries = try arena.allocator().alloc(c.WGPUBindGroupLayoutEntry, desc.entries.len);
    for (desc.entries, entries) |src, *out| {
        // Zeroed binding layouts mean "BindingNotUsed", so only the active kind is filled in.
        out.* = std.mem.zeroes(c.WGPUBindGroupLayoutEntry);
        out.binding = src.binding;
        out.visibility = shaderStages(src.visibility);
        switch (src.kind) {
            .buffer => |b| out.buffer = .{
                .nextInChain = null,
                .type = switch (b.type) {
                    .uniform => c.WGPUBufferBindingType_Uniform,
                    .storage => c.WGPUBufferBindingType_Storage,
                    .read_only_storage => c.WGPUBufferBindingType_ReadOnlyStorage,
                },
                .hasDynamicOffset = @intFromBool(b.has_dynamic_offset),
                .minBindingSize = b.min_binding_size,
            },
            .sampler => |s| out.sampler = .{
                .nextInChain = null,
                .type = switch (s.type) {
                    .filtering => c.WGPUSamplerBindingType_Filtering,
                    .non_filtering => c.WGPUSamplerBindingType_NonFiltering,
                    .comparison => c.WGPUSamplerBindingType_Comparison,
                },
            },
            .texture => |t| out.texture = .{
                .nextInChain = null,
                .sampleType = switch (t.sample_type) {
                    .float => c.WGPUTextureSampleType_Float,
                    .unfilterable_float => c.WGPUTextureSampleType_UnfilterableFloat,
                    .depth => c.WGPUTextureSampleType_Depth,
                    .sint => c.WGPUTextureSampleType_Sint,
                    .uint => c.WGPUTextureSampleType_Uint,
                },
                .viewDimension = viewDimension(t.view_dimension),
                .multisampled = @intFromBool(t.multisampled),
            },
            .storage_texture => |t| out.storageTexture = .{
                .nextInChain = null,
                .access = switch (t.access) {
                    .write_only => c.WGPUStorageTextureAccess_WriteOnly,
                    .read_only => c.WGPUStorageTextureAccess_ReadOnly,
                    .read_write => c.WGPUStorageTextureAccess_ReadWrite,
                },
                .format = nativeFormat(t.format),
                .viewDimension = viewDimension(t.view_dimension),
            },
        }
    }
    var native = std.mem.zeroes(c.WGPUBindGroupLayoutDescriptor);
    native.label = sv(desc.label);
    native.entryCount = entries.len;
    native.entries = entries.ptr;
    const raw = c.wgpuDeviceCreateBindGroupLayout(self.device, &native) orelse return error.GpuFailure;
    errdefer c.wgpuBindGroupLayoutRelease(raw);
    try self.checkValidation(true);
    return self.bind_layouts.acquire(self.allocator, .{ .raw = raw });
}

fn destroyBindGroupLayout(ctx: *anyopaque, handle: gpu.BindGroupLayoutHandle) void {
    const self = dev(ctx);
    const layout = self.bind_layouts.release(handle) orelse return;
    c.wgpuBindGroupLayoutRelease(layout.raw);
}

fn createBindGroup(ctx: *anyopaque, desc: gpu.BindGroupDesc) anyerror!gpu.BindGroupHandle {
    const self = dev(ctx);
    const layout = self.bind_layouts.get(desc.layout) orelse return error.InvalidHandle;
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const entries = try arena.allocator().alloc(c.WGPUBindGroupEntry, desc.entries.len);
    for (desc.entries, entries) |src, *out| {
        out.* = std.mem.zeroes(c.WGPUBindGroupEntry);
        out.binding = src.binding;
        switch (src.resource) {
            .buffer => |b| {
                const buffer = self.buffers.get(b.buffer) orelse return error.InvalidHandle;
                out.buffer = buffer.raw;
                out.offset = b.offset;
                out.size = if (b.size == 0) buffer.size - @min(b.offset, buffer.size) else b.size;
            },
            .sampler => |h| out.sampler = (self.samplers.get(h) orelse return error.InvalidHandle).raw,
            .texture_view => |h| out.textureView = (self.views.get(h) orelse return error.InvalidHandle).raw,
        }
    }
    var native = std.mem.zeroes(c.WGPUBindGroupDescriptor);
    native.label = sv(desc.label);
    native.layout = layout.raw;
    native.entryCount = entries.len;
    native.entries = entries.ptr;
    const raw = c.wgpuDeviceCreateBindGroup(self.device, &native) orelse return error.GpuFailure;
    errdefer c.wgpuBindGroupRelease(raw);
    try self.checkValidation(true);
    return self.bind_groups.acquire(self.allocator, .{ .raw = raw });
}

fn destroyBindGroup(ctx: *anyopaque, handle: gpu.BindGroupHandle) void {
    const self = dev(ctx);
    const group = self.bind_groups.release(handle) orelse return;
    c.wgpuBindGroupRelease(group.raw);
}

fn createPipelineLayout(ctx: *anyopaque, desc: gpu.PipelineLayoutDesc) anyerror!gpu.PipelineLayoutHandle {
    const self = dev(ctx);
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const layouts = try arena.allocator().alloc(c.WGPUBindGroupLayout, desc.bind_group_layouts.len);
    for (desc.bind_group_layouts, layouts) |h, *out| out.* = (self.bind_layouts.get(h) orelse return error.InvalidHandle).raw;
    var native = std.mem.zeroes(c.WGPUPipelineLayoutDescriptor);
    native.label = sv(desc.label);
    native.bindGroupLayoutCount = layouts.len;
    native.bindGroupLayouts = layouts.ptr;
    const raw = c.wgpuDeviceCreatePipelineLayout(self.device, &native) orelse return error.GpuFailure;
    errdefer c.wgpuPipelineLayoutRelease(raw);
    try self.checkValidation(true);
    return self.pipeline_layouts.acquire(self.allocator, .{ .raw = raw });
}

fn destroyPipelineLayout(ctx: *anyopaque, handle: gpu.PipelineLayoutHandle) void {
    const self = dev(ctx);
    const layout = self.pipeline_layouts.release(handle) orelse return;
    c.wgpuPipelineLayoutRelease(layout.raw);
}

fn createRenderPipeline(ctx: *anyopaque, desc: gpu.RenderPipelineDesc) anyerror!gpu.RenderPipelineHandle {
    const self = dev(ctx);
    const layout = self.pipeline_layouts.get(desc.layout) orelse return error.InvalidHandle;
    const shader = self.shaders.get(desc.shader) orelse return error.InvalidHandle;
    const fragment_module = if (desc.fragment_shader) |h| (self.shaders.get(h) orelse return error.InvalidHandle).raw else shader.raw;
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const buffers = try a.alloc(c.WGPUVertexBufferLayout, desc.vertex_buffers.len);
    for (desc.vertex_buffers, buffers) |src, *out| {
        const attributes = try a.alloc(c.WGPUVertexAttribute, src.attributes.len);
        for (src.attributes, attributes) |attr, *attr_out| {
            attr_out.* = .{ .nextInChain = null, .format = vertexFormat(attr.format), .offset = attr.offset, .shaderLocation = attr.shader_location };
        }
        out.* = .{
            .nextInChain = null,
            .stepMode = if (src.step_mode == .vertex) c.WGPUVertexStepMode_Vertex else c.WGPUVertexStepMode_Instance,
            .arrayStride = src.stride,
            .attributeCount = attributes.len,
            .attributes = attributes.ptr,
        };
    }

    const blends = try a.alloc(c.WGPUBlendState, desc.color_targets.len);
    const targets = try a.alloc(c.WGPUColorTargetState, desc.color_targets.len);
    for (desc.color_targets, targets, blends) |src, *out, *blend_out| {
        out.* = std.mem.zeroes(c.WGPUColorTargetState);
        out.format = nativeFormat(src.format);
        if (src.blend) |b| {
            blend_out.* = .{ .color = blendComponent(b.color), .alpha = blendComponent(b.alpha) };
            out.blend = blend_out;
        }
        var mask: c.WGPUColorWriteMask = 0;
        if (src.write_mask.r) mask |= c.WGPUColorWriteMask_Red;
        if (src.write_mask.g) mask |= c.WGPUColorWriteMask_Green;
        if (src.write_mask.b) mask |= c.WGPUColorWriteMask_Blue;
        if (src.write_mask.a) mask |= c.WGPUColorWriteMask_Alpha;
        out.writeMask = mask;
    }

    var fragment = std.mem.zeroes(c.WGPUFragmentState);
    if (desc.fragment_entry) |entry| {
        fragment.module = fragment_module;
        fragment.entryPoint = .{ .data = entry.ptr, .length = entry.len };
        fragment.targetCount = targets.len;
        fragment.targets = targets.ptr;
    }

    var depth = std.mem.zeroes(c.WGPUDepthStencilState);
    if (desc.depth_stencil) |ds| {
        depth.format = nativeFormat(ds.format);
        depth.depthWriteEnabled = if (ds.depth_write) c.WGPUOptionalBool_True else c.WGPUOptionalBool_False;
        depth.depthCompare = compareFunction(ds.depth_compare);
        depth.stencilReadMask = 0xFFFFFFFF;
        depth.stencilWriteMask = 0xFFFFFFFF;
        depth.depthBias = ds.depth_bias;
        depth.depthBiasSlopeScale = ds.depth_bias_slope_scale;
        depth.depthBiasClamp = ds.depth_bias_clamp;
    }

    var native = std.mem.zeroes(c.WGPURenderPipelineDescriptor);
    native.label = sv(desc.label);
    native.layout = layout.raw;
    native.vertex = .{
        .nextInChain = null,
        .module = shader.raw,
        .entryPoint = .{ .data = desc.vertex_entry.ptr, .length = desc.vertex_entry.len },
        .constantCount = 0,
        .constants = null,
        .bufferCount = buffers.len,
        .buffers = buffers.ptr,
    };
    native.primitive = std.mem.zeroes(c.WGPUPrimitiveState);
    native.primitive.topology = topology(desc.topology);
    native.primitive.frontFace = frontFace(desc.front_face);
    native.primitive.cullMode = cullMode(desc.cull_mode);
    if (desc.depth_stencil != null) native.depthStencil = &depth;
    native.multisample = .{ .nextInChain = null, .count = desc.sample_count, .mask = 0xFFFFFFFF, .alphaToCoverageEnabled = 0 };
    if (desc.fragment_entry != null) native.fragment = &fragment;

    const raw = c.wgpuDeviceCreateRenderPipeline(self.device, &native) orelse return error.GpuFailure;
    errdefer c.wgpuRenderPipelineRelease(raw);
    try self.checkValidation(true);
    return self.render_pipelines.acquire(self.allocator, .{ .raw = raw });
}

fn destroyRenderPipeline(ctx: *anyopaque, handle: gpu.RenderPipelineHandle) void {
    const self = dev(ctx);
    const pipeline = self.render_pipelines.release(handle) orelse return;
    c.wgpuRenderPipelineRelease(pipeline.raw);
}

fn createComputePipeline(ctx: *anyopaque, desc: gpu.ComputePipelineDesc) anyerror!gpu.ComputePipelineHandle {
    const self = dev(ctx);
    const layout = self.pipeline_layouts.get(desc.layout) orelse return error.InvalidHandle;
    const shader = self.shaders.get(desc.shader) orelse return error.InvalidHandle;
    var native = std.mem.zeroes(c.WGPUComputePipelineDescriptor);
    native.label = sv(desc.label);
    native.layout = layout.raw;
    native.compute = .{
        .nextInChain = null,
        .module = shader.raw,
        .entryPoint = .{ .data = desc.entry.ptr, .length = desc.entry.len },
        .constantCount = 0,
        .constants = null,
    };
    const raw = c.wgpuDeviceCreateComputePipeline(self.device, &native) orelse return error.GpuFailure;
    errdefer c.wgpuComputePipelineRelease(raw);
    try self.checkValidation(true);
    return self.compute_pipelines.acquire(self.allocator, .{ .raw = raw });
}

fn destroyComputePipeline(ctx: *anyopaque, handle: gpu.ComputePipelineHandle) void {
    const self = dev(ctx);
    const pipeline = self.compute_pipelines.release(handle) orelse return;
    c.wgpuComputePipelineRelease(pipeline.raw);
}

fn createQuerySet(ctx: *anyopaque, desc: gpu.QuerySetDesc) anyerror!gpu.QuerySetHandle {
    const self = dev(ctx);
    if (!self.caps.features.timestamp_query) return error.FeatureUnsupported;
    if (desc.count == 0) return error.InvalidDescriptor;
    var native = std.mem.zeroes(c.WGPUQuerySetDescriptor);
    native.label = sv(desc.label);
    native.type = c.WGPUQueryType_Timestamp;
    native.count = desc.count;
    const raw = c.wgpuDeviceCreateQuerySet(self.device, &native) orelse return error.GpuFailure;
    // Release alone frees a query set: wgpu-native's Destroy already drops it, so Destroy+Release panics.
    errdefer c.wgpuQuerySetRelease(raw);
    try self.checkValidation(true);
    return self.query_sets.acquire(self.allocator, .{ .raw = raw, .count = desc.count });
}

fn destroyQuerySet(ctx: *anyopaque, handle: gpu.QuerySetHandle) void {
    const self = dev(ctx);
    const set = self.query_sets.release(handle) orelse return;
    c.wgpuQuerySetRelease(set.raw);
}

// ---------------------------------------------------------------------------------------------
// Command replay
// ---------------------------------------------------------------------------------------------

const PassState = struct {
    render: c.WGPURenderPassEncoder = null,
    compute: c.WGPUComputePassEncoder = null,
    /// A swapchain frame was unavailable (minimized/outdated): drop this pass instead of failing the frame.
    skipping: bool = false,
};

fn timestampWrites(self: *Device, ts: ?gpu.PassTimestamps, storage: *c.WGPUPassTimestampWrites) !?*const c.WGPUPassTimestampWrites {
    const t = ts orelse return null;
    const set = self.query_sets.get(t.query_set) orelse return error.InvalidHandle;
    storage.* = .{
        .nextInChain = null,
        .querySet = set.raw,
        .beginningOfPassWriteIndex = t.begin_index orelse undefined_u32,
        .endOfPassWriteIndex = t.end_index orelse undefined_u32,
    };
    return storage;
}

/// Returns the swapchain view, or null when the frame must be skipped.
fn acquireSwapchain(self: *Device) !?TextureViewPtr {
    if (self.frame_view) |existing| return existing;
    var view: ?*anyopaque = null;
    var w: u32 = 0;
    var h: u32 = 0;
    switch (zwgpu_swapchain_acquire(self.bridge, &view, &w, &h)) {
        0 => return error.SurfaceFailure,
        2 => return null,
        else => {},
    }
    self.frame_acquired = true;
    self.frame_view = @ptrCast(@alignCast(view));
    return self.frame_view;
}

fn beginRenderPass(self: *Device, encoder: c.WGPUCommandEncoder, desc: gpu.RenderPassDesc, state: *PassState) !void {
    if (desc.color_attachments.len > 8) return error.InvalidDescriptor;
    var colors: [8]c.WGPURenderPassColorAttachment = undefined;
    for (desc.color_attachments, 0..) |att, i| {
        const view: c.WGPUTextureView = switch (att.target) {
            .view => |h| (self.views.get(h) orelse return error.InvalidHandle).raw,
            .swapchain => blk: {
                break :blk (try acquireSwapchain(self)) orelse {
                    state.skipping = true;
                    return;
                };
            },
        };
        colors[i] = std.mem.zeroes(c.WGPURenderPassColorAttachment);
        colors[i].view = view;
        colors[i].depthSlice = undefined_u32;
        colors[i].resolveTarget = if (att.resolve_target) |r| (self.views.get(r) orelse return error.InvalidHandle).raw else null;
        colors[i].loadOp = loadOp(att.load);
        colors[i].storeOp = storeOp(att.store);
        colors[i].clearValue = .{ .r = att.clear_value.r, .g = att.clear_value.g, .b = att.clear_value.b, .a = att.clear_value.a };
    }
    var depth_native = std.mem.zeroes(c.WGPURenderPassDepthStencilAttachment);
    var native = std.mem.zeroes(c.WGPURenderPassDescriptor);
    native.label = sv(desc.label);
    native.colorAttachmentCount = desc.color_attachments.len;
    native.colorAttachments = &colors;
    if (desc.depth) |d| {
        depth_native.view = (self.views.get(d.view) orelse return error.InvalidHandle).raw;
        depth_native.depthLoadOp = loadOp(d.depth_load);
        depth_native.depthStoreOp = storeOp(d.depth_store);
        depth_native.depthClearValue = d.depth_clear;
        depth_native.depthReadOnly = @intFromBool(d.read_only);
        depth_native.stencilLoadOp = c.WGPULoadOp_Undefined;
        depth_native.stencilStoreOp = c.WGPUStoreOp_Undefined;
        native.depthStencilAttachment = &depth_native;
    }
    var ts_storage: c.WGPUPassTimestampWrites = undefined;
    native.timestampWrites = try timestampWrites(self, desc.timestamps, &ts_storage);
    state.render = c.wgpuCommandEncoderBeginRenderPass(encoder, &native) orelse return error.GpuFailure;
}

fn beginComputePass(self: *Device, encoder: c.WGPUCommandEncoder, desc: gpu.ComputePassDesc, state: *PassState) !void {
    var native = std.mem.zeroes(c.WGPUComputePassDescriptor);
    native.label = sv(desc.label);
    var ts_storage: c.WGPUPassTimestampWrites = undefined;
    native.timestampWrites = try timestampWrites(self, desc.timestamps, &ts_storage);
    state.compute = c.wgpuCommandEncoderBeginComputePass(encoder, &native) orelse return error.GpuFailure;
}

fn endOpenPasses(state: *PassState) void {
    if (state.render != null) {
        c.wgpuRenderPassEncoderEnd(state.render);
        c.wgpuRenderPassEncoderRelease(state.render);
        state.render = null;
    }
    if (state.compute != null) {
        c.wgpuComputePassEncoderEnd(state.compute);
        c.wgpuComputePassEncoderRelease(state.compute);
        state.compute = null;
    }
}

fn texelCopy(self: *Device, loc: gpu.TextureCopyLocation) !c.WGPUTexelCopyTextureInfo {
    const texture = self.textures.get(loc.texture) orelse return error.InvalidHandle;
    var info = std.mem.zeroes(c.WGPUTexelCopyTextureInfo);
    info.texture = texture.raw;
    info.mipLevel = loc.mip_level;
    info.origin = .{ .x = loc.origin[0], .y = loc.origin[1], .z = loc.origin[2] };
    info.aspect = aspect(loc.aspect);
    return info;
}

fn bufferLayout(layout: gpu.BufferLayout, fallback_width_bytes: u32, height: u32, depth: u32) c.WGPUTexelCopyBufferLayout {
    const row = if (layout.bytes_per_row != 0) layout.bytes_per_row else gpu.alignedBytesPerRow(fallback_width_bytes);
    const rows = if (layout.rows_per_image != 0) layout.rows_per_image else if (depth > 1) height else undefined_u32;
    return .{ .offset = layout.offset, .bytesPerRow = row, .rowsPerImage = rows };
}

fn submit(ctx: *anyopaque, commands: []const gpu.Command) anyerror!void {
    const self = dev(ctx);
    var enc_desc = std.mem.zeroes(c.WGPUCommandEncoderDescriptor);
    enc_desc.label = sv("zengy frame");
    const encoder = c.wgpuDeviceCreateCommandEncoder(self.device, &enc_desc) orelse return error.GpuFailure;
    defer c.wgpuCommandEncoderRelease(encoder);

    var state: PassState = .{};
    // Errors unwind in reverse order: end open passes first (WebGPU requires it before the encoder is
    // released), then drop the swapchain frame so the next frame can acquire again.
    errdefer self.abortFrame();
    errdefer endOpenPasses(&state);

    for (commands) |command| {
        if (state.skipping) {
            // Skip every command of a dropped pass until its end marker.
            switch (command) {
                .end_render_pass => state.skipping = false,
                else => {},
            }
            continue;
        }
        switch (command) {
            .begin_render_pass => |desc| {
                if (state.render != null or state.compute != null) return error.PassMismatch;
                try beginRenderPass(self, encoder, desc, &state);
            },
            .end_render_pass => {
                if (state.render == null) return error.PassMismatch;
                endOpenPasses(&state);
            },
            .begin_compute_pass => |desc| {
                if (state.render != null or state.compute != null) return error.PassMismatch;
                try beginComputePass(self, encoder, desc, &state);
            },
            .end_compute_pass => {
                if (state.compute == null) return error.PassMismatch;
                endOpenPasses(&state);
            },
            .set_render_pipeline => |h| {
                if (state.render == null) return error.PassMismatch;
                const p = self.render_pipelines.get(h) orelse return error.InvalidHandle;
                c.wgpuRenderPassEncoderSetPipeline(state.render, p.raw);
            },
            .set_compute_pipeline => |h| {
                if (state.compute == null) return error.PassMismatch;
                const p = self.compute_pipelines.get(h) orelse return error.InvalidHandle;
                c.wgpuComputePassEncoderSetPipeline(state.compute, p.raw);
            },
            .set_bind_group => |b| {
                const group = self.bind_groups.get(b.group) orelse return error.InvalidHandle;
                const offsets: [*c]const u32 = if (b.dynamic_offsets.len == 0) null else b.dynamic_offsets.ptr;
                if (state.render != null) {
                    c.wgpuRenderPassEncoderSetBindGroup(state.render, b.index, group.raw, b.dynamic_offsets.len, offsets);
                } else if (state.compute != null) {
                    c.wgpuComputePassEncoderSetBindGroup(state.compute, b.index, group.raw, b.dynamic_offsets.len, offsets);
                } else return error.PassMismatch;
            },
            .set_vertex_buffer => |v| {
                if (state.render == null) return error.PassMismatch;
                const buffer = self.buffers.get(v.buffer) orelse return error.InvalidHandle;
                c.wgpuRenderPassEncoderSetVertexBuffer(state.render, v.slot, buffer.raw, v.offset, if (v.size == 0) whole_size else v.size);
            },
            .set_index_buffer => |v| {
                if (state.render == null) return error.PassMismatch;
                const buffer = self.buffers.get(v.buffer) orelse return error.InvalidHandle;
                const format: c.WGPUIndexFormat = if (v.format == .uint16) c.WGPUIndexFormat_Uint16 else c.WGPUIndexFormat_Uint32;
                c.wgpuRenderPassEncoderSetIndexBuffer(state.render, buffer.raw, format, v.offset, if (v.size == 0) whole_size else v.size);
            },
            .set_viewport => |v| {
                if (state.render == null) return error.PassMismatch;
                c.wgpuRenderPassEncoderSetViewport(state.render, v.x, v.y, v.width, v.height, v.min_depth, v.max_depth);
            },
            .set_scissor => |v| {
                if (state.render == null) return error.PassMismatch;
                c.wgpuRenderPassEncoderSetScissorRect(state.render, v.x, v.y, v.width, v.height);
            },
            .set_blend_constant => |v| {
                if (state.render == null) return error.PassMismatch;
                const color: c.WGPUColor = .{ .r = v.r, .g = v.g, .b = v.b, .a = v.a };
                c.wgpuRenderPassEncoderSetBlendConstant(state.render, &color);
            },
            .draw => |d| {
                if (state.render == null) return error.PassMismatch;
                c.wgpuRenderPassEncoderDraw(state.render, d.vertex_count, d.instance_count, d.first_vertex, d.first_instance);
            },
            .draw_indexed => |d| {
                if (state.render == null) return error.PassMismatch;
                c.wgpuRenderPassEncoderDrawIndexed(state.render, d.index_count, d.instance_count, d.first_index, d.base_vertex, d.first_instance);
            },
            .draw_indirect => |d| {
                if (state.render == null) return error.PassMismatch;
                const buffer = self.buffers.get(d.buffer) orelse return error.InvalidHandle;
                c.wgpuRenderPassEncoderDrawIndirect(state.render, buffer.raw, d.offset);
            },
            .dispatch => |d| {
                if (state.compute == null) return error.PassMismatch;
                c.wgpuComputePassEncoderDispatchWorkgroups(state.compute, d.x, d.y, d.z);
            },
            .dispatch_indirect => |d| {
                if (state.compute == null) return error.PassMismatch;
                const buffer = self.buffers.get(d.buffer) orelse return error.InvalidHandle;
                c.wgpuComputePassEncoderDispatchWorkgroupsIndirect(state.compute, buffer.raw, d.offset);
            },
            .copy_buffer_to_buffer => |d| {
                if (state.render != null or state.compute != null) return error.PassMismatch;
                const src = self.buffers.get(d.src) orelse return error.InvalidHandle;
                const dst = self.buffers.get(d.dst) orelse return error.InvalidHandle;
                c.wgpuCommandEncoderCopyBufferToBuffer(encoder, src.raw, d.src_offset, dst.raw, d.dst_offset, d.size);
            },
            .copy_texture_to_buffer => |d| {
                if (state.render != null or state.compute != null) return error.PassMismatch;
                const dst = self.buffers.get(d.dst) orelse return error.InvalidHandle;
                const tex = self.textures.get(d.src.texture) orelse return error.InvalidHandle;
                const src_info = try texelCopy(self, d.src);
                var dst_info: c.WGPUTexelCopyBufferInfo = .{ .layout = bufferLayout(d.layout, d.extent.width * tex.format.bytesPerTexel(), d.extent.height, d.extent.depth_or_layers), .buffer = dst.raw };
                const ext = extent(d.extent);
                c.wgpuCommandEncoderCopyTextureToBuffer(encoder, &src_info, &dst_info, &ext);
            },
            .copy_buffer_to_texture => |d| {
                if (state.render != null or state.compute != null) return error.PassMismatch;
                const src = self.buffers.get(d.src) orelse return error.InvalidHandle;
                const tex = self.textures.get(d.dst.texture) orelse return error.InvalidHandle;
                const dst_info = try texelCopy(self, d.dst);
                var src_info: c.WGPUTexelCopyBufferInfo = .{ .layout = bufferLayout(d.layout, d.extent.width * tex.format.bytesPerTexel(), d.extent.height, d.extent.depth_or_layers), .buffer = src.raw };
                const ext = extent(d.extent);
                c.wgpuCommandEncoderCopyBufferToTexture(encoder, &src_info, &dst_info, &ext);
            },
            .copy_texture_to_texture => |d| {
                if (state.render != null or state.compute != null) return error.PassMismatch;
                const src_info = try texelCopy(self, d.src);
                const dst_info = try texelCopy(self, d.dst);
                const ext = extent(d.extent);
                c.wgpuCommandEncoderCopyTextureToTexture(encoder, &src_info, &dst_info, &ext);
            },
            .copy_swapchain_to_buffer => |d| {
                if (state.render != null or state.compute != null) return error.PassMismatch;
                const dst = self.buffers.get(d.dst) orelse return error.InvalidHandle;
                var w: u32 = 0;
                var h: u32 = 0;
                // No acquired frame means no pass drew to the swapchain yet: there is nothing to capture.
                const raw = zwgpu_frame_texture(self.bridge, &w, &h) orelse return error.InvalidDescriptor;
                var src_info = std.mem.zeroes(c.WGPUTexelCopyTextureInfo);
                src_info.texture = @ptrCast(raw);
                src_info.aspect = c.WGPUTextureAspect_All;
                const bytes_per_texel = (self.surfaceFormat() orelse return error.InvalidDescriptor).bytesPerTexel();
                var dst_info: c.WGPUTexelCopyBufferInfo = .{ .layout = bufferLayout(d.layout, w * bytes_per_texel, h, 1), .buffer = dst.raw };
                const ext: c.WGPUExtent3D = .{ .width = w, .height = h, .depthOrArrayLayers = 1 };
                c.wgpuCommandEncoderCopyTextureToBuffer(encoder, &src_info, &dst_info, &ext);
            },
            .clear_buffer => |d| {
                if (state.render != null or state.compute != null) return error.PassMismatch;
                const buffer = self.buffers.get(d.buffer) orelse return error.InvalidHandle;
                c.wgpuCommandEncoderClearBuffer(encoder, buffer.raw, d.offset, if (d.size == 0) whole_size else d.size);
            },
            .resolve_query_set => |d| {
                if (state.render != null or state.compute != null) return error.PassMismatch;
                const set = self.query_sets.get(d.query_set) orelse return error.InvalidHandle;
                const dst = self.buffers.get(d.dst) orelse return error.InvalidHandle;
                c.wgpuCommandEncoderResolveQuerySet(encoder, set.raw, d.first, d.count, dst.raw, d.dst_offset);
            },
            .push_debug_group => |label| {
                c.wgpuCommandEncoderPushDebugGroup(encoder, sv(label));
            },
            .pop_debug_group => c.wgpuCommandEncoderPopDebugGroup(encoder),
        }
    }
    if (state.render != null or state.compute != null) return error.PassMismatch;

    const buffer = c.wgpuCommandEncoderFinish(encoder, null) orelse return error.GpuFailure;
    defer c.wgpuCommandBufferRelease(buffer);
    var to_submit = buffer;
    c.wgpuQueueSubmit(self.queue, 1, &to_submit);
    try self.checkValidation(true);
}

// ---------------------------------------------------------------------------------------------
// Readback and polling
// ---------------------------------------------------------------------------------------------

fn mapCallback(status: c.WGPUMapAsyncStatus, _: c.WGPUStringView, userdata1: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const state: *ReadbackState = @ptrCast(@alignCast(userdata1.?));
    state.status.store(if (status == c.WGPUMapAsyncStatus_Success) 1 else 2, .release);
}

fn beginReadback(ctx: *anyopaque, handle: gpu.BufferHandle, offset: u64, size: u64) anyerror!gpu.ReadbackHandle {
    const self = dev(ctx);
    const buffer = self.buffers.get(handle) orelse return error.InvalidHandle;
    if (!buffer.usage.map_read) return error.MissingUsage;
    if (offset % 8 != 0 or size % 4 != 0 or size == 0) return error.Unaligned;
    if (offset > buffer.size or size > buffer.size - offset) return error.OutOfBounds;

    const state = try self.allocator.create(ReadbackState);
    errdefer self.allocator.destroy(state);
    // Hold a reference so destroying the engine handle cannot free the buffer under a pending map.
    c.wgpuBufferAddRef(buffer.raw);
    state.* = .{ .buffer = buffer.raw, .offset = offset, .size = size };
    errdefer c.wgpuBufferRelease(buffer.raw);
    _ = c.wgpuBufferMapAsync(buffer.raw, c.WGPUMapMode_Read, offset, size, .{
        .nextInChain = null,
        .mode = c.WGPUCallbackMode_AllowProcessEvents,
        .callback = mapCallback,
        .userdata1 = state,
        .userdata2 = null,
    });
    try self.checkValidation(true);
    return self.readbacks.acquire(self.allocator, state);
}

fn pollReadback(ctx: *anyopaque, handle: gpu.ReadbackHandle, out: []u8) anyerror!bool {
    const self = dev(ctx);
    const state = (self.readbacks.get(handle) orelse return error.InvalidHandle).*;
    if (out.len != state.size) return error.OutOfBounds;
    poll(ctx, false);
    switch (state.status.load(.acquire)) {
        0 => return false,
        1 => {
            const ptr = c.wgpuBufferGetConstMappedRange(state.buffer, state.offset, state.size);
            if (ptr == null) {
                finishReadback(self, handle, state, false);
                return error.ReadbackFailed;
            }
            const bytes: [*]const u8 = @ptrCast(ptr);
            @memcpy(out, bytes[0..out.len]);
            finishReadback(self, handle, state, true);
            return true;
        },
        else => {
            finishReadback(self, handle, state, false);
            return error.ReadbackFailed;
        },
    }
}

fn finishReadback(self: *Device, handle: gpu.ReadbackHandle, state: *ReadbackState, mapped: bool) void {
    if (mapped) c.wgpuBufferUnmap(state.buffer);
    c.wgpuBufferRelease(state.buffer);
    self.allocator.destroy(state);
    _ = self.readbacks.release(handle);
}

fn poll(ctx: *anyopaque, wait: bool) void {
    const self = dev(ctx);
    _ = c.wgpuDevicePoll(self.device, @intFromBool(wait), null);
    c.wgpuInstanceProcessEvents(self.instance);
}

pub const vtable: gpu.GpuDevice.VTable = .{
    .capabilities = getCapabilities,
    .create_buffer = createBuffer,
    .destroy_buffer = destroyBuffer,
    .write_buffer = writeBuffer,
    .create_texture = createTexture,
    .destroy_texture = destroyTexture,
    .write_texture = writeTexture,
    .create_texture_view = createTextureView,
    .destroy_texture_view = destroyTextureView,
    .create_sampler = createSampler,
    .destroy_sampler = destroySampler,
    .create_shader_module = createShaderModule,
    .destroy_shader_module = destroyShaderModule,
    .create_bind_group_layout = createBindGroupLayout,
    .destroy_bind_group_layout = destroyBindGroupLayout,
    .create_bind_group = createBindGroup,
    .destroy_bind_group = destroyBindGroup,
    .create_pipeline_layout = createPipelineLayout,
    .destroy_pipeline_layout = destroyPipelineLayout,
    .create_render_pipeline = createRenderPipeline,
    .destroy_render_pipeline = destroyRenderPipeline,
    .create_compute_pipeline = createComputePipeline,
    .destroy_compute_pipeline = destroyComputePipeline,
    .create_query_set = createQuerySet,
    .destroy_query_set = destroyQuerySet,
    .submit = submit,
    .begin_readback = beginReadback,
    .poll_readback = pollReadback,
    .poll = poll,
};
