//! Cell streaming for prefab-based worlds.
//!
//! A cell is a named prefab instance (a region of the world). Loading is split so heavy work stays
//! off the frame: `prefab.prepare` (decode/migrate/validate, no `World` access) can run on any
//! thread; `CellStreamer.update` then commits queued plans on the main thread within a per-frame
//! entity budget. Unloading despawns every entity of the cell in one call, so cell-owned resources
//! that follow entity lifetime (for example physics bodies) are released with it.

const std = @import("std");
const engine = @import("engine");
const prefab_mod = @import("prefab.zig");

pub const CellStreamer = struct {
    allocator: std.mem.Allocator,
    loaded: std.StringHashMapUnmanaged(prefab_mod.Instance) = .empty,
    queue: std.ArrayList(Pending) = .empty,

    const Pending = struct {
        name: []u8,
        plan: prefab_mod.Prepared,
        opts: prefab_mod.InstantiateOptions,
    };

    pub fn init(allocator: std.mem.Allocator) CellStreamer {
        return .{ .allocator = allocator };
    }

    /// Frees queued plans and instance bookkeeping. Entities of loaded cells stay in the world
    /// (call `unload` first to remove them).
    pub fn deinit(self: *CellStreamer) void {
        for (self.queue.items) |*p| {
            self.allocator.free(p.name);
            p.plan.deinit();
        }
        self.queue.deinit(self.allocator);
        var it = self.loaded.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            e.value_ptr.deinit();
        }
        self.loaded.deinit(self.allocator);
    }

    pub fn isLoaded(self: *const CellStreamer, name: []const u8) bool {
        return self.loaded.contains(name);
    }

    pub fn isQueued(self: *const CellStreamer, name: []const u8) bool {
        for (self.queue.items) |p| {
            if (std.mem.eql(u8, p.name, name)) return true;
        }
        return false;
    }

    /// Queues `plan` (taking ownership, also on error) to be committed by `update`.
    /// `error.CellAlreadyLoaded` / `error.CellAlreadyQueued` reject duplicates.
    pub fn request(self: *CellStreamer, name: []const u8, plan: prefab_mod.Prepared, opts: prefab_mod.InstantiateOptions) !void {
        var owned_plan = plan;
        errdefer owned_plan.deinit();
        if (self.isLoaded(name)) return error.CellAlreadyLoaded;
        if (self.isQueued(name)) return error.CellAlreadyQueued;
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        try self.queue.append(self.allocator, .{ .name = name_copy, .plan = owned_plan, .opts = opts });
    }

    /// Cancels a queued (not yet committed) cell; returns false if it was not queued.
    pub fn cancel(self: *CellStreamer, name: []const u8) bool {
        for (self.queue.items, 0..) |*p, i| {
            if (std.mem.eql(u8, p.name, name)) {
                self.allocator.free(p.name);
                p.plan.deinit();
                _ = self.queue.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    /// Commits queued cells in request order until `max_entities` would be exceeded. At least one
    /// cell is committed per call when the queue is not empty, so a cell larger than the budget
    /// still loads (alone). A cell whose commit fails is dropped and the error returned; the world
    /// is unchanged by that cell. Returns the number of entities committed.
    pub fn update(self: *CellStreamer, world: *engine.World, max_entities: usize) !usize {
        var committed: usize = 0;
        while (self.queue.items.len > 0) {
            const next_size = self.queue.items[0].plan.entities.len;
            if (committed > 0 and committed + next_size > max_entities) break;
            var pending = self.queue.orderedRemove(0);
            defer pending.plan.deinit();
            errdefer self.allocator.free(pending.name);
            const inst = try prefab_mod.commit(self.allocator, world, &pending.plan, pending.opts);
            self.loaded.put(self.allocator, pending.name, inst) catch |err| {
                var doomed = inst;
                for (doomed.handles) |h| _ = world.despawn(h) catch {};
                doomed.deinit();
                return err;
            };
            committed += next_size;
        }
        return committed;
    }

    /// Despawns every entity of cell `name` and forgets it; returns false if it was not loaded.
    pub fn unload(self: *CellStreamer, world: *engine.World, name: []const u8) bool {
        const kv = self.loaded.fetchRemove(name) orelse return false;
        var inst = kv.value;
        // Children before parents is not required for despawn, but reverse order keeps hierarchy
        // links consistent for hierarchy implementations that unlink on despawn.
        var i = inst.handles.len;
        while (i > 0) {
            i -= 1;
            _ = world.despawn(inst.handles[i]) catch {};
        }
        inst.deinit();
        self.allocator.free(kv.key);
        return true;
    }
};
