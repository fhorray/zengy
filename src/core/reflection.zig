//! Runtime Reflection & Component Schema Registry (`core/reflection`).
//!
//! Enables dynamic component registration, inspection, and serialization across
//! Zig, C ABI plugins, and scripting runtimes without recompiling the host.
//!
//! Features:
//! - Deterministic `SchemaId` computed from `namespace + name + version`.
//! - Automatic C-like field alignment and offset calculation (`FieldDescriptor`).
//! - Three storage policies: `blittable`, `managed_handle`, and `blob`.
//! - Safe dynamic `getField()` / `setField()` over raw component byte slices.

const std = @import("std");
const world_mod = @import("world.zig");

pub const FieldType = enum {
    bool_t,
    i32_t,
    i64_t,
    u32_t,
    u64_t,
    f32_t,
    f64_t,
    vec2_t,
    vec3_t,
    vec4_t,

    pub fn byteSize(self: FieldType) usize {
        return switch (self) {
            .bool_t => 1,
            .i32_t, .u32_t, .f32_t => 4,
            .i64_t, .u64_t, .f64_t, .vec2_t => 8,
            .vec3_t => 12,
            .vec4_t => 16,
        };
    }

    pub fn alignment(self: FieldType) usize {
        return switch (self) {
            .bool_t => 1,
            .i32_t, .u32_t, .f32_t, .vec2_t, .vec3_t, .vec4_t => 4,
            .i64_t, .u64_t, .f64_t => 8,
        };
    }
};

pub const FieldValue = union(FieldType) {
    bool_t: bool,
    i32_t: i32,
    i64_t: i64,
    u32_t: u32,
    u64_t: u64,
    f32_t: f32,
    f64_t: f64,
    vec2_t: [2]f32,
    vec3_t: [3]f32,
    vec4_t: [4]f32,
};

pub const StoragePolicy = enum {
    blittable,
    managed_handle,
    blob,
};

pub const FieldDescriptor = struct {
    name: []const u8,
    field_type: FieldType,
    offset: usize = 0,
};

pub const SchemaId = u64;

/// Version-independent 128-bit identity of a component type (`namespace.name`). Persisted data
/// stores this plus a schema version, never a runtime index or a Zig type name hash.
pub const StableTypeId = u128;

/// Upgrades the raw bytes of version `v` into the layout of version `v + 1`.
/// The returned buffer is owned by `allocator` (the registry frees it after use).
pub const MigrationFn = *const fn (allocator: std.mem.Allocator, old_bytes: []const u8) anyerror![]u8;

pub const ComponentSchema = struct {
    schema_id: SchemaId,
    stable_id: StableTypeId,
    component_type_id: world_mod.ComponentTypeId,
    namespace: []const u8,
    name: []const u8,
    version: u32,
    storage: StoragePolicy,
    byte_size: usize,
    fields: []FieldDescriptor,
};

