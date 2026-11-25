//! GPU renderer for unlit 3D meshes and debug gizmos, written only against `graphics.gpu`.
//!
//! Two frame renderers share one depth target: the world pass (order `world`) draws queued meshes with depth
//! testing, and the gizmo passes (order `gizmos`) draw depth-tested lines, always-visible X-ray lines and solid
//! X-ray triangles on top. Meshes, uniforms and vertex buffers are persistent and grow geometrically.

const std = @import("std");
const graphics = @import("graphics");
const gizmos = @import("gizmos");
const gizmo_lines = @import("gizmo_lines.zig");

const gpu = graphics.gpu;
const frame = graphics.frame;

const unlit_source = @embedFile("unlit.wgsl");
const gizmo_source = @embedFile("gizmo.wgsl");

pub const depth_format: gpu.TextureFormat = .depth32_float;

/// Stable mesh id. Its bit pattern fits `Mesh3D.mesh_asset`-style u64 fields.
pub const MeshHandle = packed struct(u64) { index: u32, generation: u32 };

const Mesh = struct {
    vertex_buffer: gpu.BufferHandle,
    index_buffer: gpu.BufferHandle,
    index_count: u32,
};

pub const QueuedMesh = struct {
    mesh: MeshHandle,
    mvp: [16]f32,
    color: [4]f32,
    /// 0 draws with the built-in white texture.
    texture: graphics.TextureId = 0,
};

/// Matches `MeshUniforms` in unlit.wgsl (std140: mat4 + vec4).
const MeshUniforms = extern struct { mvp: [16]f32, base_color: [4]f32 };
const gizmo_vertex_stride: u64 = @sizeOf(gizmos.GizmoVertex);
const min_vertex_bytes: u64 = 64 * 1024;
const min_uniform_slots: u32 = 64;

const TextureBinding = struct { group: gpu.BindGroupHandle };

const DepthTarget = struct {
    texture: gpu.TextureHandle,
    view: gpu.TextureViewHandle,
    width: u32,
    height: u32,
};

/// Format-independent GPU objects plus lazily built, format-bound pipelines.
const GpuState = struct {
    device: gpu.GpuDevice,
    uniform_alignment: u32,

    // Unlit meshes.
    unlit_shader: gpu.ShaderModuleHandle,
    mesh_uniform_layout: gpu.BindGroupLayoutHandle,
    texture_layout: gpu.BindGroupLayoutHandle,
    unlit_pipeline_layout: gpu.PipelineLayoutHandle,
    unlit_pipeline: ?gpu.RenderPipelineHandle = null,
    unlit_format: ?gpu.TextureFormat = null,
    mesh_uniform_buffer: gpu.BufferHandle,
    mesh_uniform_capacity: u64,
    mesh_uniform_group: gpu.BindGroupHandle,
    sampler: gpu.SamplerHandle,
    white_texture: gpu.TextureHandle,
    white_view: gpu.TextureViewHandle,
    white_group: gpu.BindGroupHandle,

    // Gizmos.
    gizmo_shader: gpu.ShaderModuleHandle,
    gizmo_uniform_layout: gpu.BindGroupLayoutHandle,
    gizmo_pipeline_layout: gpu.PipelineLayoutHandle,
    gizmo_uniform_buffer: gpu.BufferHandle,
    gizmo_uniform_group: gpu.BindGroupHandle,
    gizmo_vertex_buffer: gpu.BufferHandle,
    gizmo_vertex_capacity: u64,
    /// depth line, xray line, depth tri, xray tri (all share one format).
    gizmo_pipelines: [4]?gpu.RenderPipelineHandle = .{ null, null, null, null },
    gizmo_format: ?gpu.TextureFormat = null,
};

