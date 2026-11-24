//! Headless UI Widget Behaviors (`official.ui.widgets`).
//!
//! Implements backend-neutral, styling-free widget state machines and input
//! routing on top of `ui_core.UiTree` and `window.InputService`.
//! Provides `engine.ui.widgets/1` service and `WidgetEventQueue`.

const std = @import("std");
const engine = @import("engine");
const window = @import("window");
const graphics = @import("graphics");
const ui_core = @import("ui_core");

pub const color = @import("color.zig");
pub const events = @import("events.zig");
pub const text_edit = @import("text_edit.zig");

pub const MODULE_OWNER_ID: u64 = 2014;

/// Discriminated headless widget behavior attached to a `UiNodeId`.
pub const BehaviorKind = union(enum) {
    button: struct {
        activate_on_press: bool = false,
    },
    checkbox: struct {
        checked: bool = false,
        fast_click: bool = false,
        auto_update: bool = true,
    },
    radio: struct {
        group_id: u32,
        checked: bool = false,
        fast_click: bool = false,
        auto_update: bool = true,
    },
    disclosure: struct {
        expanded: bool = false,
        target_body: ?ui_core.UiNodeId = null,
        auto_update: bool = true,
    },
    slider: struct {
        value: f64 = 0,
        range: events.NumericRange = .{ .min = 0, .max = 1 },
        step: f64 = 0,
        orientation: events.ControlOrientation = .horizontal,
        track_click: events.TrackClick = .drag,
        thumb_node: ?ui_core.UiNodeId = null,
        auto_update: bool = true,
        dragging: bool = false,
    },
    number_input: struct {
        value: events.NumericValue = .{ .f32 = 0 },
        range: events.NumericRange = .{},
        step: f64 = 0.1,
        precision: u8 = 3,
        mode: enum { idle, dragging, editing } = .idle,
        drag_accum_px: f32 = 0,
        drag_start_val: f64 = 0,
        drag_val: f64 = 0,
        edit: text_edit.TextEditState = .{},
        auto_update: bool = true,
    },
    text_input: struct {
        max_len: usize = 256,
        hex_only: bool = false,
        numeric_only: bool = false,
        multiline: bool = false,
        edit: text_edit.TextEditState = .{},
    },
    scrollbar: struct {
        target_scroll: ui_core.UiNodeId,
        thumb_node: ?ui_core.UiNodeId = null,
        orientation: events.ControlOrientation = .vertical,
        dragging: bool = false,
        drag_offset: f32 = 0,
    },
    listbox: struct {
        selected_index: ?usize = null,
        auto_update: bool = true,
    },
    list_item: struct {
        listbox_node: ui_core.UiNodeId,
        index: usize,
    },
    popover: struct {
        anchor: ui_core.UiNodeId,
        anchor_point: ?[2]f32 = null,
        context_target: ?ui_core.UiNodeId = null,
        placement: events.PopoverPlacement = .{},
        open: bool = false,
        dismiss_on_outside: bool = true,
        match_anchor_width: bool = false,
        window_margin: f32 = 6.0,
    },
    menu_trigger: struct {
        popup_node: ui_core.UiNodeId,
        menubar_group: u32 = 0,
    },
    menu_item: struct {
        popup_node: ui_core.UiNodeId,
        select_trigger: ?ui_core.UiNodeId = null,
    },
    tooltip: struct {
        target_node: ui_core.UiNodeId,
        delay_ms: f32 = 350.0,
        hover_ms: f32 = 0.0,
        open: bool = false,
    },
    range_slider: struct {
        min_val: f64 = 0.2,
        max_val: f64 = 0.8,
        range: events.NumericRange = .{ .min = 0, .max = 1 },
        step: f64 = 0,
        min_thumb: ?ui_core.UiNodeId = null,
        max_thumb: ?ui_core.UiNodeId = null,
        fill_node: ?ui_core.UiNodeId = null,
        active_thumb: enum { none, min, max } = .none,
        auto_update: bool = true,
    },
    keybind_input: struct {
        listening: bool = false,
        key: ?u8 = null,
        mods: window.KeyModifiers = .{},
        label_buf: [48]u8 = @splat(0),
        label_len: usize = 0,
    },
    color_plane: struct {
        x_val: f32 = 0.5,
        y_val: f32 = 0.5,
        thumb_node: ?ui_core.UiNodeId = null,
        dragging: bool = false,
    },
    color_wheel: struct {
        hue_deg: f32 = 0,
        whiteness: f32 = 0,
        blackness: f32 = 0,
        ring_width: f32 = 12.0,
        ring_thumb: ?ui_core.UiNodeId = null,
        tri_thumb: ?ui_core.UiNodeId = null,
        drag_part: enum { none, ring, triangle } = .none,
    },
    number_stepper: struct {
        target_input: ui_core.UiNodeId,
        dir: i8,
    },
    tabs: struct {
        active_tab: usize = 0,
        auto_update: bool = true,
    },
};

/// Bound headless widget record stored in `WidgetManager`.
pub const WidgetBinding = struct {
    node: ui_core.UiNodeId,
    tag: []const u8,
    behavior: BehaviorKind,
};

