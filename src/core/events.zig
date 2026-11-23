//! Bounded Event Bus (`core/events`).
//!
//! Provides a host-managed, world-isolated event queue using a language-neutral
//! `EventEnvelope` (event name, byte payload, world ID, entity handle).
//!
//! Key guarantees:
//! - Bounded queue capacity with explicit overflow policy (`drop_newest` or `drop_oldest`).
//! - `dropped_events` metric tracks backpressure/overflow occurrences.
//! - Reentrancy-safe `drain()`: tracks `dispatch_depth`, tombstones removed subscriptions
//!   during active dispatch, and sweeps them cleanly once `dispatch_depth` returns to 0.
//! - Subscriptions carry an `owner_id` so module/plugin unload cancels all owned
//!   subscriptions via `unsubscribeByOwner()`, preventing dangling callbacks.

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

const Subscription = struct {
    id: SubscriptionId,
    owner_id: u64,
    event_name: []const u8,
    callback: EventCallback,
    user_data: ?*anyopaque,
    pending_remove: bool = false,
};

const QueuedEvent = struct {
    name: []const u8,
    payload: []const u8,
    world_id: u64,
    entity_handle: u64,
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
            self.allocator.free(self.queue[idx].name);
            self.allocator.free(self.queue[idx].payload);
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
                    const oldest = self.queue[self.queue_head];
                    self.allocator.free(oldest.name);
                    self.allocator.free(oldest.payload);
                    self.queue_head = (self.queue_head + 1) % self.queue.len;
                    self.queue_len -= 1;
                },
            }
        }

        const name_copy = try self.allocator.dupe(u8, envelope.name);
        errdefer self.allocator.free(name_copy);
        const payload_copy = try self.allocator.dupe(u8, envelope.payload);
        errdefer self.allocator.free(payload_copy);

        const tail = (self.queue_head + self.queue_len) % self.queue.len;
        self.queue[tail] = .{
            .name = name_copy,
            .payload = payload_copy,
            .world_id = envelope.world_id,
            .entity_handle = envelope.entity_handle,
        };
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
            defer {
                self.allocator.free(ev.name);
                self.allocator.free(ev.payload);
            }

            const env = EventEnvelope{
                .name = ev.name,
                .payload = ev.payload,
                .world_id = ev.world_id,
                .entity_handle = ev.entity_handle,
            };
            const sub_len = self.subscriptions.items.len;
            for (0..sub_len) |idx| {
                const sub = self.subscriptions.items[idx];
                if (sub.pending_remove) continue;
                if (std.mem.eql(u8, sub.event_name, ev.name) or std.mem.eql(u8, sub.event_name, "*")) {
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
