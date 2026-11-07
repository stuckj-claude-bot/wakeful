"""Holds the inhibitions over the session bus.

Every inhibition is taken on this process's own D-Bus connection. PowerDevil
and kscreenlocker both watch the caller's unique name and drop its inhibitions
when that connection closes, so exiting or crashing releases them with no
cleanup code involved, and nothing outlives the process.

  Mode.SLEEP   org.freedesktop.PowerManagement.Inhibit — PowerDevil's
               InterruptSession policy: idle suspend only.
  Mode.SCREEN  the above plus org.freedesktop.ScreenSaver.Inhibit — also
               blocks dimming, screen-off and idle screen locking.

The battery applet shows the application name as the desktop entry it names
(wakeful.desktop) and the reason beside it.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass

from PyQt6.QtCore import QMetaType, QObject, QTimer
from PyQt6.QtDBus import (
    QDBus,
    QDBusArgument,
    QDBusConnection,
    QDBusMessage,
    QDBusServiceWatcher,
)

from .block import Mode

log = logging.getLogger(__name__)

APP_NAME = "wakeful"
CALL_TIMEOUT_MS = 5000

# PowerDevil only enforces an inhibition 5 s after it is requested. Replacing
# one (to change its reason text) therefore releases the old cookie after this
# delay, so there is never a moment with neither in force.
RETIRE_DELAY_MS = 6000


@dataclass(frozen=True)
class Target:
    service: str
    path: str
    interface: str


POWER = Target(
    "org.freedesktop.PowerManagement.Inhibit",
    "/org/freedesktop/PowerManagement/Inhibit",
    "org.freedesktop.PowerManagement.Inhibit",
)
SCREENSAVER = Target(
    "org.freedesktop.ScreenSaver",
    "/org/freedesktop/ScreenSaver",
    "org.freedesktop.ScreenSaver",
)

TARGETS: dict[Mode, tuple[Target, ...]] = {
    Mode.SLEEP: (POWER,),
    Mode.SCREEN: (POWER, SCREENSAVER),
}


class InhibitError(Exception):
    pass


@dataclass(frozen=True)
class Cookie:
    target: Target
    value: int
    signature: str
    """'i' for PowerDevil's Inhibit, 'u' for the ScreenSaver one. UnInhibit is
    only matched when the cookie goes back with the type it came as."""


class DBusInhibitor(QObject):
    def __init__(
        self,
        bus: QDBusConnection | None = None,
        app_name: str = APP_NAME,
        retire_delay_ms: int = RETIRE_DELAY_MS,
    ) -> None:
        super().__init__()
        self._bus = bus if bus is not None else QDBusConnection.sessionBus()
        self._app_name = app_name
        self._retire_delay_ms = retire_delay_ms
        self._held: list[Cookie] = []
        self._key: tuple[Mode, str] | None = None
        self._retiring: list[Cookie] = []
        # Connection and mode go to the constructor: with PyQt6 6.11 / Qt 6.10, calling
        # setConnection() on a default-constructed watcher deadlocks the next
        # addWatchedService().
        self._watcher = QDBusServiceWatcher(
            POWER.service,
            self._bus,
            QDBusServiceWatcher.WatchModeFlag.WatchForOwnerChange,
            self,
        )
        self._watcher.addWatchedService(SCREENSAVER.service)
        self._watcher.serviceOwnerChanged.connect(self._owner_changed)

    @property
    def held(self) -> list[Cookie]:
        return list(self._held)

    def hold(self, mode: Mode, reason: str) -> None:
        if self._key == (mode, reason):
            self._take_missing()
            return
        new: list[Cookie] = []
        try:
            for target in TARGETS[mode]:
                new.append(self._inhibit(target, reason))
        except InhibitError:
            for cookie in new:
                self._uninhibit(cookie)
            raise
        old, self._held, self._key = self._held, new, (mode, reason)
        self._retire(old)

    def release(self) -> None:
        for cookie in self._held + self._retiring:
            self._uninhibit(cookie)
        self._held, self._retiring, self._key = [], [], None

    # -- internals ---------------------------------------------------------

    def _inhibit(self, target: Target, reason: str) -> Cookie:
        msg = QDBusMessage.createMethodCall(
            target.service, target.path, target.interface, "Inhibit"
        )
        msg.setArguments([self._app_name, reason])
        reply = self._bus.call(msg, QDBus.CallMode.Block, CALL_TIMEOUT_MS)
        if reply.type() != QDBusMessage.MessageType.ReplyMessage or not reply.arguments():
            raise InhibitError(f"{target.service}: {reply.errorName()}: {reply.errorMessage()}")
        cookie = Cookie(target, int(reply.arguments()[0]), reply.signature())
        log.debug("inhibited %s: cookie %s (%r)", target.service, cookie.value, reason)
        return cookie

    def _uninhibit(self, cookie: Cookie) -> None:
        msg = QDBusMessage.createMethodCall(
            cookie.target.service, cookie.target.path, cookie.target.interface, "UnInhibit"
        )
        mtype = QMetaType.Type.UInt if cookie.signature == "u" else QMetaType.Type.Int
        msg.setArguments([QDBusArgument(cookie.value, mtype.value)])
        reply = self._bus.call(msg, QDBus.CallMode.Block, CALL_TIMEOUT_MS)
        if reply.type() != QDBusMessage.MessageType.ReplyMessage:
            # Nothing further can be done from here. If the service is gone the
            # inhibition went with it; if not, it goes when this process exits.
            log.warning(
                "UnInhibit %s cookie %s failed: %s",
                cookie.target.service,
                cookie.value,
                reply.errorMessage(),
            )

    def _retire(self, cookies: list[Cookie]) -> None:
        if not cookies:
            return
        self._retiring.extend(cookies)

        def finish() -> None:
            for cookie in cookies:
                if cookie in self._retiring:
                    self._retiring.remove(cookie)
                    self._uninhibit(cookie)

        QTimer.singleShot(self._retire_delay_ms, finish)

    def _owner_changed(self, service: str, old_owner: str, new_owner: str) -> None:
        # A cookie belongs to the process that issued it. Once the owner
        # changes, sending one to the new owner could release an inhibition
        # some other application holds, so they are forgotten, not released.
        # A service that goes away and comes back arrives as two changes, so
        # re-taking is decided by what the current mode needs, not by what was
        # just dropped.
        self._retiring = [c for c in self._retiring if c.target.service != service]
        if any(c.target.service == service for c in self._held):
            log.warning("%s changed owner; its inhibition went with the old owner", service)
            self._held = [c for c in self._held if c.target.service != service]
        if new_owner:
            try:
                self._take_missing()
            except InhibitError as e:
                # A service can own its name a moment before it answers; the
                # controller's next tick calls hold() and tries again.
                log.warning("could not re-take the inhibition yet: %s", e)

    def _take_missing(self) -> None:
        """Take any inhibition the current mode needs and does not hold."""
        if self._key is None:
            return
        mode, reason = self._key
        for target in TARGETS[mode]:
            if not any(c.target == target for c in self._held):
                self._held.append(self._inhibit(target, reason))
                log.info("re-took the inhibition from %s", target.service)