pub const Renderer3D = struct {
    allocator: std.mem.Allocator,
    meshes: gpu.HandlePool(Mesh, MeshHandle) = .{},
    queued: std.ArrayList(QueuedMesh) = .empty,
    uniform_scratch: std.ArrayList(u8) = .empty,
    gpu_state: ?GpuState = null,
    /// Device that owns the meshes and GPU state; set on first use so deinit can release everything.
    device: ?gpu.GpuDevice = null,
    texture_groups: std.AutoHashMapUnmanaged(graphics.TextureId, gpu.BindGroupHandle) = .empty,
    depth: ?DepthTarget = null,
    /// The world pass drew this frame, so gizmo depth tests have a populated depth buffer to load.
    world_drawn: bool = false,

    gizmo_view_proj: [16]f32 = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 },
    gizmo_line_width: f32 = 2.0,
    gizmo_depth_bias: f32 = 0.0,
    gizmo_depth_verts: std.ArrayList(gizmos.GizmoVertex) = .empty,
    gizmo_xray_verts: std.ArrayList(gizmos.GizmoVertex) = .empty,
    gizmo_solid_verts: std.ArrayList(gizmos.GizmoVertex) = .empty,
    gizmo_quad_verts: std.ArrayList(gizmos.GizmoVertex) = .empty,
    gizmo_upload: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Renderer3D {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Renderer3D) void {
        if (self.device) |device| self.destroyGpu(device);
        self.meshes.deinit(self.allocator);
        self.queued.deinit(self.allocator);
        self.uniform_scratch.deinit(self.allocator);
        self.texture_groups.deinit(self.allocator);
        self.gizmo_depth_verts.deinit(self.allocator);
        self.gizmo_xray_verts.deinit(self.allocator);
        self.gizmo_solid_verts.deinit(self.allocator);
        self.gizmo_quad_verts.deinit(self.allocator);
        self.gizmo_upload.deinit(self.allocator);
    }

    pub fn worldRenderer(self: *Renderer3D) frame.FrameRenderer {
        return .{ .name = "official.render.3d.gpu.world", .ctx = self, .order = frame.Order.world, .render = worldThunk, .release = releaseThunk, .forget_texture = forgetThunk };
    }

    pub fn gizmoRenderer(self: *Renderer3D) frame.FrameRenderer {
        return .{ .name = "official.render.3d.gpu.gizmos", .ctx = self, .order = frame.Order.gizmos, .render = gizmoThunk };
    }

    fn worldThunk(ctx: *anyopaque, input: *frame.FrameInput) anyerror!void {
        const self: *Renderer3D = @ptrCast(@alignCast(ctx));
        try self.renderWorld(input);
    }

    fn gizmoThunk(ctx: *anyopaque, input: *frame.FrameInput) anyerror!void {
        const self: *Renderer3D = @ptrCast(@alignCast(ctx));
        try self.renderGizmos(input);
    }

    fn forgetThunk(ctx: *anyopaque, device: gpu.GpuDevice, id: graphics.TextureId) void {
        const self: *Renderer3D = @ptrCast(@alignCast(ctx));
        self.forgetTexture(device, id);
    }

    fn releaseThunk(ctx: *anyopaque, device: gpu.GpuDevice) void {
        const self: *Renderer3D = @ptrCast(@alignCast(ctx));
        self.destroyGpu(device);
    }

    // ---------------------------------------------------------------- meshes

    /// Uploads a mesh (32-byte vertices: position, normal, uv; u32 indices).
    pub fn createMesh(self: *Renderer3D, device: gpu.GpuDevice, vertex_bytes: []const u8, indices: []const u32) !MeshHandle {
        self.device = device;
        if (vertex_bytes.len == 0 or indices.len == 0) return error.EmptyMesh;
        if (vertex_bytes.len % 32 != 0) return error.InvalidVertexData;
        const vb = try device.createBuffer(.{ .label = "mesh vertices", .size = vertex_bytes.len, .usage = .{ .vertex = true, .copy_dst = true } });
        errdefer device.destroyBuffer(vb);
        try device.writeBuffer(vb, 0, vertex_bytes);
        const ib = try device.createBuffer(.{ .label = "mesh indices", .size = indices.len * 4, .usage = .{ .index = true, .copy_dst = true } });
        errdefer device.destroyBuffer(ib);
        try device.writeBuffer(ib, 0, std.mem.sliceAsBytes(indices));
        return self.meshes.acquire(self.allocator, .{ .vertex_buffer = vb, .index_buffer = ib, .index_count = @intCast(indices.len) });
    }

    pub fn destroyMesh(self: *Renderer3D, device: gpu.GpuDevice, handle: MeshHandle) void {
        const mesh = self.meshes.release(handle) orelse return;
        device.destroyBuffer(mesh.index_buffer);
        device.destroyBuffer(mesh.vertex_buffer);
    }

    pub fn queueMesh(self: *Renderer3D, draw: QueuedMesh) !void {
        try self.queued.append(self.allocator, draw);
    }

    /// Drops the cached bind group of a texture about to be destroyed in the shared store.
    pub fn forgetTexture(self: *Renderer3D, device: gpu.GpuDevice, id: graphics.TextureId) void {
        const removed = self.texture_groups.fetchRemove(id) orelse return;
        device.destroyBindGroup(removed.value);
    }

    // ---------------------------------------------------------------- gizmos

    /// `gizmos.GizmoBackendVTable.submitGizmos` target: stages the frame's vertices until the gizmo passes run.
    pub fn stageGizmos(
        self: *Renderer3D,
        params: gizmos.GizmoSubmitParams,
        depth_lines: []const gizmos.GizmoVertex,
        xray_lines: []const gizmos.GizmoVertex,
        solid_tris: []const gizmos.GizmoVertex,
    ) !void {
        self.gizmo_view_proj = params.view_proj;
        self.gizmo_line_width = params.line_width;
        self.gizmo_depth_bias = params.depth_bias;
        self.gizmo_depth_verts.clearRetainingCapacity();
        self.gizmo_xray_verts.clearRetainingCapacity();
        self.gizmo_solid_verts.clearRetainingCapacity();
        try self.gizmo_depth_verts.appendSlice(self.allocator, depth_lines);
        try self.gizmo_xray_verts.appendSlice(self.allocator, xray_lines);
        try self.gizmo_solid_verts.appendSlice(self.allocator, solid_tris);
    }

    // ------------------------------------------------------------ GPU state

    fn ensureGpu(self: *Renderer3D, device: gpu.GpuDevice) !*GpuState {
        self.device = device;
        if (self.gpu_state == null) self.gpu_state = try createGpuState(device);
        return &self.gpu_state.?;
    }

    fn destroyGpu(self: *Renderer3D, device: gpu.GpuDevice) void {
        var groups = self.texture_groups.valueIterator();
        while (groups.next()) |g| device.destroyBindGroup(g.*);
        self.texture_groups.clearRetainingCapacity();
        if (self.depth) |d| {
            device.destroyTextureView(d.view);
            device.destroyTexture(d.texture);
            self.depth = null;
        }
        for (self.meshes.slots.items) |slot| if (slot.alive) {
            device.destroyBuffer(slot.value.index_buffer);
            device.destroyBuffer(slot.value.vertex_buffer);
        };
        self.meshes.deinit(self.allocator);
        self.meshes = .{};
        // Everything below runs once: later calls (service teardown then deinit) must not touch the device.
        self.device = null;
        const gs = self.gpu_state orelse return;
        for (gs.gizmo_pipelines) |p| if (p) |pipe| device.destroyRenderPipeline(pipe);
        device.destroyBuffer(gs.gizmo_vertex_buffer);
        device.destroyBindGroup(gs.gizmo_uniform_group);
        device.destroyBuffer(gs.gizmo_uniform_buffer);
        device.destroyPipelineLayout(gs.gizmo_pipeline_layout);
        device.destroyBindGroupLayout(gs.gizmo_uniform_layout);
        device.destroyShaderModule(gs.gizmo_shader);
        device.destroyBindGroup(gs.white_group);
        device.destroyTextureView(gs.white_view);
        device.destroyTexture(gs.white_texture);
        device.destroySampler(gs.sampler);
        device.destroyBindGroup(gs.mesh_uniform_group);
        device.destroyBuffer(gs.mesh_uniform_buffer);
        if (gs.unlit_pipeline) |p| device.destroyRenderPipeline(p);
        device.destroyPipelineLayout(gs.unlit_pipeline_layout);
        device.destroyBindGroupLayout(gs.texture_layout);
        device.destroyBindGroupLayout(gs.mesh_uniform_layout);
        device.destroyShaderModule(gs.unlit_shader);
        self.gpu_state = null;
    }

    /// Depth buffer shared by the world and gizmo passes; recreated when the target size changes.
    fn ensureDepth(self: *Renderer3D, device: gpu.GpuDevice, width: u32, height: u32) !gpu.TextureViewHandle {
        if (self.depth) |d| {
            if (d.width == width and d.height == height) return d.view;
            device.destroyTextureView(d.view);
            device.destroyTexture(d.texture);
            self.depth = null;
        }
        const texture = try device.createTexture(.{ .label = "depth", .width = width, .height = height, .format = depth_format, .usage = .{ .render_attachment = true, .texture_binding = true } });
        errdefer device.destroyTexture(texture);
        const view = try device.createTextureView(.{ .texture = texture });
        self.depth = .{ .texture = texture, .view = view, .width = width, .height = height };
        return view;
    }

    fn bindGroupForTexture(self: *Renderer3D, gs: *const GpuState, store: *const graphics.textures.TextureStore, id: graphics.TextureId) gpu.BindGroupHandle {
        if (id == 0) return gs.white_group;
        if (self.texture_groups.get(id)) |g| return g;
        const entry = store.get(id) orelse return gs.white_group;
        const group = gs.device.createBindGroup(.{ .layout = gs.texture_layout, .entries = &.{
            .{ .binding = 0, .resource = .{ .texture_view = entry.view } },
            .{ .binding = 1, .resource = .{ .sampler = gs.sampler } },
        } }) catch return gs.white_group;
        self.texture_groups.put(self.allocator, id, group) catch {
            gs.device.destroyBindGroup(group);
            return gs.white_group;
        };
        return group;
    }

    fn ensureUnlitPipeline(gs: *GpuState, format: gpu.TextureFormat) !gpu.RenderPipelineHandle {
        if (gs.unlit_pipeline) |existing| {
            if (gs.unlit_format == format) return existing;
            gs.device.destroyRenderPipeline(existing);
            gs.unlit_pipeline = null;
        }
        const pipeline = try gs.device.createRenderPipeline(.{
            .label = "unlit mesh",
            .layout = gs.unlit_pipeline_layout,
            .shader = gs.unlit_shader,
            .vertex_buffers = &.{.{ .stride = 32, .attributes = &.{
                .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
                .{ .format = .float32x3, .offset = 12, .shader_location = 1 },
                .{ .format = .float32x2, .offset = 24, .shader_location = 2 },
            } }},
            .color_targets = &.{.{ .format = format, .blend = gpu.BlendState.alpha_blend }},
            .depth_stencil = .{ .format = depth_format, .depth_write = true, .depth_compare = .less },
            .cull_mode = .back,
            .front_face = .ccw,
        });
        gs.unlit_pipeline = pipeline;
        gs.unlit_format = format;
        return pipeline;
    }

    fn ensureGizmoPipelines(gs: *GpuState, format: gpu.TextureFormat) !void {
        if (gs.gizmo_format == format and gs.gizmo_pipelines[0] != null) return;
        for (&gs.gizmo_pipelines) |*slot| {
            if (slot.*) |p| gs.device.destroyRenderPipeline(p);
            slot.* = null;
        }
        const attrs = [_]gpu.VertexAttribute{
            .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
            .{ .format = .float32x4, .offset = 12, .shader_location = 1 },
        };
        const variants = [_]struct { topology: gpu.PrimitiveTopology, depth: bool }{
            .{ .topology = .line_list, .depth = true },
            .{ .topology = .line_list, .depth = false },
            .{ .topology = .triangle_list, .depth = true },
            .{ .topology = .triangle_list, .depth = false },
        };
        for (variants, 0..) |v, i| {
            gs.gizmo_pipelines[i] = try gs.device.createRenderPipeline(.{
                .label = "gizmo",
                .layout = gs.gizmo_pipeline_layout,
                .shader = gs.gizmo_shader,
                .vertex_buffers = &.{.{ .stride = gizmo_vertex_stride, .attributes = &attrs }},
                .color_targets = &.{.{ .format = format, .blend = gpu.BlendState.alpha_blend }},
                .depth_stencil = if (v.depth) .{ .format = depth_format, .depth_write = false, .depth_compare = .less_equal } else null,
                .topology = v.topology,
                .cull_mode = .none,
            });
        }
        gs.gizmo_format = format;
    }

    // ----------------------------------------------------------- world pass

    fn renderWorld(self: *Renderer3D, input: *frame.FrameInput) !void {
        defer self.queued.clearRetainingCapacity();
        self.world_drawn = false;
        if (self.queued.items.len == 0) return;

        const gs = try self.ensureGpu(input.device);
        const pipeline = try ensureUnlitPipeline(gs, input.target.color_format);
        const depth_view = try self.ensureDepth(input.device, input.target.width, input.target.height);

        // One aligned uniform slot per draw, addressed with a dynamic offset.
        const stride: usize = std.mem.alignForward(usize, @sizeOf(MeshUniforms), gs.uniform_alignment);
        const total = stride * self.queued.items.len;
        try self.uniform_scratch.resize(self.allocator, total);
        @memset(self.uniform_scratch.items, 0);
        for (self.queued.items, 0..) |q, i| {
            const uniforms = MeshUniforms{ .mvp = q.mvp, .base_color = q.color };
            @memcpy(self.uniform_scratch.items[i * stride ..][0..@sizeOf(MeshUniforms)], std.mem.asBytes(&uniforms));
        }
        try ensureMeshUniformCapacity(gs, total);
        try gs.device.writeBuffer(gs.mesh_uniform_buffer, 0, self.uniform_scratch.items);

        const rec = input.recorder;
        const attachments = [_]gpu.ColorAttachment{input.colorAttachment()};
        try rec.beginRenderPass(.{ .label = "unlit meshes", .color_attachments = &attachments, .depth = .{ .view = depth_view } });
        try rec.setRenderPipeline(pipeline);
        for (self.queued.items, 0..) |q, i| {
            const mesh = self.meshes.get(q.mesh) orelse continue;
            try rec.setVertexBuffer(0, mesh.vertex_buffer, 0, 0);
            try rec.setIndexBuffer(mesh.index_buffer, .uint32, 0, 0);
            try rec.setBindGroup(0, gs.mesh_uniform_group, &.{@intCast(i * stride)});
            try rec.setBindGroup(1, self.bindGroupForTexture(gs, input.textures, q.texture), &.{});
            try rec.drawIndexed(mesh.index_count, 1, 0, 0, 0);
        }
        try rec.endRenderPass();
        self.world_drawn = true;
    }

    // ---------------------------------------------------------- gizmo passes

    fn renderGizmos(self: *Renderer3D, input: *frame.FrameInput) !void {
        const depth_n = self.gizmo_depth_verts.items.len;
        const xray_n = self.gizmo_xray_verts.items.len;
        const solid_n = self.gizmo_solid_verts.items.len;
        if (depth_n == 0 and xray_n == 0 and solid_n == 0) return;
        defer {
            self.gizmo_depth_verts.clearRetainingCapacity();
            self.gizmo_xray_verts.clearRetainingCapacity();
            self.gizmo_solid_verts.clearRetainingCapacity();
        }

        const gs = try self.ensureGpu(input.device);
        try ensureGizmoPipelines(gs, input.target.color_format);

        // Thick lines are expanded to screen-space quads and drawn with an identity matrix.
        const thick = self.gizmo_line_width > 1.25;
        var depth_slice: []const gizmos.GizmoVertex = self.gizmo_depth_verts.items;
        var xray_slice: []const gizmos.GizmoVertex = self.gizmo_xray_verts.items;
        var draw_vp = self.gizmo_view_proj;
        if (thick) {
            self.gizmo_quad_verts.clearRetainingCapacity();
            try gizmo_lines.appendExpandedGizmoQuads(self.allocator, &self.gizmo_quad_verts, self.gizmo_depth_verts.items, self.gizmo_view_proj, input.target.width, input.target.height, self.gizmo_line_width, self.gizmo_depth_bias);
            const depth_quads = self.gizmo_quad_verts.items.len;
            try gizmo_lines.appendExpandedGizmoQuads(self.allocator, &self.gizmo_quad_verts, self.gizmo_xray_verts.items, self.gizmo_view_proj, input.target.width, input.target.height, self.gizmo_line_width, 0.0);
            depth_slice = self.gizmo_quad_verts.items[0..depth_quads];
            xray_slice = self.gizmo_quad_verts.items[depth_quads..];
            draw_vp = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
        }

        // Single vertex buffer: [depth][xray][solid].
        const depth_bytes = std.mem.sliceAsBytes(depth_slice);
        const xray_bytes = std.mem.sliceAsBytes(xray_slice);
        const solid_bytes = std.mem.sliceAsBytes(self.gizmo_solid_verts.items);
        const total = depth_bytes.len + xray_bytes.len + solid_bytes.len;
        if (total == 0) return;
        try self.gizmo_upload.resize(self.allocator, total);
        @memcpy(self.gizmo_upload.items[0..depth_bytes.len], depth_bytes);
        @memcpy(self.gizmo_upload.items[depth_bytes.len..][0..xray_bytes.len], xray_bytes);
        @memcpy(self.gizmo_upload.items[depth_bytes.len + xray_bytes.len ..][0..solid_bytes.len], solid_bytes);
        try ensureGizmoVertexCapacity(gs, total);
        try gs.device.writeBuffer(gs.gizmo_vertex_buffer, 0, self.gizmo_upload.items);

        // Two uniform slots: the (possibly identity) matrix for lines, and the real one for solid X-ray.
        const slot: u32 = std.mem.alignForward(u32, 64, gs.uniform_alignment);
        var uniforms: [512]u8 = @splat(0);
        std.debug.assert(slot * 2 <= uniforms.len);
        @memcpy(uniforms[0..64], std.mem.asBytes(&draw_vp));
        @memcpy(uniforms[slot..][0..64], std.mem.asBytes(&self.gizmo_view_proj));
        try gs.device.writeBuffer(gs.gizmo_uniform_buffer, 0, uniforms[0 .. slot * 2]);

        const rec = input.recorder;
        const depth_view = try self.ensureDepth(input.device, input.target.width, input.target.height);
        const depth_count: u32 = @intCast(depth_slice.len);
        const xray_count: u32 = @intCast(xray_slice.len);
        const solid_count: u32 = @intCast(self.gizmo_solid_verts.items.len);

        if (depth_count > 0) {
            // Loads the world depth when a world pass ran; otherwise starts from a cleared buffer.
            const attachments = [_]gpu.ColorAttachment{input.colorAttachment()};
            try rec.beginRenderPass(.{ .label = "gizmos depth", .color_attachments = &attachments, .depth = .{
                .view = depth_view,
                .depth_load = if (self.world_drawn) .load else .clear,
            } });
            try rec.setRenderPipeline(gs.gizmo_pipelines[if (thick) 2 else 0].?);
            try rec.setBindGroup(0, gs.gizmo_uniform_group, &.{0});
            try rec.setVertexBuffer(0, gs.gizmo_vertex_buffer, 0, @as(u64, depth_count) * gizmo_vertex_stride);
            try rec.draw(depth_count, 1, 0, 0);
            try rec.endRenderPass();
        }
        if (xray_count > 0) {
            const attachments = [_]gpu.ColorAttachment{input.colorAttachment()};
            try rec.beginRenderPass(.{ .label = "gizmos xray", .color_attachments = &attachments });
            try rec.setRenderPipeline(gs.gizmo_pipelines[if (thick) 3 else 1].?);
            try rec.setBindGroup(0, gs.gizmo_uniform_group, &.{0});
            try rec.setVertexBuffer(0, gs.gizmo_vertex_buffer, depth_bytes.len, @as(u64, xray_count) * gizmo_vertex_stride);
            try rec.draw(xray_count, 1, 0, 0);
            try rec.endRenderPass();
        }
        if (solid_count > 0) {
            const attachments = [_]gpu.ColorAttachment{input.colorAttachment()};
            try rec.beginRenderPass(.{ .label = "gizmos solid xray", .color_attachments = &attachments });
            try rec.setRenderPipeline(gs.gizmo_pipelines[3].?);
            try rec.setBindGroup(0, gs.gizmo_uniform_group, &.{slot});
            try rec.setVertexBuffer(0, gs.gizmo_vertex_buffer, depth_bytes.len + xray_bytes.len, @as(u64, solid_count) * gizmo_vertex_stride);
            try rec.draw(solid_count, 1, 0, 0);
            try rec.endRenderPass();
        }
    }
};

