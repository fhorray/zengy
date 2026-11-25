//! Optional compute GI (Helios Dynamic GI on the GPU).
//!
//! The CPU owns the flat BVH snapshot; the GPU owns the probe history (the `gi` region of the cluster light
//! buffer) and the per-ray temporal reservoirs. Nothing is read back in the render path. Geometry is re-uploaded
//! only when its revision changes, so steady-state frames record one copy and one dispatch.
const std = @import("std");
const graphics = @import("graphics");
const render_3d = @import("render_3d");
const gpu_objects = @import("gpu.zig");
const frame_res = @import("frame_res.zig");

const gpu = graphics.gpu;
const pbr = render_3d.pbr;

const shader = @embedFile("../shaders/dynamic_gi_cs.wgsl");

/// Uniform block of `dynamic_gi_cs.wgsl` (`GiParams`).
pub const Params = extern struct {
    counts: [4]u32,
    offsets: [4]u32,
    dispatch_info: [4]u32,
    light_key: [4]u32,
    config: [4]f32,
    sun_dir_int: [4]f32,
    sun_color: [4]f32,
    sky_zenith: [4]f32,
    sky_horizon: [4]f32,
    sky_ground: [4]f32,
    cdf: [64][4]f32,
};
comptime {
    if (@sizeOf(Params) != 1184) @compileError("GPU GI uniform ABI mismatch");
}

/// Probe slots the compute pass walks per frame; the reservoir buffer holds one vec4 per ray per slot.
const probe_slots = 64;
const reservoir_bytes = probe_slots * 64 * 3 * 16;
const max_geometry_bytes = 128 * 1024 * 1024;

/// Pipelines and bind group layouts; created once, owned by the `Gpu` object lifetime tracker.
pub const Pipeline = struct {
    compute: gpu.ComputePipelineHandle,
    l_geometry: gpu.BindGroupLayoutHandle,
    l_output: gpu.BindGroupLayoutHandle,
    g_params: gpu.BindGroupHandle,
};

