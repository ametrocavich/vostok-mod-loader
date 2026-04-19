#!/usr/bin/env bash
# Zips each fixture folder into a .vmz under dist/. Drop the .vmz files into
# <game>/mods/ to test the archive path of the security scanner.
#
# Uses Python's stdlib zipfile -- avoids the `zip` command which isn't always
# installed on Windows.

set -euo pipefail
cd "$(dirname "$0")"

PY="${PYTHON:-python}"
if ! command -v "$PY" >/dev/null 2>&1; then
    PY=python3
fi

DIST=dist
rm -rf "$DIST"
mkdir -p "$DIST"

"$PY" - "$DIST" <<'PY'
import os, sys, zipfile
dist = sys.argv[1]
for name in sorted(os.listdir(".")):
    if name == dist or not os.path.isdir(name):
        continue
    if not os.path.isfile(os.path.join(name, "mod.txt")):
        print(f"skip: {name} (no mod.txt)")
        continue
    out = os.path.join(dist, f"{name}.vmz")
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
        for root, dirs, files in os.walk(name):
            dirs[:] = [d for d in dirs if not d.startswith(".")]
            for f in files:
                if f.startswith("."):
                    continue
                full = os.path.join(root, f)
                rel = os.path.relpath(full, name).replace(os.sep, "/")
                zf.write(full, rel)
    print(f"built {out}")
print()
print(f"Done. Drop {dist}/*.vmz into <game>/mods/ to test.")
PY
