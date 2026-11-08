"""A watchdog that restores the lid action if the main process dies first.

The main process starts this with a pipe on its stdin and never writes to it.
When the main process exits for any reason, kill -9 included, the kernel closes
the pipe and the read below returns. If the journal is still there, the main
process did not restore, so this does.

It runs in its own session and ignores the signals that end a session or a
systemd unit, so that whatever stops the main process does not stop it first;
the main process exiting is what ends it. SIGKILL can still end it; the journal
then waits for the next start of the main process.
"""

from __future__ import annotations

import logging
import os
import signal
import subprocess
import sys
from pathlib import Path

from .lid import LidGuard

log = logging.getLogger(__name__)


def spawn(journal: Path) -> subprocess.Popen[bytes]:
    # -P and cwd=/ keep a file in the starting directory (often $HOME), such as
    # a logging.py, from being imported in place of the real module.
    env = dict(os.environ, PYTHONPATH=os.pathsep.join(p for p in sys.path if p))
    return subprocess.Popen(
        [sys.executable, "-P", "-s", "-m", "wakeful.lidwatch", str(journal.resolve())],
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        start_new_session=True,
        cwd="/",
        env=env,
    )


class WatchedLidGuard:
    """A LidGuard with a watchdog running for as long as the lid is changed."""

    def __init__(self, guard: LidGuard) -> None:
        self.guard = guard
        self._watch: subprocess.Popen[bytes] | None = None

    def engage(self) -> None:
        if self._watch is None:
            self._watch = spawn(self.guard.journal)
        try:
            self.guard.engage()
        except Exception:
            self._stop_watch()
            raise

    def restore(self) -> None:
        # If this raises, the watchdog stays up: the journal is still there and
        # it is one more chance for the restore to happen.
        self.guard.restore()
        self._stop_watch()

    def _stop_watch(self) -> None:
        if self._watch is None:
            return
        assert self._watch.stdin is not None
        self._watch.stdin.close()
        try:
            self._watch.wait(timeout=10)
        except subprocess.TimeoutExpired:
            log.warning("lid watchdog did not exit")
        self._watch = None


def main(argv: list[str]) -> int:
    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(sig, signal.SIG_IGN)
    logging.basicConfig(level=logging.INFO, format="wakeful-lidwatch: %(message)s")
    journal = Path(argv[1])
    while sys.stdin.buffer.read(4096):
        pass
    if not journal.exists():
        return 0

    from PyQt6.QtCore import QCoreApplication

    from .lid import KConfigTools
    from .powerdevil import refresh_status

    _app = QCoreApplication(argv)
    log.warning("wakeful exited without restoring the lid action; restoring it now")
    LidGuard(KConfigTools(), refresh_status, journal).restore()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
