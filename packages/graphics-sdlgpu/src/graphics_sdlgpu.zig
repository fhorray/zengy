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
const c = @import("sdl3_c");
pub const gpu_resources = @import("gpu_resources.zig");

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

pub const MODULE_OWNER_ID: u64 = 2012;
pub const PROVIDER_ID = "official.graphics.sdlgpu";

const POS_VERT_SPV = @embedFile("shaders/pos_color.vert.spv");
const POS_FRAG_SPV = @embedFile("shaders/pos_color.frag.spv");
const TEX_VERT_SPV = @embedFile("shaders/textured.vert.spv");
const TEX_FRAG_SPV = @embedFile("shaders/textured.frag.spv");

const INITIAL_VERTEX_CAPACITY: usize = 4096;

/// Optional resource inserted before `app.initialize()` to customise the SDL_GPU backend.
pub const GpuConfig = struct {
    debug_mode: bool = true,
    default_clear_color: graphics.Color = .{ .r = 0.07, .g = 0.09, .b = 0.13, .a = 1.0 },
};

const TexturePool = gpu_resources.GenerationalPool(*c.SDL_GPUTexture, GpuTextureHandle);

const DrawBatch = struct {
    first_vertex: u32,
    vertex_count: u32,
    texture: GpuTextureHandle,
    scissor: ?ScissorRect,
};

const SdlGpuState = struct {
    allocator: std.mem.Allocator,
    app: *engine.App,
    diagnostics: *engine.Diagnostics,
    sdl_window: *c.SDL_Window,
    device: *c.SDL_GPUDevice,
    swapchain_format: c.SDL_GPUTextureFormat,

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
    textures: TexturePool,
    white_texture: GpuTextureHandle,
    font_texture: GpuTextureHandle,

    default_clear_color: graphics.Color,
    ndc_vertices: std.ArrayList(Vertex2D),
    queued_quads: std.ArrayList(TexturedQuad),
    tex_vertices: std.ArrayList(Vertex2DTextured),
    tex_batches: std.ArrayList(DrawBatch),
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

    _ = c.SDL_WaitForGPUIdle(device);

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

fn onPresent(raw_ctx: *anyopaque, _: graphics.RenderTargetHandle, commands: []const graphics.DrawCommand) !void {
    const state: *SdlGpuState = @ptrCast(@alignCast(raw_ctx));
    defer {
        state.ndc_vertices.clearRetainingCapacity();
        state.queued_quads.clearRetainingCapacity();
        state.tex_vertices.clearRetainingCapacity();
        state.tex_batches.clearRetainingCapacity();
    }

    const dpi_scale: f32 = if (window_sdl3.pixelSize(state.app)) |px|
        (if (px.dpi_scale > 0.0) px.dpi_scale else 1.0)
    else
        1.0;

    var clear_color = state.default_clear_color;
    var active_scissor: ?ScissorRect = null;
    var text_quad_scratch: std.ArrayList(text_pkg.TextQuad) = .empty;
    defer text_quad_scratch.deinit(state.allocator);

    // Convert DrawCommands (logical coordinates) into DPI-scaled TexturedQuads.
    for (commands) |cmd| {
        switch (cmd) {
            .clear => |col| clear_color = col,
            .clip_rect => |cr| {
                if (cr) |r| {
                    const rx: i32 = @intFromFloat(@max(0.0, r.x * dpi_scale));
                    const ry: i32 = @intFromFloat(@max(0.0, r.y * dpi_scale));
                    const rw: u32 = @intFromFloat(@max(0.0, r.width * dpi_scale));
                    const rh: u32 = @intFromFloat(@max(0.0, r.height * dpi_scale));
                    active_scissor = .{ .x = rx, .y = ry, .w = rw, .h = rh };
                } else {
                    active_scissor = null;
                }
            },
            .rect => |r| {
                try state.queued_quads.append(state.allocator, .{
                    .x = r.x * dpi_scale,
                    .y = r.y * dpi_scale,
                    .width = r.width * dpi_scale,
                    .height = r.height * dpi_scale,
                    .color = r.color,
                    .texture = state.white_texture,
                    .scissor = active_scissor,
                });
            },
            .text => |tx| {
                text_quad_scratch.clearRetainingCapacity();
                try text_pkg.emitTextQuads(
                    state.allocator,
                    &text_quad_scratch,
                    tx.x * dpi_scale,
                    tx.y * dpi_scale,
                    tx.content,
                    2.0 * dpi_scale,
                    tx.color,
                );
                for (text_quad_scratch.items) |tq| {
                    try state.queued_quads.append(state.allocator, .{
                        .x = tq.x,
                        .y = tq.y,
                        .width = tq.width,
                        .height = tq.height,
                        .u0 = tq.u0,
                        .v0 = tq.v0,
                        .u1 = tq.u1,
                        .v1 = tq.v1,
                        .color = tq.color,
                        .texture = state.font_texture,
                        .scissor = active_scissor,
                    });
                }
            },
        }
    }

    // Build batched textured vertices grouped by (texture, scissor).
    for (state.queued_quads.items) |q| {
        const first_v: u32 = @intCast(state.tex_vertices.items.len);
        try gpu_resources.appendTexturedQuadVertices(&state.tex_vertices, state.allocator, q);
        if (state.tex_batches.items.len > 0) {
            const last = &state.tex_batches.items[state.tex_batches.items.len - 1];
            if (std.meta.eql(last.texture, q.texture) and ScissorRect.eql(last.scissor, q.scissor)) {
                last.vertex_count += 6;
                continue;
            }
        }
        try state.tex_batches.append(state.allocator, .{
            .first_vertex = first_v,
            .vertex_count = 6,
            .texture = q.texture,
            .scissor = q.scissor,
        });
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

    if (pos_count > 0 or tex_count > 0) {
        const copy_pass = c.SDL_BeginGPUCopyPass(cmd_buf) orelse {
            _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);
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
                _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);
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
                _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);
                return err;
            };
        }
        c.SDL_EndGPUCopyPass(copy_pass);
    }

    var swapchain_tex: ?*c.SDL_GPUTexture = null;
    var tex_w: u32 = 0;
    var tex_h: u32 = 0;
    if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(cmd_buf, state.sdl_window, &swapchain_tex, &tex_w, &tex_h)) {
        _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);
        state.graphics_svc.setDeviceAvailable(false);
        return sdlFail(state.diagnostics, "SDL_WaitAndAcquireGPUSwapchainTexture failed");
    }

    // Minimized or occluded window: submit empty command buffer and return cleanly.
    if (swapchain_tex == null or tex_w == 0 or tex_h == 0) {
        _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);
        return;
    }

    const color_target = std.mem.zeroInit(c.SDL_GPUColorTargetInfo, .{
        .texture = swapchain_tex.?,
        .clear_color = .{ .r = clear_color.r, .g = clear_color.g, .b = clear_color.b, .a = clear_color.a },
        .load_op = c.SDL_GPU_LOADOP_CLEAR,
        .store_op = c.SDL_GPU_STOREOP_STORE,
    });

    const render_pass = c.SDL_BeginGPURenderPass(cmd_buf, &color_target, 1, null) orelse {
        _ = c.SDL_SubmitGPUCommandBuffer(cmd_buf);
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
                c.SDL_SetGPUScissor(render_pass, &.{
                    .x = sc.x,
                    .y = sc.y,
                    .w = @intCast(sc.w),
                    .h = @intCast(sc.h),
                });
            } else {
                c.SDL_SetGPUScissor(render_pass, &full_scissor);
            }
            c.SDL_BindGPUFragmentSamplers(render_pass, 0, &.{
                .texture = gpu_tex,
                .sampler = state.sampler,
            }, 1);
            c.SDL_DrawGPUPrimitives(render_pass, batch.vertex_count, 1, batch.first_vertex, 0);
        }
    }

    c.SDL_EndGPURenderPass(render_pass);

    if (!c.SDL_SubmitGPUCommandBuffer(cmd_buf)) {
        state.graphics_svc.setDeviceAvailable(false);
        return sdlFail(state.diagnostics, "SDL_SubmitGPUCommandBuffer failed");
    }
}

