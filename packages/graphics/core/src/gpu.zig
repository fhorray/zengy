//! Backend-neutral GPU resource and command contract.
//!
//! Providers (today `official.graphics.wgpu`) implement `GpuDevice`; renderers (`render/2d`, `render/3d`,
//! `render/prism`, `render/helios`) only ever see the handles, descriptors and `Command` list defined here.
//! No backend-specific type or pointer crosses this boundary.
//!
//! Ownership and lifetime rules:
//! - Handles are generational: using a destroyed handle returns `error.InvalidHandle`, never undefined behavior.
//! - Descriptors borrow their slices only for the duration of the creating call.
//! - A `Command` list borrows the memory of the `CommandRecorder` that produced it; submit before `reset()`.
//! - Resources are persistent. Providers must not allocate per frame on the steady-state path.

const std = @import("std");

/// Distinguishes handle types at compile time so a buffer handle can never be passed as a texture handle.
pub const HandleKind = enum { buffer, texture, texture_view, sampler, shader_module, bind_group_layout, bind_group, pipeline_layout, render_pipeline, compute_pipeline, query_set, readback };

/// Generational handle: `index` addresses a pool slot, `generation` detects stale uses.
pub fn Handle(comptime kind: HandleKind) type {
    return packed struct(u64) {
        index: u32,
        generation: u32,

        pub const tag = kind;
        /// A handle that is never valid (generation 0 is never issued).
        pub const none: @This() = .{ .index = std.math.maxInt(u32), .generation = 0 };

        pub fn isNone(self: @This()) bool {
            return self.generation == 0;
        }
        pub fn eql(a: @This(), b: @This()) bool {
            return a.index == b.index and a.generation == b.generation;
        }
    };
}

pub const BufferHandle = Handle(.buffer);
pub const TextureHandle = Handle(.texture);
pub const TextureViewHandle = Handle(.texture_view);
pub const SamplerHandle = Handle(.sampler);
pub const ShaderModuleHandle = Handle(.shader_module);
pub const BindGroupLayoutHandle = Handle(.bind_group_layout);
pub const BindGroupHandle = Handle(.bind_group);
pub const PipelineLayoutHandle = Handle(.pipeline_layout);
pub const RenderPipelineHandle = Handle(.render_pipeline);
pub const ComputePipelineHandle = Handle(.compute_pipeline);
pub const QuerySetHandle = Handle(.query_set);
pub const ReadbackHandle = Handle(.readback);

/// Generational slot pool shared by every provider. Slots are reused; a released slot bumps its generation.
pub fn HandlePool(comptime T: type, comptime H: type) type {
    return struct {
        const Self = @This();
        const Slot = struct { value: T, generation: u32, alive: bool };

        slots: std.ArrayList(Slot) = .empty,
        free: std.ArrayList(u32) = .empty,
        live: u32 = 0,

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.slots.deinit(allocator);
            self.free.deinit(allocator);
        }

        /// Stores `value` and returns a fresh handle. Reuses freed slots before growing.
        pub fn acquire(self: *Self, allocator: std.mem.Allocator, value: T) !H {
            if (self.free.pop()) |index| {
                const slot = &self.slots.items[index];
                slot.value = value;
                slot.alive = true;
                self.live += 1;
                return .{ .index = index, .generation = slot.generation };
            }
            if (self.slots.items.len >= std.math.maxInt(u32) - 1) return error.OutOfHandles;
            try self.free.ensureTotalCapacity(allocator, self.slots.items.len + 1);
            try self.slots.append(allocator, .{ .value = value, .generation = 1, .alive = true });
            self.live += 1;
            return .{ .index = @intCast(self.slots.items.len - 1), .generation = 1 };
        }

        pub fn get(self: *Self, handle: H) ?*T {
            if (handle.index >= self.slots.items.len) return null;
            const slot = &self.slots.items[handle.index];
            if (!slot.alive or slot.generation != handle.generation) return null;
            return &slot.value;
        }

        /// Invalidates `handle` and returns the stored value so the caller can destroy the native object.
        pub fn release(self: *Self, handle: H) ?T {
            if (handle.index >= self.slots.items.len) return null;
            const slot = &self.slots.items[handle.index];
            if (!slot.alive or slot.generation != handle.generation) return null;
            slot.alive = false;
            slot.generation +%= 1;
            if (slot.generation == 0) slot.generation = 1;
            self.live -= 1;
            // Capacity was reserved in `acquire`, so this cannot fail.
            self.free.appendAssumeCapacity(handle.index);
            return slot.value;
        }

        pub fn count(self: *const Self) u32 {
            return self.live;
        }
    };
}

pub const TextureFormat = enum {
    r8_unorm,
    rg8_unorm,
    rgba8_unorm,
    rgba8_unorm_srgb,
    bgra8_unorm,
    bgra8_unorm_srgb,
    r16_float,
    rg16_float,
    rgba16_float,
    r32_float,
    rg32_float,
    rgba32_float,
    r32_uint,
    rg11b10_ufloat,
    rgb10a2_unorm,
    depth16_unorm,
    depth24_plus,
    depth24_plus_stencil8,
    depth32_float,

    pub fn isDepth(self: TextureFormat) bool {
        return switch (self) {
            .depth16_unorm, .depth24_plus, .depth24_plus_stencil8, .depth32_float => true,
            else => false,
        };
    }

    /// Bytes per texel for uncompressed color formats; 0 for depth formats (not directly copyable).
    pub fn bytesPerTexel(self: TextureFormat) u32 {
        return switch (self) {
            .r8_unorm => 1,
            .rg8_unorm, .r16_float => 2,
            .rgba8_unorm, .rgba8_unorm_srgb, .bgra8_unorm, .bgra8_unorm_srgb, .rg16_float, .r32_float, .r32_uint, .rg11b10_ufloat, .rgb10a2_unorm => 4,
            .rgba16_float, .rg32_float => 8,
            .rgba32_float => 16,
            .depth16_unorm, .depth24_plus, .depth24_plus_stencil8, .depth32_float => 0,
        };
    }
};

