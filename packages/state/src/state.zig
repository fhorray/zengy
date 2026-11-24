//! Game State Machine & Run-Condition Helpers (`official.state`).
//!
//! Provides Bevy-inspired typed `StateMachine(StateEnum)`, `inState(...)`
//! run conditions for `Scheduler`, and deterministic `.pre_update` transitions
//! with `state.exited` / `state.entered` `EventBus` notifications.

const std = @import("std");
const engine = @import("engine");

/// Typed finite state machine resource for game/app flow (`Menu`, `Playing`, `Paused`, ...).
pub fn StateMachine(comptime StateEnum: type) type {
    return struct {
        const Self = @This();

        current: StateEnum,
        previous: ?StateEnum = null,
        pending: ?StateEnum = null,
        changed_this_frame: bool = false,

        /// Initializes the state machine at `initial`.
        pub fn init(initial: StateEnum) Self {
            return .{ .current = initial };
        }

        /// Queues a transition to `next`, applied at the next `.pre_update` barrier.
        pub fn set(self: *Self, next: StateEnum) void {
            self.pending = next;
        }

        /// Returns `true` when `current == state`.
        pub fn is(self: *const Self, state: StateEnum) bool {
            return self.current == state;
        }

        /// Returns `true` during the frame in which `state` became active.
        pub fn justEntered(self: *const Self, state: StateEnum) bool {
            return self.changed_this_frame and self.current == state;
        }

        /// Returns `true` during the frame in which `state` was exited.
        pub fn justExited(self: *const Self, state: StateEnum) bool {
            return self.changed_this_frame and self.previous != null and self.previous.? == state;
        }

        /// Flushes any pending transition. Returns `true` if the active state changed.
        pub fn applyTransition(self: *Self) bool {
            self.changed_this_frame = false;
            const next = self.pending orelse return false;
            self.pending = null;
            if (next == self.current) return false;
            self.previous = self.current;
            self.current = next;
            self.changed_this_frame = true;
            return true;
        }
    };
}

/// Returns a `RunConditionFn` that evaluates to `true` only when `StateMachine(StateEnum).is(expected)`.
pub fn inState(comptime StateEnum: type, comptime expected: StateEnum) engine.RunConditionFn {
    return struct {
        fn check(ctx: *const engine.SystemContext) bool {
            const sm = ctx.resources.getConst(StateMachine(StateEnum)) orelse return false;
            return sm.is(expected);
        }
    }.check;
}

/// Registers `StateMachine(StateEnum)` as a resource and schedules its `.pre_update` transition system.
pub fn registerState(app: *engine.App, comptime StateEnum: type, initial: StateEnum) !void {
    if (!app.resources.contains(StateMachine(StateEnum))) {
        try app.resources.insert(StateMachine(StateEnum), StateMachine(StateEnum).init(initial));
    }
    const sys = struct {
        fn run(ctx: *engine.SystemContext) !void {
            const sm = ctx.resources.get(StateMachine(StateEnum)) orelse return;
            if (sm.applyTransition()) {
                if (sm.previous) |prev| {
                    try ctx.events.post(.{
                        .name = "state.exited",
                        .payload = @tagName(prev),
                    });
                }
                try ctx.events.post(.{
                    .name = "state.entered",
                    .payload = @tagName(sm.current),
                });
            }
        }
    }.run;
    try app.addSystem(.{
        .name = "state.flush." ++ @typeName(StateEnum),
        .stage = .pre_update,
        .run = sys,
    });
}

fn buildStateModule(_: *anyopaque) !void {}
fn startStateModule(_: *anyopaque) !void {}
fn stopStateModule(_: *anyopaque) void {}

/// Returns the `official.state` module providing `engine.state/1`.
pub fn module() engine.Module {
    return .{
        .descriptor = .{
            .id = "official.state",
            .version = "0.1.0",
            .provides_capabilities = &.{"engine.state/1"},
        },
        .build = buildStateModule,
        .start = startStateModule,
        .stop = stopStateModule,
    };
}