/// Central headless widget runtime managing interactions, popovers, and events.
pub const WidgetManager = struct {
    allocator: std.mem.Allocator,
    bindings: std.ArrayList(WidgetBinding) = .empty,
    /// Node id -> index into `bindings` so `attach`/`findByNode` are O(1) instead of O(n).
    node_index: std.AutoHashMapUnmanaged(ui_core.UiNodeId, u32) = .empty,
    event_queue: events.WidgetEventQueue,
    undo_history: text_edit.UndoHistory = .{},
    last_edit_consumed_undo: bool = false,

    /// Initializes `WidgetManager`.
    pub fn init(allocator: std.mem.Allocator) WidgetManager {
        return .{
            .allocator = allocator,
            .event_queue = events.WidgetEventQueue.init(allocator),
        };
    }

    /// Frees all bindings and event buffers.
    pub fn deinit(self: *WidgetManager) void {
        for (self.bindings.items) |b| {
            if (b.tag.len > 0) self.allocator.free(b.tag);
        }
        self.bindings.deinit(self.allocator);
        self.node_index.deinit(self.allocator);
        self.event_queue.deinit();
    }

    /// Removes all registered widget bindings.
    pub fn clear(self: *WidgetManager) void {
        for (self.bindings.items) |b| {
            if (b.tag.len > 0) self.allocator.free(b.tag);
        }
        self.bindings.clearRetainingCapacity();
        self.node_index.clearRetainingCapacity();
        self.event_queue.clear();
    }

    /// Registers a headless behavior on `node` with an optional string `tag`.
    pub fn attach(self: *WidgetManager, node: ui_core.UiNodeId, tag: []const u8, behavior: BehaviorKind) !usize {
        const tag_copy = if (tag.len > 0) try self.allocator.dupe(u8, tag) else &.{};
        errdefer if (tag_copy.len > 0) self.allocator.free(tag_copy);

        // Replace existing binding on the same node if present.
        if (self.node_index.get(node)) |i| {
            const b = &self.bindings.items[i];
            if (b.tag.len > 0) self.allocator.free(b.tag);
            b.* = .{ .node = node, .tag = tag_copy, .behavior = behavior };
            return i;
        }
        const idx = self.bindings.items.len;
        // Reserve the index entry first so a failed append cannot leave a dangling map entry.
        try self.node_index.ensureUnusedCapacity(self.allocator, 1);
        try self.bindings.append(self.allocator, .{
            .node = node,
            .tag = tag_copy,
            .behavior = behavior,
        });
        self.node_index.putAssumeCapacity(node, @intCast(idx));
        return idx;
    }

    /// Finds the mutable binding for `node`, if any.
    pub fn findByNode(self: *WidgetManager, node: ui_core.UiNodeId) ?*WidgetBinding {
        const i = self.node_index.get(node) orelse return null;
        return &self.bindings.items[i];
    }

    /// Finds the mutable binding by `tag`, if any.
    pub fn findByTag(self: *WidgetManager, tag: []const u8) ?*WidgetBinding {
        for (self.bindings.items) |*b| {
            if (std.mem.eql(u8, b.tag, tag)) return b;
        }
        return null;
    }

    /// Returns the slice of events emitted during the last `processFrame`.
    pub fn eventsSlice(self: *const WidgetManager) []const events.WidgetEvent {
        return self.event_queue.items.items;
    }

    /// Runs one headless interaction & layout-sync pass over `tree` using a default ~60fps frame delta.
    pub fn processFrame(
        self: *WidgetManager,
        tree: *ui_core.UiTree,
        input: *window.InputService,
        win_svc: ?*window.WindowService,
        viewport_w: f32,
        viewport_h: f32,
    ) !void {
        return self.processFrameWithDt(tree, input, win_svc, viewport_w, viewport_h, 16.6667);
    }

    /// Runs one headless interaction & layout-sync pass over `tree` with explicit frame delta `dt_ms`.
    pub fn processFrameWithDt(
        self: *WidgetManager,
        tree: *ui_core.UiTree,
        input: *window.InputService,
        win_svc: ?*window.WindowService,
        viewport_w: f32,
        viewport_h: f32,
        dt_ms: f32,
    ) !void {
        self.event_queue.clear();

        const down = input.isMouseDown(.left);
        const clicked = input.wasMouseClicked(.left);
        const released = input.wasMouseReleased(.left);

        const active_before_release = tree.pointer_capture_node;
        const hit_opt = tree.hitTest(input.mouse_x, input.mouse_y);
        _ = tree.updatePointer(input.mouse_x, input.mouse_y, down, clicked, released);

        // Apply cursor hint from captured or hovered node.
        const cursor_idx = tree.pointer_capture_node orelse tree.hovered_node;
        if (cursor_idx) |ci| {
            if (ci < tree.nodes.items.len and tree.nodes.items[ci].alive) {
                const hint = tree.nodes.items[ci].cursor;
                input.setRequestedCursor(switch (hint) {
                    .default => .default,
                    .pointer => .pointer,
                    .text => .text,
                    .ew_resize => .ew_resize,
                    .ns_resize => .ns_resize,
                    .grab => .grab,
                    .crosshair => .crosshair,
                });
            }
        }

        // Keyboard Tab navigation.
        if (input.wasKeyPressed(window.KeyCode.tab)) {
            const prev_focus = tree.focused_node;
            _ = tree.focusNext(input.modifiers.shift);
            if (prev_focus) |pf| {
                if (tree.focused_node != pf) {
                    self.clearFocusedEditState(tree, pf);
                }
            }
        }

        // Scroll wheel over scrollable containers.
        if (@abs(input.scroll_y) > 0.001) {
            _ = tree.handleScroll(input.mouse_x, input.mouse_y, input.scroll_y);
        }

        // Dismiss open popovers on Escape or outside click.
        if (input.wasKeyPressed(window.KeyCode.escape) or clicked) {
            try self.handlePopoverDismiss(tree, hit_opt, input.wasKeyPressed(window.KeyCode.escape));
        }

        // Right-click opens matching context menu triggers at the pointer position.
        if (input.wasMouseClicked(.right)) {
            if (hit_opt) |h_idx| {
                self.handleContextMenuOpen(tree, h_idx, input.mouse_x, input.mouse_y);
            }
        }

        // Menubar hover-switching: if a menu in a menubar_group is open, hovering another opens it.
        if (hit_opt) |h_idx| {
            self.handleMenubarHover(tree, h_idx);
        }

        // Handle pointer click / release / drag across bindings.
        if (clicked) {
            const prev_focus = tree.focused_node;
            if (hit_opt) |h_idx| {
                if (!tree.nodes.items[h_idx].disabled) {
                    tree.setFocus(h_idx, false);
                }
                if (prev_focus != null and prev_focus != h_idx) {
                    self.clearFocusedEditState(tree, prev_focus.?);
                }
                if (tree.idOf(h_idx)) |hid| {
                    try self.onPointerDown(tree, hid, input);
                }
            } else if (prev_focus) |pf| {
                self.clearFocusedEditState(tree, pf);
            }
        }

        if (down and !clicked) {
            if (tree.pointer_capture_node) |cap_idx| {
                if (tree.idOf(cap_idx)) |cid| {
                    try self.onPointerDrag(tree, cid, input);
                }
            }
        }

        if (released) {
            const rel_target = active_before_release orelse hit_opt;
            if (rel_target) |r_idx| {
                if (tree.idOf(r_idx)) |rid| {
                    try self.onPointerRelease(tree, rid, hit_opt == r_idx);
                }
            }
        }

        // Route keyboard & text input to focused widget.
        self.last_edit_consumed_undo = false;
        if (tree.focused_node) |f_idx| {
            if (f_idx < tree.nodes.items.len and tree.nodes.items[f_idx].alive and !tree.nodes.items[f_idx].disabled) {
                if (tree.idOf(f_idx)) |fid| {
                    try self.onFocusedInput(tree, fid, input, win_svc);
                }
            }
        }

        // Global editor/widget Undo (Ctrl+Z) and Redo (Ctrl+Y / Ctrl+Shift+Z) when not consumed by active text edit.
        if (!self.last_edit_consumed_undo and input.modifiers.ctrl) {
            if (!input.modifiers.shift and input.wasKeyPressed(window.KeyCode.z)) {
                try self.applyGlobalUndo(tree);
            } else if (input.wasKeyPressed(window.KeyCode.y) or (input.modifiers.shift and input.wasKeyPressed(window.KeyCode.z))) {
                try self.applyGlobalRedo(tree);
            }
        }

        // Update popovers, tooltips, and scrollbars geometry after state updates.
        self.syncTooltips(tree, dt_ms, down, viewport_w, viewport_h);
        self.syncPopovers(tree, viewport_w, viewport_h);
        self.syncScrollbars(tree);
    }

    fn findBindingForAncestors(self: *WidgetManager, tree: *const ui_core.UiTree, start_node: ui_core.UiNodeId) ?*WidgetBinding {
        var cur_idx = tree.resolveId(start_node);
        while (cur_idx) |idx| {
            if (tree.idOf(idx)) |nid| {
                if (self.findByNode(nid)) |b| return b;
            }
            cur_idx = tree.nodes.items[idx].parent;
        }
        return null;
    }

    fn handlePopoverDismiss(self: *WidgetManager, tree: *ui_core.UiTree, hit_opt: ?usize, esc_pressed: bool) !void {
        for (self.bindings.items) |*b| {
            switch (b.behavior) {
                .popover => |*pop| {
                    if (!pop.open) continue;
                    const p_idx = tree.resolveId(b.node) orelse continue;
                    var should_close = esc_pressed;
                    if (!should_close and pop.dismiss_on_outside) {
                        const hit_inside = if (hit_opt) |hi|
                            isDescendantOrSelf(tree, hi, p_idx) or
                                (if (tree.resolveId(pop.anchor)) |ai| isDescendantOrSelf(tree, hi, ai) else false)
                        else
                            false;
                        if (!hit_inside) should_close = true;
                    }
                    if (should_close) {
                        pop.open = false;
                        tree.nodes.items[p_idx].style.visible = false;
                        try self.event_queue.push(.{
                            .node = b.node,
                            .tag = b.tag,
                            .payload = .{ .close_requested = {} },
                        });
                    }
                },
                else => {},
            }
        }
    }

    fn clearFocusedEditState(self: *WidgetManager, tree: *ui_core.UiTree, node_idx: usize) void {
        const nid = tree.idOf(node_idx) orelse return;
        const b = self.findByNode(nid) orelse return;
        switch (b.behavior) {
            .number_input => self.commitEditingNumberInput(tree, node_idx),
            .text_input => |*ti| ti.edit.clearSelection(tree, node_idx),
            else => {},
        }
    }

    fn commitEditingNumberInput(self: *WidgetManager, tree: *ui_core.UiTree, node_idx: usize) void {
        const nid = tree.idOf(node_idx) orelse return;
        const b = self.findByNode(nid) orelse return;
        if (b.behavior != .number_input) return;
        var ni = &b.behavior.number_input;
        if (ni.mode != .editing) return;
        const parsed = std.fmt.parseFloat(f64, tree.nodes.items[node_idx].text) catch ni.value.asF64();
        const clamped = ni.range.clamp(parsed);
        ni.value = events.NumericValue.fromF64(ni.value, clamped);
        ni.mode = .idle;
        tree.nodes.items[node_idx].kind = .custom;
        ni.edit.clearSelection(tree, node_idx);
    }

    fn isDescendantOrSelf(tree: *const ui_core.UiTree, node_idx: usize, ancestor_idx: usize) bool {
        var cur: ?usize = node_idx;
        while (cur) |idx| {
            if (idx == ancestor_idx) return true;
            if (idx >= tree.nodes.items.len) break;
            cur = tree.nodes.items[idx].parent;
        }
        return false;
    }

    fn onPointerDown(self: *WidgetManager, tree: *ui_core.UiTree, hit_id: ui_core.UiNodeId, input: *const window.InputService) !void {
        const b = self.findBindingForAncestors(tree, hit_id) orelse return;
        const idx = tree.resolveId(b.node) orelse return;
        if (tree.nodes.items[idx].disabled) return;

        switch (b.behavior) {
            .button => |btn| {
                if (btn.activate_on_press) {
                    try self.event_queue.push(.{ .node = b.node, .tag = b.tag, .payload = .{ .activate = {} } });
                }
            },
            .checkbox => |*cb| {
                if (cb.fast_click) {
                    const next = !cb.checked;
                    if (cb.auto_update) {
                        cb.checked = next;
                        tree.nodes.items[idx].checked = next;
                    }
                    try self.event_queue.push(.{ .node = b.node, .tag = b.tag, .payload = .{ .value_bool = next } });
                }
            },
            .radio => |*rd| {
                if (rd.fast_click) {
                    try self.selectRadio(tree, b, rd, idx);
                }
            },
            .disclosure => |*disc| {
                const next = !disc.expanded;
                if (disc.auto_update) {
                    disc.expanded = next;
                    tree.nodes.items[idx].expanded = next;
                    if (disc.target_body) |body_id| {
                        if (tree.resolveId(body_id)) |bi| tree.nodes.items[bi].style.visible = next;
                    }
                }
                try self.event_queue.push(.{ .node = b.node, .tag = b.tag, .payload = .{ .expanded = next } });
            },
            .slider => |*sl| {
                sl.dragging = true;
                tree.pointer_capture_node = idx;
                try self.updateSliderFromPointer(tree, b.node, b.tag, sl, idx, input.mouse_x, input.mouse_y, false);
            },
            .number_input => |*ni| {
                ni.drag_accum_px = 0;
                ni.drag_start_val = ni.value.asF64();
                ni.drag_val = ni.drag_start_val;
                if (ni.mode != .editing) {
                    ni.mode = .dragging;
                    tree.pointer_capture_node = idx;
                }
            },
            .scrollbar => |*sb| {
                sb.dragging = true;
                tree.pointer_capture_node = idx;
                self.updateScrollbarFromPointer(tree, sb, idx, input.mouse_x, input.mouse_y);
            },
            .list_item => |li| {
                if (self.findByNode(li.listbox_node)) |lb_bind| {
                    if (lb_bind.behavior == .listbox) {
                        if (lb_bind.behavior.listbox.auto_update) {
                            lb_bind.behavior.listbox.selected_index = li.index;
                            self.syncListboxSelection(tree, li.listbox_node, li.index);
                        }
                        try self.event_queue.push(.{ .node = li.listbox_node, .tag = lb_bind.tag, .payload = .{ .value_index = li.index } });
                    }
                }
            },
            .menu_trigger => |mt| {
                if (mt.menubar_group > 0) {
                    self.closeMenubarGroupExcept(tree, mt.menubar_group, b.node);
                }
                if (self.findByNode(mt.popup_node)) |pop_b| {
                    if (pop_b.behavior == .popover) {
                        const next = !pop_b.behavior.popover.open;
                        pop_b.behavior.popover.open = next;
                        pop_b.behavior.popover.anchor_point = null;
                        if (tree.resolveId(mt.popup_node)) |pi| tree.nodes.items[pi].style.visible = next;
                    }
                }
            },
            .range_slider => |*rs| {
                const rect = tree.nodes.items[idx].layout;
                const w = @max(@as(f32, 1.0), rect.width);
                const t_ptr = std.math.clamp((input.mouse_x - rect.x) / w, 0.0, 1.0);
                const span = @max(@as(f64, 1e-6), rs.range.max - rs.range.min);
                const min_t: f32 = @floatCast(std.math.clamp((rs.min_val - rs.range.min) / span, 0.0, 1.0));
                const max_t: f32 = @floatCast(std.math.clamp((rs.max_val - rs.range.min) / span, 0.0, 1.0));
                rs.active_thumb = if (@abs(t_ptr - min_t) <= @abs(t_ptr - max_t)) .min else .max;
                tree.pointer_capture_node = idx;
                try self.updateRangeSliderFromPointer(tree, b.node, b.tag, rs, idx, input.mouse_x, false);
            },
            .keybind_input => |*kb| {
                kb.listening = !kb.listening;
                if (kb.listening) {
                    try tree.setNodeText(idx, "Press a key...");
                } else {
                    try self.applyKeybindLabel(tree, idx, kb);
                }
            },
            .menu_item => |mi| {
                if (mi.select_trigger) |st_id| {
                    if (tree.resolveId(st_id)) |ti| {
                        try tree.setNodeText(ti, tree.nodes.items[idx].text);
                    }
                }
                try self.event_queue.push(.{ .node = b.node, .tag = b.tag, .payload = .{ .activate = {} } });
                if (self.findByNode(mi.popup_node)) |pop_b| {
                    if (pop_b.behavior == .popover) {
                        pop_b.behavior.popover.open = false;
                        if (tree.resolveId(mi.popup_node)) |pi| tree.nodes.items[pi].style.visible = false;
                    }
                }
            },
            .color_plane => |*cp| {
                cp.dragging = true;
                tree.pointer_capture_node = idx;
                try self.updateColorPlaneFromPointer(tree, b.node, b.tag, cp, idx, input.mouse_x, input.mouse_y, false);
            },
            .color_wheel => |*cw| {
                const rect = tree.nodes.items[idx].layout;
                const sz = @min(rect.width, rect.height);
                const cx = rect.x + rect.width * 0.5;
                const cy = rect.y + rect.height * 0.5;
                const dx = input.mouse_x - cx;
                const dy = input.mouse_y - cy;
                const dist = @sqrt(dx * dx + dy * dy);
                const outer_r = sz * 0.5;
                const inner_r = @max(@as(f32, 2.0), outer_r - cw.ring_width);
                cw.drag_part = if (dist >= inner_r - 2.0) .ring else .triangle;
                tree.pointer_capture_node = idx;
                try self.updateColorWheelFromPointer(tree, b.node, b.tag, cw, idx, input.mouse_x, input.mouse_y, false);
            },
            .number_stepper => |st_b| {
                if (self.findByNode(st_b.target_input)) |ni_b| {
                    if (ni_b.behavior == .number_input) {
                        var ni = &ni_b.behavior.number_input;
                        const delta_unit: f64 = switch (ni.value) {
                            .i32, .i64 => 1.0,
                            .f32, .f64 => @max(ni.step, 0.1),
                        };
                        const next_f = ni.range.clamp(ni.value.asF64() + @as(f64, @floatFromInt(st_b.dir)) * delta_unit);
                        ni.value = events.NumericValue.fromF64(ni.value, next_f);
                        try self.event_queue.push(.{
                            .node = st_b.target_input,
                            .tag = ni_b.tag,
                            .is_final = true,
                            .payload = .{ .value_numeric = ni.value },
                        });
                    }
                }
            },
            .tabs => |*tb| {
                _ = tb;
                try self.event_queue.push(.{ .node = b.node, .tag = b.tag, .payload = .{ .activate = {} } });
            },
            .text_input => |*ti| {
                ti.edit.clearSelection(tree, idx);
            },
            else => {},
        }
    }

    fn onPointerDrag(self: *WidgetManager, tree: *ui_core.UiTree, cap_id: ui_core.UiNodeId, input: *const window.InputService) !void {
        const b = self.findByNode(cap_id) orelse return;
        const idx = tree.resolveId(b.node) orelse return;
        if (tree.nodes.items[idx].disabled) return;

        switch (b.behavior) {
            .slider => |*sl| {
                if (sl.dragging) {
                    try self.updateSliderFromPointer(tree, b.node, b.tag, sl, idx, input.mouse_x, input.mouse_y, false);
                }
            },
            .number_input => |*ni| {
                if (ni.mode == .dragging and @abs(input.mouse_delta_x) > 0.0) {
                    ni.drag_accum_px += @abs(input.mouse_delta_x);
                    const mult: f64 = if (input.modifiers.shift) 0.1 else if (input.modifiers.ctrl) 5.0 else 1.0;
                    const base_step: f64 = switch (ni.value) {
                        .i32, .i64 => @max(ni.step, 0.5),
                        .f32, .f64 => @max(ni.step, 0.1),
                    };
                    const delta = @as(f64, input.mouse_delta_x) * base_step * mult;
                    ni.drag_val = ni.range.clamp(ni.drag_val + delta);
                    const next_typed = events.NumericValue.fromF64(ni.value, ni.drag_val);
                    if (ni.auto_update) {
                        ni.value = next_typed;
                    }
                    try self.event_queue.push(.{
                        .node = b.node,
                        .tag = b.tag,
                        .is_final = false,
                        .payload = .{ .value_numeric = next_typed },
                    });
                }
            },
            .scrollbar => |*sb| {
                if (sb.dragging) {
                    self.updateScrollbarFromPointer(tree, sb, idx, input.mouse_x, input.mouse_y);
                }
            },
            .color_plane => |*cp| {
                if (cp.dragging) {
                    try self.updateColorPlaneFromPointer(tree, b.node, b.tag, cp, idx, input.mouse_x, input.mouse_y, false);
                }
            },
            .color_wheel => |*cw| {
                if (cw.drag_part != .none) {
                    try self.updateColorWheelFromPointer(tree, b.node, b.tag, cw, idx, input.mouse_x, input.mouse_y, false);
                }
            },
            .range_slider => |*rs| {
                if (rs.active_thumb != .none) {
                    try self.updateRangeSliderFromPointer(tree, b.node, b.tag, rs, idx, input.mouse_x, false);
                }
            },
            else => {},
        }
    }

    fn onPointerRelease(self: *WidgetManager, tree: *ui_core.UiTree, rel_id: ui_core.UiNodeId, inside_on_release: bool) !void {
        const b = self.findBindingForAncestors(tree, rel_id) orelse return;
        const idx = tree.resolveId(b.node) orelse return;
        if (tree.nodes.items[idx].disabled) return;

        switch (b.behavior) {
            .button => |btn| {
                if (!btn.activate_on_press and inside_on_release) {
                    try self.event_queue.push(.{ .node = b.node, .tag = b.tag, .payload = .{ .activate = {} } });
                }
            },
            .checkbox => |*cb| {
                if (!cb.fast_click and inside_on_release) {
                    const prev = cb.checked;
                    const next = !prev;
                    if (cb.auto_update) {
                        cb.checked = next;
                        tree.nodes.items[idx].checked = next;
                        self.undo_history.push(.{ .widget_bool = .{ .node = b.node, .prev = prev, .next = next } });
                    }
                    try self.event_queue.push(.{ .node = b.node, .tag = b.tag, .payload = .{ .value_bool = next } });
                }
            },
            .radio => |*rd| {
                if (!rd.fast_click and inside_on_release) {
                    try self.selectRadio(tree, b, rd, idx);
                }
            },
            .slider => |*sl| {
                if (sl.dragging) {
                    sl.dragging = false;
                    try self.event_queue.push(.{ .node = b.node, .tag = b.tag, .is_final = true, .payload = .{ .value_f64 = sl.value } });
                }
            },
            .number_input => |*ni| {
                if (ni.mode == .dragging) {
                    if (ni.drag_accum_px < 2.0 and inside_on_release) {
                        ni.mode = .editing;
                        tree.nodes.items[idx].kind = .textbox;
                        tree.setFocus(idx, false);
                    } else {
                        ni.mode = .idle;
                        const prev_v = events.NumericValue.fromF64(ni.value, ni.drag_start_val);
                        if (@abs(ni.value.asF64() - ni.drag_start_val) > 1e-6) {
                            self.undo_history.push(.{ .widget_numeric = .{ .node = b.node, .prev = prev_v, .next = ni.value } });
                        }
                        try self.event_queue.push(.{
                            .node = b.node,
                            .tag = b.tag,
                            .is_final = true,
                            .payload = .{ .value_numeric = ni.value },
                        });
                    }
                }
            },
            .scrollbar => |*sb| sb.dragging = false,
            .color_plane => |*cp| {
                if (cp.dragging) {
                    cp.dragging = false;
                    try self.event_queue.push(.{ .node = b.node, .tag = b.tag, .is_final = true, .payload = .{ .value_vec2 = .{ cp.x_val, cp.y_val } } });
                }
            },
            .color_wheel => |*cw| {
                if (cw.drag_part != .none) {
                    cw.drag_part = .none;
                    const col = color.hwbaToSrgba(.{ .h = cw.hue_deg, .w = cw.whiteness, .b = cw.blackness, .a = 1.0 });
                    try self.event_queue.push(.{ .node = b.node, .tag = b.tag, .is_final = true, .payload = .{ .value_color = col } });
                }
            },
            .range_slider => |*rs| {
                if (rs.active_thumb != .none) {
                    rs.active_thumb = .none;
                    try self.event_queue.push(.{
                        .node = b.node,
                        .tag = b.tag,
                        .is_final = true,
                        .payload = .{ .value_vec2 = .{ @floatCast(rs.min_val), @floatCast(rs.max_val) } },
                    });
                }
            },
            else => {},
        }
    }

    fn selectRadio(self: *WidgetManager, tree: *ui_core.UiTree, b: *WidgetBinding, rd: anytype, idx: usize) !void {
        const gid = rd.group_id;
        if (rd.auto_update) {
            for (self.bindings.items) |*other| {
                if (other.behavior == .radio and other.behavior.radio.group_id == gid) {
                    const is_target = std.meta.eql(other.node, b.node);
                    other.behavior.radio.checked = is_target;
                    if (tree.resolveId(other.node)) |oi| {
                        tree.nodes.items[oi].checked = is_target;
                    }
                }
            }
        }
        _ = idx;
        try self.event_queue.push(.{ .node = b.node, .tag = b.tag, .payload = .{ .value_bool = true } });
    }

    fn updateSliderFromPointer(
        self: *WidgetManager,
        tree: *ui_core.UiTree,
        node_id: ui_core.UiNodeId,
        tag: []const u8,
        sl: anytype,
        idx: usize,
        mx: f32,
        my: f32,
        is_final: bool,
    ) !void {
        const rect = tree.nodes.items[idx].layout;
        const span_raw: f32 = if (sl.orientation == .horizontal) rect.width else rect.height;
        if (span_raw <= 1.0) return;
        const t = if (sl.orientation == .horizontal)
            std.math.clamp((mx - rect.x) / span_raw, 0.0, 1.0)
        else
            std.math.clamp(1.0 - (my - rect.y) / span_raw, 0.0, 1.0);
        var val = sl.range.min + (sl.range.max - sl.range.min) * @as(f64, t);
        if (sl.step > 0.0) {
            val = @round(val / sl.step) * sl.step;
        }
        val = sl.range.clamp(val);
        if (sl.auto_update) sl.value = val;
        try self.event_queue.push(.{ .node = node_id, .tag = tag, .is_final = is_final, .payload = .{ .value_f64 = val } });
    }

    fn updateScrollbarFromPointer(self: *WidgetManager, tree: *ui_core.UiTree, sb: anytype, idx: usize, mx: f32, my: f32) void {
        _ = self;
        const t_idx = tree.resolveId(sb.target_scroll) orelse return;
        const track = tree.nodes.items[idx].layout;
        const target = &tree.nodes.items[t_idx];
        if (sb.orientation == .vertical) {
            const max_sy = @max(@as(f32, 0.0), target.content_height - target.layout.height);
            if (track.height <= 1.0 or max_sy <= 0.0) return;
            const frac = std.math.clamp((my - track.y) / track.height, 0.0, 1.0);
            target.scroll_y = frac * max_sy;
        } else {
            const max_sx = @max(@as(f32, 0.0), target.content_width - target.layout.width);
            if (track.width <= 1.0 or max_sx <= 0.0) return;
            const frac = std.math.clamp((mx - track.x) / track.width, 0.0, 1.0);
            target.scroll_x = frac * max_sx;
        }
    }

    fn updateColorPlaneFromPointer(
        self: *WidgetManager,
        tree: *ui_core.UiTree,
        node_id: ui_core.UiNodeId,
        tag: []const u8,
        cp: anytype,
        idx: usize,
        mx: f32,
        my: f32,
        is_final: bool,
    ) !void {
        const rect = tree.nodes.items[idx].layout;
        if (rect.width <= 1.0 or rect.height <= 1.0) return;
        const nx = std.math.clamp((mx - rect.x) / rect.width, 0.0, 1.0);
        const ny = std.math.clamp(1.0 - (my - rect.y) / rect.height, 0.0, 1.0);
        cp.x_val = nx;
        cp.y_val = ny;
        try self.event_queue.push(.{ .node = node_id, .tag = tag, .is_final = is_final, .payload = .{ .value_vec2 = .{ nx, ny } } });
    }

    fn updateColorWheelFromPointer(
        self: *WidgetManager,
        tree: *ui_core.UiTree,
        node_id: ui_core.UiNodeId,
        tag: []const u8,
        cw: anytype,
        idx: usize,
        mx: f32,
        my: f32,
        is_final: bool,
    ) !void {
        const rect = tree.nodes.items[idx].layout;
        const sz = @min(rect.width, rect.height);
        const cx = rect.x + rect.width * 0.5;
        const cy = rect.y + rect.height * 0.5;
        const dx = mx - cx;
        const dy = my - cy;

        if (cw.drag_part == .ring) {
            var deg = std.math.atan2(dy, dx) * (180.0 / std.math.pi);
            if (deg < 0.0) deg += 360.0;
            cw.hue_deg = deg;
        } else if (cw.drag_part == .triangle) {
            const inner_r = @max(@as(f32, 2.0), sz * 0.5 - cw.ring_width);
            const tri_r = @max(@as(f32, 1.0), inner_r - 3.0);
            const hue_rad = cw.hue_deg * (std.math.pi / 180.0);
            const ah = hue_rad;
            const aw = hue_rad + (2.0 * std.math.pi / 3.0);
            const ab = hue_rad + (4.0 * std.math.pi / 3.0);
            const p_h = [2]f32{ @cos(ah) * tri_r, @sin(ah) * tri_r };
            const p_w = [2]f32{ @cos(aw) * tri_r, @sin(aw) * tri_r };
            const p_b = [2]f32{ @cos(ab) * tri_r, @sin(ab) * tri_r };

            // Barycentric coordinates in triangle (p_h, p_w, p_b)
            const denom = (p_w[1] - p_b[1]) * (p_h[0] - p_b[0]) + (p_b[0] - p_w[0]) * (p_h[1] - p_b[1]);
            if (@abs(denom) > 1e-4) {
                var u = ((p_w[1] - p_b[1]) * (dx - p_b[0]) + (p_b[0] - p_w[0]) * (dy - p_b[1])) / denom;
                var v = ((p_b[1] - p_h[1]) * (dx - p_b[0]) + (p_h[0] - p_b[0]) * (dy - p_b[1])) / denom;
                var w = 1.0 - u - v;
                u = @max(@as(f32, 0.0), u);
                v = @max(@as(f32, 0.0), v);
                w = @max(@as(f32, 0.0), w);
                const sum = u + v + w;
                if (sum > 0.0) {
                    cw.whiteness = v / sum;
                    cw.blackness = w / sum;
                }
            }
        }
        if (tree.nodes.items[idx].paint_extra == .color_wheel) {
            tree.nodes.items[idx].paint_extra.color_wheel.hue_deg = cw.hue_deg;
        }
        const col = color.hwbaToSrgba(.{ .h = cw.hue_deg, .w = cw.whiteness, .b = cw.blackness, .a = 1.0 });
        try self.event_queue.push(.{ .node = node_id, .tag = tag, .is_final = is_final, .payload = .{ .value_color = col } });
    }

    fn onFocusedInput(
        self: *WidgetManager,
        tree: *ui_core.UiTree,
        fid: ui_core.UiNodeId,
        input: *const window.InputService,
        win_svc: ?*window.WindowService,
    ) !void {
        const b = self.findByNode(fid) orelse return;
        const idx = tree.resolveId(fid) orelse return;

        switch (b.behavior) {
            .button => {
                if (input.wasKeyPressed(window.KeyCode.enter) or input.wasKeyPressed(window.KeyCode.space)) {
                    try self.event_queue.push(.{ .node = fid, .tag = b.tag, .payload = .{ .activate = {} } });
                }
            },
            .checkbox => |*cb| {
                if (input.wasKeyPressed(window.KeyCode.enter) or input.wasKeyPressed(window.KeyCode.space)) {
                    const next = !cb.checked;
                    if (cb.auto_update) {
                        cb.checked = next;
                        tree.nodes.items[idx].checked = next;
                    }
                    try self.event_queue.push(.{ .node = fid, .tag = b.tag, .payload = .{ .value_bool = next } });
                }
            },
            .disclosure => |*dc| {
                const toggle_req = input.wasKeyPressed(window.KeyCode.enter) or input.wasKeyPressed(window.KeyCode.space);
                const expand_req = input.wasKeyPressed(window.KeyCode.right) and !dc.expanded;
                const collapse_req = input.wasKeyPressed(window.KeyCode.left) and dc.expanded;
                if (toggle_req or expand_req or collapse_req) {
                    const next = if (expand_req) true else if (collapse_req) false else !dc.expanded;
                    if (dc.auto_update) {
                        dc.expanded = next;
                        if (dc.target_body) |tb_id| {
                            if (tree.resolveId(tb_id)) |bi| tree.nodes.items[bi].style.visible = next;
                        }
                    }
                    try self.event_queue.push(.{ .node = fid, .tag = b.tag, .payload = .{ .expanded = next } });
                }
            },
            .slider => |*sl| {
                const dir: f64 = if (input.wasKeyPressed(window.KeyCode.right) or input.wasKeyPressed(window.KeyCode.up))
                    1.0
                else if (input.wasKeyPressed(window.KeyCode.left) or input.wasKeyPressed(window.KeyCode.down))
                    -1.0
                else
                    0.0;
                if (dir != 0.0) {
                    const span = @max(@as(f64, 1e-6), sl.range.max - sl.range.min);
                    const delta = if (sl.step > 0.0) sl.step else span * (if (input.modifiers.shift) @as(f64, 0.01) else @as(f64, 0.05));
                    const next = sl.range.clamp(sl.value + dir * delta);
                    if (sl.auto_update) sl.value = next;
                    try self.event_queue.push(.{ .node = fid, .tag = b.tag, .is_final = true, .payload = .{ .value_f64 = next } });
                }
            },
            .range_slider => |*rs| {
                const dir: f64 = if (input.wasKeyPressed(window.KeyCode.right)) 1.0 else if (input.wasKeyPressed(window.KeyCode.left)) -1.0 else 0.0;
                if (dir != 0.0) {
                    const span = @max(@as(f64, 1e-6), rs.range.max - rs.range.min);
                    const delta = if (rs.step > 0.0) rs.step else span * 0.05;
                    if (input.modifiers.shift) {
                        rs.max_val = @max(rs.min_val, rs.range.clamp(rs.max_val + dir * delta));
                    } else {
                        rs.min_val = @min(rs.max_val, rs.range.clamp(rs.min_val + dir * delta));
                    }
                    try self.event_queue.push(.{ .node = fid, .tag = b.tag, .is_final = true, .payload = .{ .value_vec2 = .{ @floatCast(rs.min_val), @floatCast(rs.max_val) } } });
                }
            },
            .text_input => |*ti| {
                const out = try ti.edit.processInput(tree, idx, input, win_svc, self.allocator, ti.max_len, ti.multiline);
                if (out.consumed_undo_redo) self.last_edit_consumed_undo = true;
                if (out.changed) try self.event_queue.push(.{ .node = fid, .tag = b.tag, .payload = .{ .text_changed = {} } });
                if (out.submitted) try self.event_queue.push(.{ .node = fid, .tag = b.tag, .payload = .{ .text_submit = {} } });
            },
            .keybind_input => |*kb| {
                if (kb.listening) {
                    if (input.wasKeyPressed(window.KeyCode.escape)) {
                        kb.listening = false;
                        try self.applyKeybindLabel(tree, idx, kb);
                    } else if (findFirstPressedNonModifierKey(input)) |k| {
                        kb.key = k;
                        kb.mods = input.modifiers;
                        kb.listening = false;
                        try self.applyKeybindLabel(tree, idx, kb);
                        try self.event_queue.push(.{ .node = fid, .tag = b.tag, .payload = .{ .activate = {} } });
                    }
                }
            },
            .number_input => |*ni| {
                if (ni.mode == .editing) {
                    const out = try ni.edit.processInput(tree, idx, input, win_svc, self.allocator, 64, false);
                    if (out.consumed_undo_redo) self.last_edit_consumed_undo = true;
                    if (out.submitted) {
                        const prev_val = ni.value;
                        const parsed = std.fmt.parseFloat(f64, tree.nodes.items[idx].text) catch ni.value.asF64();
                        const clamped = ni.range.clamp(parsed);
                        ni.value = events.NumericValue.fromF64(ni.value, clamped);
                        ni.mode = .idle;
                        tree.nodes.items[idx].kind = .custom;
                        ni.edit.clearSelection(tree, idx);
                        self.undo_history.push(.{ .widget_numeric = .{ .node = fid, .prev = prev_val, .next = ni.value } });
                        try self.event_queue.push(.{ .node = fid, .tag = b.tag, .is_final = true, .payload = .{ .value_numeric = ni.value } });
                    } else if (out.cancelled) {
                        ni.mode = .idle;
                        tree.nodes.items[idx].kind = .custom;
                        ni.edit.clearSelection(tree, idx);
                    }
                }
            },
            else => {},
        }
    }

    fn syncListboxSelection(self: *WidgetManager, tree: *ui_core.UiTree, lb_id: ui_core.UiNodeId, selected_idx: usize) void {
        for (self.bindings.items) |b| {
            if (b.behavior == .list_item and std.meta.eql(b.behavior.list_item.listbox_node, lb_id)) {
                if (tree.resolveId(b.node)) |ni| {
                    tree.nodes.items[ni].selected = (b.behavior.list_item.index == selected_idx);
                }
            }
        }
    }

    fn syncPopovers(self: *WidgetManager, tree: *ui_core.UiTree, vw: f32, vh: f32) void {
        for (self.bindings.items) |b| {
            if (b.behavior != .popover) continue;
            const pop = b.behavior.popover;
            const p_idx = tree.resolveId(b.node) orelse continue;
            tree.nodes.items[p_idx].style.visible = pop.open;
            if (!pop.open) continue;

            const a_idx = tree.resolveId(pop.anchor) orelse continue;
            const anchor_r = tree.nodes.items[a_idx].layout;
            if (pop.match_anchor_width and anchor_r.width > 0.0) {
                tree.nodes.items[p_idx].style.width = anchor_r.width;
            }
            if (tree.nodes.items[p_idx].layout.width == 0.0 or tree.nodes.items[p_idx].layout.height == 0.0) {
                tree.layoutTree(vw, vh);
            }
            const pop_r = tree.nodes.items[p_idx].layout;

            var px: f32 = if (pop.anchor_point) |pt| pt[0] else anchor_r.x;
            var py: f32 = if (pop.anchor_point) |pt| pt[1] else anchor_r.y + anchor_r.height + pop.placement.gap;
            if (pop.anchor_point == null) {
                if (pop.placement.side == .top or (py + pop_r.height + pop.window_margin > vh and anchor_r.y - pop_r.height - pop.placement.gap >= pop.window_margin)) {
                    py = anchor_r.y - pop_r.height - pop.placement.gap;
                }
                if (pop.placement.align_mode == .end) {
                    px = anchor_r.x + anchor_r.width - pop_r.width;
                } else if (pop.placement.align_mode == .center) {
                    px = anchor_r.x + (anchor_r.width - pop_r.width) * 0.5;
                }
            }
            px = std.math.clamp(px, pop.window_margin, @max(pop.window_margin, vw - pop_r.width - pop.window_margin));
            py = std.math.clamp(py, pop.window_margin, @max(pop.window_margin, vh - pop_r.height - pop.window_margin));

            tree.nodes.items[p_idx].style.left = px;
            tree.nodes.items[p_idx].style.top = py;
        }
    }

    fn handleContextMenuOpen(self: *WidgetManager, tree: *ui_core.UiTree, hit_idx: usize, mx: f32, my: f32) void {
        for (self.bindings.items) |*b| {
            if (b.behavior != .popover) continue;
            const target = b.behavior.popover.context_target orelse continue;
            const t_idx = tree.resolveId(target) orelse continue;
            if (isDescendantOrSelf(tree, hit_idx, t_idx)) {
                b.behavior.popover.open = true;
                b.behavior.popover.anchor_point = .{ mx, my };
                if (tree.resolveId(b.node)) |pi| {
                    tree.nodes.items[pi].style.visible = true;
                }
                return;
            }
        }
    }

    fn closeMenubarGroupExcept(self: *WidgetManager, tree: *ui_core.UiTree, group: u32, keep_trigger: ui_core.UiNodeId) void {
        for (self.bindings.items) |other| {
            if (other.behavior == .menu_trigger and other.behavior.menu_trigger.menubar_group == group) {
                if (std.meta.eql(other.node, keep_trigger)) continue;
                if (self.findByNode(other.behavior.menu_trigger.popup_node)) |pop_b| {
                    if (pop_b.behavior == .popover) {
                        pop_b.behavior.popover.open = false;
                        if (tree.resolveId(other.behavior.menu_trigger.popup_node)) |pi| {
                            tree.nodes.items[pi].style.visible = false;
                        }
                    }
                }
            }
        }
    }

    fn handleMenubarHover(self: *WidgetManager, tree: *ui_core.UiTree, hit_idx: usize) void {
        const hit_id = tree.idOf(hit_idx) orelse return;
        const b = self.findByNode(hit_id) orelse return;
        if (b.behavior != .menu_trigger) return;
        const group = b.behavior.menu_trigger.menubar_group;
        if (group == 0) return;
        var any_open = false;
        for (self.bindings.items) |other| {
            if (other.behavior == .menu_trigger and other.behavior.menu_trigger.menubar_group == group) {
                if (self.findByNode(other.behavior.menu_trigger.popup_node)) |pop_b| {
                    if (pop_b.behavior == .popover and pop_b.behavior.popover.open) {
                        any_open = true;
                        break;
                    }
                }
            }
        }
        if (!any_open) return;
        self.closeMenubarGroupExcept(tree, group, b.node);
        if (self.findByNode(b.behavior.menu_trigger.popup_node)) |pop_b| {
            if (pop_b.behavior == .popover) {
                pop_b.behavior.popover.open = true;
                pop_b.behavior.popover.anchor_point = null;
                if (tree.resolveId(b.behavior.menu_trigger.popup_node)) |pi| {
                    tree.nodes.items[pi].style.visible = true;
                }
            }
        }
    }

    fn syncTooltips(self: *WidgetManager, tree: *ui_core.UiTree, dt_ms: f32, mouse_down: bool, vw: f32, vh: f32) void {
        for (self.bindings.items) |*b| {
            if (b.behavior != .tooltip) continue;
            const tt = &b.behavior.tooltip;
            const t_idx = tree.resolveId(tt.target_node) orelse continue;
            const p_idx = tree.resolveId(b.node) orelse continue;
            if (tree.nodes.items[t_idx].hovered and !mouse_down and !tree.nodes.items[t_idx].disabled) {
                tt.hover_ms += dt_ms;
                if (tt.hover_ms >= tt.delay_ms) {
                    tt.open = true;
                    tree.nodes.items[p_idx].style.visible = true;
                    if (tree.nodes.items[p_idx].layout.width == 0.0 or tree.nodes.items[p_idx].layout.height == 0.0) {
                        tree.layoutTree(vw, vh);
                    }
                    const anchor_r = tree.nodes.items[t_idx].layout;
                    const pop_r = tree.nodes.items[p_idx].layout;
                    const margin: f32 = 6.0;
                    var px = anchor_r.x + (anchor_r.width - pop_r.width) * 0.5;
                    var py = anchor_r.y + anchor_r.height + 6.0;
                    if (py + pop_r.height + margin > vh and anchor_r.y - pop_r.height - 6.0 >= margin) {
                        py = anchor_r.y - pop_r.height - 6.0;
                    }
                    px = std.math.clamp(px, margin, @max(margin, vw - pop_r.width - margin));
                    py = std.math.clamp(py, margin, @max(margin, vh - pop_r.height - margin));
                    tree.nodes.items[p_idx].style.left = px;
                    tree.nodes.items[p_idx].style.top = py;
                }
            } else {
                tt.hover_ms = 0.0;
                tt.open = false;
                tree.nodes.items[p_idx].style.visible = false;
            }
        }
    }

    fn updateRangeSliderFromPointer(
        self: *WidgetManager,
        tree: *ui_core.UiTree,
        node_id: ui_core.UiNodeId,
        tag: []const u8,
        rs: anytype,
        idx: usize,
        mouse_x: f32,
        is_final: bool,
    ) !void {
        const rect = tree.nodes.items[idx].layout;
        const w = @max(@as(f32, 1.0), rect.width);
        const t = std.math.clamp((mouse_x - rect.x) / w, 0.0, 1.0);
        var val = rs.range.min + @as(f64, t) * (rs.range.max - rs.range.min);
        if (rs.step > 0.0) {
            val = @round((val - rs.range.min) / rs.step) * rs.step + rs.range.min;
        }
        val = rs.range.clamp(val);
        if (rs.auto_update) {
            switch (rs.active_thumb) {
                .min => rs.min_val = @min(val, rs.max_val),
                .max => rs.max_val = @max(val, rs.min_val),
                .none => {},
            }
        }
        try self.event_queue.push(.{
            .node = node_id,
            .tag = tag,
            .is_final = is_final,
            .payload = .{ .value_vec2 = .{ @floatCast(rs.min_val), @floatCast(rs.max_val) } },
        });
    }

    fn applyGlobalUndo(self: *WidgetManager, tree: *ui_core.UiTree) !void {
        const cmd = self.undo_history.stepUndo() orelse return;
        try self.applyUndoCommand(tree, cmd, true);
    }

    fn applyGlobalRedo(self: *WidgetManager, tree: *ui_core.UiTree) !void {
        const cmd = self.undo_history.stepRedo() orelse return;
        try self.applyUndoCommand(tree, cmd, false);
    }

    fn applyUndoCommand(self: *WidgetManager, tree: *ui_core.UiTree, cmd: text_edit.UndoCommand, is_undo: bool) !void {
        switch (cmd) {
            .widget_bool => |wb| {
                const val = if (is_undo) wb.prev else wb.next;
                if (self.findByNode(wb.node)) |b| {
                    if (b.behavior == .checkbox) {
                        b.behavior.checkbox.checked = val;
                        if (tree.resolveId(wb.node)) |idx| tree.nodes.items[idx].checked = val;
                        try self.event_queue.push(.{ .node = wb.node, .tag = b.tag, .payload = .{ .value_bool = val } });
                    }
                }
            },
            .widget_f64 => |wf| {
                const val = if (is_undo) wf.prev else wf.next;
                if (self.findByNode(wf.node)) |b| {
                    if (b.behavior == .slider) {
                        b.behavior.slider.value = val;
                        try self.event_queue.push(.{ .node = wf.node, .tag = b.tag, .is_final = true, .payload = .{ .value_f64 = val } });
                    }
                }
            },
            .widget_vec2 => |wv| {
                const val = if (is_undo) wv.prev else wv.next;
                if (self.findByNode(wv.node)) |b| {
                    if (b.behavior == .range_slider) {
                        b.behavior.range_slider.min_val = val[0];
                        b.behavior.range_slider.max_val = val[1];
                        try self.event_queue.push(.{ .node = wv.node, .tag = b.tag, .is_final = true, .payload = .{ .value_vec2 = .{ @floatCast(val[0]), @floatCast(val[1]) } } });
                    }
                }
            },
            .widget_numeric => |wn| {
                const val = if (is_undo) wn.prev else wn.next;
                if (self.findByNode(wn.node)) |b| {
                    if (b.behavior == .number_input) {
                        b.behavior.number_input.value = val;
                        try self.event_queue.push(.{ .node = wn.node, .tag = b.tag, .is_final = true, .payload = .{ .value_numeric = val } });
                    }
                }
            },
            .custom => |cc| {
                if (is_undo) cc.undo_fn(cc.ctx) else cc.redo_fn(cc.ctx);
            },
        }
    }

    fn findFirstPressedNonModifierKey(input: *const window.InputService) ?u8 {
        for (input.keys_pressed, 0..) |pressed, code| {
            if (!pressed) continue;
            // Skip SDL left/right modifier scancodes (224..231).
            if (code >= 224 and code <= 231) continue;
            return @intCast(code);
        }
        return null;
    }

    fn applyKeybindLabel(self: *WidgetManager, tree: *ui_core.UiTree, idx: usize, kb: anytype) !void {
        _ = self;
        if (kb.key == null) {
            try tree.setNodeText(idx, "Unbound");
            return;
        }
        var len: usize = 0;
        const append = struct {
            fn slice(buf: *[48]u8, cur: *usize, s: []const u8) void {
                const n = @min(s.len, buf.len - cur.*);
                @memcpy(buf[cur.* .. cur.* + n], s[0..n]);
                cur.* += n;
            }
        }.slice;
        if (kb.mods.ctrl) append(&kb.label_buf, &len, "Ctrl+");
        if (kb.mods.shift) append(&kb.label_buf, &len, "Shift+");
        if (kb.mods.alt) append(&kb.label_buf, &len, "Alt+");
        if (kb.mods.super) append(&kb.label_buf, &len, "Super+");
        const k = kb.key.?;
        var single: [1]u8 = undefined;
        const k_name: []const u8 = if (k >= 4 and k <= 29) blk: {
            single[0] = 'A' + (k - 4);
            break :blk &single;
        } else if (k >= 30 and k <= 38) blk: {
            single[0] = '1' + (k - 30);
            break :blk &single;
        } else if (k == 39) "0" else switch (k) {
            window.KeyCode.enter => "Enter",
            window.KeyCode.escape => "Esc",
            window.KeyCode.backspace => "Backspace",
            window.KeyCode.tab => "Tab",
            window.KeyCode.space => "Space",
            window.KeyCode.left => "Left",
            window.KeyCode.right => "Right",
            window.KeyCode.up => "Up",
            window.KeyCode.down => "Down",
            window.KeyCode.home => "Home",
            window.KeyCode.end => "End",
            window.KeyCode.delete => "Del",
            else => "Key",
        };
        append(&kb.label_buf, &len, k_name);
        kb.label_len = len;
        try tree.setNodeText(idx, kb.label_buf[0..len]);
    }

    fn syncScrollbars(self: *WidgetManager, tree: *ui_core.UiTree) void {
        for (self.bindings.items) |b| {
            if (b.behavior != .scrollbar) continue;
            const sb = b.behavior.scrollbar;
            const sb_idx = tree.resolveId(b.node) orelse continue;
            const tgt_idx = tree.resolveId(sb.target_scroll) orelse continue;
            const thumb_id = sb.thumb_node orelse continue;
            const thumb_idx = tree.resolveId(thumb_id) orelse continue;

            const track = tree.nodes.items[sb_idx].layout;
            const tgt = tree.nodes.items[tgt_idx];
            if (sb.orientation == .vertical) {
                const ratio = if (tgt.content_height > 0.0) @min(@as(f32, 1.0), tgt.layout.height / tgt.content_height) else 1.0;
                const thumb_h = @max(@as(f32, 16.0), track.height * ratio);
                const max_sy = @max(@as(f32, 1.0), tgt.content_height - tgt.layout.height);
                const frac = std.math.clamp(tgt.scroll_y / max_sy, 0.0, 1.0);
                tree.nodes.items[thumb_idx].style.height = thumb_h;
                tree.nodes.items[thumb_idx].style.top = frac * @max(@as(f32, 0.0), track.height - thumb_h);
            }
        }
    }
};

fn buildModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    try app.resources.insert(WidgetManager, WidgetManager.init(app.allocator));
    const mgr = app.resources.get(WidgetManager).?;

    try app.services.register(.{
        .capability = "engine.ui.widgets",
        .major_version = 1,
        .provider_id = "official.ui.widgets",
        .owner_id = MODULE_OWNER_ID,
        .exclusive = true,
        .api_ptr = mgr,
        .api_size = @sizeOf(WidgetManager),
    });
}

fn stopModule(raw_app: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    _ = app.services.unregisterByOwner(MODULE_OWNER_ID);
    _ = app.resources.remove(WidgetManager);
}

/// Returns the `official.ui.widgets` module descriptor.
pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = "official.ui.widgets",
            .version = "0.1.0",
            .provides_capabilities = &.{"engine.ui.widgets/1"},
            .required_capabilities = &.{"engine.ui.tree/1"},
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