pub const State = struct {
    pipeline: ?Pipeline = null,
    geometry: ?gpu.BufferHandle = null,
    snapshot: ?gpu.BufferHandle = null,
    reservoirs: ?gpu.BufferHandle = null,
    capacity: u32 = 0,
    geometry_revision: ?u64 = null,
    grid_epoch: ?u64 = null,
    /// The GPU-resident probe grid holds data produced for `grid_epoch`.
    valid: bool = false,
    /// Setup failed once; stay on the CPU grid / IBL fallback until the feature is requested again.
    failed: bool = false,
    cursor: u32 = 0,
    frame: u32 = 0,
    counts: [3]u32 = .{ 0, 0, 0 },
    offsets: [3]u32 = .{ 0, 0, 0 },

    pub fn deinit(self: *State, device: gpu.GpuDevice) void {
        for ([_]?gpu.BufferHandle{ self.geometry, self.snapshot, self.reservoirs }) |b| if (b) |v| device.destroyBuffer(v);
        self.* = .{};
    }

    fn ensure(self: *State, g: *gpu_objects.Gpu, ring_buffer: gpu.BufferHandle) !void {
        if (self.pipeline != null) return;
        const c = gpu_objects.comp;
        const l_geometry = try g.newLayout(&.{ gpu_objects.sbo(0, true, c), gpu_objects.sbo(1, true, c) });
        const l_output = try g.newLayout(&.{ gpu_objects.sbo(0, false, c), gpu_objects.sbo(1, false, c) });
        const l_params = try g.newLayout(&.{gpu_objects.ubo(0, @sizeOf(Params), c)});
        const layout_handle = try g.newPipelineLayout(&.{ l_geometry, l_output, l_params });
        const compute = try g.newCompute(.{
            .label = "dynamic gi",
            .layout = layout_handle,
            .shader = try g.newShader("dynamic gi", shader),
            .entry = "main",
        });
        self.snapshot = try g.device.createBuffer(.{ .label = "gi snapshot", .size = @sizeOf(pbr.DynamicGiGrid), .usage = .{ .storage = true, .copy_dst = true } });
        errdefer g.device.destroyBuffer(self.snapshot.?);
        self.reservoirs = try g.device.createBuffer(.{ .label = "gi reservoirs", .size = reservoir_bytes, .usage = .{ .storage = true } });
        self.pipeline = .{
            .compute = compute,
            .l_geometry = l_geometry,
            .l_output = l_output,
            .g_params = try g.ringGroup(l_params, ring_buffer, @sizeOf(Params)),
        };
    }

    /// Uploads the BVH snapshot when its revision changed. Input slices are borrowed for this call only.
    pub fn prepare(self: *State, g: *gpu_objects.Gpu, ring_buffer: gpu.BufferHandle, input: pbr.GpuGiInput) !void {
        try self.ensure(g, ring_buffer);
        if (self.geometry_revision) |rev| if (rev == input.geometry_revision) return;
        const nodes = std.mem.sliceAsBytes(input.nodes);
        const tris = std.mem.sliceAsBytes(input.triangles);
        const mats = std.mem.sliceAsBytes(input.materials);
        const total = @as(u64, nodes.len) + tris.len + mats.len;
        if (total > max_geometry_bytes) return error.GiGeometryTooLarge;
        const required: u32 = @intCast(@max(total, 4));
        if (self.geometry == null or required > self.capacity) {
            const next = try g.device.createBuffer(.{ .label = "gi geometry", .size = required, .usage = .{ .storage = true, .copy_dst = true } });
            if (self.geometry) |old| g.device.destroyBuffer(old);
            self.geometry = next;
            self.capacity = required;
        }
        if (nodes.len > 0) try g.device.writeBuffer(self.geometry.?, 0, nodes);
        if (tris.len > 0) try g.device.writeBuffer(self.geometry.?, nodes.len, tris);
        if (mats.len > 0) try g.device.writeBuffer(self.geometry.?, nodes.len + tris.len, mats);
        self.counts = .{ @intCast(input.nodes.len), @intCast(input.triangles.len), @intCast(input.materials.len) };
        self.offsets = .{ 0, @intCast(nodes.len / 4), @intCast((nodes.len + tris.len) / 4) };
        self.geometry_revision = input.geometry_revision;
        self.valid = false;
    }

    /// Snapshots the previous probe grid and traces this frame's slice of probes into `lights` at `grid_offset`.
    pub fn dispatch(
        self: *State,
        groups: *frame_res.GroupCache,
        ring: *frame_res.Ring,
        rec: *gpu.CommandRecorder,
        lights: gpu.BufferHandle,
        grid_offset: u32,
        input: pbr.GpuGiInput,
        params_in: Params,
    ) !void {
        const p = self.pipeline.?;
        const reset = !self.valid or self.grid_epoch == null or self.grid_epoch.? != input.grid_epoch;
        if (reset) self.cursor = 0;
        try rec.copyBufferToBuffer(lights, grid_offset, self.snapshot.?, 0, @sizeOf(pbr.DynamicGiGrid));

        const geo_group = try groups.get(frame_res.key(&.{ 0x6911, frame_res.bits(self.geometry.?), frame_res.bits(self.snapshot.?) }), .{ .layout = p.l_geometry, .entries = &.{
            .{ .binding = 0, .resource = .{ .buffer = .{ .buffer = self.geometry.? } } },
            .{ .binding = 1, .resource = .{ .buffer = .{ .buffer = self.snapshot.? } } },
        } });
        const out_group = try groups.get(frame_res.key(&.{ 0x6912, frame_res.bits(lights), frame_res.bits(self.reservoirs.?) }), .{ .layout = p.l_output, .entries = &.{
            .{ .binding = 0, .resource = .{ .buffer = .{ .buffer = lights } } },
            .{ .binding = 1, .resource = .{ .buffer = .{ .buffer = self.reservoirs.? } } },
        } });

        var params = params_in;
        params.counts[0] = self.counts[0];
        params.counts[1] = self.counts[1];
        params.counts[2] = self.counts[2];
        params.offsets = .{ self.offsets[0], self.offsets[1], self.offsets[2], grid_offset / 4 };
        params.dispatch_info = .{ self.cursor, std.math.clamp(input.rays_per_probe, 12, 64), self.frame, if (reset) 1 else 0 };
        const workgroups = std.math.clamp(input.probes_per_frame, 1, probe_slots);

        try rec.beginComputePass(.{ .label = "helios gpu gi" });
        try rec.setComputePipeline(p.compute);
        try rec.setBindGroup(0, geo_group, &.{});
        try rec.setBindGroup(1, out_group, &.{});
        try rec.setBindGroup(2, p.g_params, &.{try ring.pushValue(params)});
        try rec.dispatch(workgroups, 1, 1);
        try rec.endComputePass();

        self.cursor = (self.cursor + workgroups) % probe_slots;
        self.frame +%= 1;
        self.grid_epoch = input.grid_epoch;
        self.valid = true;
    }
};
