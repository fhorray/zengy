//! Optional compute GI. CPU owns the existing flat BVH; the GPU owns probe history
//! and per-ray temporal reservoirs. No readbacks are needed in the render path.
const std=@import("std");
const c=@import("sdl3_c");
const pbr=@import("render_3d").pbr;
const code=@embedFile("shaders/dynamic_gi.comp.spv");
pub const Params=extern struct {
    counts:[4]u32,
    offsets:[4]u32,
    dispatch_info:[4]u32,
    light_key:[4]u32,
    config:[4]f32,
    sun_dir_int:[4]f32,
    sun_color:[4]f32,
    sky_zenith:[4]f32,
    sky_horizon:[4]f32,
    sky_ground:[4]f32,
    cdf:[64][4]f32,
};
pub const State=struct {
    pipeline:?*c.SDL_GPUComputePipeline=null,
    geometry:?*c.SDL_GPUBuffer=null,
    transfer:?*c.SDL_GPUTransferBuffer=null,
    snapshot:?*c.SDL_GPUBuffer=null,
    reservoirs:?*c.SDL_GPUBuffer=null,
    capacity:u32=0,
    geometry_revision:?u64=null,
    grid_epoch:?u64=null,
    valid:bool=false,
    failed:bool=false,
    cursor:u32=0,
    frame:u32=0,
    counts:[3]u32=.{0,0,0},
    offsets:[3]u32=.{0,0,0},
    pub fn deinit(self:*State,device:*c.SDL_GPUDevice) void {
        if(self.pipeline) |p| c.SDL_ReleaseGPUComputePipeline(device,p);
        if(self.transfer) |t| c.SDL_ReleaseGPUTransferBuffer(device,t);
        for([_]?*c.SDL_GPUBuffer{self.geometry,self.snapshot,self.reservoirs}) |b| if(b) |v| c.SDL_ReleaseGPUBuffer(device,v);
        self.*=.{};
    }
    fn buffer(device:*c.SDL_GPUDevice,size:u32,usage:c.SDL_GPUBufferUsageFlags) !*c.SDL_GPUBuffer {
        return c.SDL_CreateGPUBuffer(device,&std.mem.zeroInit(c.SDL_GPUBufferCreateInfo,.{.size=size,.usage=usage})) orelse error.SdlGpuFailure;
    }
    fn ensure(self:*State,device:*c.SDL_GPUDevice) !void {
        if(self.pipeline!=null)return;
        const pipe=c.SDL_CreateGPUComputePipeline(device,&std.mem.zeroInit(c.SDL_GPUComputePipelineCreateInfo,.{
            .code_size=code.len,.code=code.ptr,.entrypoint="main",.format=c.SDL_GPU_SHADERFORMAT_SPIRV,
            .num_readonly_storage_buffers=2,.num_readwrite_storage_buffers=2,.num_uniform_buffers=1,
            .threadcount_x=64,.threadcount_y=1,.threadcount_z=1,
        })) orelse return error.SdlGpuFailure;
        errdefer c.SDL_ReleaseGPUComputePipeline(device,pipe);
        const snap=try buffer(device,@sizeOf(pbr.DynamicGiGrid),c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ);
        errdefer c.SDL_ReleaseGPUBuffer(device,snap);
        const res=try buffer(device,64*64*3*16,c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ|c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE);
        self.pipeline=pipe;self.snapshot=snap;self.reservoirs=res;
    }
    /// Input is a borrowed, immutable extraction snapshot, valid until render recording completes.
    /// Uploads geometry only when its revision changes. The transfer buffer is cycled on writes.
    pub fn prepare(self:*State,device:*c.SDL_GPUDevice,cmd:*c.SDL_GPUCommandBuffer,input:pbr.GpuGiInput) !void {
        try self.ensure(device);
        if(self.geometry_revision!=null and self.geometry_revision.?==input.geometry_revision)return;
        const nodes=std.mem.sliceAsBytes(input.nodes);
        const tris=std.mem.sliceAsBytes(input.triangles);
        const mats=std.mem.sliceAsBytes(input.materials);
        const total=@as(u64,nodes.len)+@as(u64,tris.len)+@as(u64,mats.len);
        if(total>128*1024*1024)return error.GiGeometryTooLarge;
        const required:u32=@intCast(@max(total,4));
        if(self.geometry==null or required>self.capacity){
            const next=try buffer(device,required,c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ);
            errdefer c.SDL_ReleaseGPUBuffer(device,next);
            const trans=c.SDL_CreateGPUTransferBuffer(device,&std.mem.zeroInit(c.SDL_GPUTransferBufferCreateInfo,.{.usage=c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,.size=required})) orelse return error.SdlGpuFailure;
            if(self.geometry) |old| c.SDL_ReleaseGPUBuffer(device,old);
            if(self.transfer) |old| c.SDL_ReleaseGPUTransferBuffer(device,old);
            self.geometry=next;self.transfer=trans;self.capacity=required;
            self.geometry_revision=null;
        }
        const ptr=c.SDL_MapGPUTransferBuffer(device,self.transfer.?,true) orelse return error.SdlGpuFailure;
        const dst:[*]u8=@ptrCast(ptr);
        @memset(dst[0..required],0);
        @memcpy(dst[0..nodes.len],nodes);
        @memcpy(dst[nodes.len..][0..tris.len],tris);
        @memcpy(dst[nodes.len+tris.len..][0..mats.len],mats);
        c.SDL_UnmapGPUTransferBuffer(device,self.transfer.?);
        const cp=c.SDL_BeginGPUCopyPass(cmd) orelse return error.SdlGpuFailure;
        c.SDL_UploadToGPUBuffer(cp,&.{.transfer_buffer=self.transfer.?,.offset=0},&.{.buffer=self.geometry.?,.offset=0,.size=required},false);
        c.SDL_EndGPUCopyPass(cp);
        self.counts=.{@intCast(input.nodes.len),@intCast(input.triangles.len),@intCast(input.materials.len)};
        self.offsets=.{0,@intCast(nodes.len/4),@intCast((nodes.len+tris.len)/4)};
        self.geometry_revision=input.geometry_revision;
        self.valid=false;
    }
    pub fn dispatch(self:*State,cmd:*c.SDL_GPUCommandBuffer,cluster:*c.SDL_GPUBuffer,grid_offset:u32,input:pbr.GpuGiInput,params_in:Params) !void {
        const reset=!self.valid or self.grid_epoch==null or self.grid_epoch.?!=input.grid_epoch;
        if(reset)self.cursor=0;
        const cp=c.SDL_BeginGPUCopyPass(cmd) orelse return error.SdlGpuFailure;
        c.SDL_CopyGPUBufferToBuffer(cp,&.{.buffer=cluster,.offset=grid_offset},&.{.buffer=self.snapshot.?,.offset=0},@sizeOf(pbr.DynamicGiGrid),false);
        c.SDL_EndGPUCopyPass(cp);
        const rw=[_]c.SDL_GPUStorageBufferReadWriteBinding{.{.buffer=cluster,.cycle=false},.{.buffer=self.reservoirs.?,.cycle=false}};
        const pass=c.SDL_BeginGPUComputePass(cmd,null,0,&rw,rw.len) orelse return error.SdlGpuFailure;
        c.SDL_BindGPUComputePipeline(pass,self.pipeline.?);
        const ro=[_]*c.SDL_GPUBuffer{self.geometry.?,self.snapshot.?};
        c.SDL_BindGPUComputeStorageBuffers(pass,0,&ro,ro.len);
        var params=params_in;
        params.counts[0]=self.counts[0];params.counts[1]=self.counts[1];params.counts[2]=self.counts[2];
        params.offsets=.{self.offsets[0],self.offsets[1],self.offsets[2],grid_offset/4};
        params.dispatch_info=.{self.cursor,std.math.clamp(input.rays_per_probe,12,64),self.frame,if(reset) 1 else 0};
        c.SDL_PushGPUComputeUniformData(cmd,0,&params,@sizeOf(Params));
        const groups=std.math.clamp(input.probes_per_frame,1,64);
        c.SDL_DispatchGPUCompute(pass,groups,1,1);
        c.SDL_EndGPUComputePass(pass);
        self.cursor=(self.cursor+groups)%64;self.frame+%=1;self.grid_epoch=input.grid_epoch;self.valid=true;
    }
};
comptime {if(@sizeOf(Params)!=1184)@compileError("GPU GI uniform ABI mismatch");}
