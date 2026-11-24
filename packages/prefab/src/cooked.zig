//! Cooked (runtime-ready) binary prefab format.
//!
//! Layout (all integers little-endian):
//! `"ZPFB" | format_version u16 | flags u16 | entity_count u32 | entities... | crc32 u32`
//! where each entity is `local_id str | parent_index u32 (0xFFFFFFFF = none) | component_count u32 |
//! blob... | nested u8 | [prefab_name str | override_count u32 | override...]`, a blob/str is a `u32` length
//! plus bytes, and an override is `local_id str | stable_id u128 | field str | tag u8 | payload`.
//! Component blobs are the portable `TypeRegistry.encodeComponent` encoding, so a cooked prefab
//! stays loadable across schema changes through migrations. The trailing CRC-32 covers every
//! preceding byte; `load` rejects any file whose checksum, bounds, or structure is invalid and
//! never reads outside the input.

const std = @import("std");
const engine = @import("engine");
const prefab_mod = @import("prefab.zig");

const FieldType = engine.reflection.FieldType;
const FieldValue = engine.reflection.FieldValue;

pub const magic = "ZPFB";
pub const format_version: u16 = 1;
const no_parent: u32 = 0xFFFF_FFFF;

pub const CookError = error{ OutOfMemory, EntityNotFound };
pub const LoadError = error{ CorruptPrefab, UnsupportedCookedVersion, OutOfMemory } || prefab_mod.PrefabError;

fn putU32(out: *std.ArrayList(u8), a: std.mem.Allocator, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try out.appendSlice(a, &b);
}

fn putStr(out: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    try putU32(out, a, @intCast(s.len));
    try out.appendSlice(a, s);
}

fn putValue(out: *std.ArrayList(u8), a: std.mem.Allocator, v: FieldValue) !void {
    try out.append(a, @intFromEnum(@as(FieldType, v)));
    switch (v) {
        .bool_t => |x| try out.append(a, if (x) 1 else 0),
        .i32_t => |x| try putU32(out, a, @bitCast(x)),
        .u32_t => |x| try putU32(out, a, x),
        .f32_t => |x| try putU32(out, a, @bitCast(x)),
        .i64_t => |x| try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u64, @bitCast(x)))),
        .u64_t => |x| try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u64, x))),
        .f64_t => |x| try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u64, @bitCast(x)))),
        .vec2_t => |x| for (x) |f| try putU32(out, a, @bitCast(f)),
        .vec3_t => |x| for (x) |f| try putU32(out, a, @bitCast(f)),
        .vec4_t => |x| for (x) |f| try putU32(out, a, @bitCast(f)),
        .enum_u32_t => |x| try putU32(out, a, x),
        .entity_ref_t => |x| {
            try putU32(out, a, x.index);
            try putU32(out, a, x.generation);
        },
        .asset_ref_t => |x| try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u64, x))),
        .fixed_str64_t => |x| try out.appendSlice(a, &x),
    }
}

/// Serializes `prefab` into the cooked format. Caller frees the result with `allocator`.
pub fn cook(allocator: std.mem.Allocator, prefab: *const prefab_mod.Prefab) CookError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, magic);
    var hdr: [4]u8 = undefined;
    std.mem.writeInt(u16, hdr[0..2], format_version, .little);
    std.mem.writeInt(u16, hdr[2..4], 0, .little);
    try out.appendSlice(allocator, &hdr);
    try putU32(&out, allocator, @intCast(prefab.entities.items.len));

    for (prefab.entities.items) |ent| {
        try putStr(&out, allocator, ent.local_id);
        const parent_idx: u32 = if (ent.parent) |p| @intCast(prefabIndex(prefab, p) orelse return error.EntityNotFound) else no_parent;
        try putU32(&out, allocator, parent_idx);
        try putU32(&out, allocator, @intCast(ent.components.items.len));
        for (ent.components.items) |blob| try putStr(&out, allocator, blob);
        if (ent.nested) |n| {
            try out.append(allocator, 1);
            try putStr(&out, allocator, n.prefab_name);
            try putU32(&out, allocator, @intCast(n.overrides.len));
            for (n.overrides) |ov| {
                try putStr(&out, allocator, ov.local_id);
                var sid: [16]u8 = undefined;
                std.mem.writeInt(u128, &sid, ov.stable_id, .little);
                try out.appendSlice(allocator, &sid);
                try putStr(&out, allocator, ov.field);
                try putValue(&out, allocator, ov.value);
            }
        } else {
            try out.append(allocator, 0);
        }
    }
    try putU32(&out, allocator, std.hash.Crc32.hash(out.items));
    return out.toOwnedSlice(allocator);
}

fn prefabIndex(prefab: *const prefab_mod.Prefab, id: []const u8) ?usize {
    for (prefab.entities.items, 0..) |e, i| {
        if (std.mem.eql(u8, e.local_id, id)) return i;
    }
    return null;
}

