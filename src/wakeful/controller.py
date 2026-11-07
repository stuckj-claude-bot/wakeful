"""Ties the session to the things that act on it: the inhibitor and the lid guard.

Qt-free. The tray and the D-Bus control interface call in; a periodic tick()
reaps an expired block and keeps the inhibition's reason text current.
"""

from __future__ import annotations

import logging
from collections.abc import Callable
from dataclasses import dataclass
from typing import Protocol

from . import clock
from .block import Block, Mode, Session, describe_remaining

log = logging.getLogger(__name__)


class Inhibitor(Protocol):
    def hold(self, mode: Mode, reason: str) -> None:
        """Hold an inhibition for mode with this reason, replacing any held one.

        If this raises, whatever was held before is still held.
        """

    def release(self) -> None:
        """Release everything held. Safe to call when nothing is."""


class LidGuard(Protocol):
    def engage(self) -> None: ...
    def restore(self) -> None: ...


@dataclass(frozen=True)
class Status:
    active: bool
    mode: Mode | None
    remaining: float | None
    """Seconds left; None when inactive or when the block has no end."""
    text: str
    """'Keeping awake: 47 min left', or 'Not keeping awake'."""
    lid_ignored: bool
    """The lid action is set to "Do nothing" right now."""
    ignore_lid: bool
    """The option is on: the lid will be ignored whenever a block runs."""


def reason_text(remaining: float | None) -> str:
    return f"Keeping awake: {describe_remaining(remaining)}"


class Controller:
    def __init__(
        self,
        inhibitor: Inhibitor,
        lid: LidGuard | None = None,
        now: Callable[[], float] = clock.now,
    ) -> None:
        self._inhibitor = inhibitor
        self._lid = lid
        self._now = now
        self._session = Session()
        self._ignore_lid = False
        self._lid_engaged = False
        self.on_changed: Callable[[Status], None] = lambda status: None
        self.on_ended: Callable[[Block, str], None] = lambda block, why: None
        """Called with the block and 'expired' or 'stopped'."""

    # -- queries -----------------------------------------------------------

    def status(self) -> Status:
        block = self._session.block
        if block is None:
            return Status(False, None, None, "Not keeping awake", False, self._ignore_lid)
        remaining = block.remaining(self._now())
        return Status(
            True,
            block.mode,
            remaining,
            reason_text(remaining),
            self._lid_engaged,
            self._ignore_lid,
        )

    @property
    def ignore_lid(self) -> bool:
        return self._ignore_lid

    @ignore_lid.setter
    def ignore_lid(self, value: bool) -> None:
        if self._lid is None and value:
            raise RuntimeError("lid handling is not available")
        self._ignore_lid = value
        self._sync_lid()
        self._changed()

    # -- operations --------------------------------------------------------

    def start(self, duration: float | None, mode: Mode) -> None:
        """Start (or restart) a block. Raises if the inhibition cannot be taken.

        On failure a block that was already running carries on unchanged.
        """
        previous = self._session.block
        self._session.start(duration, mode, self._now())
        try:
            self._apply()
        except Exception:
            self._session.block = previous
            if previous is None:
                self._inhibitor.release()
            self._sync_lid()
            self._changed()
            raise
        self._sync_lid()
        self._changed()

    def extend(self, duration: float) -> None:
        self._session.extend(duration, self._now())
        self._apply()
        self._changed()

    def set_mode(self, mode: Mode) -> None:
        block = self._session.block
        if block is None or block.mode is mode:
            return
        self._session.set_mode(mode)
        try:
            self._apply()
        except Exception:
            self._session.set_mode(block.mode)
            raise
        self._changed()

    def stop(self) -> None:
        self._end("stopped")

    def tick(self) -> None:
        """Reap an expired block, or refresh the reason text of a running one."""
        if self._session.block is None:
            return
        if self._session.block.expired(self._now()):
            self._end("expired")
            return
        # Retried on every tick: hold() also re-takes an inhibition that was
        # lost, for example to a PowerDevil restart.
        try:
            self._apply()
        except Exception as e:
            log.warning("could not refresh the inhibition: %s", e)
        self._changed()

    def shutdown(self) -> None:
        """Release everything before exit. The block is not reported as ended."""
        self._session.cancel()
        self._inhibitor.release()
        self._sync_lid()

    # -- internals ---------------------------------------------------------

    def _apply(self) -> None:
        block = self._session.block
        assert block is not None
        self._inhibitor.hold(block.mode, reason_text(block.remaining(self._now())))

    def _end(self, why: str) -> None:
        ended = self._session.cancel()
        self._inhibitor.release()
        self._sync_lid()
        if ended is not None:
            self.on_ended(ended, why)
        self._changed()

    def _sync_lid(self) -> None:
        if self._lid is None:
            return
        want = self._ignore_lid and self._session.active
        if want == self._lid_engaged:
            return
        try:
            if want:
                self._lid.engage()
            else:
                self._lid.restore()
            self._lid_engaged = want
        except Exception:
            log.exception("could not %s the lid action", "change" if want else "restore")

    def _changed(self) -> None:
        self.on_changed(self.status())
