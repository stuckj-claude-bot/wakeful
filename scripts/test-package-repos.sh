#!/usr/bin/env bash
# Exercise rebuild-package-repos.sh end to end without GitHub, then install
# from what it generated the way the README says to.
#
#   scripts/test-package-repos.sh <work-directory>
#
# Expects dist/ to hold the packages, built with the rpm signed by the key in
# GPG_KEY_ID (with GPG_PASSPHRASE). The releases are served from a local
# directory, `gh` is replaced by a stub that lists them, and the generated
# Pages tree is served too. Debian and Fedora containers then install from the
# Pages APT suite, the apt-history archive and the YUM repository, with
# signature checking on. Needs docker or podman (CONTAINER=podman), dpkg-dev,
# createrepo-c, gnupg, curl and python3.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="${CONTAINER:-docker}"
: "${GPG_KEY_ID:?GPG_KEY_ID must be set}"
[ $# -eq 1 ] || { echo "usage: $(basename "$0") <work-directory>" >&2; exit 2; }
WORK="$(realpath -m -- "$1")"
mkdir -p "$WORK"
REL="$WORK/releases"
PAGES_PORT=18001 REL_PORT=18000
TAG="v$(dpkg-deb -f "$ROOT"/dist/wakeful_*_all.deb Version)"

rm -rf "$REL" "$WORK/stub" "$WORK/repobuild"
mkdir -p "$REL/$TAG" "$WORK/stub"
cp "$ROOT"/dist/*.deb "$ROOT"/dist/*.rpm "$REL/$TAG/"

# Answers the one releases query the script makes, in the shape of its jq filter.
cat > "$WORK/stub/gh" <<EOF
#!/bin/sh
for f in "$REL"/v*/*; do
  tag=\$(basename "\$(dirname "\$f")"); name=\$(basename "\$f")
  printf '%s/%s\t%s\thttp://localhost:$REL_PORT/%s/%s\n' "\$tag" "\$name" "\$(stat -c%s "\$f")" "\$tag" "\$name"
done
EOF
chmod +x "$WORK/stub/gh"

pids=()
trap 'kill "${pids[@]}" 2>/dev/null || true' EXIT
python3 -m http.server -d "$REL" "$REL_PORT" >/dev/null 2>&1 & pids+=($!)

PATH="$WORK/stub:$PATH" RELEASE_BASE="http://localhost:$REL_PORT" \
  PAGES_URL="http://localhost:$PAGES_PORT" EXPECT_TAG="$TAG" DRY_RUN=1 \
  bash "$ROOT/scripts/rebuild-package-repos.sh" "$WORK/repobuild"

# What the publish step would upload to the apt-history release.
mkdir -p "$REL/apt-history"
cp "$WORK"/repobuild/apt/history/* "$WORK/repobuild/apt/gpg-key.asc" "$REL/apt-history/"
python3 -m http.server -d "$WORK/repobuild/pages" "$PAGES_PORT" >/dev/null 2>&1 & pids+=($!)
sleep 1

echo
echo "== apt: the Pages suite, then the history archive"
"$ENGINE" run --rm --network host docker.io/library/debian:trixie bash -euo pipefail -c "
  export DEBIAN_FRONTEND=noninteractive
  echo 'APT::Sandbox::User \"root\";' > /etc/apt/apt.conf.d/99sandbox
  apt-get update -qq && apt-get install -y -qq curl gpg >/dev/null
  curl -fsSL http://localhost:$PAGES_PORT/gpg-key.asc | gpg --dearmor -o /usr/share/keyrings/wakeful.gpg
  echo 'deb [signed-by=/usr/share/keyrings/wakeful.gpg] http://localhost:$PAGES_PORT/apt stable main' > /etc/apt/sources.list.d/wakeful.list
  apt-get update -qq && apt-get install -y -qq wakeful >/dev/null
  wakeful --version
  apt-get remove -y -qq wakeful >/dev/null
  echo 'deb [signed-by=/usr/share/keyrings/wakeful.gpg] http://localhost:$REL_PORT/apt-history/ ./' > /etc/apt/sources.list.d/wakeful.list
  apt-get update -qq && apt-get install -y -qq wakeful >/dev/null
  wakeful --version
"

echo
echo "== dnf: the YUM repository, gpgcheck=1 as documented"
"$ENGINE" run --rm --network host registry.fedoraproject.org/fedora:43 bash -euo pipefail -c "
  cat > /etc/yum.repos.d/wakeful.repo <<'REPO'
[wakeful]
name=wakeful
baseurl=http://localhost:$PAGES_PORT/yum
enabled=1
gpgcheck=1
gpgkey=http://localhost:$PAGES_PORT/yum/gpg-key.asc
REPO
  dnf install -y -q wakeful
  wakeful --version
"
echo
echo "package repositories OK"
