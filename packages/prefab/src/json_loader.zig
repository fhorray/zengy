//! JSON authoring format for prefabs and overrides (`std.json`, no external dependencies).
//!
//! ```json
//! { "prefab": { "id": "enemy.guard" },
//!   "entities": [
//!     { "id": "guard", "components": { "game.Stats": { "hp": 150, "armor": 2.5 } } },
//!     { "id": "sword", "parent": "guard", "components": { "game.Pose": { "pos": [0, 1, 0] } } } ] }
//! ```
//! Component keys are `namespace.name` of a schema registered in the `TypeRegistry`; values are
//! built against the *latest* registered version, so authoring files always target the current
//! schema while stored/cooked data goes through migrations. Parsing is strict: unknown component
//! types, unknown fields, wrong value types, and out-of-range numbers are errors, never ignored.
//! Other syntaxes (TOML, editor formats) can feed the same `Prefab` API from their own adapters.

const std = @import("std");
const engine = @import("engine");
const prefab_mod = @import("prefab.zig");

const Value = std.json.Value;
const FieldType = engine.reflection.FieldType;
const FieldValue = engine.reflection.FieldValue;

fn asObject(v: Value) !std.json.ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => error.InvalidDocument,
    };
}

fn numberAsF64(v: Value) !f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch error.InvalidFieldValue,
        else => error.InvalidFieldValue,
    };
}

fn intInRange(comptime T: type, v: Value) !T {
    return switch (v) {
        .integer => |i| std.math.cast(T, i) orelse error.InvalidFieldValue,
        else => error.InvalidFieldValue,
    };
}

fn vecOf(comptime N: usize, v: Value) ![N]f32 {
    const arr = switch (v) {
        .array => |a| a,
        else => return error.InvalidFieldValue,
    };
    if (arr.items.len != N) return error.InvalidFieldValue;
    var out: [N]f32 = undefined;
    for (arr.items, 0..) |item, i| {
        const f = try numberAsF64(item);
        if (!std.math.isFinite(f)) return error.InvalidFieldValue;
        out[i] = @floatCast(f);
    }
    return out;
}

/// Converts a JSON value into a `FieldValue` of the declared field type.
pub fn fieldValueFromJson(ft: FieldType, v: Value) !FieldValue {
    return switch (ft) {
        .bool_t => switch (v) {
            .bool => |b| .{ .bool_t = b },
            else => error.InvalidFieldValue,
        },
        .i32_t => .{ .i32_t = try intInRange(i32, v) },
        .i64_t => .{ .i64_t = try intInRange(i64, v) },
        .u32_t => .{ .u32_t = try intInRange(u32, v) },
        .u64_t => .{ .u64_t = try intInRange(u64, v) },
        .f32_t => .{ .f32_t = @floatCast(try numberAsF64(v)) },
        .f64_t => .{ .f64_t = try numberAsF64(v) },
        .vec2_t => .{ .vec2_t = try vecOf(2, v) },
        .vec3_t => .{ .vec3_t = try vecOf(3, v) },
        .vec4_t => .{ .vec4_t = try vecOf(4, v) },
    };
}

fn splitTypeName(full: []const u8) !struct { ns: []const u8, name: []const u8 } {
    const dot = std.mem.lastIndexOfScalar(u8, full, '.') orelse return error.UnknownComponentType;
    if (dot == 0 or dot + 1 >= full.len) return error.UnknownComponentType;
    return .{ .ns = full[0..dot], .name = full[dot + 1 ..] };
}

fn fieldType(schema: engine.ComponentSchema, field: []const u8) ?FieldType {
    for (schema.fields) |f| {
        if (std.mem.eql(u8, f.name, field)) return f.field_type;
    }
    return null;
}

/// Parses a prefab document. The returned `Prefab` owns its data; `text` may be freed afterwards.
pub fn parsePrefab(allocator: std.mem.Allocator, types: *const engine.TypeRegistry, text: []const u8) !prefab_mod.Prefab {
    var parsed = try std.json.parseFromSlice(Value, allocator, text, .{});
    defer parsed.deinit();
    return parsePrefabValue(allocator, types, parsed.value);
}

/// Builds a `Prefab` from an already-parsed document tree with the layout described above.
/// Adapters for other syntaxes (e.g. TOML) convert their tree to `std.json.Value` and call this.
pub fn parsePrefabValue(allocator: std.mem.Allocator, types: *const engine.TypeRegistry, doc: Value) !prefab_mod.Prefab {
    const root = try asObject(doc);
    const entities = switch (root.get("entities") orelse return error.InvalidDocument) {
        .array => |a| a,
        else => return error.InvalidDocument,
    };

    var pf = prefab_mod.Prefab.init(allocator);
    errdefer pf.deinit();

    for (entities.items) |ev| {
        const eo = try asObject(ev);
        const id = switch (eo.get("id") orelse return error.InvalidDocument) {
            .string => |s| s,
            else => return error.InvalidDocument,
        };
        const parent: ?[]const u8 = if (eo.get("parent")) |pv| switch (pv) {
            .string => |s| s,
            .null => null,
            else => return error.InvalidDocument,
        } else null;
        try pf.addEntity(id, parent);

        const comps = if (eo.get("components")) |c| try asObject(c) else continue;
        var it = comps.iterator();
        while (it.next()) |entry| {
            const tn = try splitTypeName(entry.key_ptr.*);
            const schema = types.getLatest(tn.ns, tn.name) orelse return error.UnknownComponentType;
            const bytes = try allocator.alloc(u8, schema.byte_size);
            defer allocator.free(bytes);
            @memset(bytes, 0);
            const fields = try asObject(entry.value_ptr.*);
            var fit = fields.iterator();
            while (fit.next()) |fe| {
                const ft = fieldType(schema, fe.key_ptr.*) orelse return error.UnknownField;
                try engine.TypeRegistry.setField(schema, bytes, fe.key_ptr.*, try fieldValueFromJson(ft, fe.value_ptr.*));
            }
            try pf.addComponent(id, schema, bytes);
        }
    }
    return pf;
}

/// Parses an overrides array: `[{"entity":"guard","component":"game.Stats","field":"hp","value":250}]`.
/// Strings in the result are owned by `arena`.
pub fn parseOverrides(arena: std.mem.Allocator, types: *const engine.TypeRegistry, text: []const u8) ![]const prefab_mod.Override {
    const parsed = try std.json.parseFromSliceLeaky(Value, arena, text, .{});
    const arr = switch (parsed) {
        .array => |a| a,
        else => return error.InvalidDocument,
    };
    const out = try arena.alloc(prefab_mod.Override, arr.items.len);
    for (arr.items, 0..) |item, i| {
        const o = try asObject(item);
        const str = struct {
            fn get(obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
                return switch (obj.get(key) orelse return error.InvalidDocument) {
                    .string => |s| s,
                    else => error.InvalidDocument,
                };
            }
        }.get;
        const tn = try splitTypeName(try str(o, "component"));
        const schema = types.getLatest(tn.ns, tn.name) orelse return error.UnknownComponentType;
        const field = try str(o, "field");
        const ft = fieldType(schema, field) orelse return error.UnknownField;
        out[i] = .{
            .local_id = try str(o, "entity"),
            .stable_id = schema.stable_id,
            .field = field,
            .value = try fieldValueFromJson(ft, o.get("value") orelse return error.InvalidDocument),
        };
    }
    return out;
}
