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
};

/// Optional asset registry, importer resolver, and artifact cache.
pub const AssetService = struct {
    allocator: std.mem.Allocator,
    importers: std.ArrayList(ImporterDescriptor),
    assets: std.ArrayList(AssetSlot),
    uri_to_index: std.StringHashMapUnmanaged(u32),

    pub fn init(allocator: std.mem.Allocator) AssetService {
        return .{
            .allocator = allocator,
            .importers = .empty,
            .assets = .empty,
            .uri_to_index = .empty,
        };
    }

    pub fn deinit(self: *AssetService) void {
        for (self.assets.items) |slot| {
            self.allocator.free(slot.uri);
            if (slot.alive) {
                self.allocator.free(slot.kind);
                self.allocator.free(slot.bytes);
            }
        }
        self.assets.deinit(self.allocator);
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

        const idx: u32 = @intCast(self.assets.items.len);
        const hash = std.hash.Wyhash.hash(0, raw_source);

        try self.assets.append(self.allocator, .{
            .uri = uri_copy,
            .kind = artifact.kind,
            .bytes = artifact.bytes,
            .content_hash = hash,
            .version = 1,
            .generation = 1,
            .alive = true,
        });
        errdefer _ = self.assets.pop();
        try self.uri_to_index.put(self.allocator, uri_copy, idx);

        return .{ .index = idx, .generation = 1 };
    }

    /// Re-imports an existing asset in place, bumping its version while preserving its handle.
    pub fn reload(self: *AssetService, handle: AssetHandle, new_source: []const u8) !void {
        const slot = self.getSlotMut(handle) orelse return error.InvalidAssetHandle;
        const importer = self.resolveImporter(slot.uri) orelse return error.ImporterNotFound;
        const artifact = try importer.import_fn(self.allocator, slot.uri, new_source);

        self.allocator.free(slot.kind);
        self.allocator.free(slot.bytes);
        slot.kind = artifact.kind;
        slot.bytes = artifact.bytes;
        slot.content_hash = std.hash.Wyhash.hash(0, new_source);
        slot.version += 1;
    }

    /// Releases an asset and bumps its generation so stale handles are rejected.
    pub fn unload(self: *AssetService, handle: AssetHandle) bool {
        const slot = self.getSlotMut(handle) orelse return false;
        _ = self.uri_to_index.remove(slot.uri);
        self.allocator.free(slot.uri);
        slot.uri = &.{};
        self.allocator.free(slot.kind);
        slot.kind = &.{};
        self.allocator.free(slot.bytes);
        slot.bytes = &.{};
        slot.alive = false;
        slot.generation +%= 1;
        return true;
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
    if (app.resources.get(AssetService)) |svc| {
        svc.deinit();
        _ = app.resources.remove(AssetService);
    }
}

pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = "official.assets",
            .version = "0.1.0",
            .provides_capabilities = &.{"engine.assets/1"},
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
