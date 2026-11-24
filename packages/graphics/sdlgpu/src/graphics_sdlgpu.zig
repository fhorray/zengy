//! Native GPU Device Provider backed by SDL3 GPU (`official.graphics.sdlgpu`).
//!
//! Visual counterpart of `official.graphics` (headless). Provides `engine.graphics.device/1`
//! using `graphics.GraphicsDeviceService` with a `BackendVTable` wired to `SDL_GPUDevice`.
//!
//! Design:
//! - Depends on `engine.window/1` (specifically `official.window.sdl3`).
//! - SDL is linked only by this package and `window-sdl3`; `src/core/` does not import SDL.
//! - Shaders are precompiled SPIR-V (`src/shaders/*.spv`) embedded via `@embedFile`.
//! - Supports both NDC/pixel `pos_color` primitives (D2) and batched `textured` quads (D3/D4)
//!   with alpha blending, scissor clipping, and an embedded RGBA8 bitmap font atlas.
//! - Pipeline/shader creation and backend errors are recorded in `app.diagnostics`.

const std = @import("std");
const engine = @import("engine");
const graphics = @import("graphics");
const window_sdl3 = @import("window_sdl3");
const text_pkg = @import("text");
const render_3d = @import("render_3d");
const c = @import("sdl3_c");
pub const gpu_resources = @import("gpu_resources.zig");
pub const pbr_backend = @import("pbr_backend.zig");

pub const Vertex2D = gpu_resources.Vertex2D;
pub const FrameUniforms = gpu_resources.FrameUniforms;
pub const Vertex2DTextured = gpu_resources.Vertex2DTextured;
pub const TexturedUniforms = gpu_resources.TexturedUniforms;
pub const TexturedQuad = gpu_resources.TexturedQuad;
pub const ScissorRect = gpu_resources.ScissorRect;
pub const GpuBufferHandle = gpu_resources.GpuBufferHandle;
pub const GpuPipelineHandle = gpu_resources.GpuPipelineHandle;
pub const GpuShaderHandle = gpu_resources.GpuShaderHandle;
pub const GpuTextureHandle = gpu_resources.GpuTextureHandle;
pub const GpuMeshHandle = gpu_resources.GpuMeshHandle;
pub const MeshUniforms = gpu_resources.MeshUniforms;

pub const MODULE_OWNER_ID: u64 = 2012;
pub const PROVIDER_ID = "official.graphics.sdlgpu";

const POS_VERT_SPV = @embedFile("shaders/pos_color.vert.spv");
const POS_FRAG_SPV = @embedFile("shaders/pos_color.frag.spv");
const TEX_VERT_SPV = @embedFile("shaders/textured.vert.spv");
const TEX_FRAG_SPV = @embedFile("shaders/textured.frag.spv");
const MESH_VERT_SPV = @embedFile("shaders/mesh_unlit.vert.spv");
const MESH_FRAG_SPV = @embedFile("shaders/mesh_unlit.frag.spv");

const INITIAL_VERTEX_CAPACITY: usize = 4096;

/// Optional resource inserted before `app.initialize()` to customise the SDL_GPU backend.
pub const GpuConfig = struct {
    debug_mode: bool = true,
    default_clear_color: graphics.Color = .{ .r = 0.07, .g = 0.09, .b = 0.13, .a = 1.0 },
};

const TexturePool = gpu_resources.GenerationalPool(*c.SDL_GPUTexture, GpuTextureHandle);

const GpuMesh = struct {
    vertex_buffer: *c.SDL_GPUBuffer,
    index_buffer: *c.SDL_GPUBuffer,
    index_count: u32,
};

const MeshPool = gpu_resources.GenerationalPool(GpuMesh, GpuMeshHandle);

const QueuedMeshDraw = struct {
    mesh: GpuMeshHandle,
    mvp: [16]f32,
    color: [4]f32,
    texture: GpuTextureHandle,
};

const DrawBatch = struct {
    first_vertex: u32,
    vertex_count: u32,
    texture: GpuTextureHandle,
    scissor: ?ScissorRect,
};

const OffscreenTarget = struct {
    handle: graphics.RenderTargetHandle,
    texture: *c.SDL_GPUTexture,
    width: u32,
    height: u32,
};

const SdlGpuState = struct {
    allocator: std.mem.Allocator,
    app: *engine.App,
    diagnostics: *engine.Diagnostics,
    sdl_window: *c.SDL_Window,
    device: *c.SDL_GPUDevice,
    swapchain_format: c.SDL_GPUTextureFormat,
    depth_format: c.SDL_GPUTextureFormat,
    depth_texture: ?*c.SDL_GPUTexture = null,
    depth_w: u32 = 0,
    depth_h: u32 = 0,

    // D2: pos_color pipeline
    pos_vert_shader: *c.SDL_GPUShader,
    pos_frag_shader: *c.SDL_GPUShader,
    pos_pipeline: *c.SDL_GPUGraphicsPipeline,
    pos_vertex_buffer: *c.SDL_GPUBuffer,
    pos_transfer_buffer: *c.SDL_GPUTransferBuffer,
    pos_capacity_bytes: u32,

    // D3/D4: textured quad pipeline + sampler + texture pool
    tex_vert_shader: *c.SDL_GPUShader,
    tex_frag_shader: *c.SDL_GPUShader,
    tex_pipeline: *c.SDL_GPUGraphicsPipeline,
    tex_vertex_buffer: *c.SDL_GPUBuffer,
    tex_transfer_buffer: *c.SDL_GPUTransferBuffer,
    tex_capacity_bytes: u32,
    sampler: *c.SDL_GPUSampler,
    linear_sampler: *c.SDL_GPUSampler,
    textures: TexturePool,
    white_texture: GpuTextureHandle,
    font_texture: GpuTextureHandle,
    ttf_font_texture: GpuTextureHandle,
    ttf_atlas: text_pkg.TtfAtlas,
    lucide_texture: GpuTextureHandle,
    lucide_atlas: text_pkg.IconAtlas,

    // Phase E: 3D unlit depth-tested pipeline + mesh pool
    mesh_vert_shader: *c.SDL_GPUShader,
    mesh_frag_shader: *c.SDL_GPUShader,
    mesh_pipeline: *c.SDL_GPUGraphicsPipeline,
    meshes: MeshPool,
    queued_meshes: std.ArrayList(QueuedMeshDraw),
    pbr: pbr_backend.PbrGpuState,

    default_clear_color: graphics.Color,
    ndc_vertices: std.ArrayList(Vertex2D),
    queued_quads: std.ArrayList(TexturedQuad),
    tex_vertices: std.ArrayList(Vertex2DTextured),
    tex_batches: std.ArrayList(DrawBatch),
    offscreen_targets: std.ArrayList(OffscreenTarget),
    graphics_svc: graphics.GraphicsDeviceService,
};

fn logDiag(diag: *engine.Diagnostics, level: engine.LogLevel, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch "log message truncated";
    diag.log(level, "graphics.sdlgpu", msg) catch {};
}

fn sdlFail(diag: *engine.Diagnostics, prefix: []const u8) error{SdlGpuFailure} {
    const err_str = std.mem.span(c.SDL_GetError());
    logDiag(diag, .err, "{s}: {s}", .{ prefix, err_str });
    std.log.err("[graphics.sdlgpu] {s}: {s}", .{ prefix, err_str });
    return error.SdlGpuFailure;
}

fn createShader(
    device: *c.SDL_GPUDevice,
    diag: *engine.Diagnostics,
    stage: c.SDL_GPUShaderStage,
    code: []const u8,
    num_samplers: u32,
    num_uniform_buffers: u32,
) !*c.SDL_GPUShader {
    const info = std.mem.zeroInit(c.SDL_GPUShaderCreateInfo, .{
        .code_size = code.len,
        .code = code.ptr,
        .entrypoint = "main",
        .format = c.SDL_GPU_SHADERFORMAT_SPIRV,
        .stage = stage,
        .num_samplers = num_samplers,
        .num_uniform_buffers = num_uniform_buffers,
    });
    return c.SDL_CreateGPUShader(device, &info) orelse sdlFail(diag, "SDL_CreateGPUShader failed");
}

fn alphaBlendTarget(swapchain_format: c.SDL_GPUTextureFormat) [1]c.SDL_GPUColorTargetDescription {
    return .{.{
        .format = swapchain_format,
        .blend_state = std.mem.zeroInit(c.SDL_GPUColorTargetBlendState, .{
            .enable_blend = true,
            .src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_SRC_ALPHA,
            .dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
            .color_blend_op = c.SDL_GPU_BLENDOP_ADD,
            .src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
            .dst_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
            .alpha_blend_op = c.SDL_GPU_BLENDOP_ADD,
        }),
    }};
}

