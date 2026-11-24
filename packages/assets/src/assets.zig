//! Optional Asset Management & Importer Package (`official.assets`).
//!
//! Provides `AssetService` (`engine.assets/1`) as an optional `engine.Module`
//! without adding any asset-format or filesystem coupling to `src/core/`.
//!
//! Features:
//! - URI-based asset resolution (`project://`, `engine://`, `package://`).
//! - Extensible `ImporterDescriptor` registry with extension matching and priority selection.
//! - Generational `AssetHandle` (never exposes raw internal pointers across plugins).
//! - Content-addressed / URI deduplication cache and safe `reload()` swap.

const std = @import("std");
const engine = @import("engine");

/// Owner ID used when registering asset services and default importers.
pub const MODULE_OWNER_ID: u64 = 2006;

/// Opaque generational handle to a loaded asset artifact.
pub const AssetHandle = packed struct(u64) {
    index: u32,
    generation: u32,
};

/// Decoded asset payload produced by an importer.
pub const AssetArtifact = struct {
    kind: []const u8,
    bytes: []u8,
};

/// Callback signature implemented by asset format importers.
pub const ImportFn = *const fn (allocator: std.mem.Allocator, uri: []const u8, raw_source: []const u8) anyerror!AssetArtifact;

/// Importer plugin contract registered by official or community asset packages.
pub const ImporterDescriptor = struct {
    id: []const u8,
    extension: []const u8,
    priority: u32 = 100,
    owner_id: u64 = 0,
    import_fn: ImportFn,
};

const AssetSlot = struct {
    uri: []const u8,
    kind: []const u8,
    bytes: []u8,
    content_hash: u64,
    version: u32,
    generation: u32,
    alive: bool,
    /// Assets this one was built from (e.g. a material's textures); see `addDependency`.
    dependencies: std.ArrayList(AssetHandle) = .empty,
};

