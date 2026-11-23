# Core API Reference: App, ECS, Scheduler, Commands, Events & Diagnostics

Import the public SDK in any Zig module or executable:

```zig
const engine = @import("engine");
```

---

## 1. `App` (`src/core/app.zig`)

`App` owns and coordinates all core subsystems (`World`, `Scheduler`, `CommandBuffer`, `EventBus`, `ResourceRegistry`, `ServiceRegistry`, `ModuleRegistry`, `TypeRegistry`, `Diagnostics`, and lazy `PluginHost`).

### Lifecycle States (`AppState`)

`created -> configured -> initialized -> running -> stopping -> stopped`

### Configuration (`AppConfig`)

```zig
pub const AppConfig = struct {
    fixed_dt: f64 = 1.0 / 60.0,
    max_fixed_steps: u32 = 8,
    max_frames: ?u64 = null,
    event_queue_capacity: usize = 1024,
    event_overflow_policy: OverflowPolicy = .drop_newest,
    log_capacity: usize = 256,
};
```

### Methods

- `App.init(allocator, config) App` — Initializes a headless `App`. Does not allocate UI, GPU, or scripting resources.
- `app.deinit() void` — Shuts down active modules/plugins and frees all subsystem memory.
- `app.registerModule(module) !void` — Registers an optional `Module`.
- `app.registerComponent(comptime T: type) !ComponentTypeId` — Pre-registers a Zig component type.
- `app.addSystem(desc: SystemDescriptor) !void` — Adds a system to a scheduler stage.
- `app.initialize() !void` — Resolves/builds/starts modules, compiles stage schedules, runs `.startup` systems, and drains startup events.
- `app.tick(frame_dt: f64) !void` — Advances one frame (`.pre_update`, `0..max_fixed_steps` of `.fixed_update`, `.update`, `.post_update`, optional `.render_extract`, and event drain).
- `app.run() !void` — Calls `initialize()`, loops `tick()` until `app.quit()` or `config.max_frames`, then calls `shutdown()`.
- `app.shutdown() void` — Runs `.shutdown` stage and stops all modules in reverse topological order.

---

## 2. ECS World & Queries (`src/core/world.zig`)

### Handles & Identity

- `EntityHandle` — Packed 64-bit `(index: u32, generation: u32)`. Despawning increments `generation`, so stale handles return `false` from `isAlive()` and `null` from `get()`/`getConst()`.
- `EntityGuid` — Persistent `u128` identifier for scene serialization and asset references.
- `WorldId` — Packed 64-bit `(index: u32, generation: u32)` identifying a `World`.

### World Methods

- `world.spawn() !EntityHandle` — Allocates or recycles an entity slot. Fails with `error.MutationDuringActiveQuery` if a `Query` is open.
- `world.despawn(entity) !bool` — Removes all components, bumps generation, and recycles the index.
- `world.isAlive(entity) bool` — Checks generation and alive flag.
- `world.getGuid(entity) ?EntityGuid` — Returns the persistent GUID if alive.
- `world.set(entity, T, value) !void` — Attaches or updates component `T`. Auto-registers `T` if needed.
- `world.get(entity, T) ?*T` / `world.getConst(entity, T) ?*const T` — Returns a pointer to component `T`.
- `world.has(entity, T) bool` — Checks component presence.
- `world.remove(entity, T) !bool` — Removes component `T`.
- `world.registerDynamicComponent(name, size) !ComponentTypeId` — Registers a runtime-sized component pool.
- `world.setRaw(entity, type_id, bytes) !void` / `world.getRaw(entity, type_id) ?[]u8` — Raw byte access for schemas and scripting bridges.

### Queries

`World.query` caches component pool pointers during `init()` for zero-hash-lookup iteration:

```zig
fn movementSystem(ctx: *engine.SystemContext) !void {
    const dt = ctx.fixedDeltaSeconds();
    var q = try ctx.query(.{ .write = .{Position}, .read = .{Velocity} });
    defer q.deinit();

    while (q.next()) |row| {
        const pos = row.write(Position);
        const vel = row.read(Velocity);
        pos.x += vel.x * dt;
        pos.y += vel.y * dt;
    }
}
```

> **Note:** Always call `defer q.deinit();`. Structural mutations (`spawn`, `despawn`, `set`, `remove`) are rejected while `active_queries > 0`. Use `ctx.commands` during iteration.

---

## 3. Scheduler (`src/core/scheduler.zig`)

### Stages (`Stage`)

1. `.startup` (runs once during `initialize()`)
2. `.pre_update`
3. `.fixed_update` (driven by fixed-timestep accumulator)
4. `.update`
5. `.post_update`
6. `.render_extract` (runs only when `scheduler.render_extract_enabled == true`, e.g., when a graphics module is active)
7. `.shutdown` (runs once during `shutdown()`)

### `SystemDescriptor`

```zig
try app.addSystem(.{
    .name = "physics.integrate",
    .stage = .fixed_update,
    .run = integrateSystem,
    .reads = &.{"Velocity"},
    .writes = &.{"Position"},
    .before = &.{"physics.collide"},
    .after = &.{"input.sample"},
});
```

- Systems within each stage are topologically sorted using `before`/`after` constraints.
- Cycles return `error.DependencyCycle`.
- `CommandBuffer.apply()` runs automatically at the end of every stage.

---

## 4. CommandBuffer (`src/core/commands.zig`)

Queues deferred mutations and events to be applied safely at stage barriers:

- `commands.spawn() !void`
- `commands.despawn(entity) !void`
- `commands.set(entity, T, value) !void`
- `commands.remove(entity, T) !void`
- `commands.emit(envelope: EventEnvelope) !void`
- `commands.apply(world, events) !void`

---

## 5. EventBus (`src/core/events.zig`)

Bounded, owner-scoped event queue using `EventEnvelope`:

```zig
pub const EventEnvelope = struct {
    name: []const u8,
    payload: []const u8,
    world_id: u64 = 0,
    entity_handle: u64 = 0,
};
```

- `events.subscribe(owner_id, event_name, callback, user_data) !SubscriptionId` — Supports exact names or `"*"` wildcard.
- `events.unsubscribe(sub_id) bool`
- `events.unsubscribeByOwner(owner_id) usize` — Cancels all subscriptions owned by an unloading module or plugin.
- `events.post(envelope) !void` — Enqueues an event, enforcing `max_queue_len` and `overflow_policy` (`dropped_events` counter incremented on overflow).
- `events.drain() usize` — Dispatches all queued events to matching subscribers.

---

## 6. ResourceRegistry (`src/core/resources.zig`)

Type-erased singleton storage keyed by `@typeName(T)` hash:

- `resources.insert(T, value) !void`
- `resources.get(T) ?*T` / `resources.getConst(T) ?*const T`
- `resources.contains(T) bool`
- `resources.remove(T) bool`

---

## 7. Diagnostics (`src/core/diagnostics.zig`)

Finite-retention ring buffer for structured logs and frame telemetry:

- `diagnostics.log(level, subsystem, message) !void` (`LogLevel`: `.debug`, `.info`, `.warn`, `.err`)
- `diagnostics.count() usize`
- `diagnostics.get(idx) ?LogRecord` (chronological order, `0` = oldest retained)
- `diagnostics.evicted_logs`, `diagnostics.total_logs`, `diagnostics.frame_count`