fn createPosColorPipeline(
    device: *c.SDL_GPUDevice,
    diag: *engine.Diagnostics,
    vert: *c.SDL_GPUShader,
    frag: *c.SDL_GPUShader,
    swapchain_format: c.SDL_GPUTextureFormat,
) !*c.SDL_GPUGraphicsPipeline {
    const vb_desc = [_]c.SDL_GPUVertexBufferDescription{.{
        .slot = 0,
        .pitch = @sizeOf(Vertex2D),
        .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
        .instance_step_rate = 0,
    }};
    const attrs = [_]c.SDL_GPUVertexAttribute{
        .{ .location = 0, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(Vertex2D, "x") },
        .{ .location = 1, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4, .offset = @offsetOf(Vertex2D, "r") },
    };
    const targets = alphaBlendTarget(swapchain_format);
    const info = std.mem.zeroInit(c.SDL_GPUGraphicsPipelineCreateInfo, .{
        .vertex_shader = vert,
        .fragment_shader = frag,
        .vertex_input_state = .{
            .vertex_buffer_descriptions = &vb_desc,
            .num_vertex_buffers = vb_desc.len,
            .vertex_attributes = &attrs,
            .num_vertex_attributes = attrs.len,
        },
        .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
        .rasterizer_state = std.mem.zeroInit(c.SDL_GPURasterizerState, .{
            .fill_mode = c.SDL_GPU_FILLMODE_FILL,
            .cull_mode = c.SDL_GPU_CULLMODE_NONE,
            .front_face = c.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE,
        }),
        .multisample_state = std.mem.zeroInit(c.SDL_GPUMultisampleState, .{ .sample_count = c.SDL_GPU_SAMPLECOUNT_1 }),
        .target_info = .{ .color_target_descriptions = &targets, .num_color_targets = targets.len },
    });
    return c.SDL_CreateGPUGraphicsPipeline(device, &info) orelse sdlFail(diag, "SDL_CreateGPUGraphicsPipeline (pos_color) failed");
}

fn createTexturedPipeline(
    device: *c.SDL_GPUDevice,
    diag: *engine.Diagnostics,
    vert: *c.SDL_GPUShader,
    frag: *c.SDL_GPUShader,
    swapchain_format: c.SDL_GPUTextureFormat,
) !*c.SDL_GPUGraphicsPipeline {
    const vb_desc = [_]c.SDL_GPUVertexBufferDescription{.{
        .slot = 0,
        .pitch = @sizeOf(Vertex2DTextured),
        .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
        .instance_step_rate = 0,
    }};
    const attrs = [_]c.SDL_GPUVertexAttribute{
        .{ .location = 0, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(Vertex2DTextured, "x") },
        .{ .location = 1, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(Vertex2DTextured, "u") },
        .{ .location = 2, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4, .offset = @offsetOf(Vertex2DTextured, "r") },
    };
    const targets = alphaBlendTarget(swapchain_format);
    const info = std.mem.zeroInit(c.SDL_GPUGraphicsPipelineCreateInfo, .{
        .vertex_shader = vert,
        .fragment_shader = frag,
        .vertex_input_state = .{
            .vertex_buffer_descriptions = &vb_desc,
            .num_vertex_buffers = vb_desc.len,
            .vertex_attributes = &attrs,
            .num_vertex_attributes = attrs.len,
        },
        .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
        .rasterizer_state = std.mem.zeroInit(c.SDL_GPURasterizerState, .{
            .fill_mode = c.SDL_GPU_FILLMODE_FILL,
            .cull_mode = c.SDL_GPU_CULLMODE_NONE,
            .front_face = c.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE,
        }),
        .multisample_state = std.mem.zeroInit(c.SDL_GPUMultisampleState, .{ .sample_count = c.SDL_GPU_SAMPLECOUNT_1 }),
        .target_info = .{ .color_target_descriptions = &targets, .num_color_targets = targets.len },
    });
    return c.SDL_CreateGPUGraphicsPipeline(device, &info) orelse sdlFail(diag, "SDL_CreateGPUGraphicsPipeline (textured) failed");
}

fn createMeshUnlitPipeline(
    device: *c.SDL_GPUDevice,
    diag: *engine.Diagnostics,
    vert: *c.SDL_GPUShader,
    frag: *c.SDL_GPUShader,
    swapchain_format: c.SDL_GPUTextureFormat,
    depth_format: c.SDL_GPUTextureFormat,
) !*c.SDL_GPUGraphicsPipeline {
    const vb_desc = [_]c.SDL_GPUVertexBufferDescription{.{
        .slot = 0,
        .pitch = 32, // Vertex3D: pos(12) + normal(12) + uv(8)
        .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
        .instance_step_rate = 0,
    }};
    const attrs = [_]c.SDL_GPUVertexAttribute{
        .{ .location = 0, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3, .offset = 0 },
        .{ .location = 1, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3, .offset = 12 },
        .{ .location = 2, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = 24 },
    };
    const targets = alphaBlendTarget(swapchain_format);
    const info = std.mem.zeroInit(c.SDL_GPUGraphicsPipelineCreateInfo, .{
        .vertex_shader = vert,
        .fragment_shader = frag,
        .vertex_input_state = .{
            .vertex_buffer_descriptions = &vb_desc,
            .num_vertex_buffers = vb_desc.len,
            .vertex_attributes = &attrs,
            .num_vertex_attributes = attrs.len,
        },
        .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
        .rasterizer_state = std.mem.zeroInit(c.SDL_GPURasterizerState, .{
            .fill_mode = c.SDL_GPU_FILLMODE_FILL,
            .cull_mode = c.SDL_GPU_CULLMODE_BACK,
            .front_face = c.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE,
        }),
        .multisample_state = std.mem.zeroInit(c.SDL_GPUMultisampleState, .{ .sample_count = c.SDL_GPU_SAMPLECOUNT_1 }),
        .depth_stencil_state = std.mem.zeroInit(c.SDL_GPUDepthStencilState, .{
            .enable_depth_test = true,
            .enable_depth_write = true,
            .compare_op = c.SDL_GPU_COMPAREOP_LESS,
        }),
        .target_info = .{
            .color_target_descriptions = &targets,
            .num_color_targets = targets.len,
            .depth_stencil_format = depth_format,
            .has_depth_stencil_target = true,
        },
    });
    return c.SDL_CreateGPUGraphicsPipeline(device, &info) orelse sdlFail(diag, "SDL_CreateGPUGraphicsPipeline (mesh_unlit) failed");
}

fn ensureDepthTexture(state: *SdlGpuState, w: u32, h: u32) !*c.SDL_GPUTexture {
    if (state.depth_texture != null and state.depth_w == w and state.depth_h == h) {
        return state.depth_texture.?;
    }
    if (state.depth_texture) |old| {
        c.SDL_ReleaseGPUTexture(state.device, old);
        state.depth_texture = null;
    }
    const tex = c.SDL_CreateGPUTexture(state.device, &std.mem.zeroInit(c.SDL_GPUTextureCreateInfo, .{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = state.depth_format,
        .usage = c.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET | c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
        .width = w,
        .height = h,
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
    })) orelse return sdlFail(state.diagnostics, "SDL_CreateGPUTexture (depth) failed");
    state.depth_texture = tex;
    state.depth_w = w;
    state.depth_h = h;
    return tex;
}

