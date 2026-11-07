import signal
import time

from wakeful import lidwatch


def test_watchdog_ignores_a_shadowing_module_in_the_working_directory(tmp_path, monkeypatch):
    home = tmp_path / "home"
    home.mkdir()
    (home / "logging.py").write_text("raise SystemExit(7)\n")
    monkeypatch.chdir(home)
    watch = lidwatch.spawn(tmp_path / "no-journal.json")
    watch.stdin.close()
    assert watch.wait(timeout=30) == 0


def ignores(pid, sig):
    with open(f"/proc/{pid}/status") as f:
        mask = next(line for line in f if line.startswith("SigIgn:")).split()[1]
    return bool(int(mask, 16) & (1 << (sig - 1)))


def test_watchdog_outlives_sigterm_until_its_parent_goes(tmp_path):
    watch = lidwatch.spawn(tmp_path / "no-journal.json")
    try:
        deadline = time.monotonic() + 30
        while not ignores(watch.pid, signal.SIGTERM):
            assert time.monotonic() < deadline, "watchdog never set up its signals"
            time.sleep(0.05)
        watch.send_signal(signal.SIGTERM)
        watch.send_signal(signal.SIGHUP)
        time.sleep(0.5)
        assert watch.poll() is None
        watch.stdin.close()
        assert watch.wait(timeout=30) == 0
    finally:
        if watch.poll() is None:
            watch.kill()
