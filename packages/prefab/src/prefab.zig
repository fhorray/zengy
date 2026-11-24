//! Optional Prefab Package (`official.prefab`).
//!
//! A `Prefab` is an engine-independent description of a small entity tree: local ids, a parent
//! relation, and components stored as portable encoded blobs (`TypeRegistry.encodeComponent`),
//! so it never depends on host memory layout or Zig type names. Overrides address
//! `(local entity id, stable type id, field name)`, never memory offsets.
//!
//! `instantiate` is batched and atomic: everything is decoded, migrated, and overridden first;
//! entities are then spawned and filled, and any failure despawns what was created. Parenting is
//! delegated to a caller-provided link function so the package works with any hierarchy
//! implementation (for example `scene.graph.reparent`).

const std = @import("std");
const engine = @import("engine");

pub const MODULE_OWNER_ID: u64 = 2030;

/// JSON authoring loader (`parsePrefab`, `parseOverrides`).
pub const json = @import("json_loader.zig");

/// Cooked binary format (`cooked.cook` / `cooked.load`).
pub const cooked = @import("cooked.zig");

/// Cell streaming (`CellStreamer`).
pub const streaming = @import("streaming.zig");

/// Errors returned by `Prefab` construction.
pub const PrefabError = error{ DuplicateLocalId, UnknownParent, UnknownEntity };

/// Overrides one field of one component on one prefab entity at instantiation time.
pub const Override = struct {
    local_id: []const u8,
    stable_id: engine.reflection.StableTypeId,
    field: []const u8,
    value: engine.reflection.FieldValue,
};

/// Callback that attaches `child` under `parent` in the caller's hierarchy implementation.
pub const LinkFn = *const fn (ctx: ?*anyopaque, world: *engine.World, child: engine.EntityHandle, parent: engine.EntityHandle) anyerror!void;

/// Looks up prefabs by name for nested instantiation (see `PrefabLibrary.resolver`).
pub const Resolver = struct {
    ctx: ?*anyopaque = null,
    lookup: *const fn (ctx: ?*anyopaque, name: []const u8) ?*const Prefab,
};

/// Maximum depth of nested prefabs; deeper (or cyclic) nesting is an error.
pub const max_nesting_depth: usize = 16;

pub const InstantiateOptions = struct {
    /// Needed only when the prefab contains nested prefabs.
    resolver: ?Resolver = null,
    overrides: []const Override = &.{},
    /// Parent for prefab roots (entities without a prefab-internal parent), or null for none.
    root_parent: ?engine.EntityHandle = null,
    link: ?LinkFn = null,
    link_ctx: ?*anyopaque = null,
};

