//! Plume Hierarchy / Inspector chrome for the editor harness.
//!
//! Builds retained docks from document data without owning history or ECS mutation.

const std = @import("std");
const graphics = @import("graphics");
const ui_core = @import("ui_core");
const ui_widgets = @import("ui_widgets");
const ui_plume = @import("ui_plume");
const document = @import("document");

/// Rebuilds Hierarchy + Inspector docks into `tree` for the current document snapshot.
pub fn rebuild(
    tree: *ui_core.UiTree,
    mgr: *ui_widgets.WidgetManager,
    th: *const ui_plume.UiTheme,
    doc: *const document.EditorDocument,
    win_w: f32,
    win_h: f32,
) !void {
    tree.clear();
    const root = try tree.createNode(null, .{
        .id = "editor.root",
        .kind = .panel,
        .style = .{
            .direction = .row,
            .width_spec = .{ .px = win_w },
            .height_spec = .{ .px = win_h },
            .gap = 0,
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
    });

    const left = try ui_plume.controls.tooling.dockPanel(tree, mgr, th, root, &.{"Hierarchy"}, 0, "ed.h", .base);
    _ = try tree.createNode(left.body, .{
        .id = "",
        .kind = .label,
        .text = "Entities",
        .style = .{ .height_spec = .{ .px = 20 } },
    });
    const list = try ui_plume.controls.tooling.treeView(tree, th, left.body, .base);
    for (doc.entries.items) |entry| {
        const selected = if (doc.selected) |s| document.sameEntity(s, entry.entity) else false;
        _ = try ui_plume.controls.tooling.treeItemEx(tree, mgr, th, list, entry.name(), .{
            .expanded = false,
            .has_children = false,
            .level = if (selected) .higher else .base,
        }, "ent");
    }

    _ = try tree.createNode(root, .{
        .id = "editor.scene_gap",
        .kind = .panel,
        .style = .{
            .width_spec = .{ .grow = 1.0 },
            .height_spec = .{ .grow = 1.0 },
            .bg_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        },
    });

    const right = try ui_plume.controls.tooling.dockPanel(tree, mgr, th, root, &.{"Inspector"}, 0, "ed.i", .base);
    if (doc.selectedEntry()) |entry| {
        _ = try tree.createNode(right.body, .{
            .id = "",
            .kind = .label,
            .text = entry.name(),
            .style = .{ .height_spec = .{ .px = 22 } },
        });
    } else {
        _ = try tree.createNode(right.body, .{
            .id = "",
            .kind = .label,
            .text = "Nothing selected",
            .style = .{ .height_spec = .{ .px = 22 } },
        });
    }

    tree.layoutTree(win_w, win_h);
}

/// Paints the retained tree into `out`.
pub fn paint(tree: *const ui_core.UiTree, allocator: std.mem.Allocator, out: *std.ArrayList(graphics.DrawCommand)) !void {
    try tree.paint(allocator, out);
}