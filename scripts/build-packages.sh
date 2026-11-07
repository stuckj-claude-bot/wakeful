#!/usr/bin/env bash
# Build the deb and rpm into dist/.
#
#   scripts/build-packages.sh [VERSION]
#
# VERSION defaults to the one in src/wakeful/__init__.py. It is written into
# the packaged copy of the module, never into the source tree. Requires nfpm.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

VERSION="${1:-$(sed -n 's/^__version__ = "\(.*\)"$/\1/p' src/wakeful/__init__.py)}"
[ -n "$VERSION" ] || { echo "cannot determine the version" >&2; exit 1; }
export VERSION

rm -rf build/wakeful dist
mkdir -p build dist
cp -r src/wakeful build/wakeful
find build/wakeful -name __pycache__ -prune -exec rm -rf {} +
sed -i "s/^__version__ = .*/__version__ = \"${VERSION}\"/" build/wakeful/__init__.py
grep -q "^__version__ = \"${VERSION}\"$" build/wakeful/__init__.py \
  || { echo "failed to stamp version ${VERSION}" >&2; exit 1; }

nfpm package --packager deb --target dist/
nfpm package --packager rpm --target dist/
ls -l dist/