/// Reusable entity-tree template. Owns all of its strings and blobs.
pub const Prefab = struct {
    arena: std.heap.ArenaAllocator,
    entities: std.ArrayList(Entity) = .empty,

    pub const Entity = struct {
        local_id: []const u8,
        parent: ?[]const u8,
        /// Blobs produced by `TypeRegistry.encodeComponent`.
        components: std.ArrayList([]const u8) = .empty,
        /// When set, instantiating this entity also instantiates another prefab beneath it.
        nested: ?Nested = null,
    };

    /// Reference to another prefab instantiated under an anchor entity, with overrides addressed by
    /// the nested prefab's own `local_id`s.
    pub const Nested = struct {
        prefab_name: []const u8,
        overrides: []const Override,
    };

    pub fn init(allocator: std.mem.Allocator) Prefab {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *Prefab) void {
        self.arena.deinit();
    }

    fn indexOf(self: *const Prefab, local_id: []const u8) ?usize {
        for (self.entities.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.local_id, local_id)) return i;
        }
        return null;
    }

    /// Adds an entity. `parent` must name an entity that was added earlier, which makes the
    /// hierarchy acyclic by construction (`error.UnknownParent`, `error.DuplicateLocalId`).
    pub fn addEntity(self: *Prefab, local_id: []const u8, parent: ?[]const u8) !void {
        if (self.indexOf(local_id) != null) return error.DuplicateLocalId;
        if (parent) |p| {
            if (self.indexOf(p) == null) return error.UnknownParent;
        }
        const a = self.arena.allocator();
        try self.entities.append(a, .{
            .local_id = try a.dupe(u8, local_id),
            .parent = if (parent) |p| try a.dupe(u8, p) else null,
        });
    }

    /// Adds an anchor entity that instantiates the prefab `prefab_name` (resolved at instantiate time
    /// through a `Resolver`) as its children. `overrides` address entities of the nested prefab.
    pub fn addNested(self: *Prefab, local_id: []const u8, parent: ?[]const u8, prefab_name: []const u8, overrides: []const Override) !void {
        try self.addEntity(local_id, parent);
        const a = self.arena.allocator();
        const owned = try a.alloc(Override, overrides.len);
        for (overrides, 0..) |ov, i| {
            owned[i] = .{ .local_id = try a.dupe(u8, ov.local_id), .stable_id = ov.stable_id, .field = try a.dupe(u8, ov.field), .value = ov.value };
        }
        self.entities.items[self.entities.items.len - 1].nested = .{ .prefab_name = try a.dupe(u8, prefab_name), .overrides = owned };
    }

    /// Encodes `bytes` (laid out per `schema`) and attaches it to the entity `local_id`.
    pub fn addComponent(self: *Prefab, local_id: []const u8, schema: engine.ComponentSchema, bytes: []const u8) !void {
        const idx = self.indexOf(local_id) orelse return error.UnknownEntity;
        const a = self.arena.allocator();
        var blob: std.ArrayList(u8) = .empty;
        try engine.TypeRegistry.encodeComponent(a, schema, bytes, &blob);
        try self.entities.items[idx].components.append(a, blob.items);
    }
};

/// Handles created by `instantiate`, parallel to `Prefab.entities`.
pub const Instance = struct {
    allocator: std.mem.Allocator,
    handles: []engine.EntityHandle,

    pub fn deinit(self: *Instance) void {
        self.allocator.free(self.handles);
    }

    /// Returns the runtime handle of the prefab entity `local_id`.
    pub fn find(self: *const Instance, prefab: *const Prefab, local_id: []const u8) ?engine.EntityHandle {
        const i = prefab.indexOf(local_id) orelse return null;
        return self.handles[i];
    }
};

/// One component ready to be written: decoded, migrated, and overridden.
pub const PreparedComponent = struct { name: []const u8, size: usize, bytes: []u8 };

/// One entity of a flattened (nested prefabs expanded) instance plan.
pub const PreparedEntity = struct {
    /// Index of the parent within `Prepared.entities`, or null for a root.
    parent: ?u32,
    components: []PreparedComponent,
};

/// Fully validated instance plan. Producing it only reads the `TypeRegistry` and the prefab, never a
/// `World`, so it can run on a worker thread; `commit` then applies it on the main thread.
/// Top-level prefab entities come first (same order as `Prefab.entities`), nested ones follow.
pub const Prepared = struct {
    arena: std.heap.ArenaAllocator,
    entities: []PreparedEntity,
    top_level: usize,

    pub fn deinit(self: *Prepared) void {
        self.arena.deinit();
    }
};

