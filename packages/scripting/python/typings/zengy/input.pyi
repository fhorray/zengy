"""Input helpers bound on `zengy.input`."""

from __future__ import annotations


def is_key_down(scancode: int) -> bool:
    """Return True while the given SDL scancode (see `zengy.Key`) is held."""
    ...


def mouse_x() -> float:
    """Return the current logical mouse X position."""
    ...


def mouse_y() -> float:
    """Return the current logical mouse Y position."""
    ...


def is_mouse_down() -> bool:
    """Return True while the primary mouse button is held."""
    ...


def was_mouse_clicked() -> bool:
    """Return True on the frame the primary mouse button was clicked."""
    ...
