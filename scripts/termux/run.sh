#!/data/data/com.termux/files/usr/bin/bash
# TASKS.csv #643 — start GeoStrix on Termux: the Termux:X11 display, then Electron inside the proot container.
#   bash scripts/termux/run.sh            built app (dist/, built on first run): lighter, starts faster
#   bash scripts/termux/run.sh --dev      Vite dev server + Electron, like `npm run dev` (live reload)
# Any other arguments go to Electron (e.g. --remote-debugging-port=9333).
#
# Electron runs with --no-sandbox: proot can't provide the user namespaces or setuid helper Chromium's
# sandbox needs, so without it Electron refuses to start. The page keeps contextIsolation and no
# nodeIntegration, but renderer processes are NOT OS-sandboxed here — open only projects and files you
# trust (docs/termux.md, "Security").
# --ignore-gpu-blocklist: there is no GPU driver inside proot, only Mesa's software renderer (llvmpipe), which
# Chromium blocklists for WebGL — and without WebGL the 3D views cannot start at all.
# LIBGL_DRI3_DISABLE=1: Termux:X11 advertises DRI3, so Mesa's GLX takes the DRI3/Present path with llvmpipe and
# never gets its buffer back — glxinfo hangs, and Electron's GPU process blocks, leaving a black window and a
# page that answers nothing (2026-10-17). Without DRI3 Mesa falls back to plain X images, which works.
# GEOSTRIX_FIT_SCREEN=1 (#649): Termux:X11 has no window manager, so electron/main.js keeps the window covering the
# whole X screen itself, and re-fits it when the screen changes size. With Termux:X11's "native" resolution mode the
# screen follows the device's portrait/landscape rotation. GEOSTRIX_FIT_SCREEN=0 turns this off (e.g. a VNC desktop
# with its own window manager).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="${TMPDIR:-/data/data/com.termux/files/usr/tmp}"

mode=built
args=()
for a in "$@"; do
  case "$a" in
    --dev) mode=dev ;;
    *) args+=("$a") ;;
  esac
done

if [ -z "${GEOSTRIX_DISPLAY-}" ]; then
  export GEOSTRIX_DISPLAY=:0
  # A socket alone proves nothing: a killed server leaves X0 behind. Look for the live server process.
  if ! ps -eo args= | grep -qx "termux-x11 com.termux.x11 :0"; then
    command -v termux-x11 >/dev/null || { echo "termux-x11 is not installed: run scripts/termux/setup-proot.sh first." >&2; exit 1; }
    rm -f "$TMP/.X11-unix/X0" "$TMP/.X0-lock"
    termux-x11 :0 >/dev/null 2>&1 &
    for _ in $(seq 1 50); do [ -S "$TMP/.X11-unix/X0" ] && break; sleep 0.2; done
    [ -S "$TMP/.X11-unix/X0" ] || { echo "termux-x11 did not start (is the Termux:X11 app installed?)." >&2; exit 1; }
  fi
  # bring the Termux:X11 app to the front (harmless if it is already showing)
  am start --user 0 -n com.termux.x11/com.termux.x11.MainActivity >/dev/null 2>&1 || true
fi

# shellcheck disable=SC2016  # expanded inside the container
inner='set -e
export DISPLAY="$GEOSTRIX_DISPLAY" LIBGL_DRI3_DISABLE=1 GEOSTRIX_FIT_SCREEN
[ -x python-sidecar/venv/bin/python ] && export GEOSTRIX_PYTHON="$PWD/python-sidecar/venv/bin/python"
flags="--no-sandbox --ignore-gpu-blocklist $GEOSTRIX_ELECTRON_FLAGS"
if [ "$GEOSTRIX_MODE" = dev ]; then
  exec npx concurrently -k -n vite,app "vite" "wait-on tcp:5173 && cross-env NODE_ENV=development electron . $flags $GEOSTRIX_ARGS"
fi
[ -f dist/index.html ] || npm run build:web
exec npx electron . $flags $GEOSTRIX_ARGS'

export GEOSTRIX_MODE="$mode" GEOSTRIX_ARGS="${args[*]-}" GEOSTRIX_ELECTRON_FLAGS="${GEOSTRIX_ELECTRON_FLAGS-}" \
  GEOSTRIX_FIT_SCREEN="${GEOSTRIX_FIT_SCREEN-1}"
CONTAINER="${GEOSTRIX_CONTAINER:-geostrix}"
REPO="$(cd "$HERE/../.." && pwd)"
exec proot-distro login "$CONTAINER" --no-arch-warning --shared-tmp --bind "$REPO:/geostrix" --work-dir /geostrix \
  --env "GEOSTRIX_DISPLAY=$GEOSTRIX_DISPLAY" --env "GEOSTRIX_MODE=$GEOSTRIX_MODE" \
  --env "GEOSTRIX_ARGS=$GEOSTRIX_ARGS" --env "GEOSTRIX_ELECTRON_FLAGS=$GEOSTRIX_ELECTRON_FLAGS" \
  --env "GEOSTRIX_FIT_SCREEN=$GEOSTRIX_FIT_SCREEN" \
  -- /bin/bash -c "$inner"
