//! Scene graph v1: parent/child index, reparenting, and destruction policies.
//!
//! `Parent` (child -> parent) stays the semantic source of truth; `HierarchyLinks` adds an
//! intrusive first-child / sibling list so child traversal and detach/attach are O(1) after
//! validation. Entities do not need to participate: only linked nodes carry the components.
//! Transform parenting is a forest: self-parenting and cycles are rejected.
//!
//! Always mutate hierarchy through this module. Code that sets `Parent` directly must call
//! `rebuildLinks` afterwards.

const std = @import("std");
const engine = @import("engine");
const scene = @import("scene.zig");
const incremental = @import("incremental.zig");

const EntityHandle = engine.EntityHandle;
const World = engine.World;

/// Intrusive child list node attached to every entity that is in the hierarchy.
pub const HierarchyLinks = struct {
    first_child: EntityHandle = EntityHandle.invalid,
    next_sibling: EntityHandle = EntityHandle.invalid,
    prev_sibling: EntityHandle = EntityHandle.invalid,
};

pub const ReparentOptions = struct {
    /// Keep the child's current world transform by recomputing its local transform.
    /// Requires up-to-date `world_*` fields (run transform propagation first).
    preserve_world: bool = false,
};

/// What to do with children when a node is destroyed.
pub const DespawnPolicy = enum {
    /// Destroy the whole subtree.
    cascade,
    /// Children become roots, keeping their world transform.
    orphan,
    /// Children are reparented to the destroyed node's parent (or become roots).
    reparent_to_parent,
};

fn registerAll(world: *World) !void {
    _ = try world.registerComponent(scene.Parent);
    _ = try world.registerComponent(HierarchyLinks);
}

fn ensureLinks(world: *World, e: EntityHandle) !void {
    if (!world.has(e, HierarchyLinks)) try world.set(e, HierarchyLinks, .{});
}

/// Returns `entity`'s parent, or null for roots.
pub fn parentOf(world: *const World, entity: EntityHandle) ?EntityHandle {
    const p = world.getConst(entity, scene.Parent) orelse return null;
    return if (world.isAlive(p.entity)) p.entity else null;
}

/// True when `ancestor` is a strict ancestor of `node`. Bounded by the entity count so
/// corrupt (cyclic) data cannot loop forever.
pub fn isAncestor(world: *const World, ancestor: EntityHandle, node: EntityHandle) bool {
    var cur = node;
    var steps: usize = 0;
    while (steps <= world.entity_count) : (steps += 1) {
        const p = parentOf(world, cur) orelse return false;
        if (std.meta.eql(p, ancestor)) return true;
        cur = p;
    }
    return true; // chain longer than the world: treat as a cycle
}

/// Iterates the direct children of a node in list order (most recently attached first).
pub const ChildIterator = struct {
    world: *const World,
    next_child: EntityHandle,

    /// Returns the next direct child, or null when the list ends or a link is stale.
    pub fn next(self: *ChildIterator) ?EntityHandle {
        if (!self.world.isAlive(self.next_child)) return null;
        const cur = self.next_child;
        const links = self.world.getConst(cur, HierarchyLinks) orelse return null;
        self.next_child = links.next_sibling;
        return cur;
    }
};

/// Returns an iterator over the direct children of `parent`.
pub fn children(world: *const World, parent: EntityHandle) ChildIterator {
    const links = world.getConst(parent, HierarchyLinks);
    return .{ .world = world, .next_child = if (links) |l| l.first_child else EntityHandle.invalid };
}

/// Number of direct children.
pub fn childCount(world: *const World, parent: EntityHandle) usize {
    var it = children(world, parent);
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    return n;
}

fn unlink(world: *World, child: EntityHandle, old_parent: ?EntityHandle) void {
    const links = world.get(child, HierarchyLinks) orelse return;
    const prev = links.prev_sibling;
    const next = links.next_sibling;
    links.prev_sibling = EntityHandle.invalid;
    links.next_sibling = EntityHandle.invalid;
    if (world.isAlive(prev)) {
        world.get(prev, HierarchyLinks).?.next_sibling = next;
    } else if (old_parent) |p| {
        if (world.get(p, HierarchyLinks)) |pl| pl.first_child = next;
    }
    if (world.isAlive(next)) world.get(next, HierarchyLinks).?.prev_sibling = prev;
}

