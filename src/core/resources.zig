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
    /// `@typeName` of the stored type, used to detect hash collisions between distinct types.
    name: []const u8,
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
    /// Type keys in insertion order; resources are destroyed in reverse so later resources
    /// (which may reference earlier ones) go first, deterministically.
    order: std.ArrayList(u64) = .empty,

    pub fn init(allocator: std.mem.Allocator) ResourceRegistry {
        return .{
            .allocator = allocator,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *ResourceRegistry) void {
        var i = self.order.items.len;
        while (i > 0) {
            i -= 1;
            if (self.entries.get(self.order.items[i])) |entry| entry.destroy_fn(entry.ptr, self.allocator);
        }
        self.order.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }

    /// Inserts or overwrites a resource of type `T`.
    /// If `T` defines `pub fn deinit(*T) void`, it is invoked on overwrite, `remove()`, and `deinit()`.
    ///
    /// Ownership: on success the registry owns `value`. On error (`OutOfMemory` or
    /// `error.ResourceTypeCollision`) `value` was NOT consumed and stays with the caller, so the
    /// caller must still release it. Overwriting runs the old value's `deinit` first.
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
            if (!std.mem.eql(u8, existing.name, @typeName(T))) return error.ResourceTypeCollision;
            const typed: *T = @ptrCast(@alignCast(existing.ptr));
            deinitResourceIfSupported(T, typed);
            typed.* = value;
            existing.destroy_fn = Destroy.call;
            return;
        }

        const ptr = try self.allocator.create(T);
        errdefer self.allocator.destroy(ptr);
        ptr.* = value;

        // Reserve both containers first so a failure leaves them consistent with each other.
        try self.order.ensureUnusedCapacity(self.allocator, 1);
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        self.entries.putAssumeCapacity(key, .{
            .ptr = ptr,
            .destroy_fn = Destroy.call,
            .name = @typeName(T),
        });
        self.order.appendAssumeCapacity(key);
    }

    /// Returns a mutable pointer to resource `T`, or `null` if not registered.
    pub fn get(self: *ResourceRegistry, comptime T: type) ?*T {
        const entry = self.entries.get(typeId(T)) orelse return null;
        if (!std.mem.eql(u8, entry.name, @typeName(T))) return null;
        return @ptrCast(@alignCast(entry.ptr));
    }

    /// Returns an immutable pointer to resource `T`, or `null` if not registered.
    pub fn getConst(self: *const ResourceRegistry, comptime T: type) ?*const T {
        const entry = self.entries.get(typeId(T)) orelse return null;
        if (!std.mem.eql(u8, entry.name, @typeName(T))) return null;
        return @ptrCast(@alignCast(entry.ptr));
    }

    /// Returns `true` if resource `T` is currently registered.
    pub fn contains(self: *const ResourceRegistry, comptime T: type) bool {
        return self.entries.contains(typeId(T));
    }

    /// Removes and destroys resource `T`, returning `false` if it was not present.
    pub fn remove(self: *ResourceRegistry, comptime T: type) bool {
        const kv = self.entries.fetchRemove(typeId(T)) orelse return false;
        if (std.mem.indexOfScalar(u64, self.order.items, kv.key)) |pos| _ = self.order.orderedRemove(pos);
        kv.value.destroy_fn(kv.value.ptr, self.allocator);
        return true;
    }
};
