#!/data/data/com.termux/files/usr/bin/bash
# TASKS.csv #643 — run GeoStrix on an Android phone/tablet under Termux (see docs/termux.md).
#
# Electron has no Android build and npm sees Termux as process.platform "android", so the app cannot run
# natively. Instead this sets up a Debian userland with proot-distro and runs the OFFICIAL linux-arm64
# Electron inside it, drawing to the Termux:X11 app — the same code path as a Linux desktop, no fork.
#
# What it does (safe to re-run; each step is skipped when already done):
#   1. Termux side: proot-distro and termux-x11-nightly (from x11-repo).
#   2. A dedicated proot-distro container called "geostrix" (Debian trixie), separate from any Debian you
#      already have — `proot-distro remove geostrix` undoes everything inside it.
#   3. Inside it: Electron's runtime libraries, Python 3 + build tools (for the sidecar, #642), Xvfb (for
#      headless checks), and Node.js 22 LTS from nodejs.org (Debian's Node 20 is past end of life),
#      checked against nodejs.org's SHA-256 list.
#   4. `npm ci` for this checkout, run INSIDE the container so node_modules gets the Linux binaries
#      (esbuild/rollup linux-arm64 and the Electron download). From then on run npm commands through
#      scripts/termux/shell.sh, not from plain Termux.
#
# Usage:  bash scripts/termux/setup-proot.sh
set -euo pipefail

CONTAINER="${GEOSTRIX_CONTAINER:-geostrix}"
NODE_MAJOR=22
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLUGIN_DIR="${PREFIX:-/data/data/com.termux/files/usr}/etc/proot-distro"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mError: %s\033[0m\n' "$*" >&2; exit 1; }

[ -d /data/data/com.termux/files/usr ] && command -v pkg >/dev/null || die "run this inside Termux on Android."
[ "$(uname -m)" = "aarch64" ] || die "only 64-bit ARM (aarch64) devices are supported (this is $(uname -m))."

say "Termux packages: proot-distro, termux-x11"
command -v proot-distro >/dev/null || pkg install -y proot-distro
command -v termux-x11 >/dev/null || { pkg install -y x11-repo && pkg install -y termux-x11-nightly; }

# The stock debian plug-in's last step, `dpkg-reconfigure locales`, has been seen to exit 1 after generating
# the locale correctly (2026-10-17, proot-distro 4.38, Android 15), and proot-distro then deletes the whole
# install. This plug-in reuses Debian's tarball and checksums and only tolerates that one step.
if [ ! -f "$PLUGIN_DIR/$CONTAINER.sh" ]; then
  say "Registering the '$CONTAINER' proot-distro container (Debian trixie)"
  [ -f "$PLUGIN_DIR/debian.sh" ] || die "proot-distro has no debian plug-in at $PLUGIN_DIR/debian.sh."
  cat > "$PLUGIN_DIR/$CONTAINER.sh" <<EOF
# GeoStrix (TASKS.csv #643): Debian with a tolerant locale step. Written by scripts/termux/setup-proot.sh.
source "$PLUGIN_DIR/debian.sh"
DISTRO_NAME="GeoStrix (Debian trixie)"
DISTRO_COMMENT="Runs GeoStrix's Electron app; see docs/termux.md."
distro_setup() {
	sed -i -E 's/#[[:space:]]?(en_US.UTF-8[[:space:]]+UTF-8)/\1/g' ./etc/locale.gen
	run_proot_cmd DEBIAN_FRONTEND=noninteractive dpkg-reconfigure locales || true
}
EOF
fi

if [ ! -d "$PLUGIN_DIR/../../var/lib/proot-distro/installed-rootfs/$CONTAINER" ]; then
  say "Installing the '$CONTAINER' container (downloads ~30 MB, unpacks ~250 MB)"
  proot-distro install "$CONTAINER"
fi

in_container() { proot-distro login "$CONTAINER" --no-arch-warning --shared-tmp --bind "$REPO:/geostrix" -- /bin/bash -c "$1"; }

say "Debian packages (Electron runtime libraries, Python, build tools, Xvfb)"
in_container 'set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q --no-install-recommends ca-certificates curl xz-utils git \
  python3 python3-venv python3-dev build-essential \
  libnss3 libatk1.0-0t64 libatk-bridge2.0-0t64 libcups2t64 libdrm2 libgbm1 libgtk-3-0t64 libasound2t64 \
  libxss1 libxshmfence1 libxkbcommon0 libxcomposite1 libxdamage1 libxrandr2 libpango-1.0-0 libcairo2 \
  libsecret-1-0 libnotify4 libx11-xcb1 libgl1 libegl1 mesa-utils fonts-dejavu-core xvfb xauth dbus-x11'

say "Node.js $NODE_MAJOR LTS"
in_container "set -e
if node -v 2>/dev/null | grep -q '^v$NODE_MAJOR\.'; then echo \"already installed: \$(node -v)\"; exit 0; fi
cd /tmp
base=https://nodejs.org/dist/latest-v$NODE_MAJOR.x
curl -fsSLO \$base/SHASUMS256.txt
file=\$(grep -o 'node-v[0-9.]*-linux-arm64.tar.xz' SHASUMS256.txt | head -1)
curl -fsSLO \$base/\$file
grep \" \$file\\\$\" SHASUMS256.txt | sha256sum -c -
tar -xJf \$file -C /usr/local --strip-components=1 --exclude='*.md' --exclude=LICENSE
rm -f \$file SHASUMS256.txt
node -v; npm -v"

say "npm ci (inside the container, so node_modules gets the Linux binaries)"
in_container 'cd /geostrix && npm ci --no-audit --no-fund'

# Electron 44's package has no install script: it downloads its binary the first time it is required. Fetch it
# now so the first launch isn't a silent ~100 MB wait (and a network problem shows up here, not at startup).
say "Electron runtime (linux-arm64)"
in_container 'cd /geostrix && node node_modules/electron/install.js && node -e "console.log(\"electron:\", require(\"electron\"))"'

say "Done"
cat <<EOF
Start GeoStrix:          bash scripts/termux/run.sh
A shell in the container: bash scripts/termux/shell.sh      (run npm test / npm run build:web here)
Python sidecar (optional, for interpolation / modelling / inversions): see docs/termux.md
EOF