fn uploadStaticGpuBuffer(
    device: *c.SDL_GPUDevice,
    diag: *engine.Diagnostics,
    usage: c.SDL_GPUBufferUsageFlags,
    data: []const u8,
) !*c.SDL_GPUBuffer {
    const buf = c.SDL_CreateGPUBuffer(device, &std.mem.zeroInit(c.SDL_GPUBufferCreateInfo, .{
        .usage = usage,
        .size = @as(u32, @intCast(data.len)),
    })) orelse return sdlFail(diag, "SDL_CreateGPUBuffer (static) failed");
    errdefer c.SDL_ReleaseGPUBuffer(device, buf);

    const tb = c.SDL_CreateGPUTransferBuffer(device, &std.mem.zeroInit(c.SDL_GPUTransferBufferCreateInfo, .{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = @as(u32, @intCast(data.len)),
    })) orelse return sdlFail(diag, "SDL_CreateGPUTransferBuffer (static) failed");
    defer c.SDL_ReleaseGPUTransferBuffer(device, tb);

    const mapped = c.SDL_MapGPUTransferBuffer(device, tb, false) orelse return sdlFail(diag, "SDL_MapGPUTransferBuffer (static) failed");
    const dst: [*]u8 = @ptrCast(mapped);
    @memcpy(dst[0..data.len], data);
    c.SDL_UnmapGPUTransferBuffer(device, tb);

    const cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse return sdlFail(diag, "SDL_AcquireGPUCommandBuffer (static) failed");
    const cp = c.SDL_BeginGPUCopyPass(cmd) orelse {
        _ = c.SDL_SubmitGPUCommandBuffer(cmd);
        return sdlFail(diag, "SDL_BeginGPUCopyPass (static) failed");
    };
    c.SDL_UploadToGPUBuffer(
        cp,
        &.{ .transfer_buffer = tb, .offset = 0 },
        &.{ .buffer = buf, .offset = 0, .size = @as(u32, @intCast(data.len)) },
        false,
    );
    c.SDL_EndGPUCopyPass(cp);
    if (!c.SDL_SubmitGPUCommandBuffer(cmd)) return sdlFail(diag, "SDL_SubmitGPUCommandBuffer (static) failed");
    return buf;
}

fn ensureDynamicBuffer(
    device: *c.SDL_GPUDevice,
    diag: *engine.Diagnostics,
    vb: **c.SDL_GPUBuffer,
    tb: **c.SDL_GPUTransferBuffer,
    cap_bytes: *u32,
    needed_bytes: u32,
) !void {
    if (needed_bytes <= cap_bytes.*) return;
    var new_cap = cap_bytes.*;
    while (new_cap < needed_bytes) : (new_cap *= 2) {}

    // No idle wait: SDL_ReleaseGPU* defers destruction until in-flight command buffers finish,
    // and the previous contents are re-uploaded from the CPU every frame.
    const new_vb = c.SDL_CreateGPUBuffer(device, &std.mem.zeroInit(c.SDL_GPUBufferCreateInfo, .{
        .usage = c.SDL_GPU_BUFFERUSAGE_VERTEX,
        .size = new_cap,
    })) orelse return sdlFail(diag, "SDL_CreateGPUBuffer (resize) failed");
    errdefer c.SDL_ReleaseGPUBuffer(device, new_vb);

    const new_tb = c.SDL_CreateGPUTransferBuffer(device, &std.mem.zeroInit(c.SDL_GPUTransferBufferCreateInfo, .{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = new_cap,
    })) orelse return sdlFail(diag, "SDL_CreateGPUTransferBuffer (resize) failed");

    c.SDL_ReleaseGPUBuffer(device, vb.*);
    c.SDL_ReleaseGPUTransferBuffer(device, tb.*);
    vb.* = new_vb;
    tb.* = new_tb;
    cap_bytes.* = new_cap;
}

fn uploadBufferViaCopyPass(
    device: *c.SDL_GPUDevice,
    diag: *engine.Diagnostics,
    copy_pass: *c.SDL_GPUCopyPass,
    vb: *c.SDL_GPUBuffer,
    tb: *c.SDL_GPUTransferBuffer,
    data: []const u8,
) !void {
    const mapped = c.SDL_MapGPUTransferBuffer(device, tb, true) orelse {
        return sdlFail(diag, "SDL_MapGPUTransferBuffer failed");
    };
    const dst: [*]u8 = @ptrCast(mapped);
    @memcpy(dst[0..data.len], data);
    c.SDL_UnmapGPUTransferBuffer(device, tb);

    c.SDL_UploadToGPUBuffer(
        copy_pass,
        &.{ .transfer_buffer = tb, .offset = 0 },
        &.{ .buffer = vb, .offset = 0, .size = @intCast(data.len) },
        true,
    );
}

fn uploadTextureRgba8Internal(
    device: *c.SDL_GPUDevice,
    diag: *engine.Diagnostics,
    width: u32,
    height: u32,
    pixels: []const u8,
) !*c.SDL_GPUTexture {
    const expected_bytes: usize = @as(usize, width) * @as(usize, height) * 4;
    if (pixels.len < expected_bytes) return error.InvalidTextureData;

    const tex = c.SDL_CreateGPUTexture(device, &std.mem.zeroInit(c.SDL_GPUTextureCreateInfo, .{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
        .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
        .width = width,
        .height = height,
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
    })) orelse return sdlFail(diag, "SDL_CreateGPUTexture failed");
    errdefer c.SDL_ReleaseGPUTexture(device, tex);

    const tb = c.SDL_CreateGPUTransferBuffer(device, &std.mem.zeroInit(c.SDL_GPUTransferBufferCreateInfo, .{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = @as(u32, @intCast(expected_bytes)),
    })) orelse return sdlFail(diag, "SDL_CreateGPUTransferBuffer (texture) failed");
    defer c.SDL_ReleaseGPUTransferBuffer(device, tb);

    const mapped = c.SDL_MapGPUTransferBuffer(device, tb, false) orelse {
        return sdlFail(diag, "SDL_MapGPUTransferBuffer (texture) failed");
    };
    const dst: [*]u8 = @ptrCast(mapped);
    @memcpy(dst[0..expected_bytes], pixels[0..expected_bytes]);
    c.SDL_UnmapGPUTransferBuffer(device, tb);

    const cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse return sdlFail(diag, "SDL_AcquireGPUCommandBuffer (texture) failed");
    const copy_pass = c.SDL_BeginGPUCopyPass(cmd) orelse {
        _ = c.SDL_SubmitGPUCommandBuffer(cmd);
        return sdlFail(diag, "SDL_BeginGPUCopyPass (texture) failed");
    };
    c.SDL_UploadToGPUTexture(
        copy_pass,
        &.{ .transfer_buffer = tb, .offset = 0, .pixels_per_row = width, .rows_per_layer = height },
        &.{ .texture = tex, .w = width, .h = height, .d = 1 },
        false,
    );
    c.SDL_EndGPUCopyPass(copy_pass);
    if (!c.SDL_SubmitGPUCommandBuffer(cmd)) {
        return sdlFail(diag, "SDL_SubmitGPUCommandBuffer (texture) failed");
    }
    return tex;
}

fn createOffscreenColorTexture(device: *c.SDL_GPUDevice, diag: *engine.Diagnostics, format: c.SDL_GPUTextureFormat, width: u32, height: u32) !*c.SDL_GPUTexture {
    const w = if (width == 0) @as(u32, 1) else width;
    const h = if (height == 0) @as(u32, 1) else height;
    return c.SDL_CreateGPUTexture(device, &std.mem.zeroInit(c.SDL_GPUTextureCreateInfo, .{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = format,
        .usage = c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
        .width = w,
        .height = h,
        .layer_count_or_depth = 1,
        .num_levels = 1,
    })) orelse sdlFail(diag, "SDL_CreateGPUTexture (offscreen) failed");
}

fn onCreateSurface(raw_ctx: *anyopaque, handle: graphics.RenderTargetHandle, window_handle: u64, width: u32, height: u32) !void {
    if (window_handle != 0) return;
    const state: *SdlGpuState = @ptrCast(@alignCast(raw_ctx));
    const tex = try createOffscreenColorTexture(state.device, state.diagnostics, state.swapchain_format, width, height);
    errdefer c.SDL_ReleaseGPUTexture(state.device, tex);
    try state.offscreen_targets.append(state.allocator, .{
        .handle = handle,
        .texture = tex,
        .width = width,
        .height = height,
    });
}

fn onResizeSurface(raw_ctx: *anyopaque, handle: graphics.RenderTargetHandle, width: u32, height: u32) void {
    const state: *SdlGpuState = @ptrCast(@alignCast(raw_ctx));
    for (state.offscreen_targets.items) |*ot| {
        if (std.meta.eql(ot.handle, handle)) {
            if (ot.width == width and ot.height == height) return;
            // The callback cannot return an error: log it and keep the previous (still valid) texture.
            const new_tex = createOffscreenColorTexture(state.device, state.diagnostics, state.swapchain_format, width, height) catch {
                state.diagnostics.log(.err, "graphics-sdlgpu", "offscreen resize failed; keeping previous target size") catch {};
                return;
            };
            // Deferred release: SDL keeps the old texture alive until in-flight work completes.
            c.SDL_ReleaseGPUTexture(state.device, ot.texture);
            ot.texture = new_tex;
            ot.width = width;
            ot.height = height;
            return;
        }
    }
}

