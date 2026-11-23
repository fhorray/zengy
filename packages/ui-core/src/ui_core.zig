//! Optional Retained UI Core Package (`official.ui.core`).
//!
//! Provides `UiTree` (`engine.ui.tree/1`), a syntax-agnostic retained UI tree
//! decoupled from any HTML/CSS parser or scripting runtime.
//!
//! Pipeline:
//! `Frontend (Zig / HTML-like / NovaUI) -> UiTree -> layoutTree() -> paint() -> GraphicsDeviceService`
//!
//! Supports flex-like `column`/`row` layout, spatial `hitTest()`, focus tracking,
//! `ui.action` event emission, and deterministic `DrawCommand` generation.

const std = @import("std");
const engine = @import("engine");
const graphics = @import("graphics");

pub const MODULE_OWNER_ID: u64 = 2003;

pub const NodeKind = enum {
    panel,
    label,
    button,
    textbox,
    virtual_list,
};

pub const FlexDirection = enum {
    column,
    row,
};

pub const UiStyle = struct {
    direction: FlexDirection = .column,
    width: ?f32 = null,
    height: ?f32 = null,
    min_height: f32 = 24,
    padding: f32 = 8,
    gap: f32 = 4,
    bg_color: graphics.Color = .{ .r = 0.08, .g = 0.10, .b = 0.13 },
    text_color: graphics.Color = .{ .r = 0.90, .g = 0.92, .b = 0.94 },
};

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,

    pub fn contains(self: Rect, px: f32, py: f32) bool {
        return px >= self.x and px <= self.x + self.width and
            py >= self.y and py <= self.y + self.height;
    }
};

pub const UiNodeDescriptor = struct {
    id: []const u8,
    kind: NodeKind,
    text: []const u8 = "",
    action: []const u8 = "",
    style: UiStyle = .{},
};

pub const UiNode = struct {
    id: []const u8,
    kind: NodeKind,
    text: []const u8,
    action: []const u8,
    style: UiStyle,
    layout: Rect,
    children: std.ArrayList(usize),
    focused: bool,
};

