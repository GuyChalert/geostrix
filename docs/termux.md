# Running GeoStrix on Android (Termux)

GeoStrix can run on a 64-bit ARM Android phone or tablet through [Termux](https://termux.dev). Electron has no
Android build, so the app runs inside a small Debian system (via `proot-distro`) and draws to the
[Termux:X11](https://github.com/termux/termux-x11) app. It is the same app and code as on a Linux desktop.

Tested on 2026-10-17: Snapdragon 8 Elite (Adreno 830), 14 GB RAM, Android 15, Termux with proot-distro 4.38.

## What you need

- An aarch64 (64-bit ARM) device. Memory use hasn't been measured yet; the test device had 14 GB.
- About 2.5 GB free: the container is about 1.8 GB, and `node_modules` (including Electron) about 0.7 GB.
- **Termux** and **Termux:X11**, both from F-Droid or GitHub. Don't mix with Google Play builds.
- This repository cloned inside Termux, e.g. `git clone https://github.com/GuyChalert/geostrix ~/code/geostrix`.

## Setup (once)

```bash
cd ~/code/geostrix
bash scripts/termux/setup-proot.sh
```

This installs `proot-distro` and `termux-x11-nightly`, then creates a separate container called `geostrix`
(Debian trixie). Your own proot distributions are not touched. Inside the container it installs:

- Electron's system libraries.
- Python 3 and build tools.
- Node.js 22 LTS from nodejs.org, with its SHA-256 checked.
- The app's npm dependencies, including Electron itself.

The script is safe to re-run. To remove everything it installed inside the container:
`proot-distro remove geostrix`.

> After setup, `node_modules/` holds **Linux** binaries. Run npm commands (`npm test`,
> `npm run build:web`, …) through `bash scripts/termux/shell.sh "<command>"`, or open a shell in the
> container with `bash scripts/termux/shell.sh`. Running them in plain Termux will fail for anything that
> needs esbuild or rollup.

## Start GeoStrix

```bash
bash scripts/termux/run.sh          # the built app (builds dist/ on first run)
bash scripts/termux/run.sh --dev    # Vite dev server + Electron, with live reload
```

`run.sh` starts the Termux:X11 display if it isn't running, brings the Termux:X11 app to the front, and
launches Electron in the container. Switch back to Termux to see the log; quit the app from its menu or with
Ctrl+C in Termux.

Touch works as a mouse: drag to rotate the 3D view. A Bluetooth or USB mouse and keyboard make the app much
easier to use.

### Python sidecar

Interpolation, implicit modelling and inversions need the optional Python engine. `setup-proot.sh` does not
install it yet (TASKS.csv #642). Create `python-sidecar/venv` inside the container, following
`python-sidecar/README.md`, and `run.sh` will use `python-sidecar/venv/bin/python` automatically.

The geoML predictive-modelling add-on is only built for Windows so far (TASKS.csv #645).

### Databases

A PostgreSQL server running in Termux is reachable from the app at `127.0.0.1`, since the container shares
Termux's network.

There is no keyring in the container, so **"Remember the password" is not offered** (TASKS.csv #640). The
password is used for the session only. This is deliberate: without a keyring, Electron could only "encrypt"
it with a built-in key, which is not real protection.

### Files

The file browser and dialogs can see your Termux home (`/data/data/com.termux/files/home`) and shared
storage (`/sdcard`, after `termux-setup-storage`). The repo itself is mounted at `/geostrix` in the container.

## Performance

There is no GPU driver inside the container, so WebGL is drawn on the CPU by Mesa's llvmpipe renderer. On the
test device:

- the app starts in about 8 s;
- the 37-hole Harry sample loads in about 1–4 s;
- the 3D view stays interactive (about 30 frames/s on Termux:X11, idle scene).

Big voxel models or very large datasets will be slower than on a desktop.

## Security

Electron runs with `--no-sandbox`, because proot cannot provide what Chromium's sandbox needs (user
namespaces, or a setuid helper), and Electron refuses to start otherwise. The app still uses context
isolation and gives the page no Node.js access, but the renderer processes are **not** isolated by the
operating system as they are on Windows, macOS or a normal Linux desktop. Open only projects and files you
trust.

`--ignore-gpu-blocklist` is also set. Chromium blocks WebGL on software renderers by default, and without
WebGL the 3D views cannot start.

## Troubleshooting

- **Black Termux:X11 screen, app not responding.** Mesa's GLX was using DRI3, which hangs with Termux:X11.
  `run.sh` sets `LIBGL_DRI3_DISABLE=1` to avoid this. If you start Electron another way, set it yourself.
- **"Missing X server or $DISPLAY".** A stale `/tmp/.X11-unix/X0` from a killed server. `run.sh` checks for a
  live `termux-x11` process and replaces the stale socket; otherwise delete it and start `termux-x11 :0`.
- **`proot-distro install` ends with "Exiting due to failure" right after "Generation complete".**
  Debian's locale step returned an error after succeeding, and proot-distro deleted the install. The
  `geostrix` container avoids this by tolerating that one step.
- **Log lines about D-Bus, NETLINK or udev.** Harmless: those services don't exist in proot.