fn prepareInto(
    a: std.mem.Allocator,
    types: *const engine.TypeRegistry,
    prefab: *const Prefab,
    overrides: []const Override,
    resolver: ?Resolver,
    list: *std.ArrayList(PreparedEntity),
    base_parent: ?u32,
    stack: *[max_nesting_depth][]const u8,
    depth: usize,
) !void {
    for (overrides) |ov| {
        if (prefab.indexOf(ov.local_id) == null) return error.UnknownOverrideTarget;
    }
    const base = list.items.len;
    try list.resize(a, base + prefab.entities.items.len);

    for (prefab.entities.items, 0..) |ent, ei| {
        const comps = try a.alloc(PreparedComponent, ent.components.items.len);
        for (ent.components.items, 0..) |blob, ci| {
            const dec = try types.decodeComponent(a, blob);
            for (overrides) |ov| {
                if (!std.mem.eql(u8, ov.local_id, ent.local_id) or ov.stable_id != dec.schema.stable_id) continue;
                try engine.TypeRegistry.setField(dec.schema, dec.bytes, ov.field, ov.value);
            }
            comps[ci] = .{
                .name = try std.fmt.allocPrint(a, "{s}.{s}", .{ dec.schema.namespace, dec.schema.name }),
                .size = dec.schema.byte_size,
                .bytes = dec.bytes,
            };
        }
        const parent: ?u32 = if (ent.parent) |p| @intCast(base + prefab.indexOf(p).?) else base_parent;
        list.items[base + ei] = .{ .parent = parent, .components = comps };
    }

    for (prefab.entities.items, 0..) |ent, ei| {
        const n = ent.nested orelse continue;
        const res = resolver orelse return error.UnknownPrefab;
        if (depth + 1 >= max_nesting_depth) return error.NestingTooDeep;
        for (stack[0..depth]) |name| {
            if (std.mem.eql(u8, name, n.prefab_name)) return error.NestedPrefabCycle;
        }
        const sub = res.lookup(res.ctx, n.prefab_name) orelse return error.UnknownPrefab;
        stack[depth] = n.prefab_name;
        try prepareInto(a, types, sub, n.overrides, resolver, list, @intCast(base + ei), stack, depth + 1);
    }
}

/// Builds the instance plan for `prefab` (decode, migrate, override, expand nested prefabs).
/// Does not touch any `World`. Errors: `UnknownOverrideTarget`, `UnknownSchema`, `MissingMigration`,
/// `FieldNotFound`, `UnknownPrefab`, `NestedPrefabCycle`, `NestingTooDeep`, `OutOfMemory`.
pub fn prepare(
    allocator: std.mem.Allocator,
    types: *const engine.TypeRegistry,
    prefab: *const Prefab,
    opts: InstantiateOptions,
) !Prepared {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var list: std.ArrayList(PreparedEntity) = .empty;
    var stack: [max_nesting_depth][]const u8 = undefined;
    stack[0] = "";
    try prepareInto(a, types, prefab, opts.overrides, opts.resolver, &list, null, &stack, 0);
    return .{ .arena = arena, .entities = list.items, .top_level = prefab.entities.items.len };
}

/// Applies a plan to `world`: registers component types, spawns and fills every entity, then links
/// the hierarchy. Any failure despawns what was created, leaving the world unchanged.
pub fn commit(
    allocator: std.mem.Allocator,
    world: *engine.World,
    plan: *const Prepared,
    opts: InstantiateOptions,
) !Instance {
    // Register every component type up front: the only step that can add pools.
    for (plan.entities) |pe| {
        for (pe.components) |c| {
            _ = try world.registerComponentDesc(.{ .name = c.name, .size = c.size, .alignment = 16, .schema_version = 1 });
        }
    }

    const handles = try allocator.alloc(engine.EntityHandle, plan.entities.len);
    errdefer allocator.free(handles);
    var spawned: usize = 0;
    errdefer for (handles[0..spawned]) |h| {
        _ = world.despawn(h) catch {};
    };
    for (plan.entities, 0..) |pe, i| {
        handles[i] = try world.spawn();
        spawned += 1;
        for (pe.components) |c| {
            const tid = try world.registerComponentDesc(.{ .name = c.name, .size = c.size, .alignment = 16, .schema_version = 1 });
            try world.setRaw(handles[i], tid, c.bytes);
        }
    }

    if (opts.link) |link| {
        for (plan.entities, 0..) |pe, i| {
            if (pe.parent) |p| {
                try link(opts.link_ctx, world, handles[i], handles[p]);
            } else if (opts.root_parent) |rp| {
                try link(opts.link_ctx, world, handles[i], rp);
            }
        }
    }
    return .{ .allocator = allocator, .handles = handles };
}