/// Moves `child` under `new_parent` (or makes it a root when null).
///
/// Rejects dead handles, self-parenting, and cycles (`error.HierarchyCycle`) and, with
/// `preserve_world`, singular parent transforms (`error.SingularTransform`). All fallible work
/// happens before the links change, so an error leaves the hierarchy untouched.
pub fn reparent(world: *World, child: EntityHandle, new_parent: ?EntityHandle, opts: ReparentOptions) !void {
    if (world.active_queries > 0) return error.MutationDuringActiveQuery;
    if (!world.isAlive(child)) return error.InvalidEntity;
    if (new_parent) |np| {
        if (!world.isAlive(np)) return error.InvalidEntity;
        if (std.meta.eql(np, child) or isAncestor(world, child, np)) return error.HierarchyCycle;
    }

    // Compute the preserved local transform up front (pure).
    var new_local: ?scene.Transform2D = null;
    if (opts.preserve_world) {
        if (world.getConst(child, scene.Transform2D)) |ct| {
            const child_world = scene.Mat2D.fromWorld(ct.*);
            var parent_inv = scene.Mat2D.identity;
            if (new_parent) |np| {
                if (world.getConst(np, scene.Transform2D)) |pt| {
                    parent_inv = scene.Mat2D.fromWorld(pt.*).inverse() orelse return error.SingularTransform;
                }
            }
            var local = scene.Mat2D.decompose(scene.Mat2D.mul(parent_inv, child_world));
            local.world_x = ct.world_x;
            local.world_y = ct.world_y;
            local.world_rotation_rad = ct.world_rotation_rad;
            local.world_scale_x = ct.world_scale_x;
            local.world_scale_y = ct.world_scale_y;
            new_local = local;
        }
    }

    // The same for the derived-global model: local = inverse(parent_global) * child_global.
    var new_local_v2: ?incremental.LocalTransform2D = null;
    if (opts.preserve_world) {
        if (world.getConst(child, incremental.GlobalTransform2D)) |cg| {
            if (world.has(child, incremental.LocalTransform2D)) {
                var parent_inv = scene.Mat2D.identity;
                if (new_parent) |np| {
                    if (world.getConst(np, incremental.GlobalTransform2D)) |pg| {
                        parent_inv = pg.toMat().inverse() orelse return error.SingularTransform;
                    }
                }
                const t = scene.Mat2D.decompose(scene.Mat2D.mul(parent_inv, cg.toMat()));
                new_local_v2 = .{ .x = t.x, .y = t.y, .rotation_rad = t.rotation_rad, .scale_x = t.scale_x, .scale_y = t.scale_y };
            }
        }
    }

    // Fallible phase: component registration and insertion. The old parent is captured first
    // because `set(Parent)` overwrites it.
    const old_parent = parentOf(world, child);
    try registerAll(world);
    try ensureLinks(world, child);
    if (new_parent) |np| {
        try ensureLinks(world, np);
        try world.set(child, scene.Parent, .{ .entity = np });
    } else if (world.has(child, scene.Parent)) {
        _ = try world.remove(child, scene.Parent);
    }

    // Infallible phase: O(1) pointer surgery.
    unlink(world, child, old_parent);
    if (new_parent) |np| linkAsFirstChild(world, np, child);
    if (new_local) |l| world.get(child, scene.Transform2D).?.* = l;
    if (new_local_v2) |l| world.get(child, incremental.LocalTransform2D).?.* = l;
}

fn linkAsFirstChild(world: *World, parent: EntityHandle, child: EntityHandle) void {
    const pl = world.get(parent, HierarchyLinks).?;
    const old_first = pl.first_child;
    pl.first_child = child;
    const cl = world.get(child, HierarchyLinks).?;
    cl.next_sibling = old_first;
    cl.prev_sibling = EntityHandle.invalid;
    if (world.isAlive(old_first)) world.get(old_first, HierarchyLinks).?.prev_sibling = child;
}

/// Destroys `entity`, applying `policy` to its children. The entity is unlinked from its parent
/// first so no dangling child pointers remain.
pub fn despawnNode(world: *World, entity: EntityHandle, policy: DespawnPolicy) !void {
    if (!world.isAlive(entity)) return;
    const allocator = world.allocator;

    switch (policy) {
        .cascade => {
            var order: std.ArrayList(EntityHandle) = .empty;
            defer order.deinit(allocator);
            try order.append(allocator, entity);
            var i: usize = 0;
            while (i < order.items.len) : (i += 1) {
                var it = children(world, order.items[i]);
                while (it.next()) |c| try order.append(allocator, c);
            }
            unlink(world, entity, parentOf(world, entity));
            var j = order.items.len;
            while (j > 0) {
                j -= 1;
                _ = try world.despawn(order.items[j]);
            }
        },
        .orphan, .reparent_to_parent => {
            const target: ?EntityHandle = if (policy == .reparent_to_parent) parentOf(world, entity) else null;
            while (world.getConst(entity, HierarchyLinks)) |l| {
                const c = l.first_child;
                if (!world.isAlive(c)) break;
                try reparent(world, c, target, .{ .preserve_world = true });
            }
            unlink(world, entity, parentOf(world, entity));
            _ = try world.despawn(entity);
        },
    }
}

/// Rebuilds every `HierarchyLinks` list from the `Parent` components. Parents that are dead,
/// self-referential, or part of a cycle are dropped (the child becomes a root).
pub fn rebuildLinks(world: *World) !void {
    try registerAll(world);
    var nodes: std.ArrayList(EntityHandle) = .empty;
    defer nodes.deinit(world.allocator);
    {
        var q = try world.query(.{ .read = .{scene.Parent} });
        defer q.deinit();
        while (q.next()) |row| try nodes.append(world.allocator, row.entity);
    }
    for (nodes.items) |e| {
        try ensureLinks(world, e);
        if (parentOf(world, e)) |p| try ensureLinks(world, p);
    }
    {
        var q = try world.query(.{ .write = .{HierarchyLinks} });
        defer q.deinit();
        while (q.next()) |row| row.write(HierarchyLinks).* = .{};
    }
    for (nodes.items) |e| {
        const p = parentOf(world, e);
        if (p == null or std.meta.eql(p.?, e) or isAncestor(world, e, p.?)) {
            _ = try world.remove(e, scene.Parent);
            continue;
        }
        linkAsFirstChild(world, p.?, e);
    }
}
