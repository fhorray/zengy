//! Backend Contract & Headless Recording Provider (`packages/render/prism/src/resources/recording_backend.zig`).
//!
//! Enables contract tests to validate pass execution order, view scoping, and
//! frame lifecycle without initializing SDL or a GPU.

const std = @import("std");
const types = @import("../core/types.zig");
const pass_graph = @import("../core/pass_graph.zig");

/// Narrow Prism backend execution contract implemented by real GPU providers or mock recorders.
pub const PrismBackendVTable = struct {
    id: []const u8,
    capabilities: types.BackendCapabilities = .{},
    ctx: ?*anyopaque = null,
    begin_frame: *const fn (ctx: ?*anyopaque, frame_epoch: u64) anyerror!void,
    execute_pass: *const fn (ctx: ?*anyopaque, view_id: types.RenderViewId, pass: pass_graph.PassDesc) anyerror!void,
    end_frame: *const fn (ctx: ?*anyopaque, frame_epoch: u64) anyerror!void,
};

/// Single recorded pass execution event stored by `RecordingBackend`.
pub const RecordedPassEvent = struct {
    frame_epoch: u64,
    view_id: types.RenderViewId,
    pass_name: []const u8,
    scope: pass_graph.PassScope,
};

/// Headless recording backend for deterministic Prism contract tests.
pub const RecordingBackend = struct {
    allocator: std.mem.Allocator,
    capabilities: types.BackendCapabilities = .{},
    current_epoch: u64 = 0,
    frames_begun: u64 = 0,
    frames_ended: u64 = 0,
    recorded_passes: std.ArrayList(RecordedPassEvent),

    /// Initializes a `RecordingBackend`.
    pub fn init(allocator: std.mem.Allocator, capabilities: types.BackendCapabilities) RecordingBackend {
        return .{
            .allocator = allocator,
            .capabilities = capabilities,
            .recorded_passes = .empty,
        };
    }

    /// Releases recorded event buffers.
    pub fn deinit(self: *RecordingBackend) void {
        self.recorded_passes.deinit(self.allocator);
    }

    /// Clears recorded pass events.
    pub fn clear(self: *RecordingBackend) void {
        self.recorded_passes.clearRetainingCapacity();
    }

    /// Returns a `PrismBackendVTable` pointing to this `RecordingBackend`.
    pub fn vtable(self: *RecordingBackend) PrismBackendVTable {
        return .{
            .id = "official.render.prism.recording",
            .capabilities = self.capabilities,
            .ctx = self,
            .begin_frame = beginFrameImpl,
            .execute_pass = executePassImpl,
            .end_frame = endFrameImpl,
        };
    }

    fn beginFrameImpl(ctx: ?*anyopaque, frame_epoch: u64) !void {
        const self: *RecordingBackend = @ptrCast(@alignCast(ctx.?));
        self.current_epoch = frame_epoch;
        self.frames_begun += 1;
    }

    fn executePassImpl(ctx: ?*anyopaque, view_id: types.RenderViewId, pass: pass_graph.PassDesc) !void {
        const self: *RecordingBackend = @ptrCast(@alignCast(ctx.?));
        try self.recorded_passes.append(self.allocator, .{
            .frame_epoch = self.current_epoch,
            .view_id = view_id,
            .pass_name = pass.name,
            .scope = pass.scope,
        });
    }

    fn endFrameImpl(ctx: ?*anyopaque, _: u64) !void {
        const self: *RecordingBackend = @ptrCast(@alignCast(ctx.?));
        self.frames_ended += 1;
    }
};
