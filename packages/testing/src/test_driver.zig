//! Deterministic Test Driver & TOML Scenario Runner (`official.testing.driver`).
//!
//! Enables automated agents and tests to drive an `engine.App` deterministically:
//! - `stepFixed(app, count)`: executes exact `.fixed_update` ticks (no accumulator).
//! - `stepFrame(app, frame_dt)`: executes full application frames.
//! - Input injection into `InputService` and `UiTree` (`clickUiById`).
//! - Reflection-based component assertions (`assertFieldApprox`) rejecting `NaN`/`Inf`.
//! - Strict TOML scenario parsing powered by `official.format.toml` (`z-toml`).

const std = @import("std");
const engine = @import("engine");
const window = @import("window");
const ui_core = @import("ui_core");
const toml_format = @import("toml_format");

pub const ScenarioActionKind = enum {
    key_down,
    key_up,
    ui_click,
};

pub const ScenarioAction = struct {
    at_tick: u32,
    kind: ScenarioActionKind,
    target: []const u8,
};

pub const Scenario = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    ticks: u32,
    actions: std.ArrayList(ScenarioAction),

    pub fn deinit(self: *Scenario) void {
        self.allocator.free(self.name);
        for (self.actions.items) |a| {
            self.allocator.free(a.target);
        }
        self.actions.deinit(self.allocator);
    }
};

