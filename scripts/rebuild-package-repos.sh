#!/usr/bin/env bash
# Rebuild the published APT and YUM repositories from the release assets.
#
# The packages live only in the per-version GitHub releases. All repository
# metadata is derived from those releases, so running this twice produces the
# same repositories, and running it after a release adds that release. Nothing
# reads gh-pages to decide what exists.
#
# Everything is built before anything is published, so a failure while building
# leaves the live repositories untouched. Publishing is several mutations (the
# apt-history uploads, then the gh-pages push); re-running repairs a run that
# died between them.
#
# Produces:
#   release apt-history   flat APT repo, every version. Filename: ../<tag>/<asset>
#                         reaches the sibling release.
#   gh-pages apt/         the current version only. APT resolves Filename against
#                         the sources.list root, so a Pages-hosted index can only
#                         serve packages that are themselves on Pages.
#   gh-pages yum/         repodata only, every version; per-package xml:base points
#                         at the releases.
#
# The package is architecture-independent (deb "all", rpm "noarch"). The Pages
# APT suite still lists amd64 and arm64, each index carrying the "all" package,
# because apt skips a suite whose Architectures does not name the machine's.
#
# Requires: gh (authenticated), curl, python3, dpkg-scanpackages, createrepo_c,
# realpath, and gpg with the signing key imported and GPG_KEY_ID set.
set -euo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${GITHUB_REPOSITORY:-stuckj/wakeful}"
# RELEASE_BASE and PAGES_REMOTE let the publish path be exercised locally.
BASE="${RELEASE_BASE:-https://github.com/${REPO}/releases/download}"
export PAGES_URL="${PAGES_URL:-https://stuckj.github.io/wakeful}"
KEY="${GPG_KEY_ID:?GPG_KEY_ID must be set}"
export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
# Publishing requires DRY_RUN=0 explicitly.
DRY_RUN="${DRY_RUN:-1}"
[ "$DRY_RUN" = 0 ] || DRY_RUN=1
# Paths on gh-pages this script replaces; everything else there is left alone.
OWNED_PATHS=(apt/dists/stable apt/pool/main apt/gpg-key.asc yum index.html gpg-key.asc)

say() { printf '\n== %s\n' "$1"; }
die() { echo "FATAL: $*" >&2; exit 1; }
gpg_do() { printf '%s' "${GPG_PASSPHRASE:-}" | gpg --batch --yes --armor --passphrase-fd 0 \
                                                   --pinentry-mode loopback "$@"; }
detach() { gpg_do --detach-sign -o "$1" "$2"; }
sign() {  # sign <detached-out> <clear-out> <file>
  gpg_do --detach-sign -o "$1" "$3"
  gpg_do --clearsign -o "$2" "$3"
}

# The work tree is wiped, so refuse anything that is not clearly a scratch
# directory. The path is resolved first: "docs" from a checkout, or "$HOME/.",
# must not slip past the checks.
[ $# -ge 1 ] || die "usage: $(basename "$0") <work-directory>   (a scratch dir outside any checkout)"
WORK="$(realpath -m -- "$1")" || die "cannot resolve '$1'"
[ -d "$(dirname "$WORK")" ] || die "cannot resolve '$1' — its parent directory does not exist"
MARKER=.repobuild-marker
case "$WORK" in
  / | "${HOME:-/nonexistent}") die "refusing to use '$WORK' as a work directory" ;;
esac
if git -C "$(dirname "$WORK")" rev-parse --show-toplevel >/dev/null 2>&1; then
  die "refusing to use '$WORK': it is inside a git working tree"
fi
if [ -n "$(ls -A "$WORK" 2>/dev/null)" ] && [ ! -e "$WORK/$MARKER" ]; then
  die "refusing to wipe non-empty '$WORK': this script did not create it"
