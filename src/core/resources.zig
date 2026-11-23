const std = @import("std");

pub fn typeId(comptime T: type) usize {
    return @truncate(std.hash.Wyhash.hash(0x9e3779b97f4a7c15, @typeName(T)));
}

const ResourceEntry = struct {
    ptr: *anyopaque,
    destroy_fn: *const fn (*anyopaque, std.mem.Allocator) void,
};

pub const ResourceRegistry = struct {
    allocator: std.mem.Allocator,
    entries: std.AutoHashMapUnmanaged(usize, ResourceEntry),

    pub fn init(allocator: std.mem.Allocator) ResourceRegistry {
        return .{
            .allocator = allocator,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *ResourceRegistry) void {
        var it = self.entries.valueIterator();
        while (it.next()) |entry| {
            entry.destroy_fn(entry.ptr, self.allocator);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn insert(self: *ResourceRegistry, comptime T: type, value: T) !void {
        const key = typeId(T);
        if (self.entries.get(key)) |existing| {
            const typed: *T = @ptrCast(@alignCast(existing.ptr));
            typed.* = value;
            return;
        }

        const ptr = try self.allocator.create(T);
        ptr.* = value;

        const Destroy = struct {
            fn call(raw: *anyopaque, alloc: std.mem.Allocator) void {
                const typed: *T = @ptrCast(@alignCast(raw));
                alloc.destroy(typed);
            }
        };

        try self.entries.put(self.allocator, key, .{
            .ptr = ptr,
            .destroy_fn = Destroy.call,
        });
    }

    pub fn get(self: *ResourceRegistry, comptime T: type) ?*T {
        const entry = self.entries.get(typeId(T)) orelse return null;
        return @ptrCast(@alignCast(entry.ptr));
    }

    pub fn getConst(self: *const ResourceRegistry, comptime T: type) ?*const T {
        const entry = self.entries.get(typeId(T)) orelse return null;
        return @ptrCast(@alignCast(entry.ptr));
    }

    pub fn contains(self: *const ResourceRegistry, comptime T: type) bool {
        return self.entries.contains(typeId(T));
    }

    pub fn remove(self: *ResourceRegistry, comptime T: type) bool {
        const kv = self.entries.fetchRemove(typeId(T)) orelse return false;
        kv.value.destroy_fn(kv.value.ptr, self.allocator);
        return true;
    }
};
