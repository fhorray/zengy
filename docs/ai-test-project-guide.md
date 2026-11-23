# AI Agent Guide: Creating & Verifying a `zigeng` Test Project (Modules + Python Scripting)

This guide is designed for an **AI coding agent** (or developer) tasked with creating a standalone test project that depends on `zigeng`, composes optional modules, and verifies **PocketPy (Python) scripting** in both **headless** and **visual (SDL3 + SDL_GPU)** modes.

---

## 1. Environment Requirements

- **Zig**: `0.17.1` (exact version pinned by `zigeng`).
- **Git & Network**: to fetch `zigeng` from GitHub (or use a local path dependency).
- **Windows x64 visual runs**: place `SDL3.dll` next to the compiled `.exe` in `zig-out/bin/` and ensure a Vulkan-capable GPU driver is available.
- **Linux/macOS**: headless mode and `zig build test` work without SDL3 installed.

---

## 2. Project Setup

Create a fresh directory and initialize a Zig project:

```bash
mkdir zigeng-smoke-test && cd zigeng-smoke-test
zig init
zig fetch --save git+https://github.com/fhorray/zigeng#main
```

*(To pin a release instead of `main`, use `#v0.1.0`.)*

### Configure `build.zig`

Replace `build.zig` with the following configuration. Note that `link_libc = true` is required whenever importing `scripting_python`, `window_sdl3`, or `graphics_sdlgpu`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigeng = b.dependency("zigeng", .{
        .target = target,
        .optimize = optimize,
    });

    // 1. Headless test executable (no SDL/GPU required, runs anywhere)
    const headless_mod = b.createModule(.{
        .root_source_file = b.path("src/main_headless.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    headless_mod.addImport("engine", zigeng.module("engine"));
    headless_mod.addImport("window", zigeng.module("window"));
    headless_mod.addImport("graphics", zigeng.module("graphics"));
    headless_mod.addImport("scene", zigeng.module("scene"));
    headless_mod.addImport("scripting_host", zigeng.module("scripting_host"));
    headless_mod.addImport("scripting_python", zigeng.module("scripting_python"));

    const headless_exe = b.addExecutable(.{
        .name = "smoke-headless",
        .root_module = headless_mod,
    });
    b.installArtifact(headless_exe);

    const run_headless = b.addRunArtifact(headless_exe);
    b.step("run-headless", "Run headless module + PocketPy smoke test").dependOn(&run_headless.step);

    // 2. Visual executable (SDL3 + SDL_GPU + PocketPy)
    const visual_mod = b.createModule(.{
        .root_source_file = b.path("src/main_visual.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    visual_mod.addImport("engine", zigeng.module("engine"));
    visual_mod.addImport("window_sdl3", zigeng.module("window_sdl3"));
    visual_mod.addImport("graphics", zigeng.module("graphics"));
    visual_mod.addImport("graphics_sdlgpu", zigeng.module("graphics_sdlgpu"));
    visual_mod.addImport("scripting_host", zigeng.module("scripting_host"));
    visual_mod.addImport("scripting_python", zigeng.module("scripting_python"));

    const visual_exe = b.addExecutable(.{
        .name = "smoke-visual",
        .root_module = visual_mod,
    });
    b.installArtifact(visual_exe);

    const run_visual = b.addRunArtifact(visual_exe);
    b.step("run-visual", "Run visual SDL3 + SDL_GPU + PocketPy demo").dependOn(&run_visual.step);
}
```

---

## 3. Headless Verification (`src/main_headless.zig`)

This program verifies:
- Topological module resolution (`window`, `graphics`, `scene`, `scripting_host`, `scripting_python`)
- Custom Zig ECS component + system
- PocketPy script execution (`engine.log`, `engine.spawn_entity`, `engine.post_event`, `engine.draw_rect`)
- Event delivery and clean teardown with `DebugAllocator` leak check

```zig
const std = @import("std");
const engine = @import("engine");
const window = @import("window");
const graphics = @import("graphics");
const scene = @import("scene");
const scripting_host = @import("scripting_host");
const scripting_python = @import("scripting_python");

const CustomTag = struct { value: u32 };

const PyObserver = struct {
    received_event: bool = false,

    fn onEvent(ctx: ?*anyopaque, ev: engine.EventEnvelope) void {
        const self: *@This() = @ptrCast(@alignCast(ctx orelse return));
        if (std.mem.eql(u8, ev.name, "py.ready") and std.mem.eql(u8, ev.payload, "ok")) {
            self.received_event = true;
        }
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        if (gpa.deinit() == .leak) @panic("Memory leak detected!");
    }
    const allocator = gpa.allocator();

    var app = engine.App.init(allocator, .{});
    defer app.deinit();

    // Register optional modules (order does not matter; resolved topologically).
    try app.registerModule(scene.module());
    try app.registerModule(graphics.module());
    try app.registerModule(window.module());
    try app.registerModule(scripting_python.module());
    try app.registerModule(scripting_host.module());

    _ = try app.registerComponent(CustomTag);

    var observer = PyObserver{};
    _ = try app.events.subscribe(777, "py.ready", PyObserver.onEvent, &observer);

    try app.initialize();

    // Spawn a Zig entity with Transform2D + CustomTag.
    const e = try app.world.spawn();
    try app.world.set(e, scene.Transform2D, .{ .x = 10, .y = 20 });
    try app.world.set(e, CustomTag, .{ .value = 42 });

    // Load and invoke a PocketPy script on runtime index 0.
    const host = app.resources.get(scripting_host.ScriptingHost).?;
    const script = try host.loadScript(0, "smoke.py",
        \\import engine
        \\
        \\def run(arg):
        \\    engine.log("hello from PocketPy: " + arg)
        \\    ent = engine.spawn_entity()
        \\    engine.post_event("py.ready", arg)
        \\    engine.draw_rect(32, 48, 120, 64, 0.2, 0.8, 0.4, 1.0)
    );

    const res = host.invokeScript(script, "run", "ok");
    if (!res.ok) {
        std.debug.print("Python error: {s}\n", .{res.error_message});
        return error.ScriptFailed;
    }

    // Advance one frame so CommandBuffer applies and EventBus drains.
    try app.tick(1.0 / 60.0);

    // Assertions
    if (app.world.entity_count != 2) return error.UnexpectedEntityCount;
    if (!observer.received_event) return error.MissingPythonEvent;

    const draw_q = app.resources.get(scripting_host.ScriptDrawQueue).?;
    if (draw_q.rects.items.len != 1) return error.MissingPythonDrawRect;

    std.debug.print("[smoke-headless] PASS: entities={d}, rects={d}, logs={d}\n", .{
        app.world.entity_count,
        draw_q.rects.items.len,
        app.diagnostics.count(),
    });
}
```

---

## 4. Visual Verification (`src/main_visual.zig`)

This program swaps headless `window` + `graphics` for `window_sdl3` + `graphics_sdlgpu` and renders PocketPy's `engine.draw_rect(...)` calls on a live GPU window:

```zig
const std = @import("std");
const engine = @import("engine");
const window_sdl3 = @import("window_sdl3");
const graphics = @import("graphics");
const graphics_sdlgpu = @import("graphics_sdlgpu");
const scripting_host = @import("scripting_host");
const scripting_python = @import("scripting_python");

const PY_SCRIPT =
    \\import engine
    \\import math
    \\
    \\t = 0.0
    \\
    \\def on_frame(dt_str):
    \\    global t
    \\    t = t + float(dt_str)
    \\    x = 560.0 + math.cos(t * 2.0) * 180.0
    \\    y = 300.0 + math.sin(t * 2.0) * 120.0
    \\    engine.draw_rect(x, y, 96.0, 96.0, 0.25, 0.85, 0.65, 1.0)
;

const State = struct {
    allocator: std.mem.Allocator,
    app: *engine.App,
    host: *scripting_host.ScriptingHost,
    script: scripting_host.ScriptModuleHandle,
    gfx: *graphics.GraphicsDeviceService,
    rt: graphics.RenderTargetHandle,
    cmds: std.ArrayList(graphics.DrawCommand),
};

fn updateSystem(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(State) orelse return;
    if (st.app.resources.get(scripting_host.ScriptDrawQueue)) |q| q.clear();

    var buf: [32]u8 = undefined;
    const dt_str = std.fmt.bufPrint(&buf, "{d:.5}", .{ctx.dt}) catch "0.016";
    const res = st.host.invokeScript(st.script, "on_frame", dt_str);
    if (!res.ok) std.debug.print("Python error: {s}\n", .{res.error_message});
}

fn renderSystem(ctx: *engine.SystemContext) !void {
    const st = ctx.resources.get(State) orelse return;
    st.cmds.clearRetainingCapacity();

    try st.cmds.append(st.allocator, .{ .clear = .{ .r = 0.06, .g = 0.08, .b = 0.12, .a = 1.0 } });
    if (st.app.resources.get(scripting_host.ScriptDrawQueue)) |q| {
        for (q.rects.items) |r| {
            try st.cmds.append(st.allocator, .{
                .rect = .{
                    .x = r.x,
                    .y = r.y,
                    .width = r.width,
                    .height = r.height,
                    .color = .{ .r = r.r, .g = r.g, .b = r.b, .a = r.a },
                },
            });
        }
    }

    try st.gfx.beginFrame(st.rt);
    try st.gfx.submitDrawCommands(st.rt, st.cmds.items);
    try st.gfx.present(st.rt);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        if (gpa.deinit() == .leak) @panic("Memory leak detected!");
    }
    const allocator = gpa.allocator();

    var app = engine.App.init(allocator, .{});
    defer app.deinit();

    try app.registerModule(window_sdl3.module());
    try app.registerModule(graphics_sdlgpu.module());
    try app.registerModule(scripting_host.module());
    try app.registerModule(scripting_python.module());

    try app.resources.insert(window_sdl3.WindowConfig, .{
        .title = "ZigEng External Smoke Test (Python + SDL_GPU)",
        .width = 1280,
        .height = 720,
        .resizable = true,
    });

    try app.scheduler.addSystem(.{ .name = "py.update", .stage = .update, .run = updateSystem });
    try app.scheduler.addSystem(.{ .name = "py.render", .stage = .render_extract, .run = renderSystem });

    try app.initialize();

    const host = app.resources.get(scripting_host.ScriptingHost).?;
    const script = try host.loadScript(0, "main.py", PY_SCRIPT);

    const g_entry = try app.services.getService("engine.graphics.device", 1);
    const gfx: *graphics.GraphicsDeviceService = @ptrCast(@alignCast(@constCast(g_entry.api_ptr)));
    const px = window_sdl3.pixelSize(&app);
    const rt = try gfx.createSurface(1, if (px) |p| p.width else 1280, if (px) |p| p.height else 720);

    try app.resources.insert(State, .{
        .allocator = allocator,
        .app = &app,
        .host = host,
        .script = script,
        .gfx = gfx,
        .rt = rt,
        .cmds = .empty,
    });
    defer app.resources.get(State).?.cmds.deinit(allocator);

    try window_sdl3.runVisualLoop(&app);
}
```

---

## 5. Verification Commands & Expected Results

1. **Headless smoke test (works on Linux, macOS, Windows)**:
   ```bash
   zig build run-headless
   ```
   Expected output:
   `[smoke-headless] PASS: entities=2, rects=1, logs=1` (exit code `0`).

2. **Cross-compile visual test for Windows x64**:
   ```bash
   zig build -Dtarget=x86_64-windows
   ```
   Expected: `zig-out/bin/smoke-visual.exe` builds with exit code `0`.

3. **Run visual test on Windows** (with `SDL3.dll` next to `smoke-visual.exe`):
   ```bash
   ./zig-out/bin/smoke-visual.exe
   ```
   Expected: opens a 1280x720 window with an orbiting green square; `Escape` or window close button exits cleanly with zero leaks.

---

## 6. Common Pitfalls for AI Agents

1. **Missing `link_libc = true`**: `scripting_python`, `window_sdl3`, and `graphics_sdlgpu` wrap C libraries (`pocketpy.c`, `SDL3`). Always set `.link_libc = true` on any module/executable importing them.
2. **`MutationDuringActiveQuery`**: Never call `app.world.spawn()` or `app.world.destroy()` while a `ctx.query(...)` is still alive. Scope queries in `{ var q = ...; defer q.deinit(); ... }`.
3. **Runtime index in `ScriptingHost`**: Runtimes are indexed `0, 1, ...` in the order their modules were registered (or resolved). If only `scripting_python.module()` is registered, its runtime index is `0`.
4. **PocketPy sandbox (`-DPK_ENABLE_OS=0`)**: OS/socket modules are disabled in PocketPy; use `engine.*` bindings for host interaction.
5. **Exclusive providers**: Never register both `window` and `window_sdl3` (or both `graphics` and `graphics_sdlgpu`) in the same `App` unless you explicitly call `app.services.selectProvider(...)`.
