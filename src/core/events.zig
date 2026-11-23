//! Bounded Event Bus (`core/events`).
//!
//! Provides a host-managed, world-isolated event queue using a language-neutral
//! `EventEnvelope` (event name, byte payload, world ID, entity handle).
//!
//! Key guarantees & performance:
//! - O(1) pre-allocated circular ring buffer with explicit overflow policy (`drop_newest` / `drop_oldest`).
//! - Small-buffer optimization (inline 64B name + 128B payload) avoids heap allocations on the hot path.
//! - Pre-hashed `u64` event names accelerate subscriber filtering before string comparison.
//! - Reentrancy-safe `drain()` with `dispatch_depth` and tombstoned subscriptions.
//! - Subscriptions carry an `owner_id` so module/plugin unload cancels all owned subscriptions.

const std = @import("std");

pub const OverflowPolicy = enum {
    drop_newest,
    drop_oldest,
};

pub const EventEnvelope = struct {
    name: []const u8,
    payload: []const u8,
    world_id: u64 = 0,
    entity_handle: u64 = 0,
};

pub const EventCallback = *const fn (user_data: ?*anyopaque, event: EventEnvelope) void;

pub const SubscriptionId = u64;

const INLINE_NAME_CAP = 64;
const INLINE_PAYLOAD_CAP = 128;

const Subscription = struct {
    id: SubscriptionId,
    owner_id: u64,
    event_name: []const u8,
    name_hash: u64,
    is_wildcard: bool,
    callback: EventCallback,
    user_data: ?*anyopaque,
    pending_remove: bool = false,
};

const QueuedEvent = struct {
    name_hash: u64,
    name_len: usize,
    name_inline: [INLINE_NAME_CAP]u8,
    name_heap: ?[]const u8,
    payload_len: usize,
    payload_inline: [INLINE_PAYLOAD_CAP]u8,
    payload_heap: ?[]const u8,
    world_id: u64,
    entity_handle: u64,

    fn nameSlice(self: *const QueuedEvent) []const u8 {
        if (self.name_heap) |h| return h;
        return self.name_inline[0..self.name_len];
    }

    fn payloadSlice(self: *const QueuedEvent) []const u8 {
        if (self.payload_heap) |h| return h;
        return self.payload_inline[0..self.payload_len];
    }

    fn freeHeap(self: *const QueuedEvent, allocator: std.mem.Allocator) void {
        if (self.name_heap) |h| allocator.free(h);
        if (self.payload_heap) |h| allocator.free(h);
    }
};