pub const UiTree = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(UiNode),
    roots: std.ArrayList(usize),
    focused_node: ?usize,

    pub fn init(allocator: std.mem.Allocator) UiTree {
        return .{
            .allocator = allocator,
            .nodes = .empty,
            .roots = .empty,
            .focused_node = null,
        };
    }

    pub fn deinit(self: *UiTree) void {
        for (self.nodes.items) |*node| {
            self.allocator.free(node.id);
            self.allocator.free(node.text);
            self.allocator.free(node.action);
            node.children.deinit(self.allocator);
        }
        self.nodes.deinit(self.allocator);
        self.roots.deinit(self.allocator);
    }

    pub fn clear(self: *UiTree) void {
        for (self.nodes.items) |*node| {
            self.allocator.free(node.id);
            self.allocator.free(node.text);
            self.allocator.free(node.action);
            node.children.deinit(self.allocator);
        }
        self.nodes.clearRetainingCapacity();
        self.roots.clearRetainingCapacity();
        self.focused_node = null;
    }

    pub fn createNode(self: *UiTree, parent_idx: ?usize, desc: UiNodeDescriptor) !usize {
        const id_copy = try self.allocator.dupe(u8, desc.id);
        errdefer self.allocator.free(id_copy);
        const text_copy = try self.allocator.dupe(u8, desc.text);
        errdefer self.allocator.free(text_copy);
        const action_copy = try self.allocator.dupe(u8, desc.action);
        errdefer self.allocator.free(action_copy);

        if (parent_idx) |p| {
            try self.nodes.items[p].children.ensureUnusedCapacity(self.allocator, 1);
        } else {
            try self.roots.ensureUnusedCapacity(self.allocator, 1);
        }
        try self.nodes.ensureUnusedCapacity(self.allocator, 1);

        const idx = self.nodes.items.len;
        self.nodes.appendAssumeCapacity(.{
            .id = id_copy,
            .kind = desc.kind,
            .text = text_copy,
            .action = action_copy,
            .style = desc.style,
            .layout = .{},
            .children = .empty,
            .focused = false,
        });

        if (parent_idx) |p| {
            self.nodes.items[p].children.appendAssumeCapacity(idx);
        } else {
            self.roots.appendAssumeCapacity(idx);
        }
        return idx;
    }

    pub fn findById(self: *const UiTree, id: []const u8) ?usize {
        for (self.nodes.items, 0..) |node, i| {
            if (std.mem.eql(u8, node.id, id)) return i;
        }
        return null;
    }

    pub fn nodeCount(self: *const UiTree) usize {
        return self.nodes.items.len;
    }

    pub fn layoutTree(self: *UiTree, viewport_width: f32, viewport_height: f32) void {
        var y_cursor: f32 = 0;
        for (self.roots.items) |root_idx| {
            self.layoutNode(root_idx, 0, y_cursor, viewport_width, viewport_height);
            y_cursor += self.nodes.items[root_idx].layout.height;
        }
    }

    fn layoutNode(self: *UiTree, idx: usize, x: f32, y: f32, avail_w: f32, avail_h: f32) void {
        const node = &self.nodes.items[idx];
        const w = node.style.width orelse avail_w;
        const pad = node.style.padding;
        const gap = node.style.gap;
        const dir = node.style.direction;
        const min_h = node.style.min_height;

        var child_x = x + pad;
        var child_y = y + pad;
        const inner_w = @max(0, w - pad * 2);
        const inner_h = @max(0, avail_h - pad * 2);

        const child_count = node.children.items.len;
        var max_child_bottom: f32 = child_y;

        for (node.children.items, 0..) |c_idx, ci| {
            const slot_w = if (dir == .row and child_count > 0)
                @max(0, (inner_w - gap * @as(f32, @floatFromInt(child_count - 1))) / @as(f32, @floatFromInt(child_count)))
            else
                inner_w;

            self.layoutNode(c_idx, child_x, child_y, slot_w, inner_h);
            const c_rect = self.nodes.items[c_idx].layout;

            if (c_rect.y + c_rect.height > max_child_bottom) {
                max_child_bottom = c_rect.y + c_rect.height;
            }
            if (ci + 1 < child_count) {
                if (dir == .column) {
                    child_y += c_rect.height + gap;
                } else {
                    child_x += slot_w + gap;
                }
            }
        }

        const content_h = (max_child_bottom - y) + pad;
        const computed_h = node.style.height orelse @max(min_h, content_h);
        self.nodes.items[idx].layout = .{
            .x = x,
            .y = y,
            .width = w,
            .height = computed_h,
        };
    }

    pub fn hitTest(self: *const UiTree, px: f32, py: f32) ?usize {
        var i = self.roots.items.len;
        while (i > 0) {
            i -= 1;
            if (self.hitTestNode(self.roots.items[i], px, py)) |hit| {
                return hit;
            }
        }
        return null;
    }

    fn hitTestNode(self: *const UiTree, idx: usize, px: f32, py: f32) ?usize {
        const node = &self.nodes.items[idx];
        if (!node.layout.contains(px, py)) return null;

        var i = node.children.items.len;
        while (i > 0) {
            i -= 1;
            if (self.hitTestNode(node.children.items[i], px, py)) |child_hit| {
                return child_hit;
            }
        }
        return idx;
    }

    pub fn handlePointerClick(self: *UiTree, px: f32, py: f32, events: *engine.EventBus) ?usize {
        const hit = self.hitTest(px, py) orelse return null;

        if (self.focused_node) |prev| {
            if (prev < self.nodes.items.len) {
                self.nodes.items[prev].focused = false;
            }
        }
        self.focused_node = hit;
        self.nodes.items[hit].focused = true;

        const action = self.nodes.items[hit].action;
        if (action.len > 0) {
            events.post(.{
                .name = "ui.action",
                .payload = action,
                .entity_handle = @intCast(hit),
            }) catch {};
        }
        return hit;
    }

    pub fn paint(self: *const UiTree, allocator: std.mem.Allocator, out_cmds: *std.ArrayList(graphics.DrawCommand)) !void {
        for (self.roots.items) |root_idx| {
            try self.paintNode(allocator, root_idx, out_cmds);
        }
    }

    fn paintNode(self: *const UiTree, allocator: std.mem.Allocator, idx: usize, out_cmds: *std.ArrayList(graphics.DrawCommand)) !void {
        const node = &self.nodes.items[idx];
        try out_cmds.append(allocator, .{
            .rect = .{
                .x = node.layout.x,
                .y = node.layout.y,
                .width = node.layout.width,
                .height = node.layout.height,
                .color = node.style.bg_color,
            },
        });
        if (node.text.len > 0) {
            try out_cmds.append(allocator, .{
                .text = .{
                    .x = node.layout.x + node.style.padding,
                    .y = node.layout.y + node.style.padding,
                    .content = node.text,
                    .color = node.style.text_color,
                },
            });
        }
        for (node.children.items) |c_idx| {
            try self.paintNode(allocator, c_idx, out_cmds);
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
    if (app.resources.get(UiTree)) |tree| {
        tree.deinit();
        _ = app.resources.remove(UiTree);
    }
}

pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = "official.ui.core",
            .version = "0.1.0",
            .provides_capabilities = &.{"engine.ui.tree/1"},
            .required_capabilities = &.{"engine.graphics.device/1"},
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
