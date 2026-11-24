//! Typed Headless Widget Events & Shared Value Types (`official.ui.widgets`).

const std = @import("std");
const ui_core = @import("ui_core");
const graphics = @import("graphics");

/// Numeric storage formats supported by `NumberInputBehavior`.
pub const NumericFormat = enum {
    f32,
    f64,
    i32,
    i64,
};

/// Tagged union carrying a typed numeric value.
pub const NumericValue = union(NumericFormat) {
    f32: f32,
    f64: f64,
    i32: i32,
    i64: i64,

    /// Converts the active variant to `f64` for uniform math.
    pub fn asF64(self: NumericValue) f64 {
        return switch (self) {
            .f32 => |v| @floatCast(v),
            .f64 => |v| v,
            .i32 => |v| @floatFromInt(v),
            .i64 => |v| @floatFromInt(v),
        };
    }

    /// Constructs a `NumericValue` of `fmt` from an `f64`.
    pub fn fromF64(fmt: NumericFormat, v: f64) NumericValue {
        return switch (fmt) {
            .f32 => .{ .f32 = @floatCast(v) },
            .f64 => .{ .f64 = v },
            .i32 => .{ .i32 = @intFromFloat(@round(std.math.clamp(v, @as(f64, std.math.minInt(i32)), @as(f64, std.math.maxInt(i32))))) },
            .i64 => .{ .i64 = @intFromFloat(@round(v)) },
        };
    }
};

/// Optional inclusive bounds for sliders and numeric inputs.
pub const NumericRange = struct {
    min: f64 = -std.math.inf(f64),
    max: f64 = std.math.inf(f64),

    /// Clamps `v` into `[min, max]`.
    pub fn clamp(self: NumericRange, v: f64) f64 {
        return @max(self.min, @min(self.max, v));
    }
};

/// Orientation for sliders, scrollbars, and split panes.
pub const ControlOrientation = enum {
    horizontal,
    vertical,
};

/// Behavior when clicking the slider track outside the thumb.
pub const TrackClick = enum {
    drag,
    step,
    snap,
};

/// Preferred side of an anchor element for popover placement.
pub const PopoverSide = enum {
    top,
    bottom,
    left,
    right,

    /// Returns the opposite side for viewport collision flipping.
    pub fn mirror(self: PopoverSide) PopoverSide {
        return switch (self) {
            .top => .bottom,
            .bottom => .top,
            .left => .right,
            .right => .left,
        };
    }
};

/// Cross-axis alignment of a popover relative to its anchor.
pub const PopoverAlign = enum {
    start,
    center,
    end,
};

/// Candidate placement specification for a `Popover`.
pub const PopoverPlacement = struct {
    side: PopoverSide = .bottom,
    align_mode: PopoverAlign = .start,
    gap: f32 = 4.0,
};

/// Payload emitted by headless widgets into `WidgetEventQueue`.
pub const WidgetEvent = struct {
    node: ui_core.UiNodeId,
    tag: []const u8 = "",
    is_final: bool = true,
    payload: Payload,

    /// Discriminated event payload.
    pub const Payload = union(enum) {
        activate: void,
        value_bool: bool,
        value_f64: f64,
        value_numeric: NumericValue,
        value_vec2: [2]f32,
        value_color: graphics.Color,
        value_index: usize,
        text_changed: void,
        text_submit: void,
        expanded: bool,
        close_requested: void,
    };
};

/// Buffered per-frame queue of widget events.
pub const WidgetEventQueue = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(WidgetEvent) = .empty,

    /// Initializes an empty event queue.
    pub fn init(allocator: std.mem.Allocator) WidgetEventQueue {
        return .{ .allocator = allocator };
    }

    /// Releases the event queue backing memory.
    pub fn deinit(self: *WidgetEventQueue) void {
        self.items.deinit(self.allocator);
    }

    /// Clears all queued events at the start of a frame or after draining.
    pub fn clear(self: *WidgetEventQueue) void {
        self.items.clearRetainingCapacity();
    }

    /// Appends a new event to the queue.
    pub fn push(self: *WidgetEventQueue, ev: WidgetEvent) !void {
        try self.items.append(self.allocator, ev);
    }
};