fn ensureMeshUniformCapacity(gs: *GpuState, bytes: usize) !void {
    if (bytes <= gs.mesh_uniform_capacity) return;
    var capacity = gs.mesh_uniform_capacity;
    while (capacity < bytes) capacity *= 2;
    const buffer = try gs.device.createBuffer(.{ .label = "mesh uniforms", .size = capacity, .usage = .{ .uniform = true, .copy_dst = true } });
    errdefer gs.device.destroyBuffer(buffer);
    const group = try gs.device.createBindGroup(.{ .layout = gs.mesh_uniform_layout, .entries = &.{
        .{ .binding = 0, .resource = .{ .buffer = .{ .buffer = buffer, .size = @sizeOf(MeshUniforms) } } },
    } });
    gs.device.destroyBindGroup(gs.mesh_uniform_group);
    gs.device.destroyBuffer(gs.mesh_uniform_buffer);
    gs.mesh_uniform_buffer = buffer;
    gs.mesh_uniform_group = group;
    gs.mesh_uniform_capacity = capacity;
}

fn ensureGizmoVertexCapacity(gs: *GpuState, bytes: usize) !void {
    if (bytes <= gs.gizmo_vertex_capacity) return;
    var capacity = gs.gizmo_vertex_capacity;
    while (capacity < bytes) capacity *= 2;
    const next = try gs.device.createBuffer(.{ .label = "gizmo vertices", .size = capacity, .usage = .{ .vertex = true, .copy_dst = true } });
    gs.device.destroyBuffer(gs.gizmo_vertex_buffer);
    gs.gizmo_vertex_buffer = next;
    gs.gizmo_vertex_capacity = capacity;
}

