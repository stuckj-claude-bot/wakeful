"""Asking PowerDevil to re-read powerdevilrc.

PowerDevil does not watch its configuration file. refreshStatus reparses it
and reloads every action, which is what System Settings calls after saving;
reparseConfiguration alone would not reload the lid action.
"""

from PyQt6.QtDBus import QDBus, QDBusConnection, QDBusMessage

SERVICE = "org.kde.Solid.PowerManagement"
PATH = "/org/kde/Solid/PowerManagement"
INTERFACE = "org.kde.Solid.PowerManagement"


def refresh_status(bus: QDBusConnection | None = None) -> None:
    bus = bus if bus is not None else QDBusConnection.sessionBus()
    msg = QDBusMessage.createMethodCall(SERVICE, PATH, INTERFACE, "refreshStatus")
    reply = bus.call(msg, QDBus.CallMode.Block, 10000)
    if reply.type() != QDBusMessage.MessageType.ReplyMessage:
        raise RuntimeError(f"refreshStatus: {reply.errorName()}: {reply.errorMessage()}")