pub const EventBus = struct {
    allocator: std.mem.Allocator,
    max_queue_len: usize,
    overflow_policy: OverflowPolicy,
    queue: []QueuedEvent,
    queue_head: usize,
    queue_len: usize,
    subscriptions: std.ArrayList(Subscription),
    next_sub_id: SubscriptionId,
    dispatch_depth: u32,
    dropped_events: u64,
    total_posted: u64,
    total_drained: u64,

    pub fn init(allocator: std.mem.Allocator, max_queue_len: usize, overflow_policy: OverflowPolicy) EventBus {
        const cap = if (max_queue_len == 0) 1 else max_queue_len;
        const ring: []QueuedEvent = allocator.alloc(QueuedEvent, cap) catch &[_]QueuedEvent{};
        return .{
            .allocator = allocator,
            .max_queue_len = if (ring.len == 0) 0 else cap,
            .overflow_policy = overflow_policy,
            .queue = ring,
            .queue_head = 0,
            .queue_len = 0,
            .subscriptions = .empty,
            .next_sub_id = 1,
            .dispatch_depth = 0,
            .dropped_events = 0,
            .total_posted = 0,
            .total_drained = 0,
        };
    }

    pub fn deinit(self: *EventBus) void {
        for (0..self.queue_len) |i| {
            const idx = (self.queue_head + i) % self.queue.len;
            self.queue[idx].freeHeap(self.allocator);
        }
        if (self.queue.len > 0) {
            self.allocator.free(self.queue);
        }

        for (self.subscriptions.items) |sub| {
            self.allocator.free(sub.event_name);
        }
        self.subscriptions.deinit(self.allocator);
    }

    pub fn subscribe(
        self: *EventBus,
        owner_id: u64,
        event_name: []const u8,
        callback: EventCallback,
        user_data: ?*anyopaque,
    ) !SubscriptionId {
        const name_copy = try self.allocator.dupe(u8, event_name);
        errdefer self.allocator.free(name_copy);

        const id = self.next_sub_id;
        self.next_sub_id += 1;

        try self.subscriptions.append(self.allocator, .{
            .id = id,
            .owner_id = owner_id,
            .event_name = name_copy,
            .name_hash = std.hash.Wyhash.hash(0, event_name),
            .is_wildcard = std.mem.eql(u8, event_name, "*"),
            .callback = callback,
            .user_data = user_data,
            .pending_remove = false,
        });
        return id;
    }

    pub fn unsubscribe(self: *EventBus, sub_id: SubscriptionId) bool {
        for (self.subscriptions.items, 0..) |*sub, idx| {
            if (sub.id == sub_id and !sub.pending_remove) {
                if (self.dispatch_depth > 0) {
                    sub.pending_remove = true;
                } else {
                    self.allocator.free(sub.event_name);
                    _ = self.subscriptions.orderedRemove(idx);
                }
                return true;
            }
        }
        return false;
    }

    pub fn unsubscribeByOwner(self: *EventBus, owner_id: u64) usize {
        var removed: usize = 0;
        if (self.dispatch_depth > 0) {
            for (self.subscriptions.items) |*sub| {
                if (sub.owner_id == owner_id and !sub.pending_remove) {
                    sub.pending_remove = true;
                    removed += 1;
                }
            }
            return removed;
        }

        var i: usize = 0;
        while (i < self.subscriptions.items.len) {
            if (self.subscriptions.items[i].owner_id == owner_id) {
                self.allocator.free(self.subscriptions.items[i].event_name);
                _ = self.subscriptions.orderedRemove(i);
                removed += 1;
            } else {
                i += 1;
            }
        }
        return removed;
    }

    fn sweepTombstones(self: *EventBus) void {
        var i: usize = 0;
        while (i < self.subscriptions.items.len) {
            if (self.subscriptions.items[i].pending_remove) {
                self.allocator.free(self.subscriptions.items[i].event_name);
                _ = self.subscriptions.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn post(self: *EventBus, envelope: EventEnvelope) !void {
        self.total_posted += 1;
        if (self.queue.len == 0) {
            self.dropped_events += 1;
            return;
        }

        if (self.queue_len >= self.queue.len) {
            self.dropped_events += 1;
            switch (self.overflow_policy) {
                .drop_newest => return,
                .drop_oldest => {
                    self.queue[self.queue_head].freeHeap(self.allocator);
                    self.queue_head = (self.queue_head + 1) % self.queue.len;
                    self.queue_len -= 1;
                },
            }
        }

        var ev: QueuedEvent = .{
            .name_hash = std.hash.Wyhash.hash(0, envelope.name),
            .name_len = envelope.name.len,
            .name_inline = undefined,
            .name_heap = null,
            .payload_len = envelope.payload.len,
            .payload_inline = undefined,
            .payload_heap = null,
            .world_id = envelope.world_id,
            .entity_handle = envelope.entity_handle,
        };

        if (envelope.name.len <= INLINE_NAME_CAP) {
            @memcpy(ev.name_inline[0..envelope.name.len], envelope.name);
        } else {
            ev.name_heap = try self.allocator.dupe(u8, envelope.name);
        }
        errdefer if (ev.name_heap) |h| self.allocator.free(h);

        if (envelope.payload.len <= INLINE_PAYLOAD_CAP) {
            @memcpy(ev.payload_inline[0..envelope.payload.len], envelope.payload);
        } else {
            ev.payload_heap = try self.allocator.dupe(u8, envelope.payload);
        }

        const tail = (self.queue_head + self.queue_len) % self.queue.len;
        self.queue[tail] = ev;
        self.queue_len += 1;
    }

    pub fn drain(self: *EventBus) usize {
        const count = self.queue_len;
        if (count == 0) return 0;

        self.dispatch_depth += 1;
        defer {
            self.dispatch_depth -= 1;
            if (self.dispatch_depth == 0) {
                self.sweepTombstones();
            }
        }

        for (0..count) |_| {
            const ev = self.queue[self.queue_head];
            self.queue_head = (self.queue_head + 1) % self.queue.len;
            self.queue_len -= 1;
            defer ev.freeHeap(self.allocator);

            const ev_name = ev.nameSlice();
            const env = EventEnvelope{
                .name = ev_name,
                .payload = ev.payloadSlice(),
                .world_id = ev.world_id,
                .entity_handle = ev.entity_handle,
            };
            const sub_len = self.subscriptions.items.len;
            for (0..sub_len) |idx| {
                const sub = self.subscriptions.items[idx];
                if (sub.pending_remove) continue;
                if (sub.is_wildcard or (sub.name_hash == ev.name_hash and std.mem.eql(u8, sub.event_name, ev_name))) {
                    sub.callback(sub.user_data, env);
                }
            }
            self.total_drained += 1;
        }
        return count;
    }

    pub fn pendingCount(self: *const EventBus) usize {
        return self.queue_len;
    }

    pub fn subscriptionCount(self: *const EventBus) usize {
        var active: usize = 0;
        for (self.subscriptions.items) |sub| {
            if (!sub.pending_remove) active += 1;
        }
        return active;
    }
};
