//! GPU pass timing through timestamp queries (when the adapter supports them).
//!
//! Passes are timed by post-processing the recorded command list: every render/compute pass whose label is
//! known gets `begin`/`end` timestamp slots, so pass code stays free of profiling calls. Results are read back
//! asynchronously with a three-slot ring and arrive two or three frames late; nothing here blocks the frame.
const std = @import("std");
const graphics = @import("graphics");

const gpu = graphics.gpu;

/// Pass groups reported to the profiler. A consumer maps them by name onto its own category enum.
pub const Category = enum { shadow, ssao, volumetric, forward_plus, bloom, postfx };

/// Receives one completed frame of GPU timings. `frame_ns` is the wall-clock frame interval.
pub const Sink = struct {
    ctx: *anyopaque,
    begin_frame: *const fn (ctx: *anyopaque) void,
    record: *const fn (ctx: *anyopaque, name: []const u8, category: Category, duration_ns: u64) void,
    end_frame: *const fn (ctx: *anyopaque, frame_ns: u64) void,
};

const Span = struct { name: []const u8, category: Category };

/// Maps a pass label to the profiler entry it is summed into.
fn classify(label: []const u8) ?Span {
    const table = [_]struct { prefix: []const u8, span: Span }{
        .{ .prefix = "shadow", .span = .{ .name = "Shadow", .category = .shadow } },
        .{ .prefix = "local shadow", .span = .{ .name = "Shadow", .category = .shadow } },
        .{ .prefix = "depth prepass", .span = .{ .name = "SSAO", .category = .ssao } },
        .{ .prefix = "ssao", .span = .{ .name = "SSAO", .category = .ssao } },
        .{ .prefix = "sky", .span = .{ .name = "Forward+", .category = .forward_plus } },
        .{ .prefix = "hdri sky", .span = .{ .name = "Forward+", .category = .forward_plus } },
        .{ .prefix = "pbr lit", .span = .{ .name = "Forward+", .category = .forward_plus } },
        .{ .prefix = "helios gpu gi", .span = .{ .name = "Helios GPU GI", .category = .forward_plus } },
        .{ .prefix = "hiz", .span = .{ .name = "Screen transport", .category = .forward_plus } },
        .{ .prefix = "screen transport", .span = .{ .name = "Screen transport", .category = .forward_plus } },
        .{ .prefix = "volumetric", .span = .{ .name = "Volumetric", .category = .volumetric } },
        .{ .prefix = "froxel", .span = .{ .name = "Volumetric", .category = .volumetric } },
        .{ .prefix = "bloom", .span = .{ .name = "Bloom", .category = .bloom } },
        .{ .prefix = "exposure", .span = .{ .name = "AutoExposure", .category = .postfx } },
        .{ .prefix = "postfx", .span = .{ .name = "PostFX", .category = .postfx } },
    };
    for (table) |entry| if (std.mem.startsWith(u8, label, entry.prefix)) return entry.span;
    return null;
}

const slot_count = 3;
const max_spans = 64;
const query_bytes = max_spans * 2 * 8;

const Slot = struct {
    set: gpu.QuerySetHandle,
    resolve: gpu.BufferHandle,
    staging: gpu.BufferHandle,
    spans: [max_spans]Span = undefined,
    count: u32 = 0,
    frame_ns: u64 = 0,
    state: enum { idle, submitted, reading } = .idle,
    ticket: gpu.ReadbackHandle = undefined,
};

