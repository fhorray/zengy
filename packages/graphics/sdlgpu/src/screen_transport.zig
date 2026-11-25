//! Optional material-aware screen-space transport. Resources are allocated only for active views.
const std = @import("std");
const c = @import("sdl3_c");

pub const Params = extern struct {
    view_proj: [16]f32,
    inv_view_proj: [16]f32,
    camera_gain: [4]f32,
    controls: [4]f32,
    levels: [16][4]u32,
    budget: [4]u32,
};
const ReduceParams = extern struct { src: [4]u32, dst: [4]u32 };
pub const Layout = struct {
    levels: [16][4]u32 = @splat(.{0,0,0,0}),
    count: u32 = 0,
    bytes: u32 = 0,
    pub fn init(width: u32, height: u32) !Layout {
        if (width == 0 or height == 0 or width > 16384 or height > 16384) return error.InvalidScreenDimensions;
        var result: Layout = .{};
        var w = width;
        var h = height;
        var offset: u64 = 0;
        while (true) {
            if (result.count >= 16) return error.InvalidScreenDimensions;
            result.levels[result.count] = .{ @intCast(offset), w, h, 0 };
            result.count += 1;
            offset += @as(u64, w) * h;
            if (offset * 8 > 128 * 1024 * 1024) return error.ScreenBufferTooLarge;
            if (w == 1 and h == 1) break;
            w = (w + 1) / 2;
            h = (h + 1) / 2;
        }
        result.bytes = @intCast(offset * 8);
        return result;
    }
};
pub const State = struct {
    width: u32 = 0,
    height: u32 = 0,
    layout: Layout = .{},
    buffer: ?*c.SDL_GPUBuffer = null,
    surface: ?*c.SDL_GPUTexture = null,
    diffuse: ?*c.SDL_GPUTexture = null,
    specular: ?*c.SDL_GPUTexture = null,
    resolved: ?*c.SDL_GPUTexture = null,
    pub fn deinit(self: *State, device: *c.SDL_GPUDevice) void {
        if (self.buffer) |b| c.SDL_ReleaseGPUBuffer(device,b);
        for ([_]?*c.SDL_GPUTexture{ self.surface,self.diffuse,self.specular,self.resolved }) |t| if (t) |v| c.SDL_ReleaseGPUTexture(device,v);
        self.* = .{};
    }
    fn texture(device: *c.SDL_GPUDevice, width: u32, height: u32, format: c.SDL_GPUTextureFormat) !*c.SDL_GPUTexture {
        return c.SDL_CreateGPUTexture(device,&std.mem.zeroInit(c.SDL_GPUTextureCreateInfo,.{
            .type=c.SDL_GPU_TEXTURETYPE_2D,.format=format,.usage=c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET|c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width=width,.height=height,.layer_count_or_depth=1,.num_levels=1,
        })) orelse error.SdlGpuFailure;
    }
    pub fn ensure(self: *State, device: *c.SDL_GPUDevice, width: u32, height: u32) !void {
        if (self.buffer != null and self.width==width and self.height==height) return;
        var next: State = .{.width=width,.height=height,.layout=try Layout.init(width,height)};
        errdefer next.deinit(device);
        next.buffer=c.SDL_CreateGPUBuffer(device,&std.mem.zeroInit(c.SDL_GPUBufferCreateInfo,.{
            .usage=c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ|c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE|c.SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ,
            .size=next.layout.bytes,
        })) orelse return error.SdlGpuFailure;
        next.surface=try texture(device,width,height,c.SDL_GPU_TEXTUREFORMAT_R32G32B32A32_FLOAT);
        next.diffuse=try texture(device,width,height,c.SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT);
        next.specular=try texture(device,width,height,c.SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT);
        next.resolved=try texture(device,width,height,c.SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT);
        self.deinit(device);
        self.*=next;
    }
    pub fn buildDepth(self: *const State, cmd: *c.SDL_GPUCommandBuffer, pipeline: *c.SDL_GPUComputePipeline, depth: *c.SDL_GPUTexture, sampler: *c.SDL_GPUSampler) !void {
        const bindings=[_]c.SDL_GPUStorageBufferReadWriteBinding{.{.buffer=self.buffer.?,.cycle=false}};
        const samplers=[_]c.SDL_GPUTextureSamplerBinding{.{.texture=depth,.sampler=sampler}};
        for (0..self.layout.count) |i| {
            const pass=c.SDL_BeginGPUComputePass(cmd,null,0,&bindings,1) orelse return error.SdlGpuFailure;
            c.SDL_BindGPUComputePipeline(pass,pipeline);
            c.SDL_BindGPUComputeSamplers(pass,0,&samplers,1);
            var src=if(i==0) self.layout.levels[0] else self.layout.levels[i-1];
            src[3]=if(i==0) 1 else 0;
            const dst=self.layout.levels[i];
            const params=ReduceParams{.src=src,.dst=dst};
            c.SDL_PushGPUComputeUniformData(cmd,0,&params,@sizeOf(ReduceParams));
            c.SDL_DispatchGPUCompute(pass,(dst[1]+15)/16,(dst[2]+15)/16,1);
            c.SDL_EndGPUComputePass(pass);
        }
    }
};
comptime {
    if (@sizeOf(Params)!=432 or @sizeOf(ReduceParams)!=32) @compileError("Screen transport ABI mismatch");
}
