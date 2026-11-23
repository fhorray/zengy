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
    queue: std.ArrayList(QueuedEvent),
    subscriptions: std.ArrayList(Subscription),
    next_sub_id: SubscriptionId,
    dropped_events: u64,
    total_posted: u64,
    total_drained: u64,

    pub fn init(allocator: std.mem.Allocator, max_queue_len: usize, overflow_policy: OverflowPolicy) EventBus {
        return .{
            .allocator = allocator,
            .max_queue_len = if (max_queue_len == 0) 1 else max_queue_len,
            .overflow_policy = overflow_policy,
            .queue = .empty,
            .subscriptions = .empty,
            .next_sub_id = 1,
            .dropped_events = 0,
            .total_posted = 0,
            .total_drained = 0,
        };
    }

    pub fn deinit(self: *EventBus) void {
        for (self.queue.items) |ev| {
            self.allocator.free(ev.name);
            self.allocator.free(ev.payload);
        }
        self.queue.deinit(self.allocator);

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
        });
        return id;
    }

    pub fn unsubscribe(self: *EventBus, sub_id: SubscriptionId) bool {
        for (self.subscriptions.items, 0..) |sub, idx| {
            if (sub.id == sub_id) {
                self.allocator.free(sub.event_name);
                _ = self.subscriptions.orderedRemove(idx);
                return true;
            }
        }
        return false;
    }

    pub fn unsubscribeByOwner(self: *EventBus, owner_id: u64) usize {
        var removed: usize = 0;
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

    pub fn post(self: *EventBus, envelope: EventEnvelope) !void {
        self.total_posted += 1;

        if (self.queue.items.len >= self.max_queue_len) {
            self.dropped_events += 1;
            switch (self.overflow_policy) {
                .drop_newest => return,
                .drop_oldest => {
                    const oldest = self.queue.orderedRemove(0);
                    self.allocator.free(oldest.name);
                    self.allocator.free(oldest.payload);
                },
            }
        }

        const name_copy = try self.allocator.dupe(u8, envelope.name);
        errdefer self.allocator.free(name_copy);
        const payload_copy = try self.allocator.dupe(u8, envelope.payload);
        errdefer self.allocator.free(payload_copy);

        try self.queue.append(self.allocator, .{
            .name = name_copy,
            .payload = payload_copy,
            .world_id = envelope.world_id,
            .entity_handle = envelope.entity_handle,
        });
    }

    pub fn drain(self: *EventBus) usize {
        const count = self.queue.items.len;
        if (count == 0) return 0;

        // Snapshot current queue so callbacks posting new events do not invalidate iteration.
        var batch = self.queue;
        self.queue = .empty;
        defer {
            for (batch.items) |ev| {
                self.allocator.free(ev.name);
                self.allocator.free(ev.payload);
            }
            batch.deinit(self.allocator);
        }

        for (batch.items) |ev| {
            const env = EventEnvelope{
                .name = ev.name,
                .payload = ev.payload,
                .world_id = ev.world_id,
                .entity_handle = ev.entity_handle,
            };
            for (self.subscriptions.items) |sub| {
                if (std.mem.eql(u8, sub.event_name, ev.name) or std.mem.eql(u8, sub.event_name, "*")) {
                    sub.callback(sub.user_data, env);
                }
            }
            self.total_drained += 1;
        }
        return count;
    }

    pub fn pendingCount(self: *const EventBus) usize {
        return self.queue.items.len;
    }

    pub fn subscriptionCount(self: *const EventBus) usize {
        return self.subscriptions.items.len;
    }
};