const BACKEND_VTABLE = graphics.BackendVTable{
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
        _ = c.SDL_WaitForGPUIdle(state.device);
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
    logDiag(&app.diagnostics, .info, "Claimed window for SDL_GPU (swapchain format: {d})", .{swapchain_format});

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

    logDiag(&app.diagnostics, .info, "Created pos_color and textured SPIR-V pipelines", .{});

    const sampler = c.SDL_CreateGPUSampler(device, &std.mem.zeroInit(c.SDL_GPUSamplerCreateInfo, .{
        .min_filter = c.SDL_GPU_FILTER_NEAREST,
        .mag_filter = c.SDL_GPU_FILTER_NEAREST,
        .mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST,
        .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
    })) orelse return sdlFail(&app.diagnostics, "SDL_CreateGPUSampler failed");
    errdefer c.SDL_ReleaseGPUSampler(device, sampler);

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

    logDiag(&app.diagnostics, .info, "Uploaded built-in 1x1 white and {d}x{d} font atlas textures", .{
        text_pkg.ATLAS_WIDTH,
        text_pkg.ATLAS_HEIGHT,
    });

    try app.resources.insert(SdlGpuState, .{
        .allocator = app.allocator,
        .app = app,
        .diagnostics = &app.diagnostics,
        .sdl_window = sdl_window,
        .device = device,
        .swapchain_format = swapchain_format,
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
        .textures = tex_pool,
        .white_texture = white_handle,
        .font_texture = font_handle,
        .default_clear_color = cfg.default_clear_color,
        .ndc_vertices = .empty,
        .queued_quads = .empty,
        .tex_vertices = .empty,
        .tex_batches = .empty,
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

fn stopModule(raw_app: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    app.scheduler.render_extract_enabled = false;
    _ = app.services.unregisterByOwner(MODULE_OWNER_ID);

    if (app.resources.get(SdlGpuState)) |state| {
        _ = c.SDL_WaitForGPUIdle(state.device);
        for (state.textures.slots.items) |slot| {
            if (slot.alive) c.SDL_ReleaseGPUTexture(state.device, slot.value);
        }
        state.textures.deinit();

        c.SDL_ReleaseGPUSampler(state.device, state.sampler);
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

        state.ndc_vertices.deinit(state.allocator);
        state.queued_quads.deinit(state.allocator);
        state.tex_vertices.deinit(state.allocator);
        state.tex_batches.deinit(state.allocator);
        state.graphics_svc.deinit();
        _ = app.resources.remove(SdlGpuState);
    }
}

pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = PROVIDER_ID,
            .version = "0.1.0",
            .provides_capabilities = &.{"engine.graphics.device/1"},
            .required_capabilities = &.{"engine.window/1"},
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
