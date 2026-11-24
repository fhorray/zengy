# Modules, Services & Runtime Reflection API Reference

## 1. ModuleRegistry (`src/core/module_registry.zig`)

Modules are the primary composition unit for optional engine subsystems and game features.

### Defining a Module

```zig
const engine = @import("engine");

fn buildMyModule(raw_app: *anyopaque) !void {
    const app: *engine.App = @ptrCast(@alignCast(raw_app));
    // Register components, systems, resources, and services.
    _ = app;
}

fn startMyModule(_: *anyopaque) !void {}
fn stopMyModule(_: *anyopaque) void {}

pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = "community.my_module",
            .version = "0.1.0",
            .provides_capabilities = &.{"my.capability/1"},
            .required_capabilities = &.{"engine.window/1"},
            .optional_capabilities = &.{"engine.assets/1"},
        },
        .build = buildMyModule,
        .start = startMyModule,
        .stop = stopMyModule,
    };
}
```

### Resolution & Rollback Guarantees

- **Topological ordering:** `ModuleRegistry.resolve()` orders modules so providers always initialize before consumers, regardless of `app.registerModule()` call order.
- **Errors:**
  - `error.DuplicateModule` — Same `descriptor.id` registered twice.
  - `error.MissingRequiredCapability` — Required capability has no registered provider module.
  - `error.DependencyCycle` — Circular dependency between modules.
- **Rollback:** If `build()` or `start()` fails on any module, all previously built/started modules are rolled back via `stop()` in reverse topological order.
- **Shutdown:** `stopAll()` runs `stop()` in exact reverse topological order.

---

## 2. ServiceRegistry (`src/core/service_registry.zig`)

`ServiceRegistry` decouples capability contracts from concrete providers.

### Registering a Service

```zig
try app.services.register(.{
    .capability = "engine.graphics.device",
    .major_version = 1,
    .minor_version = 0,
    .provider_id = "official.graphics.software",
    .owner_id = MODULE_OWNER_ID,
    .scope = .application,
    .exclusive = true,
    .api_ptr = svc_ptr,
    .api_size = @sizeOf(GraphicsDeviceService),
});
```

### Resolving a Service

```zig
const entry = try app.services.getService("engine.graphics.device", 1);
const gfx: *GraphicsDeviceService = @ptrCast(@alignCast(@constCast(entry.api_ptr)));
```

Or using `getTyped`:

```zig
const gfx = try app.services.getTyped(GraphicsDeviceService, "engine.graphics.device", 1);
```

### Disambiguation & Errors

- `error.ProviderNotFound` — No provider registered for `capability`.
- `error.VersionMismatch` — Capability exists, but not for `requested_major`.
- `error.AmbiguousProvider` — Multiple providers registered for an `exclusive = true` capability without calling `app.services.selectProvider(capability, major, provider_id)`.
- `app.services.unregisterByOwner(owner_id)` — Removes all services owned by an unloading module or plugin.

---

## 3. TypeRegistry & ComponentSchema (`src/core/reflection.zig`)

Enables dynamic component schemas for editors, inspectors, scripting runtimes, and scene serialization without recompiling the host.

### Supported Field Types (`FieldType`)

`bool_t`, `i32_t`, `i64_t`, `u32_t`, `u64_t`, `f32_t`, `f64_t`, `vec2_t` (`[2]f32`), `vec3_t` (`[3]f32`), `vec4_t` (`[4]f32`), `enum_u32_t`, `entity_ref_t`, `asset_ref_t`, `fixed_str64_t`.

### Registering and Using a Schema

```zig
const schema = try app.types.registerSchema("sample.gameplay", "Health", 1, .blittable, &.{
    .{ .name = "current", .field_type = .f32_t },
    .{ .name = "maximum", .field_type = .f32_t },
});

const tid = try app.world.registerDynamicComponent("sample.gameplay.Health", schema.byte_size);
const entity = try app.world.spawn();

const buf = try allocator.alloc(u8, schema.byte_size);
defer allocator.free(buf);
@memset(buf, 0);

try engine.TypeRegistry.setField(schema, buf, "current", .{ .f32_t = 75.0 });
try engine.TypeRegistry.setField(schema, buf, "maximum", .{ .f32_t = 100.0 });
try app.world.setRaw(entity, tid, buf);

const stored = app.world.getRaw(entity, tid).?;
const current = try engine.TypeRegistry.getField(schema, stored, "current");
```

- `StableTypeId` (`u128`) is deterministically derived from `namespace + name` across schema versions; `SchemaId` (`u64`) identifies a specific `(namespace, name, version)`.
- `registerSchemaWithOwner(owner_id, ...)` / `unregisterByOwner(owner_id)` bind plugin-registered schemas to an `owner_id` so unloading a plugin cleans up its types.
- `getLatest(namespace, name)` and `getVersion(stable_id, version)` resolve schema versions; `registerMigration(namespace, name, from_version, fn)` chains `v -> v + 1` upgrades.
- `encodeComponent` / `decodeComponent` provide portable little-endian binary encoding without struct padding; `serializeWorld` / `deserializeWorld` persist and restore entities and registered component pools across worlds.
- Field offsets and total `byte_size` are automatically aligned according to each `FieldType`.