pub const TypeRegistry = struct {
    allocator: std.mem.Allocator,
    schemas: std.AutoHashMapUnmanaged(SchemaId, ComponentSchema),
    name_to_schema: std.StringHashMapUnmanaged(SchemaId),
    /// Latest registered version per stable type id.
    latest_version: std.AutoHashMapUnmanaged(StableTypeId, u32) = .empty,
    /// `(stable id, from version)` -> migration producing `from version + 1`.
    migrations: std.AutoHashMapUnmanaged(MigrationKey, MigrationFn) = .empty,
    /// Stable id -> `(namespace, name)` strings borrowed from the schema entries, so decoding can
    /// find any registered version of a type.
    stable_names: std.AutoHashMapUnmanaged(StableTypeId, SchemaId) = .empty,

    const MigrationKey = struct { stable_id: StableTypeId, from_version: u32 };

    pub fn init(allocator: std.mem.Allocator) TypeRegistry {
        return .{
            .allocator = allocator,
            .schemas = .empty,
            .name_to_schema = .empty,
        };
    }

    pub fn deinit(self: *TypeRegistry) void {
        var it = self.schemas.valueIterator();
        while (it.next()) |schema| {
            self.allocator.free(schema.namespace);
            self.allocator.free(schema.name);
            for (schema.fields) |f| {
                self.allocator.free(f.name);
            }
            self.allocator.free(schema.fields);
        }
        self.schemas.deinit(self.allocator);
        self.latest_version.deinit(self.allocator);
        self.migrations.deinit(self.allocator);
        self.stable_names.deinit(self.allocator);

        var name_it = self.name_to_schema.keyIterator();
        while (name_it.next()) |k| {
            self.allocator.free(k.*);
        }
        self.name_to_schema.deinit(self.allocator);
    }

    /// Computes the version-independent stable id of `namespace.name` (two independent 64-bit
    /// hashes concatenated, making accidental collisions negligible).
    pub fn computeStableId(namespace: []const u8, name: []const u8) StableTypeId {
        var lo = std.hash.Wyhash.init(0x243f6a8885a308d3);
        var hi = std.hash.Wyhash.init(0x13198a2e03707344);
        inline for (.{ &lo, &hi }) |h| {
            h.update(namespace);
            h.update(".");
            h.update(name);
        }
        return (@as(u128, hi.final()) << 64) | lo.final();
    }

    pub fn computeSchemaId(namespace: []const u8, name: []const u8, version: u32) SchemaId {
        var hasher = std.hash.Wyhash.init(0x517cc1b727220a95);
        hasher.update(namespace);
        hasher.update(".");
        hasher.update(name);
        hasher.update(":");
        hasher.update(std.mem.asBytes(&version));
        return hasher.final();
    }

    pub fn registerSchema(
        self: *TypeRegistry,
        namespace: []const u8,
        name: []const u8,
        version: u32,
        storage: StoragePolicy,
        input_fields: []const FieldDescriptor,
    ) !ComponentSchema {
        const schema_id = computeSchemaId(namespace, name, version);
        if (self.schemas.get(schema_id)) |existing| {
            return existing;
        }

        const ns_copy = try self.allocator.dupe(u8, namespace);
        errdefer self.allocator.free(ns_copy);
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);

        const fields = try self.allocator.alloc(FieldDescriptor, input_fields.len);
        errdefer self.allocator.free(fields);

        var initialized_fields: usize = 0;
        errdefer {
            for (fields[0..initialized_fields]) |f| {
                self.allocator.free(f.name);
            }
        }

        var cursor: usize = 0;
        var max_align: usize = 1;
        for (input_fields, 0..) |f, i| {
            const f_align = f.field_type.alignment();
            if (f_align > max_align) max_align = f_align;
            cursor = std.mem.alignForward(usize, cursor, f_align);

            const fname_copy = try self.allocator.dupe(u8, f.name);
            fields[i] = .{
                .name = fname_copy,
                .field_type = f.field_type,
                .offset = cursor,
            };
            initialized_fields += 1;
            cursor += f.field_type.byteSize();
        }
        const total_size = std.mem.alignForward(usize, cursor, max_align);

        const full_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ namespace, name });
        errdefer self.allocator.free(full_name);

        const schema = ComponentSchema{
            .schema_id = schema_id,
            .stable_id = computeStableId(namespace, name),
            .component_type_id = world_mod.World.dynamicTypeId(full_name),
            .namespace = ns_copy,
            .name = name_copy,
            .version = version,
            .storage = storage,
            .byte_size = total_size,
            .fields = fields,
        };

        try self.schemas.ensureUnusedCapacity(self.allocator, 1);
        try self.name_to_schema.ensureUnusedCapacity(self.allocator, 1);
        try self.latest_version.ensureUnusedCapacity(self.allocator, 1);
        try self.stable_names.ensureUnusedCapacity(self.allocator, 1);

        const lv = self.latest_version.getOrPutAssumeCapacity(schema.stable_id);
        if (!lv.found_existing or lv.value_ptr.* < version) lv.value_ptr.* = version;
        self.stable_names.putAssumeCapacity(schema.stable_id, schema_id);
        self.schemas.putAssumeCapacity(schema_id, schema);
        if (self.name_to_schema.getPtr(full_name)) |existing_sid| {
            existing_sid.* = schema_id;
            self.allocator.free(full_name);
        } else {
            self.name_to_schema.putAssumeCapacity(full_name, schema_id);
        }
        return schema;
    }

    /// Registers the upgrade from `from_version` to `from_version + 1` of `namespace.name`.
    pub fn registerMigration(self: *TypeRegistry, namespace: []const u8, name: []const u8, from_version: u32, func: MigrationFn) !void {
        try self.migrations.put(self.allocator, .{ .stable_id = computeStableId(namespace, name), .from_version = from_version }, func);
    }

    /// Looks up the schema of a specific version of the type with `stable_id`.
    pub fn getVersion(self: *const TypeRegistry, stable_id: StableTypeId, version: u32) ?ComponentSchema {
        const any_sid = self.stable_names.get(stable_id) orelse return null;
        const any = self.schemas.get(any_sid) orelse return null;
        return self.schemas.get(computeSchemaId(any.namespace, any.name, version));
    }

    /// Returns the newest registered schema of `namespace.name`, or null if none is registered.
    pub fn getLatest(self: *const TypeRegistry, namespace: []const u8, name: []const u8) ?ComponentSchema {
        const stable = computeStableId(namespace, name);
        const v = self.latest_version.get(stable) orelse return null;
        return self.getVersion(stable, v);
    }

    /// Size of the canonical (little-endian, unpadded) encoding of `schema`'s fields.
    pub fn encodedPayloadSize(schema: ComponentSchema) usize {
        var n: usize = 0;
        for (schema.fields) |f| n += f.field_type.byteSize();
        return n;
    }

    const header_size = 16 + 4 + 4;

    /// Appends the portable encoding of one component: `stable_id (u128) | version (u32) |
    /// payload_len (u32) | fields...` with every field little-endian and unpadded, so files are
    /// independent of host layout, alignment, and Zig type names.
    pub fn encodeComponent(allocator: std.mem.Allocator, schema: ComponentSchema, bytes: []const u8, out: *std.ArrayList(u8)) !void {
        if (bytes.len < schema.byte_size) return error.BufferTooSmall;
        const payload_len = encodedPayloadSize(schema);
        try out.ensureUnusedCapacity(allocator, header_size + payload_len);
        var hdr: [header_size]u8 = undefined;
        std.mem.writeInt(u128, hdr[0..16], schema.stable_id, .little);
        std.mem.writeInt(u32, hdr[16..20], schema.version, .little);
        std.mem.writeInt(u32, hdr[20..24], @intCast(payload_len), .little);
        out.appendSliceAssumeCapacity(&hdr);
        for (schema.fields) |f| {
            const slot = bytes[f.offset .. f.offset + f.field_type.byteSize()];
            switch (f.field_type) {
                .bool_t => out.appendAssumeCapacity(if (slot[0] != 0) 1 else 0),
                .i32_t, .u32_t, .f32_t => out.appendSliceAssumeCapacity(&toLe(u32, slot)),
                .i64_t, .u64_t, .f64_t => out.appendSliceAssumeCapacity(&toLe(u64, slot)),
                .vec2_t, .vec3_t, .vec4_t => {
                    var i: usize = 0;
                    while (i < slot.len) : (i += 4) out.appendSliceAssumeCapacity(&toLe(u32, slot[i..][0..4]));
                },
            }
        }
    }

    fn toLe(comptime T: type, slot: []const u8) [@sizeOf(T)]u8 {
        var out: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &out, std.mem.readInt(T, slot[0..@sizeOf(T)], @import("builtin").cpu.arch.endian()), .little);
        return out;
    }

    /// A decoded component upgraded to the latest registered schema version.
    pub const Decoded = struct {
        schema: ComponentSchema,
        /// Component bytes in the host layout of `schema` (free with the decode allocator).
        bytes: []u8,
        /// Bytes consumed from the input.
        consumed: usize,
    };

    /// Decodes one component written by `encodeComponent`, then applies registered migrations until
    /// it reaches the latest version. Errors: `UnknownSchema`, `SchemaTooNew` (data is newer than
    /// this build), `MissingMigration`, `PayloadTruncated`, `PayloadSizeMismatch`.
    pub fn decodeComponent(self: *const TypeRegistry, allocator: std.mem.Allocator, data: []const u8) !Decoded {
        if (data.len < header_size) return error.PayloadTruncated;
        const stable_id = std.mem.readInt(u128, data[0..16], .little);
        const version = std.mem.readInt(u32, data[16..20], .little);
        const payload_len: usize = std.mem.readInt(u32, data[20..24], .little);
        if (data.len < header_size + payload_len) return error.PayloadTruncated;
        const payload = data[header_size .. header_size + payload_len];

        const latest = self.latest_version.get(stable_id) orelse return error.UnknownSchema;
        if (version > latest) return error.SchemaTooNew;
        var schema = self.getVersion(stable_id, version) orelse return error.UnknownSchema;
        if (payload.len != encodedPayloadSize(schema)) return error.PayloadSizeMismatch;

        var bytes = try allocator.alloc(u8, schema.byte_size);
        errdefer allocator.free(bytes);
        @memset(bytes, 0);
        var cursor: usize = 0;
        for (schema.fields) |f| {
            const sz = f.field_type.byteSize();
            const dst = bytes[f.offset .. f.offset + sz];
            const src = payload[cursor .. cursor + sz];
            switch (f.field_type) {
                .bool_t => dst[0] = if (src[0] != 0) 1 else 0,
                .i32_t, .u32_t, .f32_t => fromLe(u32, dst, src),
                .i64_t, .u64_t, .f64_t => fromLe(u64, dst, src),
                .vec2_t, .vec3_t, .vec4_t => {
                    var i: usize = 0;
                    while (i < sz) : (i += 4) fromLe(u32, dst[i..][0..4], src[i..][0..4]);
                },
            }
            cursor += sz;
        }

        var v = version;
        while (v < latest) : (v += 1) {
            const mig = self.migrations.get(.{ .stable_id = stable_id, .from_version = v }) orelse return error.MissingMigration;
            const upgraded = try mig(allocator, bytes);
            allocator.free(bytes);
            bytes = upgraded;
            schema = self.getVersion(stable_id, v + 1) orelse return error.UnknownSchema;
            if (bytes.len != schema.byte_size) {
                allocator.free(bytes);
                return error.PayloadSizeMismatch;
            }
        }
        return .{ .schema = schema, .bytes = bytes, .consumed = header_size + payload_len };
    }

    fn fromLe(comptime T: type, dst: []u8, src: []const u8) void {
        std.mem.writeInt(T, dst[0..@sizeOf(T)], std.mem.readInt(T, src[0..@sizeOf(T)], .little), @import("builtin").cpu.arch.endian());
    }

    pub fn getByName(self: *const TypeRegistry, full_name: []const u8) ?ComponentSchema {
        const sid = self.name_to_schema.get(full_name) orelse return null;
        return self.schemas.get(sid);
    }

    pub fn getById(self: *const TypeRegistry, schema_id: SchemaId) ?ComponentSchema {
        return self.schemas.get(schema_id);
    }

    pub fn setField(schema: ComponentSchema, bytes: []u8, field_name: []const u8, value: FieldValue) !void {
        if (bytes.len < schema.byte_size) return error.BufferTooSmall;
        for (schema.fields) |f| {
            if (!std.mem.eql(u8, f.name, field_name)) continue;
            if (@as(FieldType, value) != f.field_type) return error.FieldTypeMismatch;
            const slot = bytes[f.offset .. f.offset + f.field_type.byteSize()];
            switch (value) {
                .bool_t => |v| slot[0] = if (v) 1 else 0,
                .i32_t => |v| @memcpy(slot, std.mem.asBytes(&v)),
                .i64_t => |v| @memcpy(slot, std.mem.asBytes(&v)),
                .u32_t => |v| @memcpy(slot, std.mem.asBytes(&v)),
                .u64_t => |v| @memcpy(slot, std.mem.asBytes(&v)),
                .f32_t => |v| @memcpy(slot, std.mem.asBytes(&v)),
                .f64_t => |v| @memcpy(slot, std.mem.asBytes(&v)),
                .vec2_t => |v| @memcpy(slot, std.mem.asBytes(&v)),
                .vec3_t => |v| @memcpy(slot, std.mem.asBytes(&v)),
                .vec4_t => |v| @memcpy(slot, std.mem.asBytes(&v)),
            }
            return;
        }
        return error.FieldNotFound;
    }

    pub fn getField(schema: ComponentSchema, bytes: []const u8, field_name: []const u8) !FieldValue {
        if (bytes.len < schema.byte_size) return error.BufferTooSmall;
        for (schema.fields) |f| {
            if (!std.mem.eql(u8, f.name, field_name)) continue;
            const slot = bytes[f.offset .. f.offset + f.field_type.byteSize()];
            return switch (f.field_type) {
                .bool_t => .{ .bool_t = slot[0] != 0 },
                .i32_t => .{ .i32_t = std.mem.bytesToValue(i32, slot[0..4]) },
                .i64_t => .{ .i64_t = std.mem.bytesToValue(i64, slot[0..8]) },
                .u32_t => .{ .u32_t = std.mem.bytesToValue(u32, slot[0..4]) },
                .u64_t => .{ .u64_t = std.mem.bytesToValue(u64, slot[0..8]) },
                .f32_t => .{ .f32_t = std.mem.bytesToValue(f32, slot[0..4]) },
                .f64_t => .{ .f64_t = std.mem.bytesToValue(f64, slot[0..8]) },
                .vec2_t => .{ .vec2_t = std.mem.bytesToValue([2]f32, slot[0..8]) },
                .vec3_t => .{ .vec3_t = std.mem.bytesToValue([3]f32, slot[0..12]) },
                .vec4_t => .{ .vec4_t = std.mem.bytesToValue([4]f32, slot[0..16]) },
            };
        }
        return error.FieldNotFound;
    }
};