fn onDestroySurface(raw_ctx: *anyopaque, handle: graphics.RenderTargetHandle) void {
    const state: *SdlGpuState = @ptrCast(@alignCast(raw_ctx));
    for (state.offscreen_targets.items, 0..) |ot, i| {
        if (std.meta.eql(ot.handle, handle)) {
            c.SDL_ReleaseGPUTexture(state.device, ot.texture);
            _ = state.offscreen_targets.swapRemove(i);
            return;
        }
    }
}

fn findOffscreenTarget(state: *const SdlGpuState, handle: graphics.RenderTargetHandle) ?OffscreenTarget {
    for (state.offscreen_targets.items) |ot| {
        if (std.meta.eql(ot.handle, handle)) return ot;
    }
    return null;
}

fn intersectScissor(a: ScissorRect, b: ScissorRect) ScissorRect {
    const ax1 = a.x + @as(i32, @intCast(a.w));
    const ay1 = a.y + @as(i32, @intCast(a.h));
    const bx1 = b.x + @as(i32, @intCast(b.w));
    const by1 = b.y + @as(i32, @intCast(b.h));
    const ix0 = @max(a.x, b.x);
    const iy0 = @max(a.y, b.y);
    const ix1 = @max(ix0, @min(ax1, bx1));
    const iy1 = @max(iy0, @min(ay1, by1));
    return .{
        .x = ix0,
        .y = iy0,
        .w = @intCast(ix1 - ix0),
        .h = @intCast(iy1 - iy0),
    };
}

fn toScissorRect(r: graphics.ClipRect, dpi_scale: f32) ScissorRect {
    const rx: i32 = @intFromFloat(@max(0.0, r.x * dpi_scale));
    const ry: i32 = @intFromFloat(@max(0.0, r.y * dpi_scale));
    const rw: u32 = @intFromFloat(@max(0.0, r.width * dpi_scale));
    const rh: u32 = @intFromFloat(@max(0.0, r.height * dpi_scale));
    return .{ .x = rx, .y = ry, .w = rw, .h = rh };
}

fn flushQuadBatch(
    state: *SdlGpuState,
    texture: GpuTextureHandle,
    scissor: ?ScissorRect,
    first_v: u32,
    v_count: u32,
) !void {
    if (v_count == 0) return;
    if (state.tex_batches.items.len > 0) {
        const last = &state.tex_batches.items[state.tex_batches.items.len - 1];
        if (std.meta.eql(last.texture, texture) and ScissorRect.eql(last.scissor, scissor)) {
            last.vertex_count += v_count;
            return;
        }
    }
    try state.tex_batches.append(state.allocator, .{
        .first_vertex = first_v,
        .vertex_count = v_count,
        .texture = texture,
        .scissor = scissor,
    });
}