pub const BufferUsage = packed struct {
    map_read: bool = false,
    map_write: bool = false,
    copy_src: bool = false,
    copy_dst: bool = false,
    index: bool = false,
    vertex: bool = false,
    uniform: bool = false,
    storage: bool = false,
    indirect: bool = false,
    query_resolve: bool = false,
};

pub const TextureUsage = packed struct {
    copy_src: bool = false,
    copy_dst: bool = false,
    texture_binding: bool = false,
    storage_binding: bool = false,
    render_attachment: bool = false,
};

pub const ShaderStages = packed struct {
    vertex: bool = false,
    fragment: bool = false,
    compute: bool = false,
};

pub const TextureDimension = enum { d1, d2, d3 };
pub const ViewDimension = enum { d1, d2, d2_array, cube, cube_array, d3 };
pub const TextureAspect = enum { all, depth_only, stencil_only };

pub const BufferDesc = struct {
    label: ?[]const u8 = null,
    size: u64,
    usage: BufferUsage,
};

pub const TextureDesc = struct {
    label: ?[]const u8 = null,
    dimension: TextureDimension = .d2,
    width: u32,
    height: u32 = 1,
    depth_or_layers: u32 = 1,
    mip_levels: u32 = 1,
    sample_count: u32 = 1,
    format: TextureFormat,
    usage: TextureUsage,
};

pub const TextureViewDesc = struct {
    label: ?[]const u8 = null,
    texture: TextureHandle,
    /// Null reinterprets nothing: the view uses the texture format.
    format: ?TextureFormat = null,
    dimension: ?ViewDimension = null,
    base_mip: u32 = 0,
    /// 0 means "all remaining mip levels".
    mip_count: u32 = 0,
    base_layer: u32 = 0,
    /// 0 means "all remaining layers".
    layer_count: u32 = 0,
    aspect: TextureAspect = .all,
};

pub const AddressMode = enum { clamp_to_edge, repeat, mirror_repeat };
pub const FilterMode = enum { nearest, linear };
pub const CompareFunction = enum { never, less, equal, less_equal, greater, not_equal, greater_equal, always };

pub const SamplerDesc = struct {
    label: ?[]const u8 = null,
    address_u: AddressMode = .clamp_to_edge,
    address_v: AddressMode = .clamp_to_edge,
    address_w: AddressMode = .clamp_to_edge,
    mag_filter: FilterMode = .linear,
    min_filter: FilterMode = .linear,
    mipmap_filter: FilterMode = .linear,
    lod_min: f32 = 0,
    lod_max: f32 = 32,
    compare: ?CompareFunction = null,
    max_anisotropy: u16 = 1,
};

pub const ShaderModuleDesc = struct {
    label: ?[]const u8 = null,
    /// WGSL is the engine's primary shader language.
    wgsl: []const u8,
};

pub const BufferBindingType = enum { uniform, storage, read_only_storage };
pub const SamplerBindingType = enum { filtering, non_filtering, comparison };
pub const TextureSampleType = enum { float, unfilterable_float, depth, sint, uint };
pub const StorageTextureAccess = enum { write_only, read_only, read_write };

pub const BindingKind = union(enum) {
    buffer: struct { type: BufferBindingType = .uniform, has_dynamic_offset: bool = false, min_binding_size: u64 = 0 },
    sampler: struct { type: SamplerBindingType = .filtering },
    texture: struct { sample_type: TextureSampleType = .float, view_dimension: ViewDimension = .d2, multisampled: bool = false },
    storage_texture: struct { access: StorageTextureAccess = .write_only, format: TextureFormat, view_dimension: ViewDimension = .d2 },
};

pub const BindGroupLayoutEntry = struct {
    binding: u32,
    visibility: ShaderStages,
    kind: BindingKind,
};

pub const BindGroupLayoutDesc = struct {
    label: ?[]const u8 = null,
    entries: []const BindGroupLayoutEntry,
};

pub const BindResource = union(enum) {
    /// `size == 0` binds from `offset` to the end of the buffer.
    buffer: struct { buffer: BufferHandle, offset: u64 = 0, size: u64 = 0 },
    sampler: SamplerHandle,
    texture_view: TextureViewHandle,
};

pub const BindGroupEntry = struct {
    binding: u32,
    resource: BindResource,
};

pub const BindGroupDesc = struct {
    label: ?[]const u8 = null,
    layout: BindGroupLayoutHandle,
    entries: []const BindGroupEntry,
};

pub const PipelineLayoutDesc = struct {
    label: ?[]const u8 = null,
    bind_group_layouts: []const BindGroupLayoutHandle,
};

pub const VertexFormat = enum { float32, float32x2, float32x3, float32x4, uint32, uint32x2, uint32x3, uint32x4, sint32, unorm8x4, float16x2, float16x4 };
pub const VertexStepMode = enum { vertex, instance };