fn createGpuState(device: gpu.GpuDevice) !GpuState {
    const alignment = @max(device.capabilities().limits.min_uniform_buffer_offset_alignment, 16);

    const unlit_shader = try device.createShaderModule(.{ .label = "unlit mesh", .wgsl = unlit_source });
    errdefer device.destroyShaderModule(unlit_shader);
    const mesh_uniform_layout = try device.createBindGroupLayout(.{ .entries = &.{
        .{ .binding = 0, .visibility = .{ .vertex = true }, .kind = .{ .buffer = .{ .type = .uniform, .has_dynamic_offset = true, .min_binding_size = @sizeOf(MeshUniforms) } } },
    } });
    errdefer device.destroyBindGroupLayout(mesh_uniform_layout);
    const texture_layout = try device.createBindGroupLayout(.{ .entries = &.{
        .{ .binding = 0, .visibility = .{ .fragment = true }, .kind = .{ .texture = .{} } },
        .{ .binding = 1, .visibility = .{ .fragment = true }, .kind = .{ .sampler = .{} } },
    } });
    errdefer device.destroyBindGroupLayout(texture_layout);
    const unlit_pipeline_layout = try device.createPipelineLayout(.{ .bind_group_layouts = &.{ mesh_uniform_layout, texture_layout } });
    errdefer device.destroyPipelineLayout(unlit_pipeline_layout);

    const slots_bytes: u64 = @as(u64, std.mem.alignForward(u32, @sizeOf(MeshUniforms), alignment)) * min_uniform_slots;
    const mesh_uniform_buffer = try device.createBuffer(.{ .label = "mesh uniforms", .size = slots_bytes, .usage = .{ .uniform = true, .copy_dst = true } });
    errdefer device.destroyBuffer(mesh_uniform_buffer);
    const mesh_uniform_group = try device.createBindGroup(.{ .layout = mesh_uniform_layout, .entries = &.{
        .{ .binding = 0, .resource = .{ .buffer = .{ .buffer = mesh_uniform_buffer, .size = @sizeOf(MeshUniforms) } } },
    } });
    errdefer device.destroyBindGroup(mesh_uniform_group);

    // Same sampling as the legacy mesh path: nearest filtering, clamped.
    const sampler = try device.createSampler(.{ .mag_filter = .nearest, .min_filter = .nearest, .mipmap_filter = .nearest });
    errdefer device.destroySampler(sampler);
    const white_texture = try device.createTexture(.{ .label = "white", .width = 1, .height = 1, .format = .rgba8_unorm, .usage = .{ .texture_binding = true, .copy_dst = true } });
    errdefer device.destroyTexture(white_texture);
    try device.writeTexture(.{ .texture = white_texture }, &[_]u8{ 255, 255, 255, 255 }, .{ .bytes_per_row = 4, .rows_per_image = 1 }, .{ .width = 1, .height = 1 });
    const white_view = try device.createTextureView(.{ .texture = white_texture });
    errdefer device.destroyTextureView(white_view);
    const white_group = try device.createBindGroup(.{ .layout = texture_layout, .entries = &.{
        .{ .binding = 0, .resource = .{ .texture_view = white_view } },
        .{ .binding = 1, .resource = .{ .sampler = sampler } },
    } });
    errdefer device.destroyBindGroup(white_group);

    const gizmo_shader = try device.createShaderModule(.{ .label = "gizmo", .wgsl = gizmo_source });
    errdefer device.destroyShaderModule(gizmo_shader);
    const gizmo_uniform_layout = try device.createBindGroupLayout(.{ .entries = &.{
        .{ .binding = 0, .visibility = .{ .vertex = true }, .kind = .{ .buffer = .{ .type = .uniform, .has_dynamic_offset = true, .min_binding_size = 64 } } },
    } });
    errdefer device.destroyBindGroupLayout(gizmo_uniform_layout);
    const gizmo_pipeline_layout = try device.createPipelineLayout(.{ .bind_group_layouts = &.{gizmo_uniform_layout} });
    errdefer device.destroyPipelineLayout(gizmo_pipeline_layout);
    const gizmo_uniform_buffer = try device.createBuffer(.{ .label = "gizmo uniforms", .size = @as(u64, std.mem.alignForward(u32, 64, alignment)) * 2, .usage = .{ .uniform = true, .copy_dst = true } });
    errdefer device.destroyBuffer(gizmo_uniform_buffer);
    const gizmo_uniform_group = try device.createBindGroup(.{ .layout = gizmo_uniform_layout, .entries = &.{
        .{ .binding = 0, .resource = .{ .buffer = .{ .buffer = gizmo_uniform_buffer, .size = 64 } } },
    } });
    errdefer device.destroyBindGroup(gizmo_uniform_group);
    const gizmo_vertex_buffer = try device.createBuffer(.{ .label = "gizmo vertices", .size = min_vertex_bytes, .usage = .{ .vertex = true, .copy_dst = true } });

    return .{
        .device = device,
        .uniform_alignment = alignment,
        .unlit_shader = unlit_shader,
        .mesh_uniform_layout = mesh_uniform_layout,
        .texture_layout = texture_layout,
        .unlit_pipeline_layout = unlit_pipeline_layout,
        .mesh_uniform_buffer = mesh_uniform_buffer,
        .mesh_uniform_capacity = slots_bytes,
        .mesh_uniform_group = mesh_uniform_group,
        .sampler = sampler,
        .white_texture = white_texture,
        .white_view = white_view,
        .white_group = white_group,
        .gizmo_shader = gizmo_shader,
        .gizmo_uniform_layout = gizmo_uniform_layout,
        .gizmo_pipeline_layout = gizmo_pipeline_layout,
        .gizmo_uniform_buffer = gizmo_uniform_buffer,
        .gizmo_uniform_group = gizmo_uniform_group,
        .gizmo_vertex_buffer = gizmo_vertex_buffer,
        .gizmo_vertex_capacity = min_vertex_bytes,
    };
}
