//! Remote JSON-RPC Inspector Protocol (`official.remote`).
//!
//! Exposes live ECS inspection, component editing, profiler pass timings,
//! panel listing, and pointer focus over JSON-RPC 2.0 (`engine.remote/1`).
//! Applications can attach an optional `RemoteIntegration` to route edits
//! through their own history and to publish panel descriptions.

const std = @import("std");
const engine = @import("engine");
const dev_tools = @import("dev_tools");
const picking = @import("picking");
const log_pkg = @import("log");

/// Owner ID used when registering `official.remote` services.
pub const MODULE_OWNER_ID: u64 = 2044;

/// An already validated reflected field edit handed to an attached integration.
pub const FieldEditRequest = struct {
    entity: engine.EntityHandle,
    schema_id: engine.reflection.SchemaId,
    /// Borrowed; valid only for the duration of the callback.
    field_name: []const u8,
    value: engine.reflection.FieldValue,
};

/// A panel description handed to a `PanelVisitor`. Strings are borrowed for the visit only.
pub const PanelView = struct {
    id: []const u8,
    title: []const u8,
    open: bool,
};

/// Synchronous callback receiving one `PanelView` per panel.
pub const PanelVisitor = struct {
    context: *anyopaque,
    visit: *const fn (context: *anyopaque, panel: PanelView) anyerror!void,
};

/// Optional application hooks for `RemoteInspectorService`.
///
/// Callbacks run synchronously on the thread that calls `handleRequest`, and only for
/// explicit RPC requests. Implementations must resolve any application state through
/// `app` at call time rather than caching pointers to removable resources.
pub const RemoteIntegration = struct {
    context: *anyopaque,
    /// Applies a validated edit. When set it is called exactly once per edit; an error is
    /// propagated and the edit is never retried as a direct write.
    edit_field: ?*const fn (context: *anyopaque, app: *engine.App, request: FieldEditRequest) anyerror!void = null,
    /// Enumerates panels for `zengy/list_panels`.
    visit_panels: ?*const fn (context: *anyopaque, app: *engine.App, visitor: PanelVisitor) anyerror!void = null,
};

/// Remote inspector service handling JSON-RPC 2.0 inspection & mutation requests.
pub const RemoteInspectorService = struct {
    requests_handled: u64 = 0,
    integration: ?RemoteIntegration = null,

    /// Attaches (or replaces) the optional application integration.
    pub fn setIntegration(self: *RemoteInspectorService, integration: RemoteIntegration) void {
        self.integration = integration;
    }

    /// Detaches the integration; later requests follow the no-integration behavior.
    pub fn clearIntegration(self: *RemoteInspectorService) void {
        self.integration = null;
    }

    /// Processes a JSON-RPC 2.0 request against `app` and returns an owned JSON response.
    pub fn handleRequest(
        self: *RemoteInspectorService,
        app: *engine.App,
        json_req: []const u8,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        self.requests_handled += 1;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_req, .{}) catch {
            return allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}");
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) {
            return allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"Invalid Request\"}}");
        }

        const id_val = root.object.get("id") orelse std.json.Value{ .null = {} };
        const method_val = root.object.get("method") orelse {
            return writeError(allocator, id_val, -32600, "Missing method");
        };
        if (method_val != .string) {
            return writeError(allocator, id_val, -32600, "Invalid method");
        }
        const method = method_val.string;
        const params = root.object.get("params");

        if (std.mem.eql(u8, method, "zengy/list_entities")) {
            return handleListEntities(app, allocator, id_val);
        } else if (std.mem.eql(u8, method, "zengy/get_entity")) {
            return handleGetEntity(app, allocator, id_val, params);
        } else if (std.mem.eql(u8, method, "zengy/set_component_field")) {
            return handleSetField(self.integration, app, allocator, id_val, params);
        } else if (std.mem.eql(u8, method, "zengy/get_profiler")) {
            return handleGetProfiler(app, allocator, id_val);
        } else if (std.mem.eql(u8, method, "zengy/list_panels")) {
            return handleListPanels(self.integration, app, allocator, id_val);
        } else if (std.mem.eql(u8, method, "zengy/get_focus")) {
            return handleGetFocus(app, allocator, id_val);
        } else if (std.mem.eql(u8, method, "zengy/get_logs")) {
            return handleGetLogs(app, allocator, id_val);
        }

        return writeError(allocator, id_val, -32601, "Method not found");
    }
};

