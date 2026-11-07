# Releasing Wakeful

Releases are built and published by the [release workflow](.github/workflows/release.yml),
which follows the same process as mkvdup's: one manual dispatch builds the packages, tests them,
tags, creates the GitHub release, and rebuilds the APT and YUM repositories on GitHub Pages.

## Prerequisites

### 1. Repository secrets

| Secret | Used by | Purpose |
| --- | --- | --- |
| `GPG_PRIVATE_KEY` | release, rebuild-package-repos | ASCII-armored private key that signs the rpm itself and the APT and YUM metadata |
| `GPG_PASSPHRASE` | release, rebuild-package-repos | its passphrase |
| `RELEASE_PAT` | release (`sync-nix`) | optional; a token that may push to `main` if branch protection blocks `GITHUB_TOKEN` |
| `PROJECT_PAT` | project-add | adds new issues and pull requests to the Open Source Maintenance project; without it the workflow skips with a warning |

The same signing key as mkvdup's is fine. Export it with:

```bash
gpg --armor --export-secret-keys YOUR_KEY_ID
```

### 2. GitHub Pages

Settings → Pages → Source: **Deploy from a branch**, branch `gh-pages`, folder `/`. The release
workflow creates and maintains the branch; its landing page is the project homepage,
<https://stuckj.github.io/wakeful/>.

## Creating a release

1. Make sure `main` is green.
2. Actions → **Build and Release Packages** → Run workflow, from `main`, with the version
   without a `v` (for example `0.1.0`).

The workflow:

1. **prepare** resolves the newest non-bookkeeping commit on the branch and checks that the tag
   does not exist yet.
2. **build** runs `scripts/build-packages.sh <version>`: a noarch `.deb` and `.rpm`. The rpm is
   signed (dnf's `gpgcheck=1` checks a signature inside the package), and
   `scripts/check-rpm-signature.py` fails the build if it is not.
3. **package-test** installs each on stock Debian, Ubuntu and Fedora images and runs the D-Bus
   tests against the installed command.
4. **sync-nix** writes the version into `flake.nix`, `default.nix` and
   `src/wakeful/__init__.py`, checks that the Nix build reports it, and commits that to the
   branch as a bookkeeping commit.
5. **release** creates the tag at that commit and the GitHub release with both packages.
6. **publish-repo** runs `scripts/rebuild-package-repos.sh`, which rebuilds the repositories
   from all release assets and pushes them to `gh-pages`.

Nothing is tagged until every build and package test has passed.

## Version numbering

[Semantic versioning](https://semver.org/). The version lives in `src/wakeful/__init__.py`;
`flake.nix` and `default.nix` carry the same value for Nix, and the release keeps all three in
step.

## Package repositories

The packages live only in the per-version GitHub releases. The repositories hold indexes:

- **APT, current version** — `https://stuckj.github.io/wakeful/apt`, suite `stable`. The deb is
  copied into Pages, because APT resolves package paths against the repository root.
- **APT, every version** — the `apt-history` release, a flat repository whose entries point at
  the per-version releases.
- **YUM** — `https://stuckj.github.io/wakeful/yum`, every version, with each package's
  `xml:base` pointing at its release.

The repositories are derived entirely from the releases, so re-running the rebuild produces the
same result. **Rebuild Package Repositories** (manual, dry run by default) does that without a
release, uploading what it would publish as an artifact.

## Local testing

```bash
go install github.com/goreleaser/nfpm/v2/cmd/nfpm@v2.47.0
scripts/build-packages.sh 0.1.0
podman run --rm -v "$PWD":/src:ro -w /src debian:trixie bash scripts/test-installed-package.sh
podman run --rm -v "$PWD":/src:ro -w /src registry.fedoraproject.org/fedora:43 bash scripts/test-installed-package.sh
```
