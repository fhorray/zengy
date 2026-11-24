//! Public Zig SDK entrypoint (`@import("engine")`).
//!
//! This module re-exports the minimal headless core contracts:
//! - Application lifecycle (`App`, `AppConfig`, `AppState`)
//! - ECS facade (`World`, `WorldId`, `EntityHandle`, `EntityGuid`, `ComponentTypeId`)
//! - Deterministic stage scheduler (`Stage`, `SystemContext`, `SystemDescriptor`)
//! - Deferred command barrier (`CommandBuffer`)
//! - Bounded event bus (`EventBus`, `EventEnvelope`)
//! - Typed resource storage (`ResourceRegistry`)
//! - Capability/provider service discovery (`ServiceRegistry`, `ServiceDescriptor`)
//! - Topological module lifecycle (`ModuleRegistry`, `ModuleDescriptor`, `Module`)
//! - Runtime reflection schemas (`TypeRegistry`, `ComponentSchema`, `FieldDescriptor`)
//! - Structured diagnostics (`Diagnostics`, `LogLevel`)
//! - Versioned C ABI host (`abi`)
//!
//! Architectural invariant: `src/core/` never imports optional packages (window, graphics,
//! UI, scripting, assets, or editor). All optional capabilities depend on this SDK.

pub const app = @import("core/app.zig");
pub const world = @import("core/world.zig");
pub const scheduler = @import("core/scheduler.zig");
pub const commands = @import("core/commands.zig");
pub const events = @import("core/events.zig");
pub const resources = @import("core/resources.zig");
pub const service_registry = @import("core/service_registry.zig");
pub const module_registry = @import("core/module_registry.zig");
pub const reflection = @import("core/reflection.zig");
pub const diagnostics = @import("core/diagnostics.zig");
pub const time = @import("core/time.zig");
pub const abi = @import("core/abi.zig");

pub const App = app.App;
pub const AppConfig = app.AppConfig;
pub const AppState = app.AppState;

pub const World = world.World;
pub const WorldId = world.WorldId;
pub const EntityHandle = world.EntityHandle;
pub const EntityGuid = world.EntityGuid;
pub const ComponentTypeId = world.ComponentTypeId;

pub const Stage = scheduler.Stage;
pub const SystemContext = scheduler.SystemContext;
pub const SystemDescriptor = scheduler.SystemDescriptor;
pub const RunConditionFn = scheduler.RunConditionFn;
pub const Time = time.Time;
pub const Timer = time.Timer;
pub const TimerMode = time.TimerMode;
pub const Stopwatch = time.Stopwatch;

pub const CommandBuffer = commands.CommandBuffer;
pub const EventBus = events.EventBus;
pub const EventEnvelope = events.EventEnvelope;
pub const ResourceRegistry = resources.ResourceRegistry;
pub const ServiceRegistry = service_registry.ServiceRegistry;
pub const ServiceDescriptor = service_registry.ServiceDescriptor;
pub const ModuleRegistry = module_registry.ModuleRegistry;
pub const ModuleDescriptor = module_registry.ModuleDescriptor;
pub const Module = module_registry.Module;
pub const TypeRegistry = reflection.TypeRegistry;
pub const ComponentSchema = reflection.ComponentSchema;
pub const FieldDescriptor = reflection.FieldDescriptor;
pub const Diagnostics = diagnostics.Diagnostics;
pub const LogLevel = diagnostics.LogLevel;