fn appendIdJson(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, id_val: std.json.Value) !void {
    switch (id_val) {
        .integer => |i| try buf.print(allocator, "{d}", .{i}),
        .string => |s| try buf.print(allocator, "\"{s}\"", .{s}),
        else => try buf.appendSlice(allocator, "null"),
    }
}

fn writeError(allocator: std.mem.Allocator, id_val: std.json.Value, code: i32, msg: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try appendIdJson(&buf, allocator, id_val);
    try buf.print(allocator, ",\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}", .{ code, msg });
    return buf.toOwnedSlice(allocator);
}

fn handleListEntities(app: *engine.App, allocator: std.mem.Allocator, id_val: std.json.Value) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try appendIdJson(&buf, allocator, id_val);
    try buf.appendSlice(allocator, ",\"result\":{\"entities\":[");

    var first_ent = true;
    for (app.world.alive_flags.items, 0..) |alive, idx| {
        if (!alive) continue;
        const handle = engine.EntityHandle{
            .index = @intCast(idx),
            .generation = app.world.generations.items[idx],
        };
        if (!first_ent) try buf.append(allocator, ',');
        first_ent = false;

        try buf.print(allocator, "{{\"index\":{d},\"generation\":{d},\"components\":[", .{ handle.index, handle.generation });
        var first_comp = true;
        var it = app.types.schemas.valueIterator();
        while (it.next()) |schema| {
            if (app.world.getRawConst(handle, schema.component_type_id) != null) {
                if (!first_comp) try buf.append(allocator, ',');
                first_comp = false;
                try buf.print(allocator, "\"{s}.{s}\"", .{ schema.namespace, schema.name });
            }
        }
        try buf.appendSlice(allocator, "]}");
    }

    try buf.appendSlice(allocator, "]}}");
    return buf.toOwnedSlice(allocator);
}

fn parseBoundedU32(v: std.json.Value) ?u32 {
    if (v != .integer) return null;
    const i = v.integer;
    if (i < 0 or i > std.math.maxInt(u32)) return null;
    return @intCast(i);
}

fn parseBoundedI32(v: std.json.Value) ?i32 {
    if (v != .integer) return null;
    const i = v.integer;
    if (i < std.math.minInt(i32) or i > std.math.maxInt(i32)) return null;
    return @intCast(i);
}

fn parseEntityFromParams(params: ?std.json.Value) ?engine.EntityHandle {
    const p = params orelse return null;
    if (p != .object) return null;
    const idx_val = p.object.get("index") orelse p.object.get("id") orelse return null;
    const idx = parseBoundedU32(idx_val) orelse return null;
    const gen_val = p.object.get("generation");
    const gen: u32 = if (gen_val) |gv| (parseBoundedU32(gv) orelse return null) else 1;
    return .{ .index = idx, .generation = gen };
}

fn appendFieldValueJson(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, val: engine.reflection.FieldValue) !void {
    switch (val) {
        .bool_t => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
        .i32_t => |v| try buf.print(allocator, "{d}", .{v}),
        .i64_t => |v| try buf.print(allocator, "{d}", .{v}),
        .u32_t => |v| try buf.print(allocator, "{d}", .{v}),
        .u64_t => |v| try buf.print(allocator, "{d}", .{v}),
        .f32_t => |v| try buf.print(allocator, "{d:.4}", .{v}),
        .f64_t => |v| try buf.print(allocator, "{d:.4}", .{v}),
        .vec2_t => |v| try buf.print(allocator, "[{d:.4},{d:.4}]", .{ v[0], v[1] }),
        .vec3_t => |v| try buf.print(allocator, "[{d:.4},{d:.4},{d:.4}]", .{ v[0], v[1], v[2] }),
        .vec4_t => |v| try buf.print(allocator, "[{d:.4},{d:.4},{d:.4},{d:.4}]", .{ v[0], v[1], v[2], v[3] }),
        .enum_u32_t => |v| try buf.print(allocator, "{d}", .{v}),
        .entity_ref_t => |e| try buf.print(allocator, "{{\"index\":{d},\"generation\":{d}}}", .{ e.index, e.generation }),
        .asset_ref_t => |a| try buf.print(allocator, "{d}", .{a}),
        .fixed_str64_t => |s| {
            const trimmed = std.mem.sliceTo(&s, 0);
            try buf.print(allocator, "\"{s}\"", .{trimmed});
        },
    }
}

