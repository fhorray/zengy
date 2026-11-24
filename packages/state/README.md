# `state` (`official.state`)

Typed finite state machine and `inState` run-condition helpers for `zengy`'s `Scheduler`.

## Usage

```zig
const state = @import("state");

const GameState = enum { menu, playing, paused };

try app.registerModule(state.module());
try state.registerState(&app, GameState, .menu);

try app.addSystem(.{
    .name = "gameplay.update",
    .run = updateGameplay,
    .run_if = state.inState(GameState, .playing),
});
```

Transitions queued via `StateMachine(GameState).set(.playing)` are flushed deterministically in `.pre_update` and emit `state.exited` / `state.entered` events on `EventBus`.