pub const VertexAttribute = struct {
    format: VertexFormat,
    offset: u64,
    shader_location: u32,
};

pub const VertexBufferLayout = struct {
    stride: u64,
    step_mode: VertexStepMode = .vertex,
    attributes: []const VertexAttribute,
};

pub const PrimitiveTopology = enum { point_list, line_list, line_strip, triangle_list, triangle_strip };
pub const CullMode = enum { none, front, back };
pub const FrontFace = enum { ccw, cw };
pub const IndexFormat = enum { uint16, uint32 };
pub const BlendFactor = enum { zero, one, src, one_minus_src, src_alpha, one_minus_src_alpha, dst, one_minus_dst, dst_alpha, one_minus_dst_alpha, constant, one_minus_constant };
pub const BlendOperation = enum { add, subtract, reverse_subtract, min, max };

pub const BlendComponent = struct {
    operation: BlendOperation = .add,
    src_factor: BlendFactor = .one,
    dst_factor: BlendFactor = .zero,
};

pub const BlendState = struct {
    color: BlendComponent,
    alpha: BlendComponent,

    /// Straight-alpha "over" blending, matching the legacy 2D contract.
    pub const alpha_blend: BlendState = .{
        .color = .{ .src_factor = .src_alpha, .dst_factor = .one_minus_src_alpha },
        .alpha = .{ .src_factor = .one, .dst_factor = .one_minus_src_alpha },
    };
    pub const additive: BlendState = .{
        .color = .{ .src_factor = .one, .dst_factor = .one },
        .alpha = .{ .src_factor = .one, .dst_factor = .one },
    };
};

pub const ColorWriteMask = packed struct { r: bool = true, g: bool = true, b: bool = true, a: bool = true };

pub const ColorTargetState = struct {
    format: TextureFormat,
    blend: ?BlendState = null,
    write_mask: ColorWriteMask = .{},
};

pub const DepthStencilState = struct {
    format: TextureFormat,
    depth_write: bool = true,
    depth_compare: CompareFunction = .less,
    depth_bias: i32 = 0,
    depth_bias_slope_scale: f32 = 0,
    depth_bias_clamp: f32 = 0,
};

pub const RenderPipelineDesc = struct {
    label: ?[]const u8 = null,
    layout: PipelineLayoutHandle,
    shader: ShaderModuleHandle,
    vertex_entry: []const u8 = "vs_main",
    /// Null builds a depth-only pipeline (for example shadow maps).
    fragment_entry: ?[]const u8 = "fs_main",
    vertex_buffers: []const VertexBufferLayout = &.{},
    color_targets: []const ColorTargetState = &.{},
    depth_stencil: ?DepthStencilState = null,
    topology: PrimitiveTopology = .triangle_list,
    cull_mode: CullMode = .none,
    front_face: FrontFace = .ccw,
    sample_count: u32 = 1,
};

pub const ComputePipelineDesc = struct {
    label: ?[]const u8 = null,
    layout: PipelineLayoutHandle,
    shader: ShaderModuleHandle,
    entry: []const u8 = "cs_main",
};

pub const QuerySetDesc = struct {
    label: ?[]const u8 = null,
    /// Timestamp query slots.
    count: u32,
};

/// Hardware/driver identification reported by the provider.
pub const Backend = enum { unknown, vulkan, dx12, metal, opengl, webgpu_browser };
pub const AdapterType = enum { unknown, discrete_gpu, integrated_gpu, cpu };