fi
mkdir -p "$WORK"
rm -rf "${WORK:?}"/* "${WORK:?}"/.[!.]* 2>/dev/null || true
touch "$WORK/$MARKER"
mkdir -p "$WORK"/{pkgs,apt/history,pages,stage/deb,stage/rpm}
cd "$WORK"

say "enumerate release assets"
# Only v* tags hold packages; apt-history is this script's own output. Drafts
# are excluded: their download URLs 404 for everyone but the owner.
enumerate() {
  # shellcheck disable=SC2016  # a jq program, not shell
  gh api "repos/$REPO/releases" --paginate \
    -q '.[] | select(.draft == false) | select(.tag_name | startswith("v"))
        | .tag_name as $t | .assets[] | select(.state == "uploaded")
        | "\($t)/\(.name)\t\(.size)\t\(.browser_download_url)"' \
    | awk -F'\t' '$1 ~ /\.(deb|rpm)$/' | sort -u > assetsizes.txt
  cut -f1 assetsizes.txt > assetmap.txt
}
enumerate
# The releases API is eventually consistent and this runs moments after the
# release was created, so wait until the new release is listed with both assets.
tag_complete() {  # tag_complete <tag>
  grep -q "^${1}/.*_all\.deb$" assetmap.txt && grep -q "^${1}/.*\.noarch\.rpm$" assetmap.txt
}
if [ -n "${EXPECT_TAG:-}" ]; then
  for attempt in 1 2 3 4 5; do
    tag_complete "$EXPECT_TAG" && break
    echo "  ${EXPECT_TAG} not fully listed yet (attempt $attempt) — re-reading in ${ENUM_RETRY_DELAY:-10}s"
    sleep "${ENUM_RETRY_DELAY:-10}"
    enumerate
  done
fi
[ -s assetmap.txt ] || die "no package assets found — refusing to publish an empty repository"
# One asset name must map to one release, or a package could point at a
# release holding different bytes: a permanent hash mismatch for every client.
dupes=$(cut -d/ -f2- assetmap.txt | sort | uniq -d)
[ -z "$dupes" ] || die "asset name(s) present under more than one release: $(echo "$dupes" | tr '\n' ' ')"
echo "  $(wc -l < assetmap.txt) package assets across $(cut -d/ -f1 assetmap.txt | sort -u | wc -l) releases"

say "download packages"
while IFS=$'\t' read -r path want url; do
  out="pkgs/$path"
  mkdir -p "$(dirname "$out")"
  curl -fsSL --retry 3 --retry-delay 2 \
       --connect-timeout 30 --speed-limit 1024 --speed-time 60 \
       -o "$out" "$url" \
    || die "could not download $path"
  got=$(stat -c%s "$out")
  # A truncated download would be indexed with the hash of the short file.
  [ "$got" = "$want" ] || die "$path is $got bytes, the release says $want"
done < assetsizes.txt
echo "  $(wc -l < assetmap.txt) files, all sizes match the release metadata"

say "stage"
while IFS=/ read -r tag name; do
  src="pkgs/$tag/$name"
  case "$name" in
    wakeful_*_all.deb)      ln -f "$src" "stage/deb/$name" ;;
    wakeful-*.noarch.rpm)   ln -f "$src" "stage/rpm/$name" ;;
    *)                      die "unclassified asset $name" ;;
  esac
done < assetmap.txt
echo "  deb: $(find stage/deb -type f | wc -l), rpm: $(find stage/rpm -type f | wc -l)"

newest() {  # newest <stagedir> -> highest Debian version, or non-zero
  local best="" v f
  for f in "$1"/wakeful_*.deb; do
    [ -f "$f" ] || return 1
    v=$(dpkg-deb -f "$f" Version 2>/dev/null) || return 1
    [ -n "$v" ] || return 1
    if [ -z "$best" ] || dpkg --compare-versions "$v" gt "$best"; then best="$v"; fi
  done
  [ -n "$best" ] || return 1
  printf '%s' "$best"
}
CURRENT=$(newest stage/deb) || die "cannot determine the newest version"
# GitHub stores '~' in asset names as '.'.
CURRENT_DEB=$(compgen -G "stage/deb/wakeful_${CURRENT//\~/.}_all.deb" \
              || compgen -G "stage/deb/wakeful_${CURRENT}_all.deb") \
  || die "no deb for the newest version $CURRENT"
compgen -G "stage/rpm/wakeful-${CURRENT//\~/.}-*.noarch.rpm" >/dev/null \
  || compgen -G "stage/rpm/wakeful-${CURRENT}-*.noarch.rpm" >/dev/null \
  || die "newest version $CURRENT has no rpm — refusing to publish a half release"
echo "  current version: $CURRENT"

say "build the flat APT history repo (metadata only)"
( cd stage/deb && dpkg-scanpackages -m . 2>/dev/null ) | sed 's|^Filename: \./|Filename: |' > apt/history/.raw
: > apt/history/Packages
while IFS= read -r line; do
  if [[ $line == Filename:\ * ]]; then
    n="${line#Filename: }"
    tag=$(grep -m1 -F "/$n" assetmap.txt | cut -d/ -f1 || true)
    [ -n "$tag" ] || die "no release holds $n"
    printf 'Filename: ../%s/%s\n' "$tag" "$n" >> apt/history/Packages
  else
    printf '%s\n' "$line" >> apt/history/Packages
  fi
done < apt/history/.raw
rm -f apt/history/.raw
# Sorted stanzas make the index byte-reproducible for an unchanged package set.
python3 - apt/history/Packages <<'PY'
import sys
path = sys.argv[1]
stanzas = sorted(s.strip("\n") for s in open(path).read().split("\n\n") if s.strip())
with open(path, "w") as fh:
    for s in stanzas:
        fh.write(s + "\n\n")
PY
entries=$(grep -c '^Package:' apt/history/Packages || true)
[ "$entries" -gt 0 ] || die "the history index is empty — refusing to publish it"
( cd apt/history
  gzip -nkf Packages
  { echo "Origin: wakeful"; echo "Label: wakeful"; echo "Codename: ./"
    echo "Architectures: all amd64 arm64"; echo "Description: wakeful (full version history)"
    echo "Date: $(date -Ru)"; echo "SHA256:"
    for f in Packages Packages.gz; do
      echo " $(sha256sum "$f" | awk '{print $1}') $(stat -c%s "$f") $f"
    done
  } > Release
  sign Release.gpg InRelease Release )
echo "  history: $entries entries"

# A partial read of the releases API looks exactly like a deleted release, so a
# shrinking index needs to be confirmed with ALLOW_SHRINK=1.
http=$(curl -sSL --retry 3 --retry-delay 2 --connect-timeout 30 --max-time 120 \
            -o prev-Packages -w '%{http_code}' "$BASE/apt-history/Packages" 2>/dev/null || true)
case "${http:-000}" in
  200) prev=$(grep -c '^Package:' prev-Packages || true) ;;
  404) prev=0 ;;
  *)   die "cannot read the published history index to compare against (HTTP ${http:-000})" ;;
esac
rm -f prev-Packages
if [ "$prev" -gt "$entries" ] && [ "${ALLOW_SHRINK:-0}" != 1 ]; then
  die "the history index would shrink from $prev to $entries entries. If a release was
       deliberately deleted, re-run with ALLOW_SHRINK=1; otherwise the releases API
       returned an incomplete view and re-running should fix it."
fi

gpg --armor --export "$KEY" > apt/gpg-key.asc
# gpg exits 0 and writes nothing if the key id does not resolve.
[ -s apt/gpg-key.asc ] || die "exported public key is empty — is GPG_KEY_ID ($KEY) right?"

say "build gh-pages APT (current version only)"
mkdir -p pages/apt/pool/main pages/apt/dists/stable/main/binary-{amd64,arm64}
cp "$CURRENT_DEB" pages/apt/pool/main/
( cd pages/apt
  for a in amd64 arm64; do
    dpkg-scanpackages --arch "$a" pool/main/ 2>/dev/null > "dists/stable/main/binary-$a/Packages"
    grep -q '^Package:' "dists/stable/main/binary-$a/Packages" \
      || die "stable/$a index is empty"
    gzip -nkf "dists/stable/main/binary-$a/Packages"
  done
  cd dists/stable
  { echo "Origin: wakeful"; echo "Label: wakeful"; echo "Suite: stable"; echo "Codename: stable"
    echo "Architectures: amd64 arm64"; echo "Components: main"
    echo "Description: wakeful (current version; see the apt-history release for older versions)"
    echo "Date: $(date -Ru)"; echo "SHA256:"
    for f in main/binary-amd64/Packages main/binary-amd64/Packages.gz \
             main/binary-arm64/Packages main/binary-arm64/Packages.gz; do
      echo " $(sha256sum "$f" | awk '{print $1}') $(stat -c%s "$f") $f"
    done
  } > Release
  sign Release.gpg InRelease Release )

say "build gh-pages YUM repodata (every version, packages via xml:base)"
# --no-database: only primary.xml can be pointed at the releases.
# gz explicitly: newer createrepo_c defaults to zstd, which yum_xmlbase.py
# does not read.
createrepo_c --quiet --no-database --general-compress-type=gz stage/rpm
mkdir -p pages/yum
python3 "$SCRIPTS/yum_xmlbase.py" stage/rpm/repodata pages/yum/repodata assetmap.txt "$BASE"
detach pages/yum/repodata/repomd.xml.asc pages/yum/repodata/repomd.xml
echo "  yum: $(find stage/rpm -name '*.rpm' | wc -l) packages indexed"

cp apt/gpg-key.asc pages/gpg-key.asc
cp apt/gpg-key.asc pages/apt/
cp apt/gpg-key.asc pages/yum/

if [ -n "${EXPECT_TAG:-}" ]; then
  grep -qF "Filename: ../${EXPECT_TAG}/" apt/history/Packages \
    || die "${EXPECT_TAG} is not in the APT history index"
  grep -qF "/${EXPECT_TAG}/" < <(gzip -dc pages/yum/repodata/*primary.xml.gz) \
    || die "${EXPECT_TAG} is not in the YUM repodata"
  echo "  confirmed ${EXPECT_TAG} is in both the APT and YUM indexes"
fi
bash "$SCRIPTS/repo-index.sh" > pages/index.html
echo "  generated tree: $(du -sh pages | cut -f1), $(find pages -type f | wc -l) files"

if [ "$DRY_RUN" = 1 ]; then
  say "dry run — publishing nothing"
  echo "  APT history and gh-pages tree left in $WORK"
  exit 0
fi

# ---- everything below publishes; nothing above has touched the live repos ----

say "publish the APT history release"
gh release view apt-history --repo "$REPO" >/dev/null 2>&1 || \
  gh release create apt-history --repo "$REPO" --prerelease --title "APT repository (full history)" \
    --notes "Flat APT repository metadata. Packages resolve into the per-version releases;
this tag holds only the index. Not a software release — marked pre-release so it
never shows as latest.

    deb [signed-by=/usr/share/keyrings/wakeful.gpg] ${BASE}/apt-history/ ./" >/dev/null
# Indexes first, then signatures: the window in which a client sees an index
# that disagrees with its signature is shorter that way round.
gh release upload apt-history --repo "$REPO" --clobber \
  apt/history/{Packages,Packages.gz} apt/gpg-key.asc >/dev/null \
  || die "could not upload indexes to apt-history"
gh release upload apt-history --repo "$REPO" --clobber \
  apt/history/{Release,Release.gpg,InRelease} >/dev/null \
  || die "could not upload signatures to apt-history"

say "publish gh-pages"
# Commit on top of the branch rather than force-pushing, so whatever else lands
# there survives; only OWNED_PATHS are replaced.
URL="${PAGES_REMOTE:-https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git}"
stage_ghp() {
  rm -rf ghp
  local rc=0
  git ls-remote --exit-code --heads "$URL" gh-pages >/dev/null || rc=$?
  case "$rc" in
    0) git clone --depth 1 --branch gh-pages --quiet "$URL" ghp ;;
    2) echo "  gh-pages does not exist yet — creating it"
       mkdir -p ghp
       git -C ghp init -q -b gh-pages ;;
    *) die "cannot reach the repository to check for gh-pages (git ls-remote exit $rc)" ;;
  esac
  local p
  for p in "${OWNED_PATHS[@]}"; do rm -rf "ghp/${p:?}"; done
  cp -r pages/. ghp/
  git -C ghp config user.name "github-actions[bot]"
  git -C ghp config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git -C ghp add -A
}

pushed=0
for attempt in 1 2 3; do
  stage_ghp
  if git -C ghp diff --staged --quiet; then
    echo "  no change to gh-pages"
    pushed=1; break
  fi
  git -C ghp commit -qm "Rebuild package repositories${EXPECT_TAG:+ for ${EXPECT_TAG}}"
  if git -C ghp push -q "$URL" gh-pages; then
    echo "  gh-pages updated (attempt $attempt)"
    pushed=1; break
  fi
  echo "  push rejected — another writer landed first, retrying from a fresh clone"
done
[ "$pushed" = 1 ] || die "could not push gh-pages after 3 attempts"
