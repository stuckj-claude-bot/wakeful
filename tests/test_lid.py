import json

import pytest

from wakeful.lid import DO_NOTHING, PROFILES, LidError, LidGuard


class FakeStore:
    def __init__(self, values):
        self.values = dict(values)
        self.fail_writes = False

    def read(self, profile):
        return self.values.get(profile)

    def write(self, profile, value):
        if self.fail_writes:
            raise LidError("kwriteconfig6 failed")
        if value is None:
            self.values.pop(profile, None)
        else:
            self.values[profile] = value


@pytest.fixture
def journal(tmp_path):
    return tmp_path / "state" / "wakeful" / "lid-restore.json"


def make(store, journal):
    reloads = []
    return LidGuard(store, lambda: reloads.append(1), journal), reloads


ORIGINAL = {"AC": "1", "LowBattery": "32"}  # Battery unset: PowerDevil's default


def test_engage_journals_before_changing(journal):
    store = FakeStore(ORIGINAL)
    guard, reloads = make(store, journal)
    guard.engage()
    assert json.loads(journal.read_text())["originals"] == {
        "AC": "1",
        "Battery": None,
        "LowBattery": "32",
    }
    assert all(store.values[p] == DO_NOTHING for p in PROFILES)
    assert reloads == [1]


def test_restore_puts_back_originals_and_deletes_unset(journal):
    store = FakeStore(ORIGINAL)
    guard, reloads = make(store, journal)
    guard.engage()
    guard.restore()
    assert store.values == ORIGINAL
    assert not journal.exists()
    assert reloads == [1, 1]


def test_restore_without_journal_is_noop(journal):
    store = FakeStore(ORIGINAL)
    guard, reloads = make(store, journal)
    guard.restore()
    assert store.values == ORIGINAL
    assert reloads == []


def test_restore_keeps_a_change_made_meanwhile(journal):
    store = FakeStore(ORIGINAL)
    guard, _ = make(store, journal)
    guard.engage()
    store.values["AC"] = "64"  # changed in System Settings during the block
    guard.restore()
    assert store.values["AC"] == "64"
    assert store.values["LowBattery"] == "32"
    assert "Battery" not in store.values


def test_recovery_by_a_new_instance_after_crash(journal):
    store = FakeStore(ORIGINAL)
    first, _ = make(store, journal)
    first.engage()
    del first  # the process died without restoring

    second, _ = make(store, journal)
    assert second.engaged
    second.restore()
    assert store.values == ORIGINAL
    assert not second.engaged


def test_engage_with_leftover_journal_keeps_true_originals(journal):
    store = FakeStore(ORIGINAL)
    first, _ = make(store, journal)
    first.engage()
    second, _ = make(store, journal)
    second.engage()  # would read the 0s if it re-journaled
    second.restore()
    assert store.values == ORIGINAL


def test_engage_failure_rolls_back(journal):
    store = FakeStore(ORIGINAL)
    guard, _ = make(store, journal)

    calls = {"n": 0}
    real_write = store.write

    def flaky(profile, value):
        calls["n"] += 1
        if calls["n"] == 2:
            raise LidError("disk full")
        real_write(profile, value)

    store.write = flaky
    with pytest.raises(LidError):
        guard.engage()
    assert store.values == ORIGINAL
    assert not journal.exists()


def test_corrupt_journal_is_left_alone(journal):
    store = FakeStore({p: DO_NOTHING for p in PROFILES})
    journal.parent.mkdir(parents=True)
    journal.write_text("{not json")
    guard, _ = make(store, journal)
    with pytest.raises(LidError):
        guard.restore()
    assert journal.exists()
    assert all(store.values[p] == DO_NOTHING for p in PROFILES)


def test_reload_failure_does_not_block_restore(journal):
    store = FakeStore(ORIGINAL)

    def broken_reload():
        raise RuntimeError("PowerDevil not running")

    guard = LidGuard(store, broken_reload, journal)
    guard.engage()
    guard.restore()
    assert store.values == ORIGINAL
    assert not journal.exists()