/// Optional asset registry, importer resolver, and artifact cache.
pub const AssetService = struct {
    allocator: std.mem.Allocator,
    importers: std.ArrayList(ImporterDescriptor),
    assets: std.ArrayList(AssetSlot),
    free_indices: std.ArrayList(u32),
    retired_allocs: std.ArrayList([]u8),
    uri_to_index: std.StringHashMapUnmanaged(u32),

    pub fn init(allocator: std.mem.Allocator) AssetService {
        return .{
            .allocator = allocator,
            .importers = .empty,
            .assets = .empty,
            .free_indices = .empty,
            .retired_allocs = .empty,
            .uri_to_index = .empty,
        };
    }

    pub fn collectGarbage(self: *AssetService) void {
        for (self.retired_allocs.items) |buf| {
            self.allocator.free(buf);
        }
        self.retired_allocs.clearRetainingCapacity();
    }

    pub fn deinit(self: *AssetService) void {
        self.collectGarbage();
        self.retired_allocs.deinit(self.allocator);
        for (self.assets.items) |slot| {
            if (slot.uri.len > 0) self.allocator.free(slot.uri);
            if (slot.alive) {
                self.allocator.free(slot.kind);
                self.allocator.free(slot.bytes);
            }
        }
        for (self.assets.items) |*slot| slot.dependencies.deinit(self.allocator);
        self.assets.deinit(self.allocator);
        self.free_indices.deinit(self.allocator);
        for (self.importers.items) |imp| {
            self.allocator.free(imp.id);
            self.allocator.free(imp.extension);
        }
        self.importers.deinit(self.allocator);
        self.uri_to_index.deinit(self.allocator);
    }

    /// Registers an importer for a file extension (e.g., `.png`, `.novaui`, `.json`).
    pub fn registerImporter(self: *AssetService, desc: ImporterDescriptor) !void {
        const id_copy = try self.allocator.dupe(u8, desc.id);
        errdefer self.allocator.free(id_copy);
        const ext_copy = try self.allocator.dupe(u8, desc.extension);
        errdefer self.allocator.free(ext_copy);

        try self.importers.append(self.allocator, .{
            .id = id_copy,
            .extension = ext_copy,
            .priority = desc.priority,
            .owner_id = desc.owner_id,
            .import_fn = desc.import_fn,
        });
    }

    /// Unregisters all importers owned by `owner_id` (safe module/plugin unload).
    pub fn unregisterImportersByOwner(self: *AssetService, owner_id: u64) usize {
        var removed: usize = 0;
        var i: usize = 0;
        while (i < self.importers.items.len) {
            if (self.importers.items[i].owner_id == owner_id) {
                const imp = self.importers.orderedRemove(i);
                self.allocator.free(imp.id);
                self.allocator.free(imp.extension);
                removed += 1;
            } else {
                i += 1;
            }
        }
        return removed;
    }

    /// Selects the highest-priority importer matching the URI's extension (case-insensitive).
    pub fn resolveImporter(self: *const AssetService, uri: []const u8) ?ImporterDescriptor {
        var best: ?ImporterDescriptor = null;
        for (self.importers.items) |imp| {
            if (uri.len >= imp.extension.len and
                std.ascii.eqlIgnoreCase(uri[uri.len - imp.extension.len ..], imp.extension))
            {
                if (best == null or imp.priority > best.?.priority) {
                    best = imp;
                }
            }
        }
        return best;
    }

    /// Imports `raw_source` for `uri` or returns the cached `AssetHandle` if already loaded.
    pub fn loadFromBytes(self: *AssetService, uri: []const u8, raw_source: []const u8) !AssetHandle {
        if (self.uri_to_index.get(uri)) |idx| {
            const slot = &self.assets.items[idx];
            if (slot.alive) {
                return .{ .index = idx, .generation = slot.generation };
            }
        }

        const importer = self.resolveImporter(uri) orelse return error.ImporterNotFound;
        const artifact = try importer.import_fn(self.allocator, uri, raw_source);
        errdefer {
            self.allocator.free(artifact.kind);
            self.allocator.free(artifact.bytes);
        }

        const uri_copy = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(uri_copy);

        const hash = std.hash.Wyhash.hash(0, raw_source);
        // Reserve every container slot first so no failure can happen after state is modified.
        try self.uri_to_index.ensureUnusedCapacity(self.allocator, 1);
        if (self.free_indices.items.len == 0) try self.assets.ensureUnusedCapacity(self.allocator, 1);

        if (self.free_indices.pop()) |reused_idx| {
            const slot = &self.assets.items[reused_idx];
            const gen = if (slot.generation == 0) @as(u32, 1) else slot.generation;
            self.uri_to_index.putAssumeCapacity(uri_copy, reused_idx);
            slot.* = .{
                .uri = uri_copy,
                .kind = artifact.kind,
                .bytes = artifact.bytes,
                .content_hash = hash,
                .version = 1,
                .generation = gen,
                .alive = true,
                .dependencies = slot.dependencies, // emptied by unload; keep its capacity
            };
            return .{ .index = reused_idx, .generation = gen };
        }

        const idx: u32 = @intCast(self.assets.items.len);
        self.assets.appendAssumeCapacity(.{
            .uri = uri_copy,
            .kind = artifact.kind,
            .bytes = artifact.bytes,
            .content_hash = hash,
            .version = 1,
            .generation = 1,
            .alive = true,
        });
        self.uri_to_index.putAssumeCapacity(uri_copy, idx);
        return .{ .index = idx, .generation = 1 };
    }

    /// Re-imports an existing asset in place, bumping its version while preserving its handle.
    /// Retired payloads stay valid until `collectGarbage()` or `deinit()`.
    pub fn reload(self: *AssetService, handle: AssetHandle, new_source: []const u8) !void {
        const slot = self.getSlotMut(handle) orelse return error.InvalidAssetHandle;
        const importer = self.resolveImporter(slot.uri) orelse return error.ImporterNotFound;
        const artifact = try importer.import_fn(self.allocator, slot.uri, new_source);
        errdefer {
            self.allocator.free(artifact.kind);
            self.allocator.free(artifact.bytes);
        }

        // Reserve both retirement entries before swapping so a failure cannot leave a buffer
        // owned by both the slot and the retired list (double-free) or free the old payload early.
        try self.retired_allocs.ensureUnusedCapacity(self.allocator, 2);
        self.retired_allocs.appendAssumeCapacity(@constCast(slot.kind));
        self.retired_allocs.appendAssumeCapacity(slot.bytes);
        slot.kind = artifact.kind;
        slot.bytes = artifact.bytes;
        slot.content_hash = std.hash.Wyhash.hash(0, new_source);
        slot.version += 1;
    }

    /// Releases an asset, bumps its generation so stale handles are rejected, and queues slot reuse.
    ///
    /// Payloads are retired (not freed) so slices from `getBytes` stay valid until
    /// `collectGarbage()`. Returns false, leaving the asset loaded and unchanged, when the handle
    /// is stale or the bookkeeping memory could not be reserved.
    pub fn unload(self: *AssetService, handle: AssetHandle) bool {
        const slot = self.getSlotMut(handle) orelse return false;
        self.retired_allocs.ensureUnusedCapacity(self.allocator, 2) catch return false;
        self.free_indices.ensureUnusedCapacity(self.allocator, 1) catch return false;

        slot.dependencies.clearRetainingCapacity();
        _ = self.uri_to_index.remove(slot.uri);
        self.allocator.free(slot.uri);
        slot.uri = &.{};
        self.retired_allocs.appendAssumeCapacity(@constCast(slot.kind));
        slot.kind = &.{};
        self.retired_allocs.appendAssumeCapacity(slot.bytes);
        slot.bytes = &.{};
        slot.alive = false;
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
        self.free_indices.appendAssumeCapacity(handle.index);
        return true;
    }

    /// Records that `asset` depends on `depends_on` (for example a material on its textures).
    /// Rejects stale handles, self-dependency, duplicates (no-op), and cycles (`DependencyCycle`).
    pub fn addDependency(self: *AssetService, asset: AssetHandle, depends_on: AssetHandle) !void {
        const slot = self.getSlotMut(asset) orelse return error.InvalidAssetHandle;
        if (self.getSlotMut(depends_on) == null) return error.InvalidAssetHandle;
        if (std.meta.eql(asset, depends_on) or self.dependsOn(depends_on, asset)) return error.DependencyCycle;
        for (slot.dependencies.items) |d| {
            if (std.meta.eql(d, depends_on)) return;
        }
        try slot.dependencies.append(self.allocator, depends_on);
    }

    /// Direct dependencies of `asset` (empty for stale handles).
    pub fn dependenciesOf(self: *const AssetService, asset: AssetHandle) []const AssetHandle {
        if (asset.index >= self.assets.items.len) return &.{};
        const slot = &self.assets.items[asset.index];
        if (!slot.alive or slot.generation != asset.generation) return &.{};
        return slot.dependencies.items;
    }

    /// True when `asset` reaches `target` through its (transitive) dependencies.
    pub fn dependsOn(self: *const AssetService, asset: AssetHandle, target: AssetHandle) bool {
        return self.dependsOnDepth(asset, target, self.assets.items.len);
    }

    fn dependsOnDepth(self: *const AssetService, asset: AssetHandle, target: AssetHandle, budget: usize) bool {
        if (budget == 0) return true; // longer than the asset table: only possible with a cycle
        for (self.dependenciesOf(asset)) |d| {
            if (std.meta.eql(d, target) or self.dependsOnDepth(d, target, budget - 1)) return true;
        }
        return false;
    }

    /// Returns every live asset that (transitively) depends on `asset`. Caller frees the slice.
    pub fn dependentsOf(self: *const AssetService, allocator: std.mem.Allocator, asset: AssetHandle) ![]AssetHandle {
        var out: std.ArrayList(AssetHandle) = .empty;
        errdefer out.deinit(allocator);
        for (self.assets.items, 0..) |slot, i| {
            if (!slot.alive) continue;
            const h: AssetHandle = .{ .index = @intCast(i), .generation = slot.generation };
            if (self.dependsOn(h, asset)) try out.append(allocator, h);
        }
        return out.toOwnedSlice(allocator);
    }

    /// Unloads `asset` only when no live asset depends on it; returns false (nothing changes)
    /// otherwise, so shared textures are not freed from under their users.
    pub fn unloadIfUnreferenced(self: *AssetService, asset: AssetHandle) bool {
        if (self.getSlotMut(asset) == null) return false;
        for (self.assets.items, 0..) |slot, i| {
            if (!slot.alive) continue;
            const h: AssetHandle = .{ .index = @intCast(i), .generation = slot.generation };
            for (slot.dependencies.items) |d| {
                if (std.meta.eql(d, asset) and !std.meta.eql(h, asset)) return false;
            }
        }
        return self.unload(asset);
    }

    /// Reloads `asset` from `new_source` and bumps the version of every transitive dependent so
    /// consumers know to rebuild. Returns the number of dependents invalidated. If the reload
    /// fails nothing is invalidated.
    pub fn reloadAndInvalidate(self: *AssetService, asset: AssetHandle, new_source: []const u8) !usize {
        try self.reload(asset, new_source);
        const deps = try self.dependentsOf(self.allocator, asset);
        defer self.allocator.free(deps);
        for (deps) |d| self.getSlotMut(d).?.version += 1;
        return deps.len;
    }

    pub fn getBytes(self: *const AssetService, handle: AssetHandle) ?[]const u8 {
        if (handle.index >= self.assets.items.len) return null;
        const slot = &self.assets.items[handle.index];
        if (!slot.alive or slot.generation != handle.generation) return null;
        return slot.bytes;
    }

    pub fn getVersion(self: *const AssetService, handle: AssetHandle) ?u32 {
        if (handle.index >= self.assets.items.len) return null;
        const slot = &self.assets.items[handle.index];
        if (!slot.alive or slot.generation != handle.generation) return null;
        return slot.version;
    }

    fn getSlotMut(self: *AssetService, handle: AssetHandle) ?*AssetSlot {
        if (handle.index >= self.assets.items.len) return null;
        const slot = &self.assets.items[handle.index];
        if (!slot.alive or slot.generation != handle.generation) return null;
        return slot;
    }
};

fn buildModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    try app.resources.insert(AssetService, AssetService.init(app.allocator));
    const svc = app.resources.get(AssetService).?;

    try app.services.register(.{
        .capability = "engine.assets",
        .major_version = 1,
        .provider_id = "official.assets.default",
        .owner_id = MODULE_OWNER_ID,
        .exclusive = true,
        .api_ptr = svc,
        .api_size = @sizeOf(AssetService),
    });
}

fn stopModule(raw_app: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    _ = app.services.unregisterByOwner(MODULE_OWNER_ID);
    _ = app.resources.remove(AssetService);
}

pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = "official.assets",
            .version = "0.2.0",
            .provides_capabilities = &.{"engine.assets/1"},
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