fn handleGetEntity(app: *engine.App, allocator: std.mem.Allocator, id_val: std.json.Value, params: ?std.json.Value) ![]u8 {
    const handle = parseEntityFromParams(params) orelse return writeError(allocator, id_val, -32602, "Invalid entity params");
    if (!app.world.isAlive(handle)) return writeError(allocator, id_val, -32001, "Entity not alive");

    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try appendIdJson(&buf, allocator, id_val);
    try buf.print(allocator, ",\"result\":{{\"index\":{d},\"generation\":{d},\"components\":{{", .{ handle.index, handle.generation });

    var first_comp = true;
    var it = app.types.schemas.valueIterator();
    while (it.next()) |schema| {
        const bytes = app.world.getRawConst(handle, schema.component_type_id) orelse continue;
        if (!first_comp) try buf.append(allocator, ',');
        first_comp = false;
        try buf.print(allocator, "\"{s}.{s}\":{{", .{ schema.namespace, schema.name });
        for (schema.fields, 0..) |f, fi| {
            if (fi > 0) try buf.append(allocator, ',');
            try buf.print(allocator, "\"{s}\":", .{f.name});
            const fv = try engine.TypeRegistry.getField(schema.*, bytes, f.name);
            try appendFieldValueJson(&buf, allocator, fv);
        }
        try buf.append(allocator, '}');
    }

    try buf.appendSlice(allocator, "}}}");
    return buf.toOwnedSlice(allocator);
}