pub const AdapterInfo = struct {
    name_buf: [128]u8 = @splat(0),
    name_len: u8 = 0,
    vendor_id: u32 = 0,
    device_id: u32 = 0,
    backend: Backend = .unknown,
    adapter_type: AdapterType = .unknown,

    pub fn name(self: *const AdapterInfo) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

/// Optional features that were requested from the adapter and are actually enabled on the device.
pub const Features = packed struct {
    timestamp_query: bool = false,
    float32_filterable: bool = false,
    float32_blendable: bool = false,
    rg11b10_renderable: bool = false,
    depth32_stencil8: bool = false,
    shader_f16: bool = false,
    subgroups: bool = false,
    indirect_first_instance: bool = false,
    bgra8_storage: bool = false,
    dual_source_blending: bool = false,
    texture_compression_bc: bool = false,
    texture_compression_etc2: bool = false,
    texture_compression_astc: bool = false,
    /// Ray queries inside shaders. This is NOT hardware ray tracing: see `Capabilities.acceleration_structures`.
    ray_query: bool = false,
};

pub const Limits = struct {
    max_texture_dimension_1d: u32 = 0,
    max_texture_dimension_2d: u32 = 0,
    max_texture_dimension_3d: u32 = 0,
    max_texture_array_layers: u32 = 0,
    max_bind_groups: u32 = 0,
    max_bindings_per_bind_group: u32 = 0,
    max_uniform_buffer_binding_size: u64 = 0,
    max_storage_buffer_binding_size: u64 = 0,
    min_uniform_buffer_offset_alignment: u32 = 256,
    min_storage_buffer_offset_alignment: u32 = 256,
    max_vertex_buffers: u32 = 0,
    max_buffer_size: u64 = 0,
    max_color_attachments: u32 = 0,
    max_sampled_textures_per_shader_stage: u32 = 0,
    max_storage_buffers_per_shader_stage: u32 = 0,
    max_storage_textures_per_shader_stage: u32 = 0,
    max_uniform_buffers_per_shader_stage: u32 = 0,
    max_compute_workgroup_storage_size: u32 = 0,
    max_compute_invocations_per_workgroup: u32 = 0,
    max_compute_workgroup_size: [3]u32 = .{ 0, 0, 0 },
    max_compute_workgroups_per_dimension: u32 = 0,
};

/// Everything a renderer needs to know before choosing a code path. Filled from the real adapter, never hard-coded.
pub const Capabilities = struct {
    info: AdapterInfo = .{},
    features: Features = .{},
    limits: Limits = .{},
    /// Nanoseconds per timestamp tick; 0 when timestamps are unsupported.
    timestamp_period_ns: f32 = 0,
    /// True only when the provider can create and query BLAS/TLAS. The pinned wgpu-native exposes no such API.
    acceleration_structures: bool = false,

    pub fn supportsCompute(self: *const Capabilities) bool {
        return self.limits.max_compute_invocations_per_workgroup > 0 and self.limits.max_storage_buffers_per_shader_stage > 0;
    }
};

pub const LoadOp = enum { clear, load };
pub const StoreOp = enum { store, discard };

/// A color attachment target: an explicit texture view or the provider's current presentation surface.
///
/// `.swapchain` resolves to the surface frame of the current present cycle. The provider acquires it on
/// first use and every later pass in the same frame shares it (use `load = .load` to layer overlays).
/// If the surface is unavailable (minimized or outdated) the pass is skipped, not failed. The frame is
/// presented by `GraphicsDeviceService.present`.
pub const ColorTarget = union(enum) {
    view: TextureViewHandle,
    swapchain,
};

pub const ClearColor = struct { r: f64 = 0, g: f64 = 0, b: f64 = 0, a: f64 = 1 };

pub const ColorAttachment = struct {
    target: ColorTarget,
    resolve_target: ?TextureViewHandle = null,
    load: LoadOp = .clear,
    store: StoreOp = .store,
    clear_value: ClearColor = .{},
};

pub const DepthAttachment = struct {
    view: TextureViewHandle,
    depth_load: LoadOp = .clear,
    depth_store: StoreOp = .store,
    depth_clear: f32 = 1.0,
    read_only: bool = false,
};

/// Optional timestamp slots written at the beginning and end of a pass.
pub const PassTimestamps = struct {
    query_set: QuerySetHandle,
    begin_index: ?u32 = null,
    end_index: ?u32 = null,
};

pub const RenderPassDesc = struct {
    label: ?[]const u8 = null,
    color_attachments: []const ColorAttachment = &.{},
    depth: ?DepthAttachment = null,
    timestamps: ?PassTimestamps = null,
};

pub const ComputePassDesc = struct {
    label: ?[]const u8 = null,
    timestamps: ?PassTimestamps = null,
};

pub const TextureCopyLocation = struct {
    texture: TextureHandle,
    mip_level: u32 = 0,
    origin: [3]u32 = .{ 0, 0, 0 },
    aspect: TextureAspect = .all,
};

pub const Extent3D = struct { width: u32, height: u32 = 1, depth_or_layers: u32 = 1 };

/// Row layout of a buffer side of a copy. For texture<->buffer copies `bytes_per_row` must be a multiple
/// of 256; 0 means "tightly packed rows rounded up to 256" (`alignedBytesPerRow`). For `writeTexture`
/// 0 means rows are tightly packed with no padding.
pub const BufferLayout = struct {
    offset: u64 = 0,
    bytes_per_row: u32 = 0,
    rows_per_image: u32 = 0,
};

pub const copy_row_alignment: u32 = 256;

/// Rounds `bytes` up to the 256-byte row alignment required for texture<->buffer copies.
pub fn alignedBytesPerRow(bytes: u32) u32 {
    return (bytes + copy_row_alignment - 1) / copy_row_alignment * copy_row_alignment;
}

/// Backend-neutral recorded GPU work. Replayed in order by `GpuDevice.submit`.
pub const Command = union(enum) {
    begin_render_pass: RenderPassDesc,
    end_render_pass,
    begin_compute_pass: ComputePassDesc,
    end_compute_pass,
    set_render_pipeline: RenderPipelineHandle,
    set_compute_pipeline: ComputePipelineHandle,
    /// `dynamic_offsets` are consumed by bindings declared with `has_dynamic_offset`.
    set_bind_group: struct { index: u32, group: BindGroupHandle, dynamic_offsets: []const u32 = &.{} },
    set_vertex_buffer: struct { slot: u32, buffer: BufferHandle, offset: u64 = 0, size: u64 = 0 },
    set_index_buffer: struct { buffer: BufferHandle, format: IndexFormat, offset: u64 = 0, size: u64 = 0 },
    set_viewport: struct { x: f32, y: f32, width: f32, height: f32, min_depth: f32 = 0, max_depth: f32 = 1 },
    set_scissor: struct { x: u32, y: u32, width: u32, height: u32 },
    set_blend_constant: ClearColor,
    draw: struct { vertex_count: u32, instance_count: u32 = 1, first_vertex: u32 = 0, first_instance: u32 = 0 },
    draw_indexed: struct { index_count: u32, instance_count: u32 = 1, first_index: u32 = 0, base_vertex: i32 = 0, first_instance: u32 = 0 },
    draw_indirect: struct { buffer: BufferHandle, offset: u64 },
    dispatch: struct { x: u32, y: u32 = 1, z: u32 = 1 },
    dispatch_indirect: struct { buffer: BufferHandle, offset: u64 },
    copy_buffer_to_buffer: struct { src: BufferHandle, src_offset: u64, dst: BufferHandle, dst_offset: u64, size: u64 },
    copy_texture_to_buffer: struct { src: TextureCopyLocation, dst: BufferHandle, layout: BufferLayout, extent: Extent3D },
    copy_buffer_to_texture: struct { src: BufferHandle, layout: BufferLayout, dst: TextureCopyLocation, extent: Extent3D },
    copy_texture_to_texture: struct { src: TextureCopyLocation, dst: TextureCopyLocation, extent: Extent3D },
    /// Copies the whole current swapchain frame (as drawn by the passes recorded before this command) into
    /// `dst`. Used by capture tooling and window tests. Fails if no pass drew to the swapchain this frame.
    /// Pixels are in the surface format (see `FrameTarget.color_format`).
    copy_swapchain_to_buffer: struct { dst: BufferHandle, layout: BufferLayout = .{} },
    clear_buffer: struct { buffer: BufferHandle, offset: u64 = 0, size: u64 = 0 },
    resolve_query_set: struct { query_set: QuerySetHandle, first: u32, count: u32, dst: BufferHandle, dst_offset: u64 },
    push_debug_group: []const u8,
    pop_debug_group,
};

/// Records `Command`s into arena-backed storage that is reused across frames.
///
/// Slices passed to the helper methods are copied into the arena, so callers may pass stack memory.
pub const CommandRecorder = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    commands: std.ArrayList(Command) = .empty,
    open_render_pass: bool = false,
    open_compute_pass: bool = false,

    pub fn init(gpa: std.mem.Allocator) CommandRecorder {
        return .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *CommandRecorder) void {
        self.commands.deinit(self.gpa);
        self.arena.deinit();
    }

    /// Drops recorded commands but keeps allocated capacity for the next frame.
    pub fn reset(self: *CommandRecorder) void {
        self.commands.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
        self.open_render_pass = false;
        self.open_compute_pass = false;
    }

    pub fn slice(self: *const CommandRecorder) []const Command {
        return self.commands.items;
    }

    fn push(self: *CommandRecorder, command: Command) !void {
        try self.commands.append(self.gpa, command);
    }

    pub fn beginRenderPass(self: *CommandRecorder, desc: RenderPassDesc) !void {
        if (self.open_render_pass or self.open_compute_pass) return error.PassAlreadyOpen;
        var owned = desc;
        owned.color_attachments = try self.arena.allocator().dupe(ColorAttachment, desc.color_attachments);
        if (desc.label) |l| owned.label = try self.arena.allocator().dupe(u8, l);
        try self.push(.{ .begin_render_pass = owned });
        self.open_render_pass = true;
    }

    pub fn endRenderPass(self: *CommandRecorder) !void {
        if (!self.open_render_pass) return error.NoOpenRenderPass;
        try self.push(.end_render_pass);
        self.open_render_pass = false;
    }

    pub fn beginComputePass(self: *CommandRecorder, desc: ComputePassDesc) !void {
        if (self.open_render_pass or self.open_compute_pass) return error.PassAlreadyOpen;
        var owned = desc;
        if (desc.label) |l| owned.label = try self.arena.allocator().dupe(u8, l);
        try self.push(.{ .begin_compute_pass = owned });
        self.open_compute_pass = true;
    }

    pub fn endComputePass(self: *CommandRecorder) !void {
        if (!self.open_compute_pass) return error.NoOpenComputePass;
        try self.push(.end_compute_pass);
        self.open_compute_pass = false;
    }

    pub fn setRenderPipeline(self: *CommandRecorder, pipeline: RenderPipelineHandle) !void {
        if (!self.open_render_pass) return error.NoOpenRenderPass;
        try self.push(.{ .set_render_pipeline = pipeline });
    }

    pub fn setComputePipeline(self: *CommandRecorder, pipeline: ComputePipelineHandle) !void {
        if (!self.open_compute_pass) return error.NoOpenComputePass;
        try self.push(.{ .set_compute_pipeline = pipeline });
    }

    pub fn setBindGroup(self: *CommandRecorder, index: u32, group: BindGroupHandle, dynamic_offsets: []const u32) !void {
        if (!self.open_render_pass and !self.open_compute_pass) return error.NoOpenPass;
        const owned = try self.arena.allocator().dupe(u32, dynamic_offsets);
        try self.push(.{ .set_bind_group = .{ .index = index, .group = group, .dynamic_offsets = owned } });
    }

    pub fn setVertexBuffer(self: *CommandRecorder, slot: u32, buffer: BufferHandle, offset: u64, size: u64) !void {
        if (!self.open_render_pass) return error.NoOpenRenderPass;
        try self.push(.{ .set_vertex_buffer = .{ .slot = slot, .buffer = buffer, .offset = offset, .size = size } });
    }

    pub fn setIndexBuffer(self: *CommandRecorder, buffer: BufferHandle, format: IndexFormat, offset: u64, size: u64) !void {
        if (!self.open_render_pass) return error.NoOpenRenderPass;
        try self.push(.{ .set_index_buffer = .{ .buffer = buffer, .format = format, .offset = offset, .size = size } });
    }

    pub fn setViewport(self: *CommandRecorder, x: f32, y: f32, width: f32, height: f32) !void {
        if (!self.open_render_pass) return error.NoOpenRenderPass;
        try self.push(.{ .set_viewport = .{ .x = x, .y = y, .width = width, .height = height } });
    }

    pub fn setScissor(self: *CommandRecorder, x: u32, y: u32, width: u32, height: u32) !void {
        if (!self.open_render_pass) return error.NoOpenRenderPass;
        try self.push(.{ .set_scissor = .{ .x = x, .y = y, .width = width, .height = height } });
    }

    pub fn draw(self: *CommandRecorder, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) !void {
        if (!self.open_render_pass) return error.NoOpenRenderPass;
        try self.push(.{ .draw = .{ .vertex_count = vertex_count, .instance_count = instance_count, .first_vertex = first_vertex, .first_instance = first_instance } });
    }

    pub fn drawIndexed(self: *CommandRecorder, index_count: u32, instance_count: u32, first_index: u32, base_vertex: i32, first_instance: u32) !void {
        if (!self.open_render_pass) return error.NoOpenRenderPass;
        try self.push(.{ .draw_indexed = .{ .index_count = index_count, .instance_count = instance_count, .first_index = first_index, .base_vertex = base_vertex, .first_instance = first_instance } });
    }

    pub fn dispatch(self: *CommandRecorder, x: u32, y: u32, z: u32) !void {
        if (!self.open_compute_pass) return error.NoOpenComputePass;
        try self.push(.{ .dispatch = .{ .x = x, .y = y, .z = z } });
    }

    pub fn copyBufferToBuffer(self: *CommandRecorder, src: BufferHandle, src_offset: u64, dst: BufferHandle, dst_offset: u64, size: u64) !void {
        if (self.open_render_pass or self.open_compute_pass) return error.PassAlreadyOpen;
        try self.push(.{ .copy_buffer_to_buffer = .{ .src = src, .src_offset = src_offset, .dst = dst, .dst_offset = dst_offset, .size = size } });
    }

    pub fn copyTextureToBuffer(self: *CommandRecorder, src: TextureCopyLocation, dst: BufferHandle, layout: BufferLayout, extent: Extent3D) !void {
        if (self.open_render_pass or self.open_compute_pass) return error.PassAlreadyOpen;
        try self.push(.{ .copy_texture_to_buffer = .{ .src = src, .dst = dst, .layout = layout, .extent = extent } });
    }

    pub fn copyBufferToTexture(self: *CommandRecorder, src: BufferHandle, layout: BufferLayout, dst: TextureCopyLocation, extent: Extent3D) !void {
        if (self.open_render_pass or self.open_compute_pass) return error.PassAlreadyOpen;
        try self.push(.{ .copy_buffer_to_texture = .{ .src = src, .layout = layout, .dst = dst, .extent = extent } });
    }

    pub fn copyTextureToTexture(self: *CommandRecorder, src: TextureCopyLocation, dst: TextureCopyLocation, extent: Extent3D) !void {
        if (self.open_render_pass or self.open_compute_pass) return error.PassAlreadyOpen;
        try self.push(.{ .copy_texture_to_texture = .{ .src = src, .dst = dst, .extent = extent } });
    }

    pub fn copySwapchainToBuffer(self: *CommandRecorder, dst: BufferHandle, layout: BufferLayout) !void {
        if (self.open_render_pass or self.open_compute_pass) return error.PassAlreadyOpen;
        try self.push(.{ .copy_swapchain_to_buffer = .{ .dst = dst, .layout = layout } });
    }

    pub fn clearBuffer(self: *CommandRecorder, buffer: BufferHandle, offset: u64, size: u64) !void {
        if (self.open_render_pass or self.open_compute_pass) return error.PassAlreadyOpen;
        try self.push(.{ .clear_buffer = .{ .buffer = buffer, .offset = offset, .size = size } });
    }

    pub fn resolveQuerySet(self: *CommandRecorder, query_set: QuerySetHandle, first: u32, count: u32, dst: BufferHandle, dst_offset: u64) !void {
        if (self.open_render_pass or self.open_compute_pass) return error.PassAlreadyOpen;
        try self.push(.{ .resolve_query_set = .{ .query_set = query_set, .first = first, .count = count, .dst = dst, .dst_offset = dst_offset } });
    }

    /// Fails if a pass is still open; call before `GpuDevice.submit`.
    pub fn finish(self: *const CommandRecorder) !void {
        if (self.open_render_pass or self.open_compute_pass) return error.PassStillOpen;
    }
};