fn onPresent(raw_ctx: *anyopaque, handle: graphics.RenderTargetHandle, commands: []const graphics.DrawCommand) !void {
    const state: *SdlGpuState = @ptrCast(@alignCast(raw_ctx));
    defer {
        state.ndc_vertices.clearRetainingCapacity();
        state.queued_quads.clearRetainingCapacity();
        state.tex_vertices.clearRetainingCapacity();
        state.tex_batches.clearRetainingCapacity();
        state.queued_meshes.clearRetainingCapacity();
    }

    const dpi_scale: f32 = if (window_sdl3.pixelSize(state.app)) |px|
        (if (px.dpi_scale > 0.0) px.dpi_scale else 1.0)
    else
        1.0;

    var clear_color = state.default_clear_color;
    var clip_stack: [32]ScissorRect = undefined;
    var clip_depth: usize = 0;
    var active_scissor: ?ScissorRect = null;
    var text_quad_scratch: std.ArrayList(text_pkg.TextQuad) = .empty;
    defer text_quad_scratch.deinit(state.allocator);

    // Pre-existing queued quads (from render_2d sprite batches) go first.
    for (state.queued_quads.items) |q| {
        const first_v: u32 = @intCast(state.tex_vertices.items.len);
        try gpu_resources.appendTexturedQuadVertices(&state.tex_vertices, state.allocator, q);
        try flushQuadBatch(state, q.texture, q.scissor, first_v, 6);
    }

    // Convert DrawCommands (logical coordinates) into DPI-scaled batched vertices.
    for (commands) |cmd| {
        switch (cmd) {
            .clear => |col| clear_color = col,
            .clip_rect => |cr| {
                clip_depth = 0;
                if (cr) |r| {
                    const sc = toScissorRect(r, dpi_scale);
                    clip_stack[0] = sc;
                    clip_depth = 1;
                    active_scissor = sc;
                } else {
                    active_scissor = null;
                }
            },
            .clip_push => |r| {
                const sc = toScissorRect(r, dpi_scale);
                const next = if (active_scissor) |prev| intersectScissor(prev, sc) else sc;
                if (clip_depth < clip_stack.len) {
                    clip_stack[clip_depth] = next;
                    clip_depth += 1;
                }
                active_scissor = next;
            },
            .clip_pop => {
                if (clip_depth > 0) {
                    clip_depth -= 1;
                }
                active_scissor = if (clip_depth > 0) clip_stack[clip_depth - 1] else null;
            },
            .rect => |r| {
                const first_v: u32 = @intCast(state.tex_vertices.items.len);
                try gpu_resources.appendTexturedQuadVertices(&state.tex_vertices, state.allocator, .{
                    .x = r.x * dpi_scale,
                    .y = r.y * dpi_scale,
                    .width = r.width * dpi_scale,
                    .height = r.height * dpi_scale,
                    .color = r.color,
                    .texture = state.white_texture,
                    .scissor = active_scissor,
                });
                try flushQuadBatch(state, state.white_texture, active_scissor, first_v, 6);
            },
            .rounded_rect => |rr| {
                const first_v: u32 = @intCast(state.tex_vertices.items.len);
                const scaled_radii = [4]f32{
                    rr.corner_radii[0] * dpi_scale,
                    rr.corner_radii[1] * dpi_scale,
                    rr.corner_radii[2] * dpi_scale,
                    rr.corner_radii[3] * dpi_scale,
                };
                const scaled_borders = [4]f32{
                    rr.border_widths[0] * dpi_scale,
                    rr.border_widths[1] * dpi_scale,
                    rr.border_widths[2] * dpi_scale,
                    rr.border_widths[3] * dpi_scale,
                };
                try gpu_resources.appendRoundedRectVertices(
                    &state.tex_vertices,
                    state.allocator,
                    rr.x * dpi_scale,
                    rr.y * dpi_scale,
                    rr.width * dpi_scale,
                    rr.height * dpi_scale,
                    rr.color,
                    rr.border_color,
                    scaled_borders,
                    scaled_radii,
                );
                const added: u32 = @intCast(state.tex_vertices.items.len - first_v);
                try flushQuadBatch(state, state.white_texture, active_scissor, first_v, added);
            },
            .gradient_rect => |gr| {
                const first_v: u32 = @intCast(state.tex_vertices.items.len);
                try gpu_resources.appendGradientRectVertices(
                    &state.tex_vertices,
                    state.allocator,
                    gr.x * dpi_scale,
                    gr.y * dpi_scale,
                    gr.width * dpi_scale,
                    gr.height * dpi_scale,
                    gr.kind,
                    gr.stops,
                    .{
                        gr.corner_radii[0] * dpi_scale,
                        gr.corner_radii[1] * dpi_scale,
                        gr.corner_radii[2] * dpi_scale,
                        gr.corner_radii[3] * dpi_scale,
                    },
                );
                const added: u32 = @intCast(state.tex_vertices.items.len - first_v);
                try flushQuadBatch(state, state.white_texture, active_scissor, first_v, added);
            },
            .color_wheel => |cw| {
                const first_v: u32 = @intCast(state.tex_vertices.items.len);
                try gpu_resources.appendColorWheelVertices(
                    &state.tex_vertices,
                    state.allocator,
                    cw.x * dpi_scale,
                    cw.y * dpi_scale,
                    cw.size * dpi_scale,
                    cw.hue_deg,
                    cw.ring_width * dpi_scale,
                );
                const added: u32 = @intCast(state.tex_vertices.items.len - first_v);
                try flushQuadBatch(state, state.white_texture, active_scissor, first_v, added);
            },
            .icon => |ic| {
                const first_v: u32 = @intCast(state.tex_vertices.items.len);
                if (state.lucide_atlas.makeIconQuad(@intFromEnum(ic.kind), ic.x * dpi_scale, ic.y * dpi_scale, ic.size * dpi_scale, ic.color)) |iq| {
                    try gpu_resources.appendTexturedQuadVertices(&state.tex_vertices, state.allocator, .{
                        .x = iq.x,
                        .y = iq.y,
                        .width = iq.width,
                        .height = iq.height,
                        .u0 = iq.u0,
                        .v0 = iq.v0,
                        .u1 = iq.u1,
                        .v1 = iq.v1,
                        .color = iq.color,
                    });
                    const added: u32 = @intCast(state.tex_vertices.items.len - first_v);
                    try flushQuadBatch(state, state.lucide_texture, active_scissor, first_v, added);
                } else {
                    try gpu_resources.appendIconVertices(
                        &state.tex_vertices,
                        state.allocator,
                        ic.x * dpi_scale,
                        ic.y * dpi_scale,
                        ic.size * dpi_scale,
                        ic.kind,
                        ic.color,
                    );
                    const added: u32 = @intCast(state.tex_vertices.items.len - first_v);
                    try flushQuadBatch(state, state.white_texture, active_scissor, first_v, added);
                }
            },
            .text => |tx| {
                text_quad_scratch.clearRetainingCapacity();
                const target_px = (if (tx.scale > 0.0) tx.scale else 2.0) * 8.0 * dpi_scale;
                var draw_x = tx.x * dpi_scale;
                if (tx.box_width > 0.0 and tx.align_mode != .left) {
                    const measured = state.ttf_atlas.measureText(tx.content, target_px);
                    const box_px = tx.box_width * dpi_scale;
                    if (tx.align_mode == .center) {
                        draw_x += @max(@as(f32, 0.0), (box_px - measured.width) * 0.5);
                    } else if (tx.align_mode == .right) {
                        draw_x += @max(@as(f32, 0.0), box_px - measured.width);
                    }
                }
                try state.ttf_atlas.emitTextQuads(
                    state.allocator,
                    &text_quad_scratch,
                    draw_x,
                    tx.y * dpi_scale,
                    tx.content,
                    target_px,
                    tx.color,
                );
                for (text_quad_scratch.items) |tq| {
                    const first_v: u32 = @intCast(state.tex_vertices.items.len);
                    try gpu_resources.appendTexturedQuadVertices(&state.tex_vertices, state.allocator, .{
                        .x = tq.x,
                        .y = tq.y,
                        .width = tq.width,
                        .height = tq.height,
                        .u0 = tq.u0,
                        .v0 = tq.v0,
                        .u1 = tq.u1,
                        .v1 = tq.v1,
                        .color = tq.color,
                        .texture = state.ttf_font_texture,
                        .scissor = active_scissor,
                    });
                    try flushQuadBatch(state, state.ttf_font_texture, active_scissor, first_v, 6);
                }
            },
        }
    }

    const pos_count: u32 = @intCast(state.ndc_vertices.items.len);
    const tex_count: u32 = @intCast(state.tex_vertices.items.len);

    if (pos_count > 0) {
        try ensureDynamicBuffer(
            state.device,
            state.diagnostics,
            &state.pos_vertex_buffer,
            &state.pos_transfer_buffer,
            &state.pos_capacity_bytes,
            pos_count * @sizeOf(Vertex2D),
        );
    }
    if (tex_count > 0) {
        try ensureDynamicBuffer(
            state.device,
            state.diagnostics,
            &state.tex_vertex_buffer,
            &state.tex_transfer_buffer,
            &state.tex_capacity_bytes,
            tex_count * @sizeOf(Vertex2DTextured),
        );
    }

    const cmd_buf = c.SDL_AcquireGPUCommandBuffer(state.device) orelse {
        state.graphics_svc.setDeviceAvailable(false);
        return sdlFail(state.diagnostics, "SDL_AcquireGPUCommandBuffer failed");
    };
    var cmd_submitted = false;
    errdefer if (!cmd_submitted) {
        _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);
    };

    if (pos_count > 0 or tex_count > 0) {
        const copy_pass = c.SDL_BeginGPUCopyPass(cmd_buf) orelse {
            return sdlFail(state.diagnostics, "SDL_BeginGPUCopyPass failed");
        };
        if (pos_count > 0) {
            uploadBufferViaCopyPass(
                state.device,
                state.diagnostics,
                copy_pass,
                state.pos_vertex_buffer,
                state.pos_transfer_buffer,
                std.mem.sliceAsBytes(state.ndc_vertices.items),
            ) catch |err| {
                c.SDL_EndGPUCopyPass(copy_pass);
                return err;
            };
        }
        if (tex_count > 0) {
            uploadBufferViaCopyPass(
                state.device,
                state.diagnostics,
                copy_pass,
                state.tex_vertex_buffer,
                state.tex_transfer_buffer,
                std.mem.sliceAsBytes(state.tex_vertices.items),
            ) catch |err| {
                c.SDL_EndGPUCopyPass(copy_pass);
                return err;
            };
        }
        c.SDL_EndGPUCopyPass(copy_pass);
    }

    var target_tex: ?*c.SDL_GPUTexture = null;
    var tex_w: u32 = 0;
    var tex_h: u32 = 0;
    if (findOffscreenTarget(state, handle)) |ot| {
        target_tex = ot.texture;
        tex_w = ot.width;
        tex_h = ot.height;
    } else {
        if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(cmd_buf, state.sdl_window, &target_tex, &tex_w, &tex_h)) {
            state.graphics_svc.setDeviceAvailable(false);
            return sdlFail(state.diagnostics, "SDL_WaitAndAcquireGPUSwapchainTexture failed");
        }
    }

    // Minimized or occluded window: submit empty command buffer and return cleanly.
    if (target_tex == null or tex_w == 0 or tex_h == 0) {
        cmd_submitted = true;
        _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);
        return;
    }

    // Optional PBR pass (HDR -> Shadow -> Sky -> Lit -> AutoExposure -> Bloom -> PostFX) or legacy unlit 3D pass.
    const has_pbr = state.pbr.frame_active;
    const has_3d = has_pbr or state.queued_meshes.items.len > 0;
    if (has_pbr) {
        const depth_tex = try ensureDepthTexture(state, tex_w, tex_h);
        const white_tex = state.textures.get(state.white_texture).?;
        try state.pbr.renderFrame(
            cmd_buf,
            target_tex.?,
            depth_tex,
            tex_w,
            tex_h,
            white_tex,
            state.linear_sampler,
            state.sampler,
            &state.meshes,
            &state.textures,
        );
    } else if (state.queued_meshes.items.len > 0) {
        const depth_tex = try ensureDepthTexture(state, tex_w, tex_h);
        const color_3d = std.mem.zeroInit(c.SDL_GPUColorTargetInfo, .{
            .texture = target_tex.?,
            .clear_color = .{ .r = clear_color.r, .g = clear_color.g, .b = clear_color.b, .a = clear_color.a },
            .load_op = c.SDL_GPU_LOADOP_CLEAR,
            .store_op = c.SDL_GPU_STOREOP_STORE,
        });
        const depth_target = std.mem.zeroInit(c.SDL_GPUDepthStencilTargetInfo, .{
            .texture = depth_tex,
            .clear_depth = 1.0,
            .load_op = c.SDL_GPU_LOADOP_CLEAR,
            .store_op = c.SDL_GPU_STOREOP_DONT_CARE,
            .stencil_load_op = c.SDL_GPU_LOADOP_DONT_CARE,
            .stencil_store_op = c.SDL_GPU_STOREOP_DONT_CARE,
        });
        const pass_3d = c.SDL_BeginGPURenderPass(cmd_buf, &color_3d, 1, &depth_target) orelse {
            return sdlFail(state.diagnostics, "SDL_BeginGPURenderPass (3D) failed");
        };
        c.SDL_SetGPUViewport(pass_3d, &.{
            .x = 0.0,
            .y = 0.0,
            .w = @floatFromInt(tex_w),
            .h = @floatFromInt(tex_h),
            .min_depth = 0.0,
            .max_depth = 1.0,
        });
        c.SDL_BindGPUGraphicsPipeline(pass_3d, state.mesh_pipeline);
        for (state.queued_meshes.items) |qm| {
            const gpu_mesh = state.meshes.get(qm.mesh) orelse continue;
            const gpu_tex = state.textures.get(qm.texture) orelse state.textures.get(state.white_texture).?;
            c.SDL_BindGPUVertexBuffers(pass_3d, 0, &.{ .buffer = gpu_mesh.vertex_buffer, .offset = 0 }, 1);
            c.SDL_BindGPUIndexBuffer(pass_3d, &.{ .buffer = gpu_mesh.index_buffer, .offset = 0 }, c.SDL_GPU_INDEXELEMENTSIZE_32BIT);
            const uniforms = MeshUniforms{ .mvp = qm.mvp, .base_color = qm.color };
            c.SDL_PushGPUVertexUniformData(cmd_buf, 0, &uniforms, @sizeOf(MeshUniforms));
            c.SDL_BindGPUFragmentSamplers(pass_3d, 0, &.{ .texture = gpu_tex, .sampler = state.sampler }, 1);
            c.SDL_DrawGPUIndexedPrimitives(pass_3d, gpu_mesh.index_count, 1, 0, 0, 0);
        }
        c.SDL_EndGPURenderPass(pass_3d);
    }

    const color_load_op: c.SDL_GPULoadOp = if (has_3d) c.SDL_GPU_LOADOP_LOAD else c.SDL_GPU_LOADOP_CLEAR;
    const color_target = std.mem.zeroInit(c.SDL_GPUColorTargetInfo, .{
        .texture = target_tex.?,
        .clear_color = .{ .r = clear_color.r, .g = clear_color.g, .b = clear_color.b, .a = clear_color.a },
        .load_op = color_load_op,
        .store_op = c.SDL_GPU_STOREOP_STORE,
    });

    const render_pass = c.SDL_BeginGPURenderPass(cmd_buf, &color_target, 1, null) orelse {
        return sdlFail(state.diagnostics, "SDL_BeginGPURenderPass failed");
    };

    c.SDL_SetGPUViewport(render_pass, &.{
        .x = 0.0,
        .y = 0.0,
        .w = @floatFromInt(tex_w),
        .h = @floatFromInt(tex_h),
        .min_depth = 0.0,
        .max_depth = 1.0,
    });

    if (pos_count > 0) {
        c.SDL_BindGPUGraphicsPipeline(render_pass, state.pos_pipeline);
        c.SDL_BindGPUVertexBuffers(render_pass, 0, &.{ .buffer = state.pos_vertex_buffer, .offset = 0 }, 1);
        const uniforms = FrameUniforms{
            .viewport_w = @floatFromInt(tex_w),
            .viewport_h = @floatFromInt(tex_h),
            .use_pixel_coords = 0.0,
        };
        c.SDL_PushGPUVertexUniformData(cmd_buf, 0, &uniforms, @sizeOf(FrameUniforms));
        c.SDL_DrawGPUPrimitives(render_pass, pos_count, 1, 0, 0);
    }

    if (tex_count > 0) {
        c.SDL_BindGPUGraphicsPipeline(render_pass, state.tex_pipeline);
        c.SDL_BindGPUVertexBuffers(render_pass, 0, &.{ .buffer = state.tex_vertex_buffer, .offset = 0 }, 1);
        const uniforms = TexturedUniforms{
            .viewport_w = @floatFromInt(tex_w),
            .viewport_h = @floatFromInt(tex_h),
        };
        c.SDL_PushGPUVertexUniformData(cmd_buf, 0, &uniforms, @sizeOf(TexturedUniforms));

        const full_scissor = c.SDL_Rect{ .x = 0, .y = 0, .w = @intCast(tex_w), .h = @intCast(tex_h) };
        for (state.tex_batches.items) |batch| {
            const gpu_tex = state.textures.get(batch.texture) orelse state.textures.get(state.white_texture).?;
            if (batch.scissor) |sc| {
                const max_w: i32 = @intCast(tex_w);
                const max_h: i32 = @intCast(tex_h);
                const x0 = std.math.clamp(sc.x, 0, max_w);
                const y0 = std.math.clamp(sc.y, 0, max_h);
                const x1 = std.math.clamp(sc.x + @as(i32, @intCast(sc.w)), 0, max_w);
                const y1 = std.math.clamp(sc.y + @as(i32, @intCast(sc.h)), 0, max_h);
                if (x1 <= x0 or y1 <= y0) continue;
                c.SDL_SetGPUScissor(render_pass, &.{
                    .x = x0,
                    .y = y0,
                    .w = x1 - x0,
                    .h = y1 - y0,
                });
            } else {
                c.SDL_SetGPUScissor(render_pass, &full_scissor);
            }
            const active_sampler = if (std.meta.eql(batch.texture, state.ttf_font_texture) or std.meta.eql(batch.texture, state.lucide_texture)) state.linear_sampler else state.sampler;
            c.SDL_BindGPUFragmentSamplers(render_pass, 0, &.{
                .texture = gpu_tex,
                .sampler = active_sampler,
            }, 1);
            c.SDL_DrawGPUPrimitives(render_pass, batch.vertex_count, 1, batch.first_vertex, 0);
        }
    }

    c.SDL_EndGPURenderPass(render_pass);

    cmd_submitted = true;
    if (!c.SDL_SubmitGPUCommandBuffer(cmd_buf)) {
        state.graphics_svc.setDeviceAvailable(false);
        return sdlFail(state.diagnostics, "SDL_SubmitGPUCommandBuffer failed");
    }
}

