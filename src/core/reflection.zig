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

pub const ComponentSchema = struct {
    schema_id: SchemaId,
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

        var name_it = self.name_to_schema.keyIterator();
        while (name_it.next()) |k| {
            self.allocator.free(k.*);
        }
        self.name_to_schema.deinit(self.allocator);
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

        self.schemas.putAssumeCapacity(schema_id, schema);
        self.name_to_schema.putAssumeCapacity(full_name, schema_id);
        return schema;
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
