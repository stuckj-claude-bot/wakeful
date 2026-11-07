#!/usr/bin/env bash
# Emit the GitHub Pages landing page (project homepage and package repository
# instructions) on stdout.
set -euo pipefail
REPO="${GITHUB_REPOSITORY:-stuckj/wakeful}"
BASE="${RELEASE_BASE:-https://github.com/${REPO}/releases/download}"
PAGES="${PAGES_URL:-https://stuckj.github.io/wakeful}"
# Set while no release exists yet, so the page says so instead of offering
# repositories that 404.
PRERELEASE="${PRERELEASE:-0}"

cat <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Wakeful - keep KDE Plasma awake for a set time</title>
  <meta name="description" content="A KDE Plasma 6 tray app that keeps the computer awake for a set time, sleep only or with the screen on, then releases the block by itself. Packaged for apt, dnf and Nix.">
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; max-width: 800px; margin: 50px auto; padding: 0 20px; line-height: 1.5; }
    pre { background: #f4f4f4; padding: 15px; border-radius: 5px; overflow-x: auto; }
    code { background: #f4f4f4; padding: 2px 6px; border-radius: 3px; }
    h1 { border-bottom: 2px solid #333; padding-bottom: 10px; }
    h2 { margin-top: 30px; }
    .note { background: #f0f6ff; border-left: 4px solid #4a7dbd; padding: 10px 15px; margin: 15px 0; }
    .warn { background: #fff6e5; border-left: 4px solid #f67400; padding: 10px 15px; margin: 15px 0; }
  </style>
</head>
<body>
  <h1>Wakeful</h1>
  <p>A tray app for KDE Plasma 6 that keeps the computer awake for a set time — sleep only,
  or with the screen on too — then releases the block by itself, and leaves nothing behind if
  it crashes.</p>
  <p>Plasma's own "Manually block sleep and screen locking" switch has no time limit and always
  keeps the screen on too. Wakeful blocks sleep for 30 minutes, a few hours, or until you turn
  it off, and by default lets the screen dim, turn off and lock as usual.</p>
EOF

if [ "$PRERELEASE" = 1 ]; then
  cat <<EOF
  <div class="warn">
    <p><strong>Early development; not yet usable.</strong> No release has been published yet,
    so the package repositories below do not exist yet. Follow
    <a href="https://github.com/${REPO}">the repository</a> for the first release.</p>
  </div>
EOF
fi

cat <<EOF

  <h2>Debian/Ubuntu (APT)</h2>
  <p>Debian 13, Ubuntu 25.04 and later (Plasma 6).</p>
  <pre>
# Add the GPG key
curl -fsSL ${PAGES}/gpg-key.asc | sudo gpg --dearmor -o /usr/share/keyrings/wakeful.gpg

# Add the repository
echo "deb [signed-by=/usr/share/keyrings/wakeful.gpg] ${PAGES}/apt stable main" | sudo tee /etc/apt/sources.list.d/wakeful.list

# Install
sudo apt update
sudo apt install wakeful</pre>

  <div class="note">
    <p>This repository carries the <strong>current release only</strong>. To install or pin an
    older version, add the archive repository below, which indexes every version published.
    Enabling both is safe: they are two sources for the same package.</p>
  </div>

  <h3>Debian/Ubuntu (APT) — full version history</h3>
  <pre>
echo "deb [signed-by=/usr/share/keyrings/wakeful.gpg] ${BASE}/apt-history/ ./" | sudo tee /etc/apt/sources.list.d/wakeful-history.list

sudo apt update
apt list -a wakeful</pre>

  <h2>Fedora (DNF)</h2>
  <p>Fedora 40 and later. Indexes every version published.</p>
  <pre>
sudo tee /etc/yum.repos.d/wakeful.repo &lt;&lt; 'REPO'
[wakeful]
name=wakeful
baseurl=${PAGES}/yum
enabled=1
gpgcheck=1
gpgkey=${PAGES}/yum/gpg-key.asc
REPO

sudo dnf install wakeful</pre>

  <h2>Nix</h2>
  <pre>
# Home Manager: install it and start it with the Plasma session
inputs.wakeful.url = "github:${REPO}";
imports = [ inputs.wakeful.homeManagerModules.default ];
services.wakeful.enable = true;

# NixOS without Home Manager
imports = [ inputs.wakeful.nixosModules.default ];
programs.wakeful.enable = true;

# Or just the package
nix profile install github:${REPO}</pre>

  <h2>Where the packages live</h2>
  <p>Package files are served from the per-version
  <a href="https://github.com/${REPO}/releases">GitHub releases</a>; these repositories carry
  only the indexes.</p>

  <h2>Links</h2>
  <ul>
    <li><a href="https://github.com/${REPO}">Source, documentation and issues</a></li>
    <li><a href="https://github.com/${REPO}/releases">Releases</a></li>
  </ul>
</body>
</html>
EOF
