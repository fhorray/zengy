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

pub const CommandBuffer = commands.CommandBuffer;
pub const EventBus = events.EventBus;
pub const EventEnvelope = events.EventEnvelope;
pub const ResourceRegistry = resources.ResourceRegistry;
pub const ServiceRegistry = service_registry.ServiceRegistry;
pub const ServiceDescriptor = service_registry.ServiceDescriptor;
pub const ModuleRegistry = module_registry.ModuleRegistry;
pub const ModuleDescriptor = module_mod_helper.ModuleDescriptor;
pub const Module = module_mod_helper.Module;
pub const TypeRegistry = reflection.TypeRegistry;
pub const ComponentSchema = reflection.ComponentSchema;
pub const FieldDescriptor = reflection.FieldDescriptor;
pub const Diagnostics = diagnostics.Diagnostics;
pub const LogLevel = diagnostics.LogLevel;

const module_mod_helper = module_registry;
