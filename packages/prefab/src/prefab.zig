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

pub const InstantiateOptions = struct {
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

const Decoded = struct { tid: engine.ComponentTypeId, bytes: []u8 };

/// Instantiates `prefab` into `world`. Component types must be registered in `types`; older
/// stored versions are migrated to the latest registered version first.
/// Errors leave the world with no entities from this call (`UnknownOverrideTarget`,
/// `UnknownSchema`, `MissingMigration`, `FieldNotFound`, `OutOfMemory`, ...).
pub fn instantiate(
    allocator: std.mem.Allocator,
    world: *engine.World,
    types: *const engine.TypeRegistry,
    prefab: *const Prefab,
    opts: InstantiateOptions,
) !Instance {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const sa = scratch.allocator();

    for (opts.overrides) |ov| {
        if (prefab.indexOf(ov.local_id) == null) return error.UnknownOverrideTarget;
    }

    // Phase 1: decode, migrate, override, and register every component without touching entities.
    const per_entity = try sa.alloc([]Decoded, prefab.entities.items.len);
    for (prefab.entities.items, 0..) |ent, ei| {
        const list = try sa.alloc(Decoded, ent.components.items.len);
        for (ent.components.items, 0..) |blob, ci| {
            const dec = try types.decodeComponent(sa, blob);
            for (opts.overrides) |ov| {
                if (!std.mem.eql(u8, ov.local_id, ent.local_id) or ov.stable_id != dec.schema.stable_id) continue;
                try engine.TypeRegistry.setField(dec.schema, dec.bytes, ov.field, ov.value);
            }
            const full = try std.fmt.allocPrint(sa, "{s}.{s}", .{ dec.schema.namespace, dec.schema.name });
            const tid = try world.registerComponentDesc(.{ .name = full, .size = dec.schema.byte_size, .alignment = 16, .schema_version = 1 });
            list[ci] = .{ .tid = tid, .bytes = dec.bytes };
        }
        per_entity[ei] = list;
    }

    // Phase 2: spawn + fill; undo everything on failure.
    const handles = try allocator.alloc(engine.EntityHandle, prefab.entities.items.len);
    errdefer allocator.free(handles);
    var spawned: usize = 0;
    errdefer for (handles[0..spawned]) |h| {
        _ = world.despawn(h) catch {};
    };
    for (prefab.entities.items, 0..) |_, i| {
        handles[i] = try world.spawn();
        spawned += 1;
        for (per_entity[i]) |d| try world.setRaw(handles[i], d.tid, d.bytes);
    }

    // Phase 3: hierarchy.
    if (opts.link) |link| {
        for (prefab.entities.items, 0..) |ent, i| {
            if (ent.parent) |p| {
                try link(opts.link_ctx, world, handles[i], handles[prefab.indexOf(p).?]);
            } else if (opts.root_parent) |rp| {
                try link(opts.link_ctx, world, handles[i], rp);
            }
        }
    }
    return .{ .allocator = allocator, .handles = handles };
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
            .version = "0.1.0",
            .provides_capabilities = &.{"engine.prefab/1"},
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
