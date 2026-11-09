#!/usr/bin/env bash
# Install the built package into this (stock) system and run the D-Bus
# integration tests against the installed command, then remove it again.
#
#   scripts/test-installed-package.sh
#
# Meant for a throwaway Debian, Ubuntu or Fedora container, as root, from the
# repository root with the packages in dist/. It proves the declared
# dependencies are enough: only the package and the test tools are installed.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# shellcheck source=/dev/null
. /etc/os-release
echo "== ${PRETTY_NAME}"

if command -v apt-get >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  # Rootless containers cannot drop privileges for apt's download sandbox.
  echo 'APT::Sandbox::User "root";' > /etc/apt/apt.conf.d/99wakeful-test
  echo 'Acquire::Retries "5";' >> /etc/apt/apt.conf.d/99wakeful-test
  # GitHub's runners are Azure VMs, and Canonical's Azure mirror is what the
  # runners' own Ubuntu images use; archive.ubuntu.com can time out from them.
  if [ "${GITHUB_ACTIONS:-}" = true ] && [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
    sed -i 's#http://archive.ubuntu.com/#http://azure.archive.ubuntu.com/#' \
      /etc/apt/sources.list.d/ubuntu.sources
  fi
  # --error-on=any: without it a failed fetch is only a warning, and the
  # install below fails as an unsatisfiable dependency instead.
  apt-get update -qq --error-on=any
  apt-get install -y -qq ./dist/wakeful_*_all.deb
  apt-get install -y -qq python3-pytest python3-jeepney dbus-daemon
  remove() { apt-get remove -y -qq wakeful; }
  installed() { dpkg -s wakeful >/dev/null 2>&1; }
else
  dnf install -y -q ./dist/wakeful-*.noarch.rpm
  dnf install -y -q python3-pytest python3-jeepney dbus-daemon util-linux shadow-utils
  remove() { dnf remove -y -q wakeful; }
  installed() { rpm -q wakeful >/dev/null 2>&1; }
fi

echo "-- installed: $(wakeful --version)"
for tool in kreadconfig6 kwriteconfig6; do
  command -v "$tool" >/dev/null || { echo "$tool missing: the recommended package was not installed" >&2; exit 1; }
done
test -f /usr/share/applications/wakeful.desktop
test -f /usr/share/icons/hicolor/scalable/apps/wakeful.svg

# Run as an ordinary user, as the app is meant to be, from a copy outside the
# checkout so nothing imports the source tree. A root run would hide files the
# package installs unreadable.
id tester >/dev/null 2>&1 || useradd -m tester
work=$(mktemp -d)
cp -r tests pyproject.toml "$work/"
chown -R tester "$work"
runuser -u tester -- env -C "$work" WAKEFUL_CMD=wakeful \
  dbus-run-session -- python3 -m pytest -p no:cacheprovider -m dbus \
  --junitxml="$work/results.xml" -q tests/integration
[ -z "${JUNIT_OUT:-}" ] || cp "$work/results.xml" "$JUNIT_OUT"

remove
installed && { echo "package still installed after removal" >&2; exit 1; }
test ! -e /usr/bin/wakeful
test ! -e /usr/lib/wakeful
echo "-- removed cleanly"