const BACKEND_VTABLE = graphics.BackendVTable{
    .on_create_surface = onCreateSurface,
    .on_resize_surface = onResizeSurface,
    .on_destroy_surface = onDestroySurface,
    .on_present = onPresent,
};

/// Queues an NDC-space triangle (`[-1..1]`) to be rendered on the next `present()` call.
pub fn queueTriangle(app: *engine.App, v0: Vertex2D, v1: Vertex2D, v2: Vertex2D, _: bool) !void {
    const state = app.resources.get(SdlGpuState) orelse return error.MissingGpuState;
    try state.ndc_vertices.appendSlice(state.allocator, &.{ v0, v1, v2 });
}

/// Queues a textured, optionally rotated quad in physical pixels for the next `present()` call.
pub fn queueTexturedQuad(app: *engine.App, quad: TexturedQuad) !void {
    const state = app.resources.get(SdlGpuState) orelse return error.MissingGpuState;
    try state.queued_quads.append(state.allocator, quad);
}

/// Uploads an RGBA8 texture to the GPU and returns a generational handle.
pub fn createTextureRgba8(app: *engine.App, width: u32, height: u32, pixels: []const u8) !GpuTextureHandle {
    const state = app.resources.get(SdlGpuState) orelse return error.MissingGpuState;
    const tex = try uploadTextureRgba8Internal(state.device, state.diagnostics, width, height, pixels);
    errdefer c.SDL_ReleaseGPUTexture(state.device, tex);
    return try state.textures.insert(tex);
}

/// Releases a GPU texture previously created with `createTextureRgba8`.
pub fn destroyTexture(app: *engine.App, handle: GpuTextureHandle) void {
    const state = app.resources.get(SdlGpuState) orelse return;
    if (state.textures.remove(handle)) |tex| {
        c.SDL_ReleaseGPUTexture(state.device, tex);
    }
}

pub fn whiteTextureHandle(app: *engine.App) ?GpuTextureHandle {
    const state = app.resources.get(SdlGpuState) orelse return null;
    return state.white_texture;
}

pub fn fontTextureHandle(app: *engine.App) ?GpuTextureHandle {
    const state = app.resources.get(SdlGpuState) orelse return null;
    return state.font_texture;
}

/// Uploads a 3D mesh (32-byte Vertex3D stride + u32 indices) to the GPU.
pub fn createMesh3D(app: *engine.App, vertex_bytes: []const u8, indices: []const u32) !GpuMeshHandle {
    const state = app.resources.get(SdlGpuState) orelse return error.MissingGpuState;
    const vb = try uploadStaticGpuBuffer(state.device, state.diagnostics, c.SDL_GPU_BUFFERUSAGE_VERTEX, vertex_bytes);
    errdefer c.SDL_ReleaseGPUBuffer(state.device, vb);
    const ib = try uploadStaticGpuBuffer(state.device, state.diagnostics, c.SDL_GPU_BUFFERUSAGE_INDEX, std.mem.sliceAsBytes(indices));
    errdefer c.SDL_ReleaseGPUBuffer(state.device, ib);
    return try state.meshes.insert(.{
        .vertex_buffer = vb,
        .index_buffer = ib,
        .index_count = @intCast(indices.len),
    });
}

/// Releases a 3D GPU mesh previously created with `createMesh3D`.
pub fn destroyMesh3D(app: *engine.App, handle: GpuMeshHandle) void {
    const state = app.resources.get(SdlGpuState) orelse return;
    if (state.meshes.remove(handle)) |m| {
        c.SDL_ReleaseGPUBuffer(state.device, m.index_buffer);
        c.SDL_ReleaseGPUBuffer(state.device, m.vertex_buffer);
    }
}

