"""Stand-ins for PowerDevil and kscreenlocker on a private session bus.

Serves the calls wakeful makes, with the signatures the real services use
(PowerManagement cookies are int32, ScreenSaver cookies uint32, and UnInhibit
with the wrong type fails as an unknown method), and drops a caller's
inhibitions when its connection closes, as both real services do.

  python3 stub_services.py [--no-screensaver]

Prints "ready" once every name is owned. State is read back with
test.wakeful.Stub.Dump, which returns JSON.
"""

from __future__ import annotations

import json
import sys

from jeepney import (
    HeaderFields,
    MatchRule,
    MessageType,
    message_bus,
    new_error,
    new_method_return,
)
from jeepney.io.blocking import open_dbus_connection

PM = (
    "org.freedesktop.PowerManagement.Inhibit",
    "/org/freedesktop/PowerManagement/Inhibit",
    "org.freedesktop.PowerManagement.Inhibit",
)
SS = ("org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver", "org.freedesktop.ScreenSaver")
SOLID = (
    "org.kde.Solid.PowerManagement",
    "/org/kde/Solid/PowerManagement",
    "org.kde.Solid.PowerManagement",
)
STUB = ("test.wakeful.Stub", "/test/wakeful/Stub", "test.wakeful.Stub")
UNKNOWN = "org.freedesktop.DBus.Error.UnknownMethod"


def main(argv: list[str]) -> int:
    services = {"pm": PM, "solid": SOLID, "stub": STUB}
    if "--no-screensaver" not in argv:
        services["ss"] = SS
    # --fail-inhibits=N refuses the first N Inhibit calls: a service that owns
    # its name but is not answering yet.
    fail_inhibits = next(
        (int(a.split("=", 1)[1]) for a in argv if a.startswith("--fail-inhibits=")), 0
    )

    # Callers can reach a name the moment it is owned, so everything, the
    # RequestName replies included, is read by the one loop below; a blocking
    # send_and_get_reply here would discard a call that arrived meanwhile.
    conn = open_dbus_connection(bus="SESSION")
    rule = MatchRule(type="signal", interface="org.freedesktop.DBus", member="NameOwnerChanged")
    conn.send_and_get_reply(message_bus.AddMatch(rule))
    pending: dict[int, str] = {}
    for serial, (name, _, _) in enumerate(services.values(), start=1000):
        conn.send(message_bus.RequestName(name, 0x4), serial=serial)
        pending[serial] = name

    by_path = {path: (kind, iface) for kind, (_, path, iface) in services.items()}
    cookies = {"pm": 0, "ss": 0}
    held: dict[tuple[str, int], dict[str, str]] = {}
    events: list[list[object]] = []
    refreshes = 0

    while True:
        msg = conn.receive()
        f = msg.header.fields
        if f.get(HeaderFields.reply_serial) in pending:
            name = pending.pop(f[HeaderFields.reply_serial])
            if msg.header.message_type != MessageType.method_return or msg.body[0] != 1:
                print(f"could not own {name}: is this a real session bus?", file=sys.stderr)
                return 1
            if not pending:
                print("ready", flush=True)
            continue
        if msg.header.message_type == MessageType.signal:
            if f.get(HeaderFields.member) == "NameOwnerChanged":
                name, _old, new = msg.body
                if name.startswith(":") and not new:
                    for key in [k for k, v in held.items() if v["sender"] == name]:
                        events.append(["disconnect", key[0], key[1], held.pop(key)["who"]])
            continue
        if msg.header.message_type != MessageType.method_call:
            continue

        path, iface, member = (
            f.get(HeaderFields.path),
            f.get(HeaderFields.interface),
            f.get(HeaderFields.member),
        )
        sig = f.get(HeaderFields.signature, "")
        sender = f.get(HeaderFields.sender)
        kind, served_iface = by_path.get(path, (None, None))
        if kind is None or iface != served_iface:
            conn.send(new_error(msg, UNKNOWN, "s", (f"{path} {iface}.{member}",)))
            continue

        cookie_sig = "i" if kind == "pm" else "u"
        if kind in ("pm", "ss") and member == "Inhibit" and sig == "ss" and fail_inhibits > 0:
            fail_inhibits -= 1
            events.append(["refused", kind])
            conn.send(new_error(msg, "org.freedesktop.DBus.Error.Failed", "s", ("not ready",)))
        elif kind in ("pm", "ss") and member == "Inhibit" and sig == "ss":
            cookies[kind] += 1
            who, why = msg.body
            held[(kind, cookies[kind])] = {"who": who, "why": why, "sender": sender}
            events.append(["inhibit", kind, cookies[kind], who, why])
            conn.send(new_method_return(msg, cookie_sig, (cookies[kind],)))
        elif kind in ("pm", "ss") and member == "UnInhibit" and sig == cookie_sig:
            cookie = msg.body[0]
            gone = held.pop((kind, cookie), None)
            events.append(["uninhibit", kind, cookie, gone is not None])
            conn.send(new_method_return(msg))
        elif kind == "solid" and member == "refreshStatus":
            refreshes += 1
            conn.send(new_method_return(msg))
        elif kind == "stub" and member == "Dump":
            state = {
                "held": [{"kind": k, "cookie": c, **v} for (k, c), v in held.items()],
                "events": events,
                "refreshes": refreshes,
            }
            conn.send(new_method_return(msg, "s", (json.dumps(state),)))
        else:
            conn.send(new_error(msg, UNKNOWN, "s", (f"{member}({sig})",)))


if __name__ == "__main__":
    sys.exit(main(sys.argv))
