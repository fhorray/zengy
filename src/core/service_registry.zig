const std = @import("std");

pub const CapabilityScope = enum {
    process,
    application,
    world,
    window,
    plugin,
    frame,
};

pub const ServiceError = error{
    ProviderNotFound,
    VersionMismatch,
    AmbiguousProvider,
    OutOfMemory,
};

pub const ServiceDescriptor = struct {
    capability: []const u8,
    major_version: u32,
    minor_version: u32 = 0,
    provider_id: []const u8,
    owner_id: u64 = 0,
    scope: CapabilityScope = .application,
    exclusive: bool = false,
    api_ptr: *const anyopaque,
    api_size: u32,
};

pub const ServiceEntry = struct {
    capability: []const u8,
    major_version: u32,
    minor_version: u32,
    provider_id: []const u8,
    owner_id: u64,
    scope: CapabilityScope,
    exclusive: bool,
    api_ptr: *const anyopaque,
    api_size: u32,
};

const ProviderSelection = struct {
    capability: []const u8,
    major_version: u32,
    provider_id: []const u8,
};

pub const ServiceRegistry = struct {
    allocator: std.mem.Allocator,
    services: std.ArrayList(ServiceEntry),
    selections: std.ArrayList(ProviderSelection),

    pub fn init(allocator: std.mem.Allocator) ServiceRegistry {
        return .{
            .allocator = allocator,
            .services = .empty,
            .selections = .empty,
        };
    }

    pub fn deinit(self: *ServiceRegistry) void {
        for (self.services.items) |svc| {
            self.allocator.free(svc.capability);
            self.allocator.free(svc.provider_id);
        }
        self.services.deinit(self.allocator);

        for (self.selections.items) |sel| {
            self.allocator.free(sel.capability);
            self.allocator.free(sel.provider_id);
        }
        self.selections.deinit(self.allocator);
    }

    pub fn register(self: *ServiceRegistry, desc: ServiceDescriptor) !void {
        const cap_copy = try self.allocator.dupe(u8, desc.capability);
        errdefer self.allocator.free(cap_copy);
        const prov_copy = try self.allocator.dupe(u8, desc.provider_id);
        errdefer self.allocator.free(prov_copy);

        try self.services.append(self.allocator, .{
            .capability = cap_copy,
            .major_version = desc.major_version,
            .minor_version = desc.minor_version,
            .provider_id = prov_copy,
            .owner_id = desc.owner_id,
            .scope = desc.scope,
            .exclusive = desc.exclusive,
            .api_ptr = desc.api_ptr,
            .api_size = desc.api_size,
        });
    }

    pub fn selectProvider(self: *ServiceRegistry, capability: []const u8, major_version: u32, provider_id: []const u8) !void {
        for (self.selections.items) |*sel| {
            if (sel.major_version == major_version and std.mem.eql(u8, sel.capability, capability)) {
                const new_prov = try self.allocator.dupe(u8, provider_id);
                self.allocator.free(sel.provider_id);
                sel.provider_id = new_prov;
                return;
            }
        }
        const cap_copy = try self.allocator.dupe(u8, capability);
        errdefer self.allocator.free(cap_copy);
        const prov_copy = try self.allocator.dupe(u8, provider_id);
        errdefer self.allocator.free(prov_copy);

        try self.selections.append(self.allocator, .{
            .capability = cap_copy,
            .major_version = major_version,
            .provider_id = prov_copy,
        });
    }

    pub fn getService(self: *const ServiceRegistry, capability: []const u8, requested_major: u32) ServiceError!ServiceEntry {
        var found_capability = false;
        var match_count: usize = 0;
        var any_exclusive = false;
        var first_match: ?ServiceEntry = null;

        var selected_provider: ?[]const u8 = null;
        for (self.selections.items) |sel| {
            if (sel.major_version == requested_major and std.mem.eql(u8, sel.capability, capability)) {
                selected_provider = sel.provider_id;
                break;
            }
        }

        for (self.services.items) |svc| {
            if (!std.mem.eql(u8, svc.capability, capability)) continue;
            found_capability = true;

            if (svc.major_version != requested_major) continue;

            if (selected_provider) |sel_id| {
                if (std.mem.eql(u8, svc.provider_id, sel_id)) {
                    return svc;
                }
            }

            match_count += 1;
            if (svc.exclusive) any_exclusive = true;
            if (first_match == null) first_match = svc;
        }

        if (!found_capability) return error.ProviderNotFound;
        if (match_count == 0) return error.VersionMismatch;
        if (selected_provider != null) return error.ProviderNotFound;
        if (match_count > 1 and any_exclusive) return error.AmbiguousProvider;

        return first_match.?;
    }

    pub fn getTyped(self: *const ServiceRegistry, comptime T: type, capability: []const u8, requested_major: u32) ServiceError!*const T {
        const entry = try self.getService(capability, requested_major);
        return @ptrCast(@alignCast(entry.api_ptr));
    }

    pub fn hasService(self: *const ServiceRegistry, capability: []const u8, requested_major: u32) bool {
        _ = self.getService(capability, requested_major) catch return false;
        return true;
    }

    pub fn unregisterByOwner(self: *ServiceRegistry, owner_id: u64) usize {
        var removed: usize = 0;
        var i: usize = 0;
        while (i < self.services.items.len) {
            if (self.services.items[i].owner_id == owner_id) {
                const svc = self.services.orderedRemove(i);
                self.allocator.free(svc.capability);
                self.allocator.free(svc.provider_id);
                removed += 1;
            } else {
                i += 1;
            }
        }
        return removed;
    }

    pub fn count(self: *const ServiceRegistry) usize {
        return self.services.items.len;
    }
};
