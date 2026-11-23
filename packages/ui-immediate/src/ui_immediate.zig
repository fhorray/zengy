//! Alternative Immediate-Mode UI Backend (`community.ui.immediate`).
//!
//! Proves architectural independence from `official.ui.core`: this package does NOT
//! import `ui-core` or build a retained `UiTree`. Instead, it consumes only
//! `engine.window/1`, `engine.input/1`, and `engine.graphics.device/1` directly.

const std = @import("std");
const engine = @import("engine");
const window = @import("window");
const graphics = @import("graphics");

pub const MODULE_OWNER_ID: u64 = 2004;

/// Alternative immediate-mode UI backend that does NOT import or depend on ui-core.
/// Consumes only engine.window, engine.input, and engine.graphics.device.
pub const ImmediateUiService = struct {
    allocator: std.mem.Allocator,
    commands: std.ArrayList(graphics.DrawCommand),
    cursor_y: f32,

    pub fn init(allocator: std.mem.Allocator) ImmediateUiService {
        return .{
            .allocator = allocator,
            .commands = .empty,
            .cursor_y = 8,
        };
    }

    pub fn deinit(self: *ImmediateUiService) void {
        self.commands.deinit(self.allocator);
    }

    pub fn beginFrame(self: *ImmediateUiService) void {
        self.commands.clearRetainingCapacity();
        self.cursor_y = 8;
    }

    pub fn button(
        self: *ImmediateUiService,
        input: *const window.InputService,
        x: f32,
        w: f32,
        h: f32,
        label: []const u8,
    ) !bool {
        const y = self.cursor_y;
        self.cursor_y += h + 6;

        const hovered = input.mouse_x >= x and input.mouse_x <= x + w and
            input.mouse_y >= y and input.mouse_y <= y + h;

        try self.commands.append(self.allocator, .{
            .rect = .{
                .x = x,
                .y = y,
                .width = w,
                .height = h,
                .color = if (hovered) .{ .r = 0.22, .g = 0.32, .b = 0.48 } else .{ .r = 0.14, .g = 0.18, .b = 0.24 },
            },
        });
        try self.commands.append(self.allocator, .{
            .text = .{
                .x = x + 8,
                .y = y + 6,
                .content = label,
                .color = .{ .r = 1, .g = 1, .b = 1 },
            },
        });

        return hovered and input.wasMouseClicked(.left);
    }

    pub fn flush(self: *ImmediateUiService, gfx: *graphics.GraphicsDeviceService, target: graphics.RenderTargetHandle) !void {
        try gfx.submitDrawCommands(target, self.commands.items);
    }
};

fn buildModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    try app.resources.insert(ImmediateUiService, ImmediateUiService.init(app.allocator));
    const svc = app.resources.get(ImmediateUiService).?;

    try app.services.register(.{
        .capability = "engine.ui.backend.immediate",
        .major_version = 1,
        .provider_id = "community.ui.immediate",
        .owner_id = MODULE_OWNER_ID,
        .exclusive = false,
        .api_ptr = svc,
        .api_size = @sizeOf(ImmediateUiService),
    });
}

fn stopModule(raw_app: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    _ = app.services.unregisterByOwner(MODULE_OWNER_ID);
    if (app.resources.get(ImmediateUiService)) |svc| {
        svc.deinit();
        _ = app.resources.remove(ImmediateUiService);
    }
}

pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = "community.ui.immediate",
            .version = "0.1.0",
            .provides_capabilities = &.{"engine.ui.backend.immediate/1"},
            .required_capabilities = &.{ "engine.window/1", "engine.input/1", "engine.graphics.device/1" },
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