pub const Timing = struct {
    device: gpu.GpuDevice,
    slots: [slot_count]Slot,
    period_ns: f64,
    /// Slot being recorded this frame.
    current: ?usize = null,
    last_recorded: ?usize = null,
    dropped_spans: u64 = 0,

    /// Returns null when the adapter has no timestamp queries (the profiler then simply shows no GPU passes).
    pub fn init(device: gpu.GpuDevice) ?Timing {
        const caps = device.capabilities();
        if (!caps.features.timestamp_query or !std.math.isFinite(caps.timestamp_period_ns) or caps.timestamp_period_ns <= 0) return null;
        var self: Timing = .{ .device = device, .slots = undefined, .period_ns = caps.timestamp_period_ns };
        var made: usize = 0;
        while (made < slot_count) : (made += 1) {
            self.slots[made] = makeSlot(device) catch {
                self.destroySlots(made);
                return null;
            };
        }
        return self;
    }

    fn makeSlot(device: gpu.GpuDevice) !Slot {
        const set = try device.createQuerySet(.{ .label = "pbr timing", .count = max_spans * 2 });
        errdefer device.destroyQuerySet(set);
        const resolve = try device.createBuffer(.{ .label = "pbr timing resolve", .size = query_bytes, .usage = .{ .query_resolve = true, .copy_src = true } });
        errdefer device.destroyBuffer(resolve);
        const staging = try device.createBuffer(.{ .label = "pbr timing readback", .size = query_bytes, .usage = .{ .map_read = true, .copy_dst = true } });
        return .{ .set = set, .resolve = resolve, .staging = staging };
    }

    fn destroySlots(self: *Timing, count: usize) void {
        for (self.slots[0..count]) |slot| {
            if (slot.state == .reading) self.device.cancelReadback(slot.ticket);
            self.device.destroyQuerySet(slot.set);
            self.device.destroyBuffer(slot.resolve);
            self.device.destroyBuffer(slot.staging);
        }
    }

    pub fn deinit(self: *Timing) void {
        self.destroySlots(slot_count);
    }

    /// Start of a frame: collects finished readbacks and picks a free slot to record into.
    pub fn beginFrame(self: *Timing, sink: ?Sink, frame_ns: u64) void {
        self.current = null;
        self.last_recorded = null;
        for (&self.slots, 0..) |*slot, i| {
            switch (slot.state) {
                .idle => if (self.current == null) {
                    self.current = i;
                },
                .submitted => {
                    // The commands were submitted last frame, so the staging copy is queued behind them.
                    if (self.device.beginReadback(slot.staging, 0, slot.count * 2 * 8)) |ticket| {
                        slot.ticket = ticket;
                        slot.state = .reading;
                    } else |_| slot.state = .idle;
                },
                .reading => {
                    var raw: [query_bytes]u8 = undefined;
                    const bytes = raw[0 .. slot.count * 2 * 8];
                    const done = self.device.pollReadback(slot.ticket, bytes) catch {
                        self.device.cancelReadback(slot.ticket);
                        slot.state = .idle;
                        continue;
                    };
                    if (done) {
                        if (sink) |s| self.publish(slot, bytes, s, slot.frame_ns);
                        slot.state = .idle;
                        if (self.current == null) self.current = i;
                    }
                },
            }
        }
        if (sink == null) self.current = null;
        if (self.current) |index| self.slots[index].frame_ns = frame_ns;
    }

    pub fn abortRecorded(self: *Timing) void {
        if (self.last_recorded) |i| self.slots[i].state = .idle;
        self.last_recorded = null;
        self.current = null;
    }

    fn publish(self: *Timing, slot: *const Slot, bytes: []const u8, sink: Sink, frame_ns: u64) void {
        var names: [max_spans]Span = undefined;
        var totals: [max_spans]u64 = @splat(0);
        var distinct: usize = 0;
        for (0..slot.count) |i| {
            const begin = std.mem.readInt(u64, bytes[i * 16 ..][0..8], .little);
            const end = std.mem.readInt(u64, bytes[i * 16 + 8 ..][0..8], .little);
            if (end < begin) continue;
            const elapsed = @as(f64, @floatFromInt(end - begin)) * self.period_ns;
            if (!std.math.isFinite(elapsed) or elapsed < 0 or elapsed >= 18446744073709551616.0) continue;
            const ns: u64 = @intFromFloat(elapsed);
            const span = slot.spans[i];
            var found: ?usize = null;
            for (names[0..distinct], 0..) |n, j| if (std.mem.eql(u8, n.name, span.name)) {
                found = j;
                break;
            };
            const index = found orelse blk: {
                names[distinct] = span;
                distinct += 1;
                break :blk distinct - 1;
            };
            totals[index] +|= ns;
        }
        sink.begin_frame(sink.ctx);
        for (names[0..distinct], totals[0..distinct]) |n, t| sink.record(sink.ctx, n.name, n.category, t);
        sink.end_frame(sink.ctx, frame_ns);
    }

    /// End of the renderer's recording: stamps the passes recorded since `first_command` and queues the resolve.
    pub fn endFrame(self: *Timing, rec: *gpu.CommandRecorder, first_command: usize) !void {
        const index = self.current orelse return;
        // Resolve commands cannot be recorded inside an open pass (e.g. after an error mid-frame).
        if (rec.open_render_pass or rec.open_compute_pass) return;
        const slot = &self.slots[index];
        var count: u32 = 0;
        for (rec.commands.items[first_command..]) |*command| {
            const label: ?[]const u8 = switch (command.*) {
                .begin_render_pass => |d| d.label,
                .begin_compute_pass => |d| d.label,
                else => continue,
            };
            const span = classify(label orelse continue) orelse continue;
            if (count >= max_spans) {
                self.dropped_spans +|= 1;
                continue;
            }
            const stamps: gpu.PassTimestamps = .{ .query_set = slot.set, .begin_index = count * 2, .end_index = count * 2 + 1 };
            switch (command.*) {
                .begin_render_pass => |*d| d.timestamps = stamps,
                .begin_compute_pass => |*d| d.timestamps = stamps,
                else => unreachable,
            }
            slot.spans[count] = span;
            count += 1;
        }
        if (count == 0) return;
        try rec.resolveQuerySet(slot.set, 0, count * 2, slot.resolve, 0);
        try rec.copyBufferToBuffer(slot.resolve, 0, slot.staging, 0, count * 2 * 8);
        slot.count = count;
        slot.state = .submitted;
        self.last_recorded = index;
        self.current = null;
    }
};

test "pass labels map to profiler entries" {
    try std.testing.expectEqualStrings("Shadow", classify("shadow cascades").?.name);
    try std.testing.expectEqualStrings("Shadow", classify("local shadow atlas").?.name);
    try std.testing.expectEqualStrings("SSAO", classify("ssao blur").?.name);
    try std.testing.expectEqualStrings("Forward+", classify("pbr lit").?.name);
    try std.testing.expectEqualStrings("Volumetric", classify("froxel integrate").?.name);
    try std.testing.expect(classify("clear") == null);
}
