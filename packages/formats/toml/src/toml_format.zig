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

/// Errors of the TOML -> JSON bridge.
pub const JsonBridgeError = error{ OutOfMemory, UnsupportedTomlValue };

/// Converts a parsed TOML table (as returned by `TomlService.parseTable`) into a JSON object.
pub fn tableToJsonValue(arena: std.mem.Allocator, table: *const toml.Table) JsonBridgeError!std.json.Value {
    var out: std.json.ObjectMap = .empty;
    try out.ensureTotalCapacity(arena, table.count());
    var it = table.iterator();
    while (it.next()) |e| {
        out.putAssumeCapacity(try arena.dupe(u8, e.key_ptr.*), try toJsonValue(arena, e.value_ptr.*));
    }
    return .{ .object = out };
}

/// Converts a parsed TOML value into the equivalent `std.json.Value` tree, so authoring code that
/// is syntax-agnostic (for example `prefab.json.parsePrefabValue`) can consume TOML documents.
/// All containers and strings are allocated from `arena` (free by resetting it). Date/time values
/// have no JSON counterpart and return `error.UnsupportedTomlValue`.
pub fn toJsonValue(arena: std.mem.Allocator, value: toml.Value) JsonBridgeError!std.json.Value {
    switch (value) {
        .string => |s| return .{ .string = try arena.dupe(u8, s) },
        .integer => |i| return .{ .integer = i.value },
        .float => |f| return .{ .float = f },
        .boolean => |b| return .{ .bool = b },
        .array => |arr| {
            var out = std.json.Array.init(arena);
            try out.ensureTotalCapacity(arr.items.len);
            for (arr.items) |item| out.appendAssumeCapacity(try toJsonValue(arena, item));
            return .{ .array = out };
        },
        .table => |t| return tableToJsonValue(arena, t),
        .offset_datetime, .local_datetime, .local_date, .local_time => return error.UnsupportedTomlValue,
    }
}

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

    pub const GameManifest = struct {
        title: []const u8,
        width: u32 = 1280,
        height: u32 = 720,
        mode: []const u8,
        entry_script: []const u8,
        ui: []const u8,
        plugins: []const []const u8 = &.{},

        pub fn deinit(self: *GameManifest, allocator: std.mem.Allocator) void {
            allocator.free(self.title);
            allocator.free(self.mode);
            allocator.free(self.entry_script);
            allocator.free(self.ui);
            for (self.plugins) |p| allocator.free(p);
            if (self.plugins.len > 0) allocator.free(self.plugins);
        }
    };

    /// Parses a `game.toml` project manifest (`[game]` table).
    pub fn parseGameManifest(allocator: std.mem.Allocator, source: []const u8) !GameManifest {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const root = try toml.parseSlice(arena.allocator(), source, null);
        const game_val = root.get("game") orelse return error.MissingGameSection;
        const tbl = switch (game_val) {
            .table => |t| t,
            else => return error.InvalidGameSection,
        };

        const title_s = if (tbl.get("title")) |v| (if (v == .string) v.string else "Zengy Game") else "Zengy Game";
        const mode_s = if (tbl.get("mode")) |v| (if (v == .string) v.string else "2d") else "2d";
        const script_s = if (tbl.get("entry_script")) |v| (if (v == .string) v.string else "") else "";
        const ui_s = if (tbl.get("ui")) |v| (if (v == .string) v.string else "") else "";
        const w: u32 = if (tbl.get("width")) |v| (if (v == .integer and v.integer.value > 0) @intCast(v.integer.value) else 1280) else 1280;
        const h: u32 = if (tbl.get("height")) |v| (if (v == .integer and v.integer.value > 0) @intCast(v.integer.value) else 720) else 720;

        var plugins_list: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (plugins_list.items) |p| allocator.free(p);
            plugins_list.deinit(allocator);
        }
        if (tbl.get("plugins")) |pv| {
            if (pv == .array) {
                for (pv.array.items) |item| {
                    if (item == .string) {
                        try plugins_list.append(allocator, try allocator.dupe(u8, item.string));
                    }
                }
            }
        }

        const title_copy = try allocator.dupe(u8, title_s);
        errdefer allocator.free(title_copy);
        const mode_copy = try allocator.dupe(u8, mode_s);
        errdefer allocator.free(mode_copy);
        const script_copy = try allocator.dupe(u8, script_s);
        errdefer allocator.free(script_copy);
        const ui_copy = try allocator.dupe(u8, ui_s);
        errdefer allocator.free(ui_copy);

        return .{
            .title = title_copy,
            .width = w,
            .height = h,
            .mode = mode_copy,
            .entry_script = script_copy,
            .ui = ui_copy,
            .plugins = try plugins_list.toOwnedSlice(allocator),
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