fn jsonToF32(v: std.json.Value) ?f32 {
    return switch (v) {
        .float => |f| @floatCast(f),
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

fn handleSetField(integration: ?RemoteIntegration, app: *engine.App, allocator: std.mem.Allocator, id_val: std.json.Value, params: ?std.json.Value) ![]u8 {
    const handle = parseEntityFromParams(params) orelse return writeError(allocator, id_val, -32602, "Invalid entity params");
    if (!app.world.isAlive(handle)) return writeError(allocator, id_val, -32001, "Entity not alive");

    const obj = params.?.object;
    const schema_val = obj.get("schema") orelse return writeError(allocator, id_val, -32602, "Missing schema");
    const field_val = obj.get("field") orelse return writeError(allocator, id_val, -32602, "Missing field");
    const val_json = obj.get("value") orelse return writeError(allocator, id_val, -32602, "Missing value");
    if (schema_val != .string or field_val != .string) return writeError(allocator, id_val, -32602, "Invalid schema/field");

    const schema_id = app.types.name_to_schema.get(schema_val.string) orelse return writeError(allocator, id_val, -32002, "Schema not found");
    const schema = app.types.getById(schema_id) orelse return writeError(allocator, id_val, -32002, "Schema not found");

    var field_desc: ?engine.reflection.FieldDescriptor = null;
    for (schema.fields) |fd| {
        if (std.mem.eql(u8, fd.name, field_val.string)) {
            field_desc = fd;
            break;
        }
    }
    const fd = field_desc orelse return writeError(allocator, id_val, -32003, "Field not found");

    const typed_val: engine.reflection.FieldValue = switch (fd.field_type) {
        .bool_t => if (val_json == .bool) .{ .bool_t = val_json.bool } else return writeError(allocator, id_val, -32602, "Expected bool"),
        .i32_t => .{ .i32_t = parseBoundedI32(val_json) orelse return writeError(allocator, id_val, -32602, "Expected i32") },
        .u32_t => .{ .u32_t = parseBoundedU32(val_json) orelse return writeError(allocator, id_val, -32602, "Expected u32") },
        .f32_t => blk: {
            const f = jsonToF32(val_json) orelse return writeError(allocator, id_val, -32602, "Expected f32");
            if (!std.math.isFinite(f)) return writeError(allocator, id_val, -32602, "Expected finite f32");
            break :blk .{ .f32_t = f };
        },
        .vec3_t => blk: {
            if (val_json != .array or val_json.array.items.len != 3) return writeError(allocator, id_val, -32602, "Expected [3]f32");
            const x = jsonToF32(val_json.array.items[0]) orelse return writeError(allocator, id_val, -32602, "Expected f32");
            const y = jsonToF32(val_json.array.items[1]) orelse return writeError(allocator, id_val, -32602, "Expected f32");
            const z = jsonToF32(val_json.array.items[2]) orelse return writeError(allocator, id_val, -32602, "Expected f32");
            if (!std.math.isFinite(x) or !std.math.isFinite(y) or !std.math.isFinite(z)) {
                return writeError(allocator, id_val, -32602, "Expected finite f32");
            }
            break :blk .{ .vec3_t = .{ x, y, z } };
        },
        else => return writeError(allocator, id_val, -32602, "Unsupported field type"),
    };

    const edit_hook: ?struct { context: *anyopaque, edit: *const fn (*anyopaque, *engine.App, FieldEditRequest) anyerror!void } = blk: {
        const hooks = integration orelse break :blk null;
        const edit = hooks.edit_field orelse break :blk null;
        break :blk .{ .context = hooks.context, .edit = edit };
    };
    if (edit_hook) |h| {
        try h.edit(h.context, app, .{
            .entity = handle,
            .schema_id = schema.schema_id,
            .field_name = fd.name,
            .value = typed_val,
        });
    } else {
        try app.types.setReflectedField(&app.world, handle, schema.schema_id, fd.name, typed_val);
    }

    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try appendIdJson(&buf, allocator, id_val);
    try buf.appendSlice(allocator, ",\"result\":{\"ok\":true}}");
    return buf.toOwnedSlice(allocator);
}

fn handleGetProfiler(app: *engine.App, allocator: std.mem.Allocator, id_val: std.json.Value) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try appendIdJson(&buf, allocator, id_val);

    if (app.resources.get(dev_tools.FrameProfilerService)) |prof| {
        try buf.print(
            allocator,
            ",\"result\":{{\"frame_index\":{d},\"total_ms\":{d:.3},\"fps\":{d:.1},\"passes\":[",
            .{ prof.latest_snapshot.frame_index, prof.totalFrameMs(), prof.fps() },
        );
        for (prof.latestPasses(), 0..) |p, i| {
            if (i > 0) try buf.append(allocator, ',');
            try buf.print(
                allocator,
                "{{\"name\":\"{s}\",\"category\":\"{s}\",\"duration_ms\":{d:.3},\"ema_ms\":{d:.3}}}",
                .{ p.nameSlice(), @tagName(p.category), p.duration_ms, p.ema_ms },
            );
        }
        try buf.appendSlice(allocator, "]}}");
    } else {
        try buf.appendSlice(allocator, ",\"result\":{\"frame_index\":0,\"total_ms\":0.0,\"fps\":0.0,\"passes\":[]}}");
    }
    return buf.toOwnedSlice(allocator);
}

/// Appends each visited panel to the response; JSON encoding stays in Remote.
const PanelJsonContext = struct {
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    count: usize = 0,

    fn visit(raw: *anyopaque, panel: PanelView) anyerror!void {
        const self: *PanelJsonContext = @ptrCast(@alignCast(raw));
        if (self.count > 0) try self.buf.append(self.allocator, ',');
        self.count += 1;
        try self.buf.print(self.allocator, "{{\"id\":\"{s}\",\"title\":\"{s}\",\"open\":{}}}", .{ panel.id, panel.title, panel.open });
    }
};

fn handleListPanels(integration: ?RemoteIntegration, app: *engine.App, allocator: std.mem.Allocator, id_val: std.json.Value) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try appendIdJson(&buf, allocator, id_val);
    try buf.appendSlice(allocator, ",\"result\":{\"panels\":[");

    if (integration) |hooks| if (hooks.visit_panels) |visit_panels| {
        var ctx = PanelJsonContext{ .buf = &buf, .allocator = allocator };
        try visit_panels(hooks.context, app, .{ .context = &ctx, .visit = PanelJsonContext.visit });
    };
    try buf.appendSlice(allocator, "]}}");
    return buf.toOwnedSlice(allocator);
}

