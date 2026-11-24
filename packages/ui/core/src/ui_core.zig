//! Optional Syntax-Agnostic Retained UI Core (`official.ui.core`).
//!
//! Provides a retained, cache-friendly `UiTree` IR (`engine.ui.tree/1`) with:
//! - Generational `UiNodeId` handles and subtree removal.
//! - Flex-like layout (`column`/`row`, `SizeSpec`, `AlignItems`, `JustifyContent`, `PositionMode`).
//! - Layered hit testing & painting (`.base`, `.overlay`, `.modal`) with nested `clip_push`/`clip_pop`.
//! - Pointer hover/press/capture, scroll, keyboard `Tab` navigation, and `ui.action` events.
//! - Backend-neutral output via `graphics.DrawCommand`.

const std = @import("std");
const engine = @import("engine");
const graphics = @import("graphics");

fn measureTextSimple(txt: []const u8, scale: f32) struct { width: f32, height: f32 } {
    const s = if (scale > 0.0) scale else 1.0;
    const adv = 4.4 * s;
    const line_h = 8.0 * s;
    var max_w: f32 = 0;
    var cur_w: f32 = 0;
    var lines: f32 = 1;
    for (txt) |ch| {
        if (ch == '\n') {
            if (cur_w > max_w) max_w = cur_w;
            cur_w = 0;
            lines += 1;
        } else {
            cur_w += adv;
        }
    }
    if (cur_w > max_w) max_w = cur_w;
    return .{ .width = max_w, .height = lines * line_h };
}

/// Module owner identifier for `official.ui.core`.
pub const MODULE_OWNER_ID: u64 = 2003;

/// Semantic node kinds stored in `UiTree`.
pub const NodeKind = enum {
    panel,
    label,
    button,
    textbox,
    virtual_list,
    custom,
};

/// Main-axis layout direction for child nodes.
pub const FlexDirection = enum {
    column,
    row,
};

/// Cross-axis alignment for child nodes.
pub const AlignItems = enum {
    start,
    center,
    end,
    stretch,
};

/// Main-axis distribution for child nodes.
pub const JustifyContent = enum {
    start,
    center,
    end,
    space_between,
};

/// Positioning mode for a node inside its parent.
pub const PositionMode = enum {
    relative,
    absolute,
};

/// Horizontal text alignment within a node's inner box.
pub const TextAlign = enum {
    left,
    center,
    right,
};

/// Paint and hit-test layer priority.
pub const UiLayer = enum(u8) {
    base = 0,
    overlay = 1,
    modal = 2,
};

/// Cursor hint requested when the pointer hovers or captures a node.
pub const CursorHint = enum {
    default,
    pointer,
    text,
    ew_resize,
    ns_resize,
    grab,
    crosshair,
};

/// Dimensional sizing specification.
pub const SizeSpec = union(enum) {
    auto,
    px: f32,
    percent: f32,
    grow: f32,
};

/// Four-sided edge spacing (top, right, bottom, left).
pub const Edges = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,

    /// Uniform edge spacing on all four sides.
    pub fn all(v: f32) Edges {
        return .{ .top = v, .right = v, .bottom = v, .left = v };
    }

    /// Symmetric horizontal and vertical edge spacing.
    pub fn xy(horiz: f32, vert: f32) Edges {
        return .{ .top = vert, .right = horiz, .bottom = vert, .left = horiz };
    }
};

/// Optional specialized visual payload rendered inside a node.
pub const PaintExtra = union(enum) {
    none,
    gradient: struct {
        kind: graphics.GradientKind,
        stops: [4]graphics.Color,
    },
    color_wheel: struct {
        hue_deg: f32,
        ring_width: f32 = 12.0,
    },
    icon: struct {
        kind: graphics.IconKind,
        size: f32,
        color: graphics.Color,
    },
};

/// Generational node reference safe across node removal and slot reuse.
pub const UiNodeId = packed struct(u64) {
    index: u32,
    generation: u32,
};

/// Styling and layout configuration for a `UiNode`.
pub const UiStyle = struct {
    direction: FlexDirection = .column,
    width: ?f32 = null,
    height: ?f32 = null,
    width_spec: ?SizeSpec = null,
    height_spec: ?SizeSpec = null,
    min_width: f32 = 0,
    min_height: f32 = 24,
    max_width: f32 = std.math.inf(f32),
    max_height: f32 = std.math.inf(f32),
    padding: f32 = 8,
    padding_edges: ?Edges = null,
    gap: f32 = 4,
    align_items: AlignItems = .stretch,
    justify_content: JustifyContent = .start,
    position: PositionMode = .relative,
    left: ?f32 = null,
    top: ?f32 = null,
    right: ?f32 = null,
    bottom: ?f32 = null,
    clip_children: bool = false,
    visible: bool = true,
    layer: UiLayer = .base,
    bg_color: graphics.Color = .{ .r = 0.08, .g = 0.10, .b = 0.13, .a = 1.0 },
    text_color: graphics.Color = .{ .r = 0.90, .g = 0.92, .b = 0.94, .a = 1.0 },
    border_color: graphics.Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    border_widths: [4]f32 = .{ 0, 0, 0, 0 },
    corner_radii: [4]f32 = .{ 0, 0, 0, 0 },
    focus_ring_color: graphics.Color = .{ .r = 0.25, .g = 0.58, .b = 0.96, .a = 0.70 },
    font_scale: f32 = 2.0,
    text_align: TextAlign = .left,

    /// Resolves effective padding edges (falling back to uniform `padding`).
    pub fn resolvedPadding(self: UiStyle) Edges {
        return self.padding_edges orelse Edges.all(self.padding);
    }
};

/// Axis-aligned rectangle in logical UI coordinates.
pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,

    /// Returns true if `(px, py)` lies within this rectangle.
    pub fn contains(self: Rect, px: f32, py: f32) bool {
        return px >= self.x and px <= self.x + self.width and
            py >= self.y and py <= self.y + self.height;
    }
};

/// Descriptor passed to `UiTree.createNode`.
pub const UiNodeDescriptor = struct {
    id: []const u8,
    kind: NodeKind,
    text: []const u8 = "",
    action: []const u8 = "",
    style: UiStyle = .{},
    focusable: bool = false,
    disabled: bool = false,
    scrollable: bool = false,
    pickable: bool = true,
    cursor: CursorHint = .default,
    tab_index: i32 = 0,
    user_tag: u64 = 0,
    paint_extra: PaintExtra = .none,
};

