//! Testing & Automation SDK Package (`official.testing`).
//!
//! Provides deterministic simulation stepping (`TestDriver` / `engine.testing.driver/1`),
//! TOML scenario execution (`Scenario`, `parseScenarioToml`, `runScenario`), and
//! offscreen software render capture (`CaptureService` / `engine.testing.capture/1`).

const engine = @import("engine");
pub const driver = @import("test_driver.zig");
pub const capture = @import("capture.zig");

pub const TestDriver = driver.TestDriver;
pub const Scenario = driver.Scenario;
pub const CaptureService = capture.CaptureService;

pub const MODULE_OWNER_ID: u64 = 2013;

fn buildModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));

    try app.resources.insert(TestDriver, .{});
    const drv = app.resources.get(TestDriver).?;

    try app.resources.insert(CaptureService, try CaptureService.init(app.allocator, 128, 128));
    errdefer _ = app.resources.remove(CaptureService);
    const cap = app.resources.get(CaptureService).?;

    try app.services.register(.{
        .capability = "engine.testing.driver",
        .major_version = 1,
        .provider_id = "official.testing.driver",
        .owner_id = MODULE_OWNER_ID,
        .exclusive = true,
        .api_ptr = drv,
        .api_size = @sizeOf(TestDriver),
    });

    try app.services.register(.{
        .capability = "engine.testing.capture",
        .major_version = 1,
        .provider_id = "official.testing.capture.software",
        .owner_id = MODULE_OWNER_ID,
        .exclusive = true,
        .api_ptr = cap,
        .api_size = @sizeOf(CaptureService),
    });
}

fn stopModule(raw_app: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    _ = app.services.unregisterByOwner(MODULE_OWNER_ID);
    _ = app.resources.remove(CaptureService);
    _ = app.resources.remove(TestDriver);
}

pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = "official.testing",
            .version = "0.1.0",
            .provides_capabilities = &.{ "engine.testing.driver/1", "engine.testing.capture/1" },
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