fn handleGetFocus(app: *engine.App, allocator: std.mem.Allocator, id_val: std.json.Value) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try appendIdJson(&buf, allocator, id_val);
    try buf.appendSlice(allocator, ",\"result\":{");

    if (app.resources.get(picking.InputFocus)) |focus| {
        try buf.appendSlice(allocator, "\"focused\":");
        if (focus.focused_entity) |f| {
            try buf.print(allocator, "{{\"index\":{d},\"generation\":{d}}}", .{ f.index, f.generation });
        } else {
            try buf.appendSlice(allocator, "null");
        }
        try buf.appendSlice(allocator, ",\"hovered\":");
        if (focus.hovered_entity) |h| {
            try buf.print(allocator, "{{\"index\":{d},\"generation\":{d}}}", .{ h.index, h.generation });
        } else {
            try buf.appendSlice(allocator, "null");
        }
    } else {
        try buf.appendSlice(allocator, "\"focused\":null,\"hovered\":null");
    }
    try buf.appendSlice(allocator, "}}");
    return buf.toOwnedSlice(allocator);
}

fn handleGetLogs(app: *engine.App, allocator: std.mem.Allocator, id_val: std.json.Value) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try appendIdJson(&buf, allocator, id_val);
    try buf.appendSlice(allocator, ",\"result\":{\"logs\":[");

    if (app.resources.get(log_pkg.LogService)) |lsvc| {
        for (lsvc.recentRecords(), 0..) |rec, i| {
            if (i > 0) try buf.append(allocator, ',');
            try buf.print(
                allocator,
                "{{\"level\":\"{s}\",\"subsystem\":\"{s}\",\"message\":\"{s}\"}}",
                .{ @tagName(rec.level), rec.subsystemSlice(), rec.messageSlice() },
            );
        }
    } else {
        const total = app.diagnostics.count();
        var i: usize = 0;
        while (i < total) : (i += 1) {
            if (app.diagnostics.get(i)) |rec| {
                if (i > 0) try buf.append(allocator, ',');
                try buf.print(
                    allocator,
                    "{{\"level\":\"{s}\",\"subsystem\":\"{s}\",\"message\":\"{s}\"}}",
                    .{ @tagName(rec.level), rec.subsystem, rec.message },
                );
            }
        }
    }
    try buf.appendSlice(allocator, "]}}");
    return buf.toOwnedSlice(allocator);
}

fn buildModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    try app.resources.insert(RemoteInspectorService, .{});
    const svc = app.resources.get(RemoteInspectorService).?;
    try app.services.register(.{
        .capability = "engine.remote",
        .major_version = 1,
        .provider_id = "official.remote",
        .owner_id = MODULE_OWNER_ID,
        .exclusive = true,
        .api_ptr = svc,
        .api_size = @sizeOf(RemoteInspectorService),
    });
}

fn stopModule(raw_app: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    _ = app.services.unregisterByOwner(MODULE_OWNER_ID);
    _ = app.resources.remove(RemoteInspectorService);
}

/// Returns the `official.remote` module descriptor.
pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = "official.remote",
            .version = "0.1.0",
            .provides_capabilities = &.{"engine.remote/1"},
            .required_capabilities = &.{},
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