/// Provider-implemented device. All methods are callable from the render thread only.
pub const GpuDevice = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        capabilities: *const fn (ctx: *anyopaque) *const Capabilities,
        create_buffer: *const fn (ctx: *anyopaque, desc: BufferDesc) anyerror!BufferHandle,
        destroy_buffer: *const fn (ctx: *anyopaque, handle: BufferHandle) void,
        write_buffer: *const fn (ctx: *anyopaque, handle: BufferHandle, offset: u64, data: []const u8) anyerror!void,
        create_texture: *const fn (ctx: *anyopaque, desc: TextureDesc) anyerror!TextureHandle,
        destroy_texture: *const fn (ctx: *anyopaque, handle: TextureHandle) void,
        write_texture: *const fn (ctx: *anyopaque, dst: TextureCopyLocation, data: []const u8, layout: BufferLayout, extent: Extent3D) anyerror!void,
        create_texture_view: *const fn (ctx: *anyopaque, desc: TextureViewDesc) anyerror!TextureViewHandle,
        destroy_texture_view: *const fn (ctx: *anyopaque, handle: TextureViewHandle) void,
        create_sampler: *const fn (ctx: *anyopaque, desc: SamplerDesc) anyerror!SamplerHandle,
        destroy_sampler: *const fn (ctx: *anyopaque, handle: SamplerHandle) void,
        create_shader_module: *const fn (ctx: *anyopaque, desc: ShaderModuleDesc) anyerror!ShaderModuleHandle,
        destroy_shader_module: *const fn (ctx: *anyopaque, handle: ShaderModuleHandle) void,
        create_bind_group_layout: *const fn (ctx: *anyopaque, desc: BindGroupLayoutDesc) anyerror!BindGroupLayoutHandle,
        destroy_bind_group_layout: *const fn (ctx: *anyopaque, handle: BindGroupLayoutHandle) void,
        create_bind_group: *const fn (ctx: *anyopaque, desc: BindGroupDesc) anyerror!BindGroupHandle,
        destroy_bind_group: *const fn (ctx: *anyopaque, handle: BindGroupHandle) void,
        create_pipeline_layout: *const fn (ctx: *anyopaque, desc: PipelineLayoutDesc) anyerror!PipelineLayoutHandle,
        destroy_pipeline_layout: *const fn (ctx: *anyopaque, handle: PipelineLayoutHandle) void,
        create_render_pipeline: *const fn (ctx: *anyopaque, desc: RenderPipelineDesc) anyerror!RenderPipelineHandle,
        destroy_render_pipeline: *const fn (ctx: *anyopaque, handle: RenderPipelineHandle) void,
        create_compute_pipeline: *const fn (ctx: *anyopaque, desc: ComputePipelineDesc) anyerror!ComputePipelineHandle,
        destroy_compute_pipeline: *const fn (ctx: *anyopaque, handle: ComputePipelineHandle) void,
        create_query_set: *const fn (ctx: *anyopaque, desc: QuerySetDesc) anyerror!QuerySetHandle,
        destroy_query_set: *const fn (ctx: *anyopaque, handle: QuerySetHandle) void,
        submit: *const fn (ctx: *anyopaque, commands: []const Command) anyerror!void,
        begin_readback: *const fn (ctx: *anyopaque, buffer: BufferHandle, offset: u64, size: u64) anyerror!ReadbackHandle,
        /// Returns true and fills `out` when the mapping completed; false when it is still pending.
        poll_readback: *const fn (ctx: *anyopaque, handle: ReadbackHandle, out: []u8) anyerror!bool,
        /// Drives provider callbacks. `wait` blocks until submitted work completes.
        poll: *const fn (ctx: *anyopaque, wait: bool) void,
    };

    pub fn capabilities(self: GpuDevice) *const Capabilities {
        return self.vtable.capabilities(self.ctx);
    }
    pub fn createBuffer(self: GpuDevice, desc: BufferDesc) !BufferHandle {
        return self.vtable.create_buffer(self.ctx, desc);
    }
    pub fn destroyBuffer(self: GpuDevice, handle: BufferHandle) void {
        self.vtable.destroy_buffer(self.ctx, handle);
    }
    pub fn writeBuffer(self: GpuDevice, handle: BufferHandle, offset: u64, data: []const u8) !void {
        return self.vtable.write_buffer(self.ctx, handle, offset, data);
    }
    pub fn createTexture(self: GpuDevice, desc: TextureDesc) !TextureHandle {
        return self.vtable.create_texture(self.ctx, desc);
    }
    pub fn destroyTexture(self: GpuDevice, handle: TextureHandle) void {
        self.vtable.destroy_texture(self.ctx, handle);
    }
    pub fn writeTexture(self: GpuDevice, dst: TextureCopyLocation, data: []const u8, layout: BufferLayout, extent: Extent3D) !void {
        return self.vtable.write_texture(self.ctx, dst, data, layout, extent);
    }
    pub fn createTextureView(self: GpuDevice, desc: TextureViewDesc) !TextureViewHandle {
        return self.vtable.create_texture_view(self.ctx, desc);
    }
    pub fn destroyTextureView(self: GpuDevice, handle: TextureViewHandle) void {
        self.vtable.destroy_texture_view(self.ctx, handle);
    }
    pub fn createSampler(self: GpuDevice, desc: SamplerDesc) !SamplerHandle {
        return self.vtable.create_sampler(self.ctx, desc);
    }
    pub fn destroySampler(self: GpuDevice, handle: SamplerHandle) void {
        self.vtable.destroy_sampler(self.ctx, handle);
    }
    pub fn createShaderModule(self: GpuDevice, desc: ShaderModuleDesc) !ShaderModuleHandle {
        return self.vtable.create_shader_module(self.ctx, desc);
    }
    pub fn destroyShaderModule(self: GpuDevice, handle: ShaderModuleHandle) void {
        self.vtable.destroy_shader_module(self.ctx, handle);
    }
    pub fn createBindGroupLayout(self: GpuDevice, desc: BindGroupLayoutDesc) !BindGroupLayoutHandle {
        return self.vtable.create_bind_group_layout(self.ctx, desc);
    }
    pub fn destroyBindGroupLayout(self: GpuDevice, handle: BindGroupLayoutHandle) void {
        self.vtable.destroy_bind_group_layout(self.ctx, handle);
    }
    pub fn createBindGroup(self: GpuDevice, desc: BindGroupDesc) !BindGroupHandle {
        return self.vtable.create_bind_group(self.ctx, desc);
    }
    pub fn destroyBindGroup(self: GpuDevice, handle: BindGroupHandle) void {
        self.vtable.destroy_bind_group(self.ctx, handle);
    }
    pub fn createPipelineLayout(self: GpuDevice, desc: PipelineLayoutDesc) !PipelineLayoutHandle {
        return self.vtable.create_pipeline_layout(self.ctx, desc);
    }
    pub fn destroyPipelineLayout(self: GpuDevice, handle: PipelineLayoutHandle) void {
        self.vtable.destroy_pipeline_layout(self.ctx, handle);
    }
    pub fn createRenderPipeline(self: GpuDevice, desc: RenderPipelineDesc) !RenderPipelineHandle {
        return self.vtable.create_render_pipeline(self.ctx, desc);
    }
    pub fn destroyRenderPipeline(self: GpuDevice, handle: RenderPipelineHandle) void {
        self.vtable.destroy_render_pipeline(self.ctx, handle);
    }
    pub fn createComputePipeline(self: GpuDevice, desc: ComputePipelineDesc) !ComputePipelineHandle {
        return self.vtable.create_compute_pipeline(self.ctx, desc);
    }
    pub fn destroyComputePipeline(self: GpuDevice, handle: ComputePipelineHandle) void {
        self.vtable.destroy_compute_pipeline(self.ctx, handle);
    }
    pub fn createQuerySet(self: GpuDevice, desc: QuerySetDesc) !QuerySetHandle {
        return self.vtable.create_query_set(self.ctx, desc);
    }
    pub fn destroyQuerySet(self: GpuDevice, handle: QuerySetHandle) void {
        self.vtable.destroy_query_set(self.ctx, handle);
    }
    pub fn submit(self: GpuDevice, commands: []const Command) !void {
        return self.vtable.submit(self.ctx, commands);
    }
    pub fn beginReadback(self: GpuDevice, buffer: BufferHandle, offset: u64, size: u64) !ReadbackHandle {
        return self.vtable.begin_readback(self.ctx, buffer, offset, size);
    }
    pub fn pollReadback(self: GpuDevice, handle: ReadbackHandle, out: []u8) !bool {
        return self.vtable.poll_readback(self.ctx, handle, out);
    }
    pub fn poll(self: GpuDevice, wait: bool) void {
        self.vtable.poll(self.ctx, wait);
    }

    /// Blocking readback for tests and tools. Gameplay code must use `beginReadback`/`pollReadback`
    /// so frames never stall on the GPU.
    pub fn readBufferBlocking(self: GpuDevice, buffer: BufferHandle, offset: u64, out: []u8) !void {
        const ticket = try self.beginReadback(buffer, offset, out.len);
        var spins: u32 = 0;
        while (!try self.pollReadback(ticket, out)) {
            self.poll(true);
            spins += 1;
            if (spins > 100_000) return error.ReadbackTimeout;
        }
    }
};