const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    fn take(self: *Reader, n: usize) ![]const u8 {
        if (n > self.data.len - self.pos) return error.CorruptPrefab;
        const s = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }
    fn u8_(self: *Reader) !u8 {
        return (try self.take(1))[0];
    }
    fn u32_(self: *Reader) !u32 {
        return std.mem.readInt(u32, (try self.take(4))[0..4], .little);
    }
    fn u64_(self: *Reader) !u64 {
        return std.mem.readInt(u64, (try self.take(8))[0..8], .little);
    }
    fn str(self: *Reader) ![]const u8 {
        const n = try self.u32_();
        return self.take(n);
    }
};

fn readValue(r: *Reader) !FieldValue {
    const tag = try r.u8_();
    const ft = std.enums.fromInt(FieldType, tag) orelse return error.CorruptPrefab;
    return switch (ft) {
        .bool_t => .{ .bool_t = (try r.u8_()) != 0 },
        .i32_t => .{ .i32_t = @bitCast(try r.u32_()) },
        .u32_t => .{ .u32_t = try r.u32_() },
        .f32_t => .{ .f32_t = @bitCast(try r.u32_()) },
        .i64_t => .{ .i64_t = @bitCast(try r.u64_()) },
        .u64_t => .{ .u64_t = try r.u64_() },
        .f64_t => .{ .f64_t = @bitCast(try r.u64_()) },
        .vec2_t => .{ .vec2_t = .{ @bitCast(try r.u32_()), @bitCast(try r.u32_()) } },
        .vec3_t => .{ .vec3_t = .{ @bitCast(try r.u32_()), @bitCast(try r.u32_()), @bitCast(try r.u32_()) } },
        .vec4_t => .{ .vec4_t = .{ @bitCast(try r.u32_()), @bitCast(try r.u32_()), @bitCast(try r.u32_()), @bitCast(try r.u32_()) } },
        .enum_u32_t => .{ .enum_u32_t = try r.u32_() },
        .entity_ref_t => .{ .entity_ref_t = .{ .index = try r.u32_(), .generation = try r.u32_() } },
        .asset_ref_t => .{ .asset_ref_t = try r.u64_() },
        .fixed_str64_t => .{ .fixed_str64_t = (try r.take(64))[0..64].* },
    };
}

/// Loads a cooked prefab. The result owns copies of everything it needs; `bytes` may be freed.
pub fn load(allocator: std.mem.Allocator, bytes: []const u8) LoadError!prefab_mod.Prefab {
    if (bytes.len < magic.len + 4 + 4 + 4) return error.CorruptPrefab;
    const body = bytes[0 .. bytes.len - 4];
    const stored = std.mem.readInt(u32, bytes[bytes.len - 4 ..][0..4], .little);
    if (std.hash.Crc32.hash(body) != stored) return error.CorruptPrefab;
    if (!std.mem.eql(u8, body[0..4], magic)) return error.CorruptPrefab;

    var r = Reader{ .data = body, .pos = 4 };
    const version = std.mem.readInt(u16, (try r.take(2))[0..2], .little);
    if (version != format_version) return error.UnsupportedCookedVersion;
    _ = try r.take(2); // flags, reserved
    const count = try r.u32_();
    // Each entity needs at least 14 bytes; reject absurd counts before allocating anything.
    if (@as(u64, count) * 14 > body.len) return error.CorruptPrefab;

    var pf = prefab_mod.Prefab.init(allocator);
    errdefer pf.deinit();
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(allocator);

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const local_id = try r.str();
        const parent_idx = try r.u32_();
        const parent: ?[]const u8 = if (parent_idx == no_parent) null else blk: {
            if (parent_idx >= ids.items.len) return error.CorruptPrefab; // parents precede children
            break :blk ids.items[parent_idx];
        };
        const comp_count = try r.u32_();
        const a = pf.arena.allocator();
        try pf.addEntity(local_id, parent);
        const ent = &pf.entities.items[pf.entities.items.len - 1];
        try ids.append(allocator, ent.local_id);
        var c: u32 = 0;
        while (c < comp_count) : (c += 1) {
            const blob = try r.str();
            try ent.components.append(a, try a.dupe(u8, blob));
        }
        const has_nested = try r.u8_();
        if (has_nested > 1) return error.CorruptPrefab;
        if (has_nested == 1) {
            const name = try r.str();
            const ov_count = try r.u32_();
            if (@as(u64, ov_count) * 21 > body.len) return error.CorruptPrefab;
            const ovs = try a.alloc(prefab_mod.Override, ov_count);
            for (ovs) |*ov| {
                const lid = try a.dupe(u8, try r.str());
                const sid = std.mem.readInt(u128, (try r.take(16))[0..16], .little);
                const field = try a.dupe(u8, try r.str());
                ov.* = .{ .local_id = lid, .stable_id = sid, .field = field, .value = try readValue(&r) };
            }
            ent.nested = .{ .prefab_name = try a.dupe(u8, name), .overrides = ovs };
        }
    }
    if (r.pos != body.len) return error.CorruptPrefab;
    return pf;
}
