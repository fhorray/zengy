"""Type stubs for the embedded `zigeng` Python scripting API (PocketPy v2.2.0)."""

from __future__ import annotations

from typing import Literal

from . import Key as Key
from . import input as input

LogLevel = Literal["debug", "info", "warn", "error"]


def log(msg: str, level: LogLevel = "info") -> None:
    """Write a message to `app.diagnostics`."""
    ...


def spawn_entity() -> int:
    """Spawn a new ECS entity and return its 64-bit handle."""
    ...


def is_alive(entity: int) -> bool:
    """Return True if the given entity handle is still alive in the World."""
    ...


def post_event(name: str, payload: str = "", entity: int = 0) -> None:
    """Emit an EventBus event queued through the host CommandBuffer."""
    ...


def draw_rect(
    x: float,
    y: float,
    w: float,
    h: float,
    r: float = 1.0,
    g: float = 1.0,
    b: float = 1.0,
    a: float = 1.0,
) -> None:
    """Queue an RGBA rectangle draw command for the current frame."""
    ...


def clear_draw_queue() -> None:
    """Clear any rectangles queued for the current frame."""
    ...
