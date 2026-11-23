//! Optional JSON Format Adapter Package (`official.format.json`).
//!
//! Provides `JsonService` (`engine.format.json/1`) exposing two interchangeable
//! parsing paths:
//! - `std.json` (native Zig, zero external C code, ideal for small configs)
//! - `yyjson` (high-throughput C parser, ideal for large 100 KB - 100 MB scene/asset payloads)

const std = @import("std");
const engine = @import("engine");
const yyjson_c = @import("yyjson_c");

pub const MODULE_OWNER_ID: u64 = 2011;

pub const JsonBackend = enum {
    std_json,
    yyjson,
};

pub const JsonStats = struct {
    root_type: enum { object, array, other },
    child_count: usize,
};

/// Engine adapter service over `std.json` and `yyjson`.
pub const JsonService = struct {
    /// Parses a JSON document using `std.json` and returns structural stats.
    pub fn inspectStdJson(allocator: std.mem.Allocator, source: []const u8) !JsonStats {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, source, .{});
        defer parsed.deinit();

        return switch (parsed.value) {
            .object => |obj| .{ .root_type = .object, .child_count = obj.count() },
            .array => |arr| .{ .root_type = .array, .child_count = arr.items.len },
            else => .{ .root_type = .other, .child_count = 0 },
        };
    }

    /// Parses a JSON document using `yyjson` (C11) and returns structural stats.
    pub fn inspectYyjson(source: []const u8) !JsonStats {
        const doc = yyjson_c.yyjson_read(source.ptr, source.len, 0) orelse return error.InvalidJson;
        defer yyjson_c.yyjson_doc_free(doc);

        const root = yyjson_c.yyjson_doc_get_root(doc) orelse return error.InvalidJson;
        if (yyjson_c.yyjson_is_obj(root)) {
            return .{ .root_type = .object, .child_count = yyjson_c.yyjson_obj_size(root) };
        }
        if (yyjson_c.yyjson_is_arr(root)) {
            return .{ .root_type = .array, .child_count = yyjson_c.yyjson_arr_size(root) };
        }
        return .{ .root_type = .other, .child_count = 0 };
    }
};

var g_json_service = JsonService{};

fn buildModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    try app.services.register(.{
        .capability = "engine.format.json",
        .major_version = 1,
        .provider_id = "official.format.json.dual",
        .owner_id = MODULE_OWNER_ID,
        .exclusive = true,
        .api_ptr = &g_json_service,
        .api_size = @sizeOf(JsonService),
    });
}

fn stopModule(raw_app: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    _ = app.services.unregisterByOwner(MODULE_OWNER_ID);
}

pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = "official.format.json",
            .version = "0.1.0",
            .provides_capabilities = &.{"engine.format.json/1"},
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
