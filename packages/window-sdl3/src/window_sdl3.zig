//! Native Window & Input Provider backed by SDL 3.4.20 (`official.window.sdl3`).
//!
//! Visual counterpart of `official.window` (headless). It provides the same
//! `engine.window/1` and `engine.input/1` capabilities, using the same
//! `WindowService` / `InputService` types, so existing consumers keep working.
//!
//! Only one of `official.window` and `official.window.sdl3` may be registered in an App
//! (both are exclusive providers).
//!
//! Design:
//! - SDL is linked only by this package. `src/core/` does not import SDL.
//! - The main window is created at module build from an optional `WindowConfig` resource.
//! - `pollEvents` drains SDL's queue once per frame and feeds `InputService` and
//!   `WindowService` (close requests, resizes), which also post `EventBus` events.
//! - `runVisualLoop` owns the OS loop: poll -> tick -> frame pacing, until the window closes.

const std = @import("std");
const engine = @import("engine");
const window = @import("window");
const c = @import("sdl3_c");

pub const MODULE_OWNER_ID: u64 = 2011;
pub const PROVIDER_ID = "official.window.sdl3";

/// Optional resource inserted before `app.initialize()` to customise the main window.
pub const WindowConfig = struct {
    title: []const u8 = "ZigEng",
    width: u32 = 1280,
    height: u32 = 720,
    resizable: bool = true,
};

/// Target frame time used by `runVisualLoop` (60 Hz) to avoid spinning a CPU core.
const TARGET_FRAME_NS: u64 = 16_666_667;
/// Upper bound for a single frame's dt, so a stall (drag, breakpoint) does not explode physics.
const MAX_FRAME_DT: f64 = 0.25;

const SdlState = struct {
    window_svc: window.WindowService,
    input_svc: window.InputService,
    sdl_window: *c.SDL_Window,
    handle: window.WindowHandle,
    pixel_w: u32,
    pixel_h: u32,
    dpi_scale: f32,
    owns_sdl: bool,
};

/// Maps SDL mouse button indices (1 left, 2 middle, 3 right) to `window.MouseButton`.
pub fn mapMouseButton(sdl_button: u8) ?window.MouseButton {
    return switch (sdl_button) {
        c.SDL_BUTTON_LEFT => .left,
        c.SDL_BUTTON_RIGHT => .right,
        c.SDL_BUTTON_MIDDLE => .middle,
        else => null,
    };
}

/// Keyboard codes exposed to `InputService` are physical scancodes (0..255).
/// Keys outside that range are ignored by the current `InputService` table.
pub fn mapScancode(scancode: c.SDL_Scancode) ?u8 {
    const raw: u32 = @intCast(scancode);
    if (raw >= 256) return null;
    return @intCast(raw);
}

fn sdlError(prefix: []const u8) error{SdlFailure} {
    std.log.err("{s}: {s}", .{ prefix, std.mem.span(c.SDL_GetError()) });
    return error.SdlFailure;
}

fn buildModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    const cfg: WindowConfig = if (app.resources.get(WindowConfig)) |p| p.* else .{};

    // SDL subsystems are ref-counted: only release the video subsystem if this module initialised it.
    const owns_sdl = c.SDL_WasInit(c.SDL_INIT_VIDEO) == 0;
    if (owns_sdl and !c.SDL_InitSubSystem(c.SDL_INIT_VIDEO)) return sdlError("SDL_InitSubSystem failed");

    var flags: c.SDL_WindowFlags = c.SDL_WINDOW_HIGH_PIXEL_DENSITY;
    if (cfg.resizable) flags |= c.SDL_WINDOW_RESIZABLE;

    var title_buf: [256]u8 = undefined;
    const title_len = @min(cfg.title.len, title_buf.len - 1);
    @memcpy(title_buf[0..title_len], cfg.title[0..title_len]);
    title_buf[title_len] = 0;

    const sdl_window = c.SDL_CreateWindow(&title_buf, @intCast(cfg.width), @intCast(cfg.height), flags) orelse {
        return sdlError("SDL_CreateWindow failed");
    };
    errdefer c.SDL_DestroyWindow(sdl_window);

    var window_svc = window.WindowService.init(app.allocator, &app.events);
    errdefer window_svc.deinit();
    const handle = try window_svc.createWindow(.{
        .title = cfg.title,
        .width = cfg.width,
        .height = cfg.height,
        .dpi_scale = c.SDL_GetWindowDisplayScale(sdl_window),
    });

    _ = c.SDL_StartTextInput(sdl_window);

    try app.resources.insert(SdlState, .{
        .window_svc = window_svc,
        .input_svc = .{},
        .sdl_window = sdl_window,
        .handle = handle,
        .pixel_w = cfg.width,
        .pixel_h = cfg.height,
        .dpi_scale = c.SDL_GetWindowDisplayScale(sdl_window),
        .owns_sdl = owns_sdl,
    });

    const state = app.resources.get(SdlState).?;
    try app.services.register(.{
        .capability = "engine.window",
        .major_version = 1,
        .provider_id = PROVIDER_ID,
        .owner_id = MODULE_OWNER_ID,
        .exclusive = true,
        .api_ptr = &state.window_svc,
        .api_size = @sizeOf(window.WindowService),
    });
    try app.services.register(.{
        .capability = "engine.input",
        .major_version = 1,
        .provider_id = PROVIDER_ID,
        .owner_id = MODULE_OWNER_ID,
        .exclusive = true,
        .api_ptr = &state.input_svc,
        .api_size = @sizeOf(window.InputService),
    });

    refreshPixelSize(state);
}

