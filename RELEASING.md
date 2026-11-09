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
| `RELEASE_PAT` | release (`sync-nix`) | pushes the version bump to `main`, which the `Protect main` ruleset refuses from `GITHUB_TOKEN`; see below |
| `PROJECT_PAT` | project-add | adds new issues and pull requests to the Open Source Maintenance project; without it the workflow skips with a warning |

Set them with `gh secret set <NAME> -R stuckj/wakeful`, which reads the value from stdin or
prompts for it.

### 2. The signing key

Wakeful has a signing key of its own, not shared with other projects. To create one (for
example to replace it), generate it in your normal keyring, whose gpg-agent has a pinentry for
the passphrase prompt; a throwaway `GNUPGHOME` fails with `No pinentry`.

```bash
gpg --full-generate-key
# Kind: the default, ECC (sign and encrypt) on Curve 25519
# Expiration: 0, or a date you will remember to extend
# Real name: John Stucklen
# Email: the address on the other project keys
# Comment: wakeful apt/yum repo GPG Key
# Passphrase: becomes GPG_PASSPHRASE

gpg --list-secret-keys --keyid-format LONG     # "sec ed25519/<KEYID>"
```

The key is ed25519. rpm verifies EdDSA signatures from 4.16 on, which covers every Fedora with
Plasma 6; apt has no such limit.

Then export it, store the files, the key ID and the passphrase in the password manager, and add
the secrets:

```bash
KEYID=<KEYID>
gpg --export "$KEYID" > wakeful-signing-public.pgp                # binary public key
gpg --armor --export-secret-keys "$KEYID" > wakeful-signing-private.asc
gh secret set GPG_PRIVATE_KEY -R stuckj/wakeful < wakeful-signing-private.asc
gh secret set GPG_PASSPHRASE -R stuckj/wakeful
shred -u wakeful-signing-public.pgp wakeful-signing-private.asc
```

`GPG_PRIVATE_KEY` must be the armored export. The workflows take the public key from it and
publish it on Pages (`gpg-key.asc`, `apt/gpg-key.asc`, `yum/gpg-key.asc`), which is where the
install instructions fetch it.

### 3. The release token

`sync-nix` commits the new version to `main` before tagging. The `Protect main` ruleset only
accepts changes through a pull request, so that push needs a token whose account the ruleset lets
through:

1. Create a fine-grained personal access token: resource owner `stuckj`, repository access
   `stuckj/wakeful` only, permission **Contents: Read and write**, nothing else.
2. `gh secret set RELEASE_PAT -R stuckj/wakeful`, and paste it.
3. In Settings → Rules → Rulesets → Protect main, add **Repository admin** to the bypass list
   with **Always allow**.

Without it, a release whose version is already in the files still works. One that needs the bump
stops at `sync-nix`, before anything is tagged or published, with an error naming this token.

### 4. GitHub Pages

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
