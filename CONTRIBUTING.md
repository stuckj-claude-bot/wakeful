# Contributing

## Development environment

Wakeful is Python 3.11+ on PyQt6. PyQt6 comes from your distribution, not from pip:

```bash
# Fedora
sudo dnf install python3-pyqt6 qt6-qtsvg python3-pytest python3-jeepney dbus-daemon kf6-kconfig ruff
# Debian / Ubuntu
sudo apt install python3-pyqt6 qt6-svg-plugins python3-pytest python3-jeepney dbus-daemon libkf6config-bin
```

Run it from the checkout with `PYTHONPATH=src python3 -m wakeful -v`. It talks to your real
session, so a block you start is a real block; `wakeful stop` or quitting ends it.

## Checks

CI runs all of these on every pull request:

```bash
ruff check . && ruff format --check .        # lint and formatting
shellcheck scripts/*.sh
python3 -m pytest                             # unit tests: timer, controller, lid journal
dbus-run-session -- python3 -m pytest -m dbus tests/integration
scripts/build-packages.sh                     # needs nfpm v2.47.0
nix flake check -L
```

CI also installs the built deb and rpm on stock Debian 13, Ubuntu 26.04 and Fedora 43 images and
runs the D-Bus tests against the installed command as an ordinary user
(`scripts/test-installed-package.sh`, which expects to run as root in a throwaway container). And
it generates the APT and YUM repositories from those packages with a throwaway signing key, then
installs from them in Debian and Fedora containers (`scripts/test-package-repos.sh`).

### The D-Bus tests

`tests/integration` starts the real program against stand-ins for PowerDevil and kscreenlocker
(`tests/integration/stub_services.py`) on a private bus. They are deselected by default and must
run under `dbus-run-session`, never on your real session bus: the stub needs the names PowerDevil
owns, and refuses to start if it cannot get them.

### Never skip a test

CI fails on any skipped test (`scripts/check-no-skips.py`). A test that cannot run somewhere is
kept out of that run by a marker, as the D-Bus tests are, so a coverage gap shows up as a test
that does not exist there rather than behind a green check.

## Pull requests

- Branch from `main`, open a pull request, and wait for CI.
- If a change alters what a user can expect, update the README and the man page
  (`docs/wakeful.1`) in the same pull request. If it changes the design's direction — a
  component, a boundary, who owns what — update [DESIGN.md](DESIGN.md) too.
- Close the issues a pull request finishes with `Closes #N`.

## What lives where

- [README.md](README.md) — for users: what it does, installing, using.
- [DESIGN.md](DESIGN.md) — how it is put together and the decisions that constrain it.
- [RELEASING.md](RELEASING.md) — releases, signing and the package repositories.
- The code — the authority on how it actually behaves.