fn stopModule(raw_app: *anyopaque) void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    _ = app.services.unregisterByOwner(MODULE_OWNER_ID);
    if (app.resources.get(SdlState)) |state| {
        _ = state.window_svc.destroyWindow(state.handle);
        state.window_svc.deinit();
        c.SDL_DestroyWindow(state.sdl_window);
        if (state.owns_sdl) c.SDL_QuitSubSystem(c.SDL_INIT_VIDEO);
        _ = app.resources.remove(SdlState);
    }
}

/// Reads the window size in physical pixels and DPI scale from SDL.
fn refreshPixelSize(state: *SdlState) void {
    var w: c_int = 0;
    var h: c_int = 0;
    if (c.SDL_GetWindowSizeInPixels(state.sdl_window, &w, &h)) {
        state.pixel_w = @intCast(w);
        state.pixel_h = @intCast(h);
    }
    state.dpi_scale = c.SDL_GetWindowDisplayScale(state.sdl_window);
}

/// Returns an opaque pointer to the underlying `SDL_Window` for sibling native backends
/// (such as `official.graphics.sdlgpu`) without leaking SDL types into public engine contracts.
pub fn sdlWindowOpaque(app: *engine.App) ?*anyopaque {
    const state = app.resources.get(SdlState) orelse return null;
    return @ptrCast(state.sdl_window);
}

/// Returns true if the main window is currently minimized or has zero pixel extent.
pub fn isMinimized(app: *engine.App) bool {
    const state = app.resources.get(SdlState) orelse return false;
    if ((c.SDL_GetWindowFlags(state.sdl_window) & c.SDL_WINDOW_MINIMIZED) != 0) return true;
    return state.pixel_w == 0 or state.pixel_h == 0;
}

/// Returns the window's current size in physical pixels (for render targets) and its DPI scale.
pub fn pixelSize(app: *engine.App) ?struct { width: u32, height: u32, dpi_scale: f32 } {
    const state = app.resources.get(SdlState) orelse return null;
    return .{ .width = state.pixel_w, .height = state.pixel_h, .dpi_scale = state.dpi_scale };
}

/// Drains the SDL event queue for this frame and updates Input and Window services.
pub fn pollEvents(app: *engine.App) void {
    const state = app.resources.get(SdlState) orelse return;
    state.input_svc.beginFrame();

    var ev: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&ev)) {
        switch (ev.type) {
            c.SDL_EVENT_QUIT, c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => {
                _ = state.window_svc.requestClose(state.handle);
            },
            c.SDL_EVENT_WINDOW_RESIZED, c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED, c.SDL_EVENT_WINDOW_RESTORED => {
                var w: c_int = 0;
                var h: c_int = 0;
                if (c.SDL_GetWindowSize(state.sdl_window, &w, &h)) {
                    _ = state.window_svc.resize(state.handle, @intCast(w), @intCast(h));
                }
                refreshPixelSize(state);
            },
            c.SDL_EVENT_WINDOW_MINIMIZED => {
                refreshPixelSize(state);
            },
            c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => {
                if (ev.key.repeat) continue;
                const key = mapScancode(ev.key.scancode) orelse continue;
                state.input_svc.injectKey(key, ev.key.down);
                // Escape closes the window, matching the D1 acceptance criteria.
                if (ev.key.down and ev.key.scancode == c.SDL_SCANCODE_ESCAPE) {
                    _ = state.window_svc.requestClose(state.handle);
                }
            },
            c.SDL_EVENT_MOUSE_MOTION => {
                state.input_svc.injectMouseMove(ev.motion.x, ev.motion.y);
            },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP => {
                const button = mapMouseButton(ev.button.button) orelse continue;
                state.input_svc.injectMouseButton(button, ev.button.down);
            },
            c.SDL_EVENT_TEXT_INPUT => {
                state.input_svc.injectText(std.mem.span(ev.text.text));
            },
            else => {},
        }
    }
}

/// Requests a close from the application side (e.g. a "Quit" button).
pub fn requestClose(app: *engine.App) void {
    const state = app.resources.get(SdlState) orelse return;
    _ = state.window_svc.requestClose(state.handle);
}

/// Returns true once the main window has been asked to close.
pub fn closeRequested(app: *engine.App) bool {
    const state = app.resources.get(SdlState) orelse return true;
    return state.window_svc.shouldClose(state.handle);
}

/// Runs the visual application loop: initialize, then poll -> tick -> pace, until the window
/// is closed or `app.quit()` is called. Shuts the app down before returning.
pub fn runVisualLoop(app: *engine.App) !void {
    try app.initialize();

    const freq = c.SDL_GetPerformanceFrequency();
    var last = c.SDL_GetPerformanceCounter();

    while (!app.should_quit and !closeRequested(app)) {
        pollEvents(app);
        if (closeRequested(app)) break;

        if (isMinimized(app)) {
            c.SDL_Delay(50);
            last = c.SDL_GetPerformanceCounter();
            continue;
        }

        const now = c.SDL_GetPerformanceCounter();
        const dt_ns_raw = (now - last) * std.time.ns_per_s / freq;
        last = now;
        const dt = @min(@as(f64, @floatFromInt(dt_ns_raw)) / std.time.ns_per_s, MAX_FRAME_DT);

        try app.tick(dt);

        // Frame pacing: sleep off the remaining budget so an idle window does not spin.
        const frame_ns = (c.SDL_GetPerformanceCounter() - now) * std.time.ns_per_s / freq;
        if (frame_ns < TARGET_FRAME_NS) {
            c.SDL_Delay(@intCast((TARGET_FRAME_NS - frame_ns) / std.time.ns_per_ms));
        }
    }

    app.shutdown();
}

pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = PROVIDER_ID,
            .version = "0.1.0",
            .provides_capabilities = &.{ "engine.window/1", "engine.input/1" },
        },
        .build = buildModule,
        .stop = stopModule,
    };
}
