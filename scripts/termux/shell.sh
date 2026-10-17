#!/data/data/com.termux/files/usr/bin/bash
# TASKS.csv #643 — a shell (or one command) inside the GeoStrix proot container, in the repo (mounted at
# /geostrix). node_modules holds LINUX binaries once setup-proot.sh has run, so npm commands belong here.
#   bash scripts/termux/shell.sh                 interactive shell
#   bash scripts/termux/shell.sh "npm test"      one command, exit code passed through
# --shared-tmp: Termux's $TMPDIR is the container's /tmp, which is where termux-x11 puts its X socket.
set -euo pipefail
CONTAINER="${GEOSTRIX_CONTAINER:-geostrix}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [ $# -eq 0 ]; then
  exec proot-distro login "$CONTAINER" --no-arch-warning --shared-tmp --bind "$REPO:/geostrix" --work-dir /geostrix
fi
exec proot-distro login "$CONTAINER" --no-arch-warning --shared-tmp --bind "$REPO:/geostrix" --work-dir /geostrix -- /bin/bash -c "$*"