/// Retained node stored inside `UiTree`.
pub const UiNode = struct {
    id: []const u8,
    kind: NodeKind,
    text: []const u8,
    action: []const u8,
    style: UiStyle,
    layout: Rect,
    children: std.ArrayList(usize),
    parent: ?usize = null,
    generation: u32 = 1,
    alive: bool = true,
    focused: bool = false,
    focus_visible: bool = false,
    hovered: bool = false,
    pressed: bool = false,
    disabled: bool = false,
    checked: bool = false,
    selected: bool = false,
    expanded: bool = false,
    focusable: bool = false,
    scrollable: bool = false,
    pickable: bool = true,
    cursor: CursorHint = .default,
    tab_index: i32 = 0,
    user_tag: u64 = 0,
    paint_extra: PaintExtra = .none,
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,
    content_width: f32 = 0,
    content_height: f32 = 0,
};

/// Retained UI tree IR providing layout, hit testing, interaction state, and draw emission.
pub const UiTree = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(UiNode),
    roots: std.ArrayList(usize),
    id_index: std.StringHashMapUnmanaged(usize),
    focused_node: ?usize,
    hovered_node: ?usize = null,
    pressed_node: ?usize = null,
    pointer_capture_node: ?usize = null,
    focus_visible: bool = false,
    caret_phase: f32 = 0.0,
    text_cursor: usize = 0,
    measure_text_fn: ?TextMeasureFn = null,
    measure_text_ctx: ?*anyopaque = null,

    /// Optional backend text width callback (`content`, `font_scale`) -> logical width in pixels.
    pub const TextMeasureFn = *const fn (ctx: ?*anyopaque, content: []const u8, scale: f32) f32;

    fn measureTextWidth(self: *const UiTree, txt: []const u8, scale: f32) f32 {
        if (self.measure_text_fn) |f| {
            return f(self.measure_text_ctx, txt, scale);
        }
        return measureTextSimple(txt, scale).width;
    }

    /// Initializes an empty `UiTree`.
    pub fn init(allocator: std.mem.Allocator) UiTree {
        return .{
            .allocator = allocator,
            .nodes = .empty,
            .roots = .empty,
            .id_index = .empty,
            .focused_node = null,
        };
    }

    /// Releases all node buffers and indices owned by `UiTree`.
    pub fn deinit(self: *UiTree) void {
        self.id_index.deinit(self.allocator);
        for (self.nodes.items) |*node| {
            if (node.alive) {
                self.allocator.free(node.id);
                self.allocator.free(node.text);
                self.allocator.free(node.action);
            }
            node.children.deinit(self.allocator);
        }
        self.nodes.deinit(self.allocator);
        self.roots.deinit(self.allocator);
    }

    /// Clears all nodes while retaining backing capacity.
    pub fn clear(self: *UiTree) void {
        self.id_index.clearRetainingCapacity();
        for (self.nodes.items) |*node| {
            if (node.alive) {
                self.allocator.free(node.id);
                self.allocator.free(node.text);
                self.allocator.free(node.action);
            }
            node.children.deinit(self.allocator);
        }
        self.nodes.clearRetainingCapacity();
        self.roots.clearRetainingCapacity();
        self.focused_node = null;
        self.hovered_node = null;
        self.pressed_node = null;
        self.pointer_capture_node = null;
        self.focus_visible = false;
    }

    /// Creates a node under `parent_idx` (or as a root when `null`) and returns its index.
    pub fn createNode(self: *UiTree, parent_idx: ?usize, desc: UiNodeDescriptor) !usize {
        const id_copy = try self.allocator.dupe(u8, desc.id);
        errdefer self.allocator.free(id_copy);
        const text_copy = try self.allocator.dupe(u8, desc.text);
        errdefer self.allocator.free(text_copy);
        const action_copy = try self.allocator.dupe(u8, desc.action);
        errdefer self.allocator.free(action_copy);

        if (parent_idx) |p| {
            if (p >= self.nodes.items.len or !self.nodes.items[p].alive) return error.InvalidParentNode;
            try self.nodes.items[p].children.ensureUnusedCapacity(self.allocator, 1);
        } else {
            try self.roots.ensureUnusedCapacity(self.allocator, 1);
        }
        try self.nodes.ensureUnusedCapacity(self.allocator, 1);
        if (id_copy.len > 0) {
            try self.id_index.ensureUnusedCapacity(self.allocator, 1);
        }

        const idx = self.nodes.items.len;
        const auto_focusable = desc.focusable or desc.kind == .button or desc.kind == .textbox;
        self.nodes.appendAssumeCapacity(.{
            .id = id_copy,
            .kind = desc.kind,
            .text = text_copy,
            .action = action_copy,
            .style = desc.style,
            .layout = .{},
            .children = .empty,
            .parent = parent_idx,
            .generation = 1,
            .alive = true,
            .focused = false,
            .disabled = desc.disabled,
            .focusable = auto_focusable,
            .scrollable = desc.scrollable or desc.kind == .virtual_list,
            .pickable = desc.pickable,
            .cursor = desc.cursor,
            .tab_index = desc.tab_index,
            .user_tag = desc.user_tag,
            .paint_extra = desc.paint_extra,
        });

        if (parent_idx) |p| {
            self.nodes.items[p].children.appendAssumeCapacity(idx);
        } else {
            self.roots.appendAssumeCapacity(idx);
        }
        if (id_copy.len > 0) {
            self.id_index.putAssumeCapacity(id_copy, idx);
        }
        return idx;
    }

    /// Returns a generational `UiNodeId` for `idx`, or `null` if invalid/dead.
    pub fn idOf(self: *const UiTree, idx: usize) ?UiNodeId {
        if (idx >= self.nodes.items.len) return null;
        const n = &self.nodes.items[idx];
        if (!n.alive) return null;
        return .{ .index = @intCast(idx), .generation = n.generation };
    }

    /// Resolves a generational `UiNodeId` to its current slice index if alive.
    pub fn resolveId(self: *const UiTree, id: UiNodeId) ?usize {
        if (id.index >= self.nodes.items.len) return null;
        const n = &self.nodes.items[id.index];
        if (!n.alive or n.generation != id.generation) return null;
        return id.index;
    }

    /// Detaches and frees a node and all of its descendants.
    pub fn removeSubtree(self: *UiTree, idx: usize) void {
        if (idx >= self.nodes.items.len or !self.nodes.items[idx].alive) return;
        if (self.nodes.items[idx].parent) |p_idx| {
            if (p_idx < self.nodes.items.len and self.nodes.items[p_idx].alive) {
                var children = &self.nodes.items[p_idx].children;
                for (children.items, 0..) |c, ci| {
                    if (c == idx) {
                        _ = children.orderedRemove(ci);
                        break;
                    }
                }
            }
        } else {
            for (self.roots.items, 0..) |r, ri| {
                if (r == idx) {
                    _ = self.roots.orderedRemove(ri);
                    break;
                }
            }
        }
        self.destroySubtreeRecursive(idx);
    }

    fn destroySubtreeRecursive(self: *UiTree, idx: usize) void {
        const node = &self.nodes.items[idx];
        if (!node.alive) return;
        for (node.children.items) |c_idx| {
            self.destroySubtreeRecursive(c_idx);
        }
        node.children.clearRetainingCapacity();

        if (node.id.len > 0) {
            _ = self.id_index.remove(node.id);
        }
        if (self.focused_node == idx) self.focused_node = null;
        if (self.hovered_node == idx) self.hovered_node = null;
        if (self.pressed_node == idx) self.pressed_node = null;
        if (self.pointer_capture_node == idx) self.pointer_capture_node = null;

        self.allocator.free(node.id);
        self.allocator.free(node.text);
        self.allocator.free(node.action);
        node.id = &.{};
        node.text = &.{};
        node.action = &.{};
        node.alive = false;
        node.generation +%= 1;
    }

    /// Removes all children of `parent_idx` while keeping the parent node intact.
    pub fn clearChildren(self: *UiTree, parent_idx: usize) void {
        if (parent_idx >= self.nodes.items.len or !self.nodes.items[parent_idx].alive) return;
        for (self.nodes.items[parent_idx].children.items) |c_idx| {
            self.destroySubtreeRecursive(c_idx);
        }
        self.nodes.items[parent_idx].children.clearRetainingCapacity();
    }

    /// Looks up a node index by string ID.
    pub fn findById(self: *const UiTree, id: []const u8) ?usize {
        const idx = self.id_index.get(id) orelse return null;
        if (idx >= self.nodes.items.len or !self.nodes.items[idx].alive) return null;
        return idx;
    }

    /// Returns the number of alive nodes in `UiTree`.
    pub fn nodeCount(self: *const UiTree) usize {
        var alive_count: usize = 0;
        for (self.nodes.items) |n| {
            if (n.alive) alive_count += 1;
        }
        return alive_count;
    }

    fn resolveWidthSpec(style: UiStyle) SizeSpec {
        if (style.width_spec) |ws| return ws;
        if (style.width) |w| return .{ .px = w };
        return .auto;
    }

    fn resolveHeightSpec(style: UiStyle) SizeSpec {
        if (style.height_spec) |hs| return hs;
        if (style.height) |h| return .{ .px = h };
        return .auto;
    }

    /// Measures and lays out all visible root trees inside `(viewport_width, viewport_height)`.
    pub fn layoutTree(self: *UiTree, viewport_width: f32, viewport_height: f32) void {
        var y_cursor: f32 = 0;
        for (self.roots.items) |root_idx| {
            const root = &self.nodes.items[root_idx];
            if (!root.alive or !root.style.visible) continue;
            if (root.style.position == .absolute or root.style.layer != .base) {
                self.layoutAbsoluteRoot(root_idx, viewport_width, viewport_height);
            } else {
                self.layoutNode(root_idx, 0, y_cursor, viewport_width, viewport_height);
                y_cursor += self.nodes.items[root_idx].layout.height;
            }
        }
    }

    fn layoutAbsoluteRoot(self: *UiTree, idx: usize, vw: f32, vh: f32) void {
        const style = self.nodes.items[idx].style;
        const w = switch (resolveWidthSpec(style)) {
            .px => |px_w| px_w,
            .percent => |pct| vw * (pct * 0.01),
            else => vw,
        };
        const h_avail = switch (resolveHeightSpec(style)) {
            .px => |px_h| px_h,
            .percent => |pct| vh * (pct * 0.01),
            else => vh,
        };
        const rx = style.left orelse if (style.right) |r| @max(0.0, vw - w - r) else 0.0;
        const ry = style.top orelse if (style.bottom) |b| @max(0.0, vh - h_avail - b) else 0.0;
        self.layoutNode(idx, rx, ry, vw, vh);
    }

    fn estimateIntrinsicWidth(self: *const UiTree, idx: usize, avail_w: f32) f32 {
        const node = &self.nodes.items[idx];
        const pad = node.style.resolvedPadding();
        switch (resolveWidthSpec(node.style)) {
            .px => |px_w| return std.math.clamp(px_w, node.style.min_width, node.style.max_width),
            .percent => |pct| return std.math.clamp(avail_w * (pct * 0.01), node.style.min_width, node.style.max_width),
            .grow => return avail_w,
            .auto => {
                if (node.kind == .label or node.kind == .button) {
                    const txt_w = measureTextSimple(node.text, node.style.font_scale).width + pad.left + pad.right;
                    return std.math.clamp(@max(txt_w, node.style.min_width), node.style.min_width, @min(avail_w, node.style.max_width));
                }
                return std.math.clamp(avail_w, node.style.min_width, node.style.max_width);
            },
        }
    }

    fn layoutNode(self: *UiTree, idx: usize, x: f32, y: f32, avail_w: f32, avail_h: f32) void {
        const style = self.nodes.items[idx].style;
        if (!style.visible) {
            self.nodes.items[idx].layout = .{ .x = x, .y = y, .width = 0, .height = 0 };
            return;
        }

        const pad = style.resolvedPadding();
        const gap = style.gap;
        const dir = style.direction;

        const w_raw: f32 = switch (resolveWidthSpec(style)) {
            .px => |px_w| px_w,
            .percent => |pct| avail_w * (pct * 0.01),
            .grow, .auto => avail_w,
        };
        const w = std.math.clamp(w_raw, style.min_width, style.max_width);
        const inner_w = @max(@as(f32, 0.0), w - pad.left - pad.right);
        const inner_h = @max(@as(f32, 0.0), avail_h - pad.top - pad.bottom);

        // Count visible relative children and collect grow weights.
        var rel_count: usize = 0;
        var total_grow: f32 = 0;
        var fixed_main: f32 = 0;
        const children_len = self.nodes.items[idx].children.items.len;

        for (0..children_len) |ci| {
            const c_idx = self.nodes.items[idx].children.items[ci];
            const c_node = &self.nodes.items[c_idx];
            if (!c_node.alive or !c_node.style.visible or c_node.style.position == .absolute) continue;
            rel_count += 1;
            if (dir == .row) {
                switch (resolveWidthSpec(c_node.style)) {
                    .grow => |g| total_grow += @max(@as(f32, 0.01), g),
                    .px => |px_w| fixed_main += px_w,
                    .percent => |pct| fixed_main += inner_w * (pct * 0.01),
                    .auto => {
                        if (c_node.children.items.len == 0 and (c_node.kind == .label or c_node.kind == .button)) {
                            fixed_main += self.estimateIntrinsicWidth(c_idx, inner_w);
                        } else {
                            total_grow += 1.0;
                        }
                    },
                }
            } else {
                switch (resolveHeightSpec(c_node.style)) {
                    .grow => |g| total_grow += @max(@as(f32, 0.01), g),
                    .px => |px_h| fixed_main += px_h,
                    .percent => |pct| fixed_main += inner_h * (pct * 0.01),
                    .auto => {},
                }
            }
        }

        const total_gap = if (rel_count > 1) gap * @as(f32, @floatFromInt(rel_count - 1)) else 0.0;
        const avail_for_grow = if (dir == .row)
            @max(@as(f32, 0.0), inner_w - fixed_main - total_gap)
        else
            @max(@as(f32, 0.0), inner_h - fixed_main - total_gap);

        const scroll_x = self.nodes.items[idx].scroll_x;
        const scroll_y = self.nodes.items[idx].scroll_y;
        var child_x = x + pad.left - scroll_x;
        var child_y = y + pad.top - scroll_y;
        var max_child_right: f32 = child_x;
        var max_child_bottom: f32 = child_y;

        // Pass 1: lay out relative children sequentially.
        var rel_seen: usize = 0;
        for (0..children_len) |ci| {
            const c_idx = self.nodes.items[idx].children.items[ci];
            const c_node = &self.nodes.items[c_idx];
            if (!c_node.alive or !c_node.style.visible or c_node.style.position == .absolute) continue;

            const slot_w: f32 = if (dir == .row) blk: {
                switch (resolveWidthSpec(c_node.style)) {
                    .grow => |g| break :blk if (total_grow > 0) avail_for_grow * (@max(@as(f32, 0.01), g) / total_grow) else 0,
                    .px => |px_w| break :blk px_w,
                    .percent => break :blk inner_w,
                    .auto => {
                        if (c_node.children.items.len == 0 and (c_node.kind == .label or c_node.kind == .button)) {
                            break :blk self.estimateIntrinsicWidth(c_idx, inner_w);
                        }
                        break :blk if (total_grow > 0) avail_for_grow * (1.0 / total_grow) else inner_w;
                    },
                }
            } else inner_w;

            const slot_h: f32 = if (dir == .column) blk: {
                switch (resolveHeightSpec(c_node.style)) {
                    .grow => |g| break :blk if (total_grow > 0) avail_for_grow * (@max(@as(f32, 0.01), g) / total_grow) else inner_h,
                    else => break :blk inner_h,
                }
            } else inner_h;

            self.layoutNode(c_idx, child_x, child_y, slot_w, slot_h);
            const c_rect = self.nodes.items[c_idx].layout;

            if (c_rect.x + c_rect.width > max_child_right) max_child_right = c_rect.x + c_rect.width;
            if (c_rect.y + c_rect.height > max_child_bottom) max_child_bottom = c_rect.y + c_rect.height;

            rel_seen += 1;
            if (rel_seen < rel_count) {
                if (dir == .column) {
                    child_y += c_rect.height + gap;
                } else {
                    child_x += c_rect.width + gap;
                }
            }
        }

        const content_w = (max_child_right - (x + pad.left - scroll_x)) + pad.left + pad.right;
        const content_h = (max_child_bottom - (y + pad.top - scroll_y)) + pad.top + pad.bottom;

        const computed_h_raw: f32 = switch (resolveHeightSpec(style)) {
            .px => |px_h| px_h,
            .percent => |pct| avail_h * (pct * 0.01),
            .grow => avail_h,
            .auto => @max(style.min_height, content_h),
        };
        const computed_h = std.math.clamp(computed_h_raw, style.min_height, style.max_height);

        self.nodes.items[idx].layout = .{
            .x = x,
            .y = y,
            .width = w,
            .height = computed_h,
        };
        self.nodes.items[idx].content_width = content_w;
        self.nodes.items[idx].content_height = content_h;

        // Clamp scroll offsets to valid range.
        const max_scroll_y = @max(@as(f32, 0.0), content_h - computed_h);
        const max_scroll_x = @max(@as(f32, 0.0), content_w - w);
        self.nodes.items[idx].scroll_y = std.math.clamp(self.nodes.items[idx].scroll_y, 0.0, max_scroll_y);
        self.nodes.items[idx].scroll_x = std.math.clamp(self.nodes.items[idx].scroll_x, 0.0, max_scroll_x);

        // Pass 2: align cross-axis and position `.absolute` children relative to finalized parent box.
        const final_inner_h = @max(@as(f32, 0.0), computed_h - pad.top - pad.bottom);
        for (0..children_len) |ci| {
            const c_idx = self.nodes.items[idx].children.items[ci];
            const c_node = &self.nodes.items[c_idx];
            if (!c_node.alive or !c_node.style.visible) continue;

            if (c_node.style.position == .absolute) {
                const aw: f32 = switch (resolveWidthSpec(c_node.style)) {
                    .px => |px_w| px_w,
                    .percent => |pct| w * (pct * 0.01),
                    else => inner_w,
                };
                const ah: f32 = switch (resolveHeightSpec(c_node.style)) {
                    .px => |px_h| px_h,
                    .percent => |pct| computed_h * (pct * 0.01),
                    else => final_inner_h,
                };
                const ax = if (c_node.style.left) |l|
                    x + l
                else if (c_node.style.right) |r|
                    x + w - aw - r
                else
                    x + pad.left;
                const ay = if (c_node.style.top) |t|
                    y + t
                else if (c_node.style.bottom) |b|
                    y + computed_h - ah - b
                else
                    y + pad.top;
                const child_avail_w = switch (resolveWidthSpec(c_node.style)) {
                    .percent => w,
                    else => inner_w,
                };
                const child_avail_h = switch (resolveHeightSpec(c_node.style)) {
                    .percent => computed_h,
                    else => final_inner_h,
                };
                self.layoutNode(c_idx, ax, ay, child_avail_w, child_avail_h);
            } else if (dir == .row) {
                if (style.align_items == .center) {
                    const dy = (final_inner_h - c_node.layout.height) * 0.5;
                    if (@abs(dy) > 0.1) self.shiftSubtree(c_idx, 0, dy);
                } else if (style.align_items == .end) {
                    const dy = final_inner_h - c_node.layout.height;
                    if (@abs(dy) > 0.1) self.shiftSubtree(c_idx, 0, dy);
                }
            } else if (dir == .column) {
                if (style.align_items == .center) {
                    const dx = (inner_w - c_node.layout.width) * 0.5;
                    if (@abs(dx) > 0.1) self.shiftSubtree(c_idx, dx, 0);
                } else if (style.align_items == .end) {
                    const dx = inner_w - c_node.layout.width;
                    if (@abs(dx) > 0.1) self.shiftSubtree(c_idx, dx, 0);
                }
            }
        }

        // Cross-check main-axis justification (`center` / `end`) for `.column` and `.row` containers.
        if (rel_count > 0 and (style.justify_content == .center or style.justify_content == .end)) {
            if (dir == .column) {
                const used_h = @max(@as(f32, 0.0), max_child_bottom - (y + pad.top - scroll_y));
                const extra_h = @max(@as(f32, 0.0), final_inner_h - used_h);
                const shift_y = if (style.justify_content == .center) extra_h * 0.5 else extra_h;
                if (shift_y > 0.1) {
                    for (0..children_len) |ci| {
                        const c_idx = self.nodes.items[idx].children.items[ci];
                        if (self.nodes.items[c_idx].alive and self.nodes.items[c_idx].style.visible and self.nodes.items[c_idx].style.position != .absolute) {
                            self.shiftSubtree(c_idx, 0, shift_y);
                        }
                    }
                }
            } else {
                const used_w = @max(@as(f32, 0.0), max_child_right - (x + pad.left - scroll_x));
                const extra_w = @max(@as(f32, 0.0), inner_w - used_w);
                const shift_x = if (style.justify_content == .center) extra_w * 0.5 else extra_w;
                if (shift_x > 0.1) {
                    for (0..children_len) |ci| {
                        const c_idx = self.nodes.items[idx].children.items[ci];
                        if (self.nodes.items[c_idx].alive and self.nodes.items[c_idx].style.visible and self.nodes.items[c_idx].style.position != .absolute) {
                            self.shiftSubtree(c_idx, shift_x, 0);
                        }
                    }
                }
            }
        }
    }

    fn shiftSubtree(self: *UiTree, idx: usize, dx: f32, dy: f32) void {
        const node = &self.nodes.items[idx];
        node.layout.x += dx;
        node.layout.y += dy;
        for (node.children.items) |c_idx| {
            self.shiftSubtree(c_idx, dx, dy);
        }
    }

    /// Hit-tests all visible roots from top layer (`.modal` -> `.overlay` -> `.base`) downward.
    pub fn hitTest(self: *const UiTree, px: f32, py: f32) ?usize {
        const layers = [3]UiLayer{ .modal, .overlay, .base };
        for (layers) |layer| {
            var i = self.roots.items.len;
            while (i > 0) {
                i -= 1;
                const root_idx = self.roots.items[i];
                const root = &self.nodes.items[root_idx];
                if (!root.alive or !root.style.visible or root.style.layer != layer) continue;
                if (self.hitTestNode(root_idx, px, py)) |hit| {
                    return hit;
                }
            }
            // Modal layers block hit-testing on lower layers when visible.
            if (layer == .modal) {
                for (self.roots.items) |root_idx| {
                    const root = &self.nodes.items[root_idx];
                    if (root.alive and root.style.visible and root.style.layer == .modal) {
                        return root_idx;
                    }
                }
            }
        }
        return null;
    }

    fn hitTestNode(self: *const UiTree, idx: usize, px: f32, py: f32) ?usize {
        const node = &self.nodes.items[idx];
        if (!node.alive or !node.style.visible) return null;
        if (!node.layout.contains(px, py)) return null;

        var i = node.children.items.len;
        while (i > 0) {
            i -= 1;
            if (self.hitTestNode(node.children.items[i], px, py)) |child_hit| {
                return child_hit;
            }
        }
        if (!node.pickable) return null;
        return idx;
    }

    /// Updates hover, active press, and pointer capture state for the current frame.
    pub fn updatePointer(self: *UiTree, px: f32, py: f32, down: bool, clicked: bool, released: bool) ?usize {
        if (self.focused_node != null) {
            self.caret_phase = @mod(self.caret_phase + 1.0 / 60.0, 1.0);
        }
        if (self.hovered_node) |prev_h| {
            if (prev_h < self.nodes.items.len) self.nodes.items[prev_h].hovered = false;
        }
        const hit = self.hitTest(px, py);
        if (hit) |h| {
            if (!self.nodes.items[h].disabled) {
                self.nodes.items[h].hovered = true;
                self.hovered_node = h;
            } else {
                self.hovered_node = null;
            }
        } else {
            self.hovered_node = null;
        }

        if (clicked) {
            self.focus_visible = false;
            if (hit) |h| {
                if (!self.nodes.items[h].disabled) {
                    self.pressed_node = h;
                    self.pointer_capture_node = h;
                    self.nodes.items[h].pressed = true;
                }
            }
        }

        if (released or !down) {
            if (self.pressed_node) |p| {
                if (p < self.nodes.items.len) self.nodes.items[p].pressed = false;
            }
            self.pressed_node = null;
            self.pointer_capture_node = null;
        }

        return self.pointer_capture_node orelse self.hovered_node;
    }

    /// Handles a pointer click, updating focus and emitting `ui.action` when configured.
    pub fn handlePointerClick(self: *UiTree, px: f32, py: f32, events: *engine.EventBus) ?usize {
        const hit = self.hitTest(px, py) orelse return null;
        if (self.nodes.items[hit].disabled) return hit;

        self.setFocus(hit, false);

        const action = self.nodes.items[hit].action;
        if (action.len > 0) {
            events.post(.{
                .name = "ui.action",
                .payload = action,
                .entity_handle = @bitCast(self.idOf(hit) orelse UiNodeId{ .index = 0, .generation = 0 }),
            }) catch {};
        }
        return hit;
    }

    /// Moves focus to `target_idx` (or clears focus if `null`).
    pub fn setFocus(self: *UiTree, target_idx: ?usize, via_keyboard: bool) void {
        if (self.focused_node) |prev| {
            if (prev < self.nodes.items.len) {
                self.nodes.items[prev].focused = false;
                self.nodes.items[prev].focus_visible = false;
            }
        }
        self.focus_visible = via_keyboard;
        if (target_idx) |idx| {
            if (idx < self.nodes.items.len and self.nodes.items[idx].alive and !self.nodes.items[idx].disabled) {
                if (self.focused_node != idx) {
            self.caret_phase = 0.0;
            self.text_cursor = self.nodes.items[idx].text.len;
        }
        self.focused_node = idx;
                self.nodes.items[idx].focused = true;
                self.nodes.items[idx].focus_visible = via_keyboard;
                return;
            }
        }
        self.focused_node = null;
    }

    /// Cycles keyboard focus (`Tab` / `Shift+Tab`) across visible, enabled, focusable nodes.
    pub fn focusNext(self: *UiTree, reverse: bool) ?usize {
        var candidates: [256]usize = undefined;
        var count: usize = 0;
        for (self.nodes.items, 0..) |n, idx| {
            if (n.alive and n.style.visible and !n.disabled and n.focusable and count < candidates.len) {
                candidates[count] = idx;
                count += 1;
            }
        }
        if (count == 0) return null;

        var cur_pos: ?usize = null;
        if (self.focused_node) |f| {
            for (candidates[0..count], 0..) |c, ci| {
                if (c == f) {
                    cur_pos = ci;
                    break;
                }
            }
        }

        const next_pos: usize = if (cur_pos) |cp| blk: {
            if (reverse) {
                break :blk if (cp == 0) count - 1 else cp - 1;
            } else {
                break :blk (cp + 1) % count;
            }
        } else (if (reverse) count - 1 else 0);

        const target = candidates[next_pos];
        self.setFocus(target, true);
        return target;
    }

    /// Scrolls the nearest scrollable ancestor containing `(px, py)`.
    pub fn handleScroll(self: *UiTree, px: f32, py: f32, delta_y: f32) bool {
        var cur = self.hitTest(px, py);
        while (cur) |idx| {
            const n = &self.nodes.items[idx];
            if (n.scrollable and n.content_height > n.layout.height) {
                const max_sy = @max(@as(f32, 0.0), n.content_height - n.layout.height);
                n.scroll_y = std.math.clamp(n.scroll_y - delta_y * 24.0, 0.0, max_sy);
                return true;
            }
            cur = n.parent;
        }
        return false;
    }

    /// Replaces the text string owned by node `idx`.
    pub fn setNodeText(self: *UiTree, idx: usize, new_text: []const u8) !void {
        if (idx >= self.nodes.items.len or !self.nodes.items[idx].alive) return error.InvalidNode;
        const copy = try self.allocator.dupe(u8, new_text);
        self.allocator.free(self.nodes.items[idx].text);
        self.nodes.items[idx].text = copy;
        if (self.focused_node == idx) {
            self.text_cursor = @min(self.text_cursor, new_text.len);
        }
    }

    /// Appends typed text to the currently focused `.textbox` node.
    pub fn handleTextInput(self: *UiTree, input_text: []const u8) !bool {
        const idx = self.focused_node orelse return false;
        if (idx >= self.nodes.items.len or !self.nodes.items[idx].alive) return false;
        const node = &self.nodes.items[idx];
        if (node.kind != .textbox or node.disabled or input_text.len == 0) return false;

        const pos = @min(self.text_cursor, node.text.len);
        const next = try std.mem.concat(self.allocator, u8, &.{ node.text[0..pos], input_text, node.text[pos..] });
        self.allocator.free(node.text);
        node.text = next;
        self.text_cursor = pos + input_text.len;
        self.caret_phase = 0.0;
        return true;
    }

    /// Deletes the byte before `text_cursor` from the currently focused `.textbox` node.
    pub fn handleBackspace(self: *UiTree) !bool {
        const idx = self.focused_node orelse return false;
        if (idx >= self.nodes.items.len or !self.nodes.items[idx].alive) return false;
        const node = &self.nodes.items[idx];
        const pos = @min(self.text_cursor, node.text.len);
        if (node.kind != .textbox or node.disabled or pos == 0) return false;

        const next = try std.mem.concat(self.allocator, u8, &.{ node.text[0 .. pos - 1], node.text[pos..] });
        self.allocator.free(node.text);
        node.text = next;
        self.text_cursor = pos - 1;
        self.caret_phase = 0.0;
        return true;
    }

    /// Deletes the byte at `text_cursor` from the currently focused `.textbox` node.
    pub fn handleDelete(self: *UiTree) !bool {
        const idx = self.focused_node orelse return false;
        if (idx >= self.nodes.items.len or !self.nodes.items[idx].alive) return false;
        const node = &self.nodes.items[idx];
        const pos = @min(self.text_cursor, node.text.len);
        if (node.kind != .textbox or node.disabled or pos >= node.text.len) return false;

        const next = try std.mem.concat(self.allocator, u8, &.{ node.text[0..pos], node.text[pos + 1 ..] });
        self.allocator.free(node.text);
        node.text = next;
        self.caret_phase = 0.0;
        return true;
    }

    /// Moves `text_cursor` horizontally (`delta < 0` left, `delta > 0` right) on the focused `.textbox`.
    pub fn moveTextCursor(self: *UiTree, delta: isize) void {
        const idx = self.focused_node orelse return;
        if (idx >= self.nodes.items.len or !self.nodes.items[idx].alive) return;
        const len = self.nodes.items[idx].text.len;
        const cur: isize = @intCast(@min(self.text_cursor, len));
        const next = std.math.clamp(cur + delta, 0, @as(isize, @intCast(len)));
        self.text_cursor = @intCast(next);
        self.caret_phase = 0.0;
    }

    /// Moves `text_cursor` to the start (`to_end == false`) or end (`to_end == true`) of the current line.
    pub fn moveTextCursorLineEdge(self: *UiTree, to_end: bool) void {
        const idx = self.focused_node orelse return;
        if (idx >= self.nodes.items.len or !self.nodes.items[idx].alive) return;
        const txt = self.nodes.items[idx].text;
        const pos = @min(self.text_cursor, txt.len);
        if (!to_end) {
            const prev_nl = std.mem.lastIndexOfScalar(u8, txt[0..pos], '\n');
            self.text_cursor = if (prev_nl) |nl| nl + 1 else 0;
        } else {
            const next_nl = std.mem.indexOfScalarPos(u8, txt, pos, '\n');
            self.text_cursor = next_nl orelse txt.len;
        }
        self.caret_phase = 0.0;
    }

    /// Moves `text_cursor` up (`delta_lines < 0`) or down (`delta_lines > 0`) in multiline `.textbox` nodes.
    pub fn moveTextCursorVertical(self: *UiTree, delta_lines: isize) void {
        const idx = self.focused_node orelse return;
        if (idx >= self.nodes.items.len or !self.nodes.items[idx].alive) return;
        const txt = self.nodes.items[idx].text;
        const pos = @min(self.text_cursor, txt.len);
        const cur_line_start = if (std.mem.lastIndexOfScalar(u8, txt[0..pos], '\n')) |nl| nl + 1 else 0;
        const col = pos - cur_line_start;
        if (delta_lines < 0) {
            if (cur_line_start == 0) {
                self.text_cursor = 0;
            } else {
                const prev_end = cur_line_start - 1;
                const prev_start = if (std.mem.lastIndexOfScalar(u8, txt[0..prev_end], '\n')) |nl| nl + 1 else 0;
                self.text_cursor = @min(prev_start + col, prev_end);
            }
        } else if (delta_lines > 0) {
            if (std.mem.indexOfScalarPos(u8, txt, pos, '\n')) |nl| {
                const next_start = nl + 1;
                const next_end = std.mem.indexOfScalarPos(u8, txt, next_start, '\n') orelse txt.len;
                self.text_cursor = @min(next_start + col, next_end);
            } else {
                self.text_cursor = txt.len;
            }
        }
        self.caret_phase = 0.0;
    }

    /// Adjusts `scroll_y` directly on node `idx`.
    pub fn scrollNode(self: *UiTree, idx: usize, delta_y: f32) void {
        if (idx >= self.nodes.items.len or !self.nodes.items[idx].alive) return;
        self.nodes.items[idx].scroll_y = @max(0.0, self.nodes.items[idx].scroll_y + delta_y);
    }

    /// Emits `graphics.DrawCommand`s for all visible nodes ordered by `UiLayer`.
    pub fn paint(self: *const UiTree, allocator: std.mem.Allocator, out_cmds: *std.ArrayList(graphics.DrawCommand)) !void {
        const layers = [3]UiLayer{ .base, .overlay, .modal };
        for (layers) |layer| {
            for (self.roots.items) |root_idx| {
                const root = &self.nodes.items[root_idx];
                if (!root.alive or !root.style.visible or root.style.layer != layer) continue;
                try self.paintNode(allocator, root_idx, out_cmds);
            }
        }
    }

    fn paintNode(self: *const UiTree, allocator: std.mem.Allocator, idx: usize, out_cmds: *std.ArrayList(graphics.DrawCommand)) !void {
        const node = &self.nodes.items[idx];
        if (!node.alive or !node.style.visible) return;

        const has_rounded_or_border = (node.style.corner_radii[0] > 0 or node.style.corner_radii[1] > 0 or
            node.style.corner_radii[2] > 0 or node.style.corner_radii[3] > 0 or
            node.style.border_widths[0] > 0 or node.style.border_widths[1] > 0 or
            node.style.border_widths[2] > 0 or node.style.border_widths[3] > 0);

        if (has_rounded_or_border) {
            try out_cmds.append(allocator, .{
                .rounded_rect = .{
                    .x = node.layout.x,
                    .y = node.layout.y,
                    .width = node.layout.width,
                    .height = node.layout.height,
                    .color = node.style.bg_color,
                    .border_color = node.style.border_color,
                    .border_widths = node.style.border_widths,
                    .corner_radii = node.style.corner_radii,
                },
            });
        } else if (node.style.bg_color.a > 0.0) {
            try out_cmds.append(allocator, .{
                .rect = .{
                    .x = node.layout.x,
                    .y = node.layout.y,
                    .width = node.layout.width,
                    .height = node.layout.height,
                    .color = node.style.bg_color,
                },
            });
        }

        switch (node.paint_extra) {
            .none => {},
            .gradient => |gr| {
                try out_cmds.append(allocator, .{
                    .gradient_rect = .{
                        .x = node.layout.x,
                        .y = node.layout.y,
                        .width = node.layout.width,
                        .height = node.layout.height,
                        .kind = gr.kind,
                        .stops = gr.stops,
                        .corner_radii = node.style.corner_radii,
                    },
                });
            },
            .color_wheel => |cw| {
                const sz = @min(node.layout.width, node.layout.height);
                try out_cmds.append(allocator, .{
                    .color_wheel = .{
                        .x = node.layout.x + (node.layout.width - sz) * 0.5,
                        .y = node.layout.y + (node.layout.height - sz) * 0.5,
                        .size = sz,
                        .hue_deg = cw.hue_deg,
                        .ring_width = cw.ring_width,
                    },
                });
            },
            .icon => |ic| {
                try out_cmds.append(allocator, .{
                    .icon = .{
                        .x = node.layout.x + (node.layout.width - ic.size) * 0.5,
                        .y = node.layout.y + (node.layout.height - ic.size) * 0.5,
                        .size = ic.size,
                        .kind = ic.kind,
                        .color = ic.color,
                    },
                });
            },
        }

        const clip_text = (node.kind == .textbox or node.scrollable) and (node.text.len > 0 or (node.kind == .textbox and node.focused));
        if (clip_text) {
            try out_cmds.append(allocator, .{
                .clip_push = .{
                    .x = node.layout.x,
                    .y = node.layout.y,
                    .width = node.layout.width,
                    .height = node.layout.height,
                },
            });
        }

        const s_txt = if (node.style.font_scale > 0.0) node.style.font_scale else 1.0;
        const line_h_txt = 8.0 * s_txt;
        const line_step_txt = line_h_txt * 1.25;
        var nl_count: usize = 0;
        for (node.text) |ch| {
            if (ch == '\n') nl_count += 1;
        }
        const total_txt_h = line_h_txt + @as(f32, @floatFromInt(nl_count)) * line_step_txt;
        const pad_txt = node.style.resolvedPadding();
        const inner_w_txt = @max(@as(f32, 0.0), node.layout.width - pad_txt.left - pad_txt.right);
        const inner_h_txt = @max(@as(f32, 0.0), node.layout.height - pad_txt.top - pad_txt.bottom);
        const auto_scroll_y: f32 = if (node.kind == .textbox and total_txt_h > inner_h_txt) total_txt_h - inner_h_txt else 0.0;
        const base_tx_y = if (node.kind == .textbox and nl_count > 0)
            node.layout.y + pad_txt.top - auto_scroll_y
        else
            node.layout.y + pad_txt.top + @max(@as(f32, 0.0), (inner_h_txt - total_txt_h) * 0.5);

        if (node.kind == .textbox and node.selected and node.text.len > 0) {
            var line_it = std.mem.splitScalar(u8, node.text, '\n');
            var li: usize = 0;
            while (line_it.next()) |line_str| : (li += 1) {
                if (line_str.len == 0) continue;
                const lw = self.measureTextWidth(line_str, s_txt);
                const lx = switch (node.style.text_align) {
                    .left => node.layout.x + pad_txt.left,
                    .center => node.layout.x + pad_txt.left + @max(@as(f32, 0.0), (inner_w_txt - lw) * 0.5),
                    .right => node.layout.x + pad_txt.left + @max(@as(f32, 0.0), inner_w_txt - lw),
                };
                const ly = base_tx_y + @as(f32, @floatFromInt(li)) * line_step_txt;
                try out_cmds.append(allocator, .{
                    .rect = .{
                        .x = lx,
                        .y = ly,
                        .width = @min(lw + 2.0, inner_w_txt),
                        .height = line_h_txt,
                        .color = .{ .r = 0.18, .g = 0.45, .b = 0.85, .a = 0.45 },
                    },
                });
            }
        }

        if (node.text.len > 0) {
            try out_cmds.append(allocator, .{
                .text = .{
                    .x = node.layout.x + pad_txt.left,
                    .y = base_tx_y,
                    .content = node.text,
                    .color = node.style.text_color,
                    .scale = node.style.font_scale,
                    .align_mode = switch (node.style.text_align) {
                        .left => .left,
                        .center => .center,
                        .right => .right,
                    },
                    .box_width = inner_w_txt,
                },
            });
        }

        // Draw blinking text caret at `self.text_cursor` for focused `.textbox` nodes.
        if (node.kind == .textbox and node.focused and !node.disabled and self.caret_phase < 0.55) {
            const cur_pos = @min(self.text_cursor, node.text.len);
            const prefix = node.text[0..cur_pos];
            var cur_line: usize = 0;
            for (prefix) |ch| {
                if (ch == '\n') cur_line += 1;
            }
            const last_nl = std.mem.lastIndexOfScalar(u8, prefix, '\n');
            const line_start = if (last_nl) |nl| nl + 1 else 0;
            const line_end = std.mem.indexOfScalarPos(u8, node.text, cur_pos, '\n') orelse node.text.len;
            const full_line = node.text[line_start..line_end];
            const tail = prefix[line_start..];
            const full_line_w = self.measureTextWidth(full_line, s_txt);
            const tail_w = self.measureTextWidth(tail, s_txt);
            const caret_pad: f32 = if (tail_w <= 0.01) -1.0 else 0.0;
            const caret_x = switch (node.style.text_align) {
                .left => node.layout.x + pad_txt.left + @min(tail_w + caret_pad, inner_w_txt),
                .center => node.layout.x + pad_txt.left + @max(@as(f32, 0.0), (inner_w_txt - full_line_w) * 0.5) + tail_w + caret_pad,
                .right => node.layout.x + pad_txt.left + @max(@as(f32, 0.0), inner_w_txt - full_line_w) + tail_w + caret_pad,
            };
            const caret_y = base_tx_y + @as(f32, @floatFromInt(cur_line)) * line_step_txt;
            try out_cmds.append(allocator, .{
                .rect = .{
                    .x = caret_x,
                    .y = caret_y,
                    .width = 1.5,
                    .height = line_h_txt,
                    .color = node.style.text_color,
                },
            });
        }

        if (clip_text) {
            try out_cmds.append(allocator, .{ .clip_pop = {} });
        }

        if (node.focused and node.focus_visible) {
            try out_cmds.append(allocator, .{
                .rounded_rect = .{
                    .x = node.layout.x - 1.0,
                    .y = node.layout.y - 1.0,
                    .width = node.layout.width + 2.0,
                    .height = node.layout.height + 2.0,
                    .color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                    .border_color = node.style.focus_ring_color,
                    .border_widths = .{ 2, 2, 2, 2 },
                    .corner_radii = node.style.corner_radii,
                },
            });
        }

        const clips = (node.style.clip_children or node.scrollable or node.kind == .virtual_list) and node.children.items.len > 0;
        if (clips) {
            try out_cmds.append(allocator, .{
                .clip_push = .{
                    .x = node.layout.x,
                    .y = node.layout.y,
                    .width = node.layout.width,
                    .height = node.layout.height,
                },
            });
        }
        for (node.children.items) |c_idx| {
            try self.paintNode(allocator, c_idx, out_cmds);
        }
        if (clips) {
            try out_cmds.append(allocator, .{ .clip_pop = {} });
        }
    }
};

fn buildModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    try app.resources.insert(UiTree, UiTree.init(app.allocator));
    const tree = app.resources.get(UiTree).?;

    try app.services.register(.{
        .capability = "engine.ui.tree",
        .major_version = 1,
        .provider_id = "official.ui.core",
        .owner_id = MODULE_OWNER_ID,
        .exclusive = true,
        .api_ptr = tree,
        .api_size = @sizeOf(UiTree),
    });
}

fn stopModule(raw_app: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    _ = app.services.unregisterByOwner(MODULE_OWNER_ID);
    _ = app.resources.remove(UiTree);
}

/// Returns the `official.ui.core` module descriptor.
pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = "official.ui.core",
            .version = "0.2.0",
            .provides_capabilities = &.{"engine.ui.tree/1"},
            .required_capabilities = &.{"engine.graphics.device/1"},
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