/// Queues a 3D mesh draw for the next `present()` call (rendered with depth testing).
pub fn queueMeshDraw(
    app: *engine.App,
    mesh: GpuMeshHandle,
    mvp: [16]f32,
    color: [4]f32,
    texture: ?GpuTextureHandle,
) !void {
    const state = app.resources.get(SdlGpuState) orelse return error.MissingGpuState;
    try state.queued_meshes.append(state.allocator, .{
        .mesh = mesh,
        .mvp = mvp,
        .color = color,
        .texture = texture orelse state.white_texture,
    });
}

/// Returns the active SDL_GPU driver name (e.g., "vulkan", "direct3d12", "metal").
pub fn driverName(app: *engine.App) ?[]const u8 {
    const state = app.resources.get(SdlGpuState) orelse return null;
    const raw = c.SDL_GetGPUDeviceDriver(state.device) orelse return null;
    return std.mem.span(raw);
}

fn buildModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    const cfg: GpuConfig = if (app.resources.get(GpuConfig)) |p| p.* else .{};

    const raw_win = window_sdl3.sdlWindowOpaque(app) orelse {
        logDiag(&app.diagnostics, .err, "SDL_Window not available; register official.window.sdl3 before graphics.sdlgpu", .{});
        return error.MissingWindowBackend;
    };
    const sdl_window: *c.SDL_Window = @ptrCast(@alignCast(raw_win));

    const device = c.SDL_CreateGPUDevice(c.SDL_GPU_SHADERFORMAT_SPIRV, cfg.debug_mode, null) orelse {
        return sdlFail(&app.diagnostics, "SDL_CreateGPUDevice failed");
    };
    errdefer c.SDL_DestroyGPUDevice(device);

    const driver = if (c.SDL_GetGPUDeviceDriver(device)) |d| std.mem.span(d) else "unknown";
    logDiag(&app.diagnostics, .info, "SDL_GPU device created (driver: {s}, debug: {})", .{ driver, cfg.debug_mode });

    if (!c.SDL_ClaimWindowForGPUDevice(device, sdl_window)) {
        return sdlFail(&app.diagnostics, "SDL_ClaimWindowForGPUDevice failed");
    }
    errdefer c.SDL_ReleaseWindowFromGPUDevice(device, sdl_window);

    const swapchain_format = c.SDL_GetGPUSwapchainTextureFormat(device, sdl_window);
    const depth_format: c.SDL_GPUTextureFormat = if (c.SDL_GPUTextureSupportsFormat(
        device,
        c.SDL_GPU_TEXTUREFORMAT_D24_UNORM,
        c.SDL_GPU_TEXTURETYPE_2D,
        c.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET,
    )) c.SDL_GPU_TEXTUREFORMAT_D24_UNORM else c.SDL_GPU_TEXTUREFORMAT_D16_UNORM;
    logDiag(&app.diagnostics, .info, "Claimed window for SDL_GPU (swapchain: {d}, depth: {d})", .{ swapchain_format, depth_format });

    const pos_vert = try createShader(device, &app.diagnostics, c.SDL_GPU_SHADERSTAGE_VERTEX, POS_VERT_SPV, 0, 1);
    errdefer c.SDL_ReleaseGPUShader(device, pos_vert);
    const pos_frag = try createShader(device, &app.diagnostics, c.SDL_GPU_SHADERSTAGE_FRAGMENT, POS_FRAG_SPV, 0, 0);
    errdefer c.SDL_ReleaseGPUShader(device, pos_frag);
    const pos_pipeline = try createPosColorPipeline(device, &app.diagnostics, pos_vert, pos_frag, swapchain_format);
    errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, pos_pipeline);

    const tex_vert = try createShader(device, &app.diagnostics, c.SDL_GPU_SHADERSTAGE_VERTEX, TEX_VERT_SPV, 0, 1);
    errdefer c.SDL_ReleaseGPUShader(device, tex_vert);
    const tex_frag = try createShader(device, &app.diagnostics, c.SDL_GPU_SHADERSTAGE_FRAGMENT, TEX_FRAG_SPV, 1, 0);
    errdefer c.SDL_ReleaseGPUShader(device, tex_frag);
    const tex_pipeline = try createTexturedPipeline(device, &app.diagnostics, tex_vert, tex_frag, swapchain_format);
    errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, tex_pipeline);

    const mesh_vert = try createShader(device, &app.diagnostics, c.SDL_GPU_SHADERSTAGE_VERTEX, MESH_VERT_SPV, 0, 1);
    errdefer c.SDL_ReleaseGPUShader(device, mesh_vert);
    const mesh_frag = try createShader(device, &app.diagnostics, c.SDL_GPU_SHADERSTAGE_FRAGMENT, MESH_FRAG_SPV, 1, 0);
    errdefer c.SDL_ReleaseGPUShader(device, mesh_frag);
    const mesh_pipeline = try createMeshUnlitPipeline(device, &app.diagnostics, mesh_vert, mesh_frag, swapchain_format, depth_format);
    errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, mesh_pipeline);

    logDiag(&app.diagnostics, .info, "Created pos_color, textured, and mesh_unlit SPIR-V pipelines", .{});

    const sampler = c.SDL_CreateGPUSampler(device, &std.mem.zeroInit(c.SDL_GPUSamplerCreateInfo, .{
        .min_filter = c.SDL_GPU_FILTER_NEAREST,
        .mag_filter = c.SDL_GPU_FILTER_NEAREST,
        .mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST,
        .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
    })) orelse return sdlFail(&app.diagnostics, "SDL_CreateGPUSampler failed");
    errdefer c.SDL_ReleaseGPUSampler(device, sampler);

    const linear_sampler = c.SDL_CreateGPUSampler(device, &std.mem.zeroInit(c.SDL_GPUSamplerCreateInfo, .{
        .min_filter = c.SDL_GPU_FILTER_LINEAR,
        .mag_filter = c.SDL_GPU_FILTER_LINEAR,
        .mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_LINEAR,
        .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .max_lod = 16.0,
    })) orelse return sdlFail(&app.diagnostics, "SDL_CreateGPUSampler (linear) failed");
    errdefer c.SDL_ReleaseGPUSampler(device, linear_sampler);

    const pos_bytes: u32 = @intCast(INITIAL_VERTEX_CAPACITY * @sizeOf(Vertex2D));
    const pos_vb = c.SDL_CreateGPUBuffer(device, &std.mem.zeroInit(c.SDL_GPUBufferCreateInfo, .{
        .usage = c.SDL_GPU_BUFFERUSAGE_VERTEX,
        .size = pos_bytes,
    })) orelse return sdlFail(&app.diagnostics, "SDL_CreateGPUBuffer (pos) failed");
    errdefer c.SDL_ReleaseGPUBuffer(device, pos_vb);

    const pos_tb = c.SDL_CreateGPUTransferBuffer(device, &std.mem.zeroInit(c.SDL_GPUTransferBufferCreateInfo, .{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = pos_bytes,
    })) orelse return sdlFail(&app.diagnostics, "SDL_CreateGPUTransferBuffer (pos) failed");
    errdefer c.SDL_ReleaseGPUTransferBuffer(device, pos_tb);

    const tex_bytes: u32 = @intCast(INITIAL_VERTEX_CAPACITY * @sizeOf(Vertex2DTextured));
    const tex_vb = c.SDL_CreateGPUBuffer(device, &std.mem.zeroInit(c.SDL_GPUBufferCreateInfo, .{
        .usage = c.SDL_GPU_BUFFERUSAGE_VERTEX,
        .size = tex_bytes,
    })) orelse return sdlFail(&app.diagnostics, "SDL_CreateGPUBuffer (tex) failed");
    errdefer c.SDL_ReleaseGPUBuffer(device, tex_vb);

    const tex_tb = c.SDL_CreateGPUTransferBuffer(device, &std.mem.zeroInit(c.SDL_GPUTransferBufferCreateInfo, .{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = tex_bytes,
    })) orelse return sdlFail(&app.diagnostics, "SDL_CreateGPUTransferBuffer (tex) failed");
    errdefer c.SDL_ReleaseGPUTransferBuffer(device, tex_tb);

    var tex_pool = TexturePool.init(app.allocator);
    errdefer tex_pool.deinit();

    const white_pixels = [_]u8{ 255, 255, 255, 255 };
    const white_raw = try uploadTextureRgba8Internal(device, &app.diagnostics, 1, 1, &white_pixels);
    const white_handle = try tex_pool.insert(white_raw);

    const font_pixels = try text_pkg.generateFontAtlasRgba8(app.allocator);
    defer app.allocator.free(font_pixels);
    const font_raw = try uploadTextureRgba8Internal(device, &app.diagnostics, text_pkg.ATLAS_WIDTH, text_pkg.ATLAS_HEIGHT, font_pixels);
    const font_handle = try tex_pool.insert(font_raw);

    var ttf_atlas = try text_pkg.TtfAtlas.bake(app.allocator, text_pkg.FIRA_SANS_REGULAR, 28.0);
    errdefer ttf_atlas.deinit();
    const ttf_raw = try uploadTextureRgba8Internal(device, &app.diagnostics, ttf_atlas.width, ttf_atlas.height, ttf_atlas.rgba_pixels);
    const ttf_font_handle = try tex_pool.insert(ttf_raw);

    var lucide_atlas = try text_pkg.IconAtlas.bake(app.allocator, 32.0);
    errdefer lucide_atlas.deinit();
    const lucide_raw = try uploadTextureRgba8Internal(device, &app.diagnostics, lucide_atlas.width, lucide_atlas.height, lucide_atlas.rgba_pixels);
    const lucide_handle = try tex_pool.insert(lucide_raw);

    logDiag(&app.diagnostics, .info, "Uploaded built-in 1x1 white and {d}x{d} font atlas textures", .{
        text_pkg.ATLAS_WIDTH,
        text_pkg.ATLAS_HEIGHT,
    });

    var pbr_state = try pbr_backend.PbrGpuState.init(app.allocator, device, &app.diagnostics, swapchain_format, depth_format);
    errdefer pbr_state.deinit();

    try app.resources.insert(SdlGpuState, .{
        .allocator = app.allocator,
        .app = app,
        .diagnostics = &app.diagnostics,
        .sdl_window = sdl_window,
        .device = device,
        .swapchain_format = swapchain_format,
        .depth_format = depth_format,
        .pos_vert_shader = pos_vert,
        .pos_frag_shader = pos_frag,
        .pos_pipeline = pos_pipeline,
        .pos_vertex_buffer = pos_vb,
        .pos_transfer_buffer = pos_tb,
        .pos_capacity_bytes = pos_bytes,
        .tex_vert_shader = tex_vert,
        .tex_frag_shader = tex_frag,
        .tex_pipeline = tex_pipeline,
        .tex_vertex_buffer = tex_vb,
        .tex_transfer_buffer = tex_tb,
        .tex_capacity_bytes = tex_bytes,
        .sampler = sampler,
        .linear_sampler = linear_sampler,
        .textures = tex_pool,
        .white_texture = white_handle,
        .font_texture = font_handle,
        .ttf_font_texture = ttf_font_handle,
        .ttf_atlas = ttf_atlas,
        .lucide_texture = lucide_handle,
        .lucide_atlas = lucide_atlas,
        .mesh_vert_shader = mesh_vert,
        .mesh_frag_shader = mesh_frag,
        .mesh_pipeline = mesh_pipeline,
        .meshes = MeshPool.init(app.allocator),
        .queued_meshes = .empty,
        .pbr = pbr_state,
        .default_clear_color = cfg.default_clear_color,
        .ndc_vertices = .empty,
        .queued_quads = .empty,
        .tex_vertices = .empty,
        .tex_batches = .empty,
        .offscreen_targets = .empty,
        .graphics_svc = undefined,
    });

    const state = app.resources.get(SdlGpuState).?;
    state.graphics_svc = graphics.GraphicsDeviceService.initWithBackend(
        app.allocator,
        &BACKEND_VTABLE,
        state,
        .{
            .compute = false,
            .depth_texture_sampling = true,
            .storage_buffers = false,
            .timestamp_queries = false,
        },
    );

    app.scheduler.render_extract_enabled = true;

    try app.services.register(.{
        .capability = "engine.graphics.device",
        .major_version = 1,
        .provider_id = PROVIDER_ID,
        .owner_id = MODULE_OWNER_ID,
        .exclusive = true,
        .api_ptr = &state.graphics_svc,
        .api_size = @sizeOf(graphics.GraphicsDeviceService),
    });
}

