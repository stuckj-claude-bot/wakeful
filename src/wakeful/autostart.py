"""Start at login, through an XDG autostart entry in the user's config."""

from __future__ import annotations

import os
import shutil
from pathlib import Path

ENTRY = """\
[Desktop Entry]
Type=Application
Name=Wakeful
Comment=Keep the computer awake for a while
Exec={exec}
Icon=wakeful
Terminal=false
X-GNOME-Autostart-enabled=true
"""


def path() -> Path:
    config = os.environ.get("XDG_CONFIG_HOME") or os.path.join(Path.home(), ".config")
    return Path(config) / "autostart" / "wakeful.desktop"


def enabled() -> bool:
    return path().exists()


def set_enabled(value: bool) -> None:
    p = path()
    if not value:
        p.unlink(missing_ok=True)
        return
    p.parent.mkdir(parents=True, exist_ok=True)
    # The full path where it can be found, so a Nix profile switch or a PATH
    # that differs at login cannot leave the entry pointing at nothing.
    p.write_text(ENTRY.format(exec=shutil.which("wakeful") or "wakeful"))