/// Deterministic test driver controlling simulation clock, input, and assertions.
pub const TestDriver = struct {
    current_tick: u64 = 0,

    /// Advances `app` by exactly `count` `.fixed_update` ticks deterministically.
    pub fn stepFixed(self: *TestDriver, app: *engine.App, count: u32) !void {
        for (0..count) |_| {
            try app.tickFixed();
            self.current_tick += 1;
        }
    }

    /// Advances `app` by `count` full frames (`frame_dt` seconds each).
    pub fn stepFrame(self: *TestDriver, app: *engine.App, count: u32, frame_dt: f64) !void {
        for (0..count) |_| {
            try app.tick(frame_dt);
            self.current_tick += 1;
        }
    }

    pub fn pressKey(_: *TestDriver, input: *window.InputService, key_code: u8) void {
        input.injectKey(key_code, true);
    }

    pub fn releaseKey(_: *TestDriver, input: *window.InputService, key_code: u8) void {
        input.injectKey(key_code, false);
    }

    pub fn moveMouse(_: *TestDriver, input: *window.InputService, x: f32, y: f32) void {
        input.injectMouseMove(x, y);
    }

    /// Locates a `UiTree` node by ID in O(1) and simulates a pointer click at its center.
    pub fn clickUiById(_: *TestDriver, tree: *ui_core.UiTree, node_id: []const u8, events: *engine.EventBus) !usize {
        const idx = tree.findById(node_id) orelse return error.UiNodeNotFound;
        const rect = tree.nodes.items[idx].layout;
        const cx = rect.x + rect.width * 0.5;
        const cy = rect.y + rect.height * 0.5;
        return tree.handlePointerClick(cx, cy, events) orelse error.UiHitTestMissed;
    }

    /// Asserts that a reflected `f32_t` field is finite and within `tolerance` of `expected`.
    pub fn assertFieldApprox(
        world: *engine.World,
        types: *const engine.TypeRegistry,
        entity: engine.EntityHandle,
        schema_id: engine.reflection.SchemaId,
        field_name: []const u8,
        expected: f32,
        tolerance: f32,
    ) !void {
        const schema = types.getById(schema_id) orelse return error.SchemaNotFound;
        const bytes = world.getRaw(entity, schema.component_type_id) orelse return error.ComponentNotPresent;
        const val = try engine.TypeRegistry.getField(schema, bytes, field_name);

        const actual: f32 = switch (val) {
            .f32_t => |v| v,
            else => return error.FieldTypeMismatch,
        };

        if (!std.math.isFinite(actual) or !std.math.isFinite(expected) or !std.math.isFinite(tolerance) or tolerance < 0.0) {
            return error.InvalidAssertionValue;
        }
        if (@abs(actual - expected) > tolerance) {
            return error.AssertionFailed;
        }
    }

    fn parseNonNegativeU32(val: i64) !u32 {
        if (val < 0 or val > std.math.maxInt(u32)) return error.InvalidTickValue;
        return @intCast(val);
    }

    /// Parses a TOML test scenario document using `official.format.toml` with strict validation.
    pub fn parseScenarioToml(allocator: std.mem.Allocator, source: []const u8) !Scenario {
        const root = try toml_format.TomlService.parseTable(allocator, source);
        defer toml_format.TomlService.freeTable(allocator, root);

        const scen_val = root.get("scenario") orelse return error.MissingScenarioSection;
        if (scen_val != .table) return error.InvalidScenarioSection;

        const name_str = if (scen_val.table.get("name")) |v| switch (v) {
            .string => |s| s,
            else => return error.InvalidScenarioName,
        } else "unnamed";

        const ticks_u32: u32 = if (scen_val.table.get("ticks")) |v| switch (v) {
            .integer => |iv| try parseNonNegativeU32(iv.value),
            else => return error.InvalidTickValue,
        } else 1;

        var actions: std.ArrayList(ScenarioAction) = .empty;
        errdefer {
            for (actions.items) |a| allocator.free(a.target);
            actions.deinit(allocator);
        }

        if (root.get("actions")) |acts_val| {
            if (acts_val != .array) return error.InvalidActionsSection;
            for (acts_val.array.items) |item| {
                if (item != .table) return error.InvalidActionEntry;

                const at_tick: u32 = if (item.table.get("at_tick")) |tv| switch (tv) {
                    .integer => |iv| try parseNonNegativeU32(iv.value),
                    else => return error.InvalidTickValue,
                } else return error.MissingActionTick;

                if (at_tick >= ticks_u32) return error.ActionOutOfRange;

                const kind_str = if (item.table.get("type")) |kv| switch (kv) {
                    .string => |s| s,
                    else => return error.InvalidActionType,
                } else return error.MissingActionType;

                const kind: ScenarioActionKind = if (std.mem.eql(u8, kind_str, "ui_click"))
                    .ui_click
                else if (std.mem.eql(u8, kind_str, "key_up"))
                    .key_up
                else if (std.mem.eql(u8, kind_str, "key_down"))
                    .key_down
                else
                    return error.UnsupportedAction;

                const target_str = if (item.table.get("target")) |tg| switch (tg) {
                    .string => |s| s,
                    else => return error.InvalidActionTarget,
                } else "";

                const target_copy = try allocator.dupe(u8, target_str);
                errdefer allocator.free(target_copy);

                try actions.append(allocator, .{
                    .at_tick = at_tick,
                    .kind = kind,
                    .target = target_copy,
                });
            }
        }

        return .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name_str),
            .ticks = ticks_u32,
            .actions = actions,
        };
    }

    fn resolveKeyCode(target: []const u8) ?u8 {
        if (target.len == 0) return null;
        if (target.len == 1) return target[0];
        if (std.ascii.eqlIgnoreCase(target, "Space")) return ' ';
        if (std.ascii.eqlIgnoreCase(target, "Enter") or std.ascii.eqlIgnoreCase(target, "Return")) return '\r';
        if (std.ascii.eqlIgnoreCase(target, "Escape") or std.ascii.eqlIgnoreCase(target, "Esc")) return 27;
        if (std.ascii.eqlIgnoreCase(target, "Tab")) return '\t';
        if (std.ascii.eqlIgnoreCase(target, "Backspace")) return 8;
        return target[0];
    }

    /// Executes a parsed TOML `Scenario` tick-by-tick deterministically using `stepFixed`.
    pub fn runScenario(
        self: *TestDriver,
        scenario: *const Scenario,
        app: *engine.App,
        input: *window.InputService,
        ui_tree: ?*ui_core.UiTree,
    ) !void {
        for (0..scenario.ticks) |tick_idx| {
            input.beginFrame();
            for (scenario.actions.items) |act| {
                if (act.at_tick == tick_idx) {
                    switch (act.kind) {
                        .key_down => if (resolveKeyCode(act.target)) |k| self.pressKey(input, k),
                        .key_up => if (resolveKeyCode(act.target)) |k| self.releaseKey(input, k),
                        .ui_click => if (ui_tree) |tree| {
                            _ = try self.clickUiById(tree, act.target, &app.events);
                        },
                    }
                }
            }
            try self.stepFixed(app, 1);
        }
    }
};
