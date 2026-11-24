//! Typed Resource Registry (`core/resources`).
//!
//! Stores singleton application- or world-scoped resources keyed by a deterministic
//! compile-time type hash (`typeId`). Each inserted resource stores a type-erased
//! destructor so `deinit()` and `remove()` cleanly release memory without leaks.

const std = @import("std");

/// Computes a deterministic type identifier from `@typeName(T)`.
/// Hashing `@typeName(T)` avoids LLVM identical-code-folding (ICF) collisions
/// that can occur with empty marker structs.
pub fn typeId(comptime T: type) u64 {
    return std.hash.Wyhash.hash(0x9e3779b97f4a7c15, @typeName(T));
}

const ResourceEntry = struct {
    ptr: *anyopaque,
    destroy_fn: *const fn (*anyopaque, std.mem.Allocator) void,
};

fn deinitResourceIfSupported(comptime T: type, typed: *T) void {
    if (@hasDecl(T, "deinit") and @TypeOf(T.deinit) == fn (*T) void) {
        typed.deinit();
    }
}

/// Type-erased registry of singleton resources owned by an `App` or `World`.
pub const ResourceRegistry = struct {
    allocator: std.mem.Allocator,
    entries: std.AutoHashMapUnmanaged(u64, ResourceEntry),

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

    /// Inserts or overwrites a resource of type `T`.
    /// If `T` defines `pub fn deinit(*T) void`, it is invoked on overwrite, `remove()`, and `deinit()`.
    pub fn insert(self: *ResourceRegistry, comptime T: type, value: T) !void {
        const key = typeId(T);
        const Destroy = struct {
            fn call(raw: *anyopaque, alloc: std.mem.Allocator) void {
                const typed: *T = @ptrCast(@alignCast(raw));
                deinitResourceIfSupported(T, typed);
                alloc.destroy(typed);
            }
        };

        if (self.entries.getPtr(key)) |existing| {
            const typed: *T = @ptrCast(@alignCast(existing.ptr));
            deinitResourceIfSupported(T, typed);
            typed.* = value;
            existing.destroy_fn = Destroy.call;
            return;
        }

        const ptr = try self.allocator.create(T);
        errdefer self.allocator.destroy(ptr);
        ptr.* = value;

        try self.entries.put(self.allocator, key, .{
            .ptr = ptr,
            .destroy_fn = Destroy.call,
        });
    }

    /// Returns a mutable pointer to resource `T`, or `null` if not registered.
    pub fn get(self: *ResourceRegistry, comptime T: type) ?*T {
        const entry = self.entries.get(typeId(T)) orelse return null;
        return @ptrCast(@alignCast(entry.ptr));
    }

    /// Returns an immutable pointer to resource `T`, or `null` if not registered.
    pub fn getConst(self: *const ResourceRegistry, comptime T: type) ?*const T {
        const entry = self.entries.get(typeId(T)) orelse return null;
        return @ptrCast(@alignCast(entry.ptr));
    }

    /// Returns `true` if resource `T` is currently registered.
    pub fn contains(self: *const ResourceRegistry, comptime T: type) bool {
        return self.entries.contains(typeId(T));
    }

    /// Removes and destroys resource `T`, returning `false` if it was not present.
    pub fn remove(self: *ResourceRegistry, comptime T: type) bool {
        const kv = self.entries.fetchRemove(typeId(T)) orelse return false;
        kv.value.destroy_fn(kv.value.ptr, self.allocator);
        return true;
    }
};