test "handles are generational and slots are reused" {
    const Pool = HandlePool(u32, BufferHandle);
    var pool: Pool = .{};
    defer pool.deinit(std.testing.allocator);

    const a = try pool.acquire(std.testing.allocator, 10);
    try std.testing.expectEqual(@as(u32, 10), pool.get(a).?.*);
    try std.testing.expectEqual(@as(u32, 1), pool.count());

    try std.testing.expectEqual(@as(?u32, 10), pool.release(a));
    // Stale handles are rejected and cannot be released twice.
    try std.testing.expect(pool.get(a) == null);
    try std.testing.expectEqual(@as(?u32, null), pool.release(a));

    const b = try pool.acquire(std.testing.allocator, 20);
    try std.testing.expectEqual(a.index, b.index);
    try std.testing.expect(a.generation != b.generation);
    try std.testing.expect(pool.get(a) == null);
    try std.testing.expectEqual(@as(u32, 20), pool.get(b).?.*);
    try std.testing.expect(BufferHandle.none.isNone());
    try std.testing.expect(pool.get(BufferHandle.none) == null);
}

test "recorder enforces pass structure and copies borrowed slices" {
    var rec = CommandRecorder.init(std.testing.allocator);
    defer rec.deinit();

    try std.testing.expectError(error.NoOpenRenderPass, rec.draw(3, 1, 0, 0));
    try std.testing.expectError(error.NoOpenComputePass, rec.dispatch(1, 1, 1));

    {
        var attachments = [_]ColorAttachment{.{ .target = .swapchain }};
        try rec.beginRenderPass(.{ .label = "main", .color_attachments = &attachments });
        attachments[0].load = .load; // The recorder must have copied the original value.
    }
    try std.testing.expectError(error.PassAlreadyOpen, rec.beginComputePass(.{}));
    try rec.draw(3, 1, 0, 0);
    try std.testing.expectError(error.PassStillOpen, rec.finish());
    try rec.endRenderPass();
    try rec.finish();

    try std.testing.expectEqual(@as(usize, 3), rec.slice().len);
    try std.testing.expectEqual(LoadOp.clear, rec.slice()[0].begin_render_pass.color_attachments[0].load);

    rec.reset();
    try std.testing.expectEqual(@as(usize, 0), rec.slice().len);
}

test "aligned row pitch and format sizes" {
    try std.testing.expectEqual(@as(u32, 256), alignedBytesPerRow(1));
    try std.testing.expectEqual(@as(u32, 256), alignedBytesPerRow(256));
    try std.testing.expectEqual(@as(u32, 512), alignedBytesPerRow(257));
    try std.testing.expectEqual(@as(u32, 8), TextureFormat.rgba16_float.bytesPerTexel());
    try std.testing.expect(TextureFormat.depth32_float.isDepth());
}
