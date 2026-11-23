//! Optional TOML Format Adapter Package (`official.format.toml`).
//!
//! Wraps the external `z-toml` library behind a stable engine capability
//! (`engine.format.toml/1`) without introducing any TOML dependency into `src/core/`.
//!
//! Primary use case: parsing `engine.package.toml` manifests and project configs.

const std = @import("std");
const engine = @import("engine");
const toml = @import("toml");

pub const MODULE_OWNER_ID: u64 = 2010;

/// Parsed package manifest metadata extracted from `engine.package.toml`.
pub const PackageManifest = struct {
    id: []const u8,
    version: []const u8,
    kind: []const u8,
    abi_major: i64 = 1,
};

/// Engine adapter service over `z-toml`.
pub const TomlService = struct {
    /// Parses a TOML string into a dynamic `*toml.Table` owned by `allocator`.
    pub fn parseTable(allocator: std.mem.Allocator, source: []const u8) !*toml.Table {
        return toml.parseSlice(allocator, source, null);
    }

    /// Frees a `*toml.Table` previously returned by `parseTable`.
    pub fn freeTable(allocator: std.mem.Allocator, table: *toml.Table) void {
        toml.deinit(table, allocator);
    }

    /// Parses a `PackageManifest` from an `engine.package.toml` document.
    /// Caller owns the returned strings (allocated via `allocator`).
    pub fn parsePackageManifest(allocator: std.mem.Allocator, source: []const u8) !PackageManifest {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const root = try toml.parseSlice(arena.allocator(), source, null);
        const pkg_val = root.get("package") orelse return error.MissingPackageSection;
        const pkg_tbl = switch (pkg_val) {
            .table => |t| t,
            else => return error.InvalidPackageSection,
        };

        const id_str = switch (pkg_tbl.get("id") orelse return error.MissingPackageId) {
            .string => |s| s,
            else => return error.InvalidPackageId,
        };
        const ver_str = switch (pkg_tbl.get("version") orelse return error.MissingPackageVersion) {
            .string => |s| s,
            else => return error.InvalidPackageVersion,
        };
        const kind_str = if (pkg_tbl.get("kind")) |k| switch (k) {
            .string => |s| s,
            else => "native-module",
        } else "native-module";

        var abi_major: i64 = 1;
        if (root.get("compatibility")) |compat_val| {
            if (compat_val == .table) {
                if (compat_val.table.get("abi_major")) |m| {
                    if (m == .integer) abi_major = m.integer.value;
                }
            }
        }

        const id_copy = try allocator.dupe(u8, id_str);
        errdefer allocator.free(id_copy);
        const ver_copy = try allocator.dupe(u8, ver_str);
        errdefer allocator.free(ver_copy);
        const kind_copy = try allocator.dupe(u8, kind_str);

        return .{
            .id = id_copy,
            .version = ver_copy,
            .kind = kind_copy,
            .abi_major = abi_major,
        };
    }
};

var g_toml_service = TomlService{};

fn buildModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    try app.services.register(.{
        .capability = "engine.format.toml",
        .major_version = 1,
        .provider_id = "official.format.toml.z_toml",
        .owner_id = MODULE_OWNER_ID,
        .exclusive = true,
        .api_ptr = &g_toml_service,
        .api_size = @sizeOf(TomlService),
    });
}

fn stopModule(raw_app: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    _ = app.services.unregisterByOwner(MODULE_OWNER_ID);
}

pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = "official.format.toml",
            .version = "0.1.0",
            .provides_capabilities = &.{"engine.format.toml/1"},
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