/// Instantiates `prefab` into `world` (`prepare` + `commit`). Component types must be registered in
/// `types`; older stored versions are migrated to the latest registered version first. Nested
/// prefabs need `opts.resolver`. On error the world has no entities from this call.
pub fn instantiate(
    allocator: std.mem.Allocator,
    world: *engine.World,
    types: *const engine.TypeRegistry,
    prefab: *const Prefab,
    opts: InstantiateOptions,
) !Instance {
    var plan = try prepare(allocator, types, prefab, opts);
    defer plan.deinit();
    return commit(allocator, world, &plan, opts);
}

/// Replaces a live instance with a freshly instantiated one (hot reload of an edited prefab).
/// The new instance is built and fully validated first; only then are the old entities despawned,
/// so any failure leaves `old` untouched and running. On success `old` is consumed (its handles
/// are freed) and the new `Instance` is returned.
pub fn reinstantiate(
    allocator: std.mem.Allocator,
    world: *engine.World,
    types: *const engine.TypeRegistry,
    prefab: *const Prefab,
    old: *Instance,
    opts: InstantiateOptions,
) !Instance {
    const fresh = try instantiate(allocator, world, types, prefab, opts);
    for (old.handles) |h| _ = world.despawn(h) catch {};
    old.deinit();
    old.handles = &.{};
    return fresh;
}

/// Named prefab store registered as a resource by `module()` (`engine.prefab/1`).
pub const PrefabLibrary = struct {
    allocator: std.mem.Allocator,
    prefabs: std.StringHashMapUnmanaged(*Prefab) = .empty,

    pub fn init(allocator: std.mem.Allocator) PrefabLibrary {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PrefabLibrary) void {
        var it = self.prefabs.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            e.value_ptr.*.deinit();
            self.allocator.destroy(e.value_ptr.*);
        }
        self.prefabs.deinit(self.allocator);
    }

    /// Stores `prefab` under `name` (taking ownership); replaces any previous prefab of that name.
    pub fn put(self: *PrefabLibrary, name: []const u8, prefab: Prefab) !void {
        const owned = try self.allocator.create(Prefab);
        errdefer self.allocator.destroy(owned);
        owned.* = prefab;
        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);
        try self.prefabs.ensureUnusedCapacity(self.allocator, 1);
        if (self.prefabs.fetchRemove(name)) |old| {
            self.allocator.free(old.key);
            old.value.deinit();
            self.allocator.destroy(old.value);
        }
        self.prefabs.putAssumeCapacity(key, owned);
    }

    pub fn get(self: *const PrefabLibrary, name: []const u8) ?*const Prefab {
        return self.prefabs.get(name);
    }

    fn lookupThunk(ctx: ?*anyopaque, name: []const u8) ?*const Prefab {
        const lib: *const PrefabLibrary = @ptrCast(@alignCast(ctx.?));
        return lib.get(name);
    }

    /// Resolver that looks nested prefabs up in this library (the library must outlive its use).
    pub fn resolver(self: *const PrefabLibrary) Resolver {
        return .{ .ctx = @constCast(self), .lookup = lookupThunk };
    }
};

fn buildModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    try app.resources.insert(PrefabLibrary, PrefabLibrary.init(app.allocator));
    const lib = app.resources.get(PrefabLibrary).?;
    try app.services.register(.{
        .capability = "engine.prefab",
        .major_version = 1,
        .provider_id = "official.prefab.default",
        .owner_id = MODULE_OWNER_ID,
        .exclusive = true,
        .api_ptr = lib,
        .api_size = @sizeOf(PrefabLibrary),
    });
}

fn stopModule(raw_app: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    _ = app.services.unregisterByOwner(MODULE_OWNER_ID);
    _ = app.resources.remove(PrefabLibrary);
}

pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = "official.prefab",
            .version = "0.2.0",
            .provides_capabilities = &.{"engine.prefab/1"},
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