fn startModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    if (app.resources.get(render_3d.Render3DService)) |r3d| {
        if (app.resources.get(SdlGpuState)) |state| {
            r3d.setPbrBackend(state.pbr.vtable());
        }
    }
}

fn stopModule(raw_app: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    if (app.resources.get(render_3d.Render3DService)) |r3d| {
        r3d.setPbrBackend(null);
    }
    app.scheduler.render_extract_enabled = false;
    _ = app.services.unregisterByOwner(MODULE_OWNER_ID);

    if (app.resources.get(SdlGpuState)) |state| {
        _ = c.SDL_WaitForGPUIdle(state.device);
        state.pbr.deinit();
        if (state.depth_texture) |dt| c.SDL_ReleaseGPUTexture(state.device, dt);

        for (state.meshes.slots.items) |slot| {
            if (slot.alive) {
                c.SDL_ReleaseGPUBuffer(state.device, slot.value.index_buffer);
                c.SDL_ReleaseGPUBuffer(state.device, slot.value.vertex_buffer);
            }
        }
        state.meshes.deinit();

        for (state.textures.slots.items) |slot| {
            if (slot.alive) c.SDL_ReleaseGPUTexture(state.device, slot.value);
        }
        state.textures.deinit();

        c.SDL_ReleaseGPUGraphicsPipeline(state.device, state.mesh_pipeline);
        c.SDL_ReleaseGPUShader(state.device, state.mesh_frag_shader);
        c.SDL_ReleaseGPUShader(state.device, state.mesh_vert_shader);

        c.SDL_ReleaseGPUSampler(state.device, state.linear_sampler);
        c.SDL_ReleaseGPUSampler(state.device, state.sampler);
        state.ttf_atlas.deinit();
        state.lucide_atlas.deinit();
        c.SDL_ReleaseGPUTransferBuffer(state.device, state.tex_transfer_buffer);
        c.SDL_ReleaseGPUBuffer(state.device, state.tex_vertex_buffer);
        c.SDL_ReleaseGPUGraphicsPipeline(state.device, state.tex_pipeline);
        c.SDL_ReleaseGPUShader(state.device, state.tex_frag_shader);
        c.SDL_ReleaseGPUShader(state.device, state.tex_vert_shader);

        c.SDL_ReleaseGPUTransferBuffer(state.device, state.pos_transfer_buffer);
        c.SDL_ReleaseGPUBuffer(state.device, state.pos_vertex_buffer);
        c.SDL_ReleaseGPUGraphicsPipeline(state.device, state.pos_pipeline);
        c.SDL_ReleaseGPUShader(state.device, state.pos_frag_shader);
        c.SDL_ReleaseGPUShader(state.device, state.pos_vert_shader);

        c.SDL_ReleaseWindowFromGPUDevice(state.device, state.sdl_window);
        c.SDL_DestroyGPUDevice(state.device);

        for (state.offscreen_targets.items) |ot| {
            c.SDL_ReleaseGPUTexture(state.device, ot.texture);
        }
        state.offscreen_targets.deinit(state.allocator);

        state.queued_meshes.deinit(state.allocator);
        state.ndc_vertices.deinit(state.allocator);
        state.queued_quads.deinit(state.allocator);
        state.tex_vertices.deinit(state.allocator);
        state.tex_batches.deinit(state.allocator);
        state.graphics_svc.deinit();
        _ = app.resources.remove(SdlGpuState);
    }
}

/// Measures proportional UI text width in logical pixels using the loaded `TtfAtlas`.
pub fn measureTextWidth(raw_ctx: ?*anyopaque, content: []const u8, scale: f32) f32 {
    const ctx_ptr = raw_ctx orelse return @as(f32, @floatFromInt(content.len)) * 4.4 * (if (scale > 0.0) scale else 1.0);
    const state: *const SdlGpuState = @ptrCast(@alignCast(ctx_ptr));
    const target_px = (if (scale > 0.0) scale else 2.0) * 8.0;
    return state.ttf_atlas.measureText(content, target_px).width;
}

pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = PROVIDER_ID,
            .version = "0.1.1",
            .provides_capabilities = &.{"engine.graphics.device/1"},
            .required_capabilities = &.{"engine.window/1"},
        },
        .build = buildModule,
        .start = startModule,
        .stop = stopModule,
    };
}
