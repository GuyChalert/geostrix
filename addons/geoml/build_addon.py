"""Build the GeoStrix predictive-modelling add-on (TASKS.csv #638): freeze it with PyInstaller, zip it, print the
release fields (url / sha256 / bytes / installedBytes / longestPath) for addons/geoml/release.json.
Copyright (C) 2026 Matt Mendes. GNU GPL v3 (see LICENSE).

    python build_addon.py [--out <folder>]        (run with the add-on's own Python, requirements + pyinstaller installed)

Writes <out>/geostrix-geoml/ (the frozen program), <out>/geostrix-geoml-addon-<version>-win.zip and <out>/release-fields.json.
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(HERE, "dist"))
    args = ap.parse_args()
    release = json.load(open(os.path.join(HERE, "release.json"), encoding="utf-8"))
    version = release["version"]
    out = os.path.abspath(args.out)
    work = os.path.join(out, "_build")
    subprocess.run([sys.executable, "-m", "PyInstaller", os.path.join(HERE, "run_addon.py"), "--name", "geostrix-geoml", "--onedir", "--noconfirm",
                    "--log-level", "WARN", "--distpath", out, "--workpath", work, "--specpath", work, "--paths", HERE,
                    "--hidden-import", "geostrix_geoml.models", "--hidden-import", "geostrix_geoml.server",
                    "--collect-all", "geoml", "--collect-submodules", "tensorflow_probability", "--collect-data", "tensorflow_probability",
                    "--copy-metadata", "geoml"], check=True)
    folder = os.path.join(out, "geostrix-geoml")
    # the licence and the source pointer travel with the program (GPL-3.0 section 4 / 6d)
    for f in ("LICENSE", "README.md"):
        with open(os.path.join(HERE, f), "rb") as src, open(os.path.join(folder, f), "wb") as dst:
            dst.write(src.read())
    installed = 0
    longest = 0  # the longest path inside the add-on: GeoStrix refuses to install where root + this would pass Windows' 260
    zpath = os.path.join(out, f"geostrix-geoml-addon-{version}-win.zip")
    with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for root, _, files in os.walk(folder):
            for f in files:
                p = os.path.join(root, f)
                installed += os.path.getsize(p)
                longest = max(longest, len(os.path.relpath(p, out)))
                z.write(p, os.path.relpath(p, out))
    h = hashlib.sha256()
    with open(zpath, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    fields = {"version": version, "file": os.path.basename(zpath), "sha256": h.hexdigest(), "bytes": os.path.getsize(zpath), "installedBytes": installed, "longestPath": longest}
    json.dump(fields, open(os.path.join(out, "release-fields.json"), "w"), indent=2)
    print(json.dumps(fields, indent=2))


if __name__ == "__main__":
    main()
