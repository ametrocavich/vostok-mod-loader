#!/usr/bin/env bash
# Install the B2 test mods into the game and select a profile that enables
# only them. Backs up mod_config.cfg first; restore.sh undoes everything.
# Never launches the game.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GAME="${GAME:-/c/Program Files (x86)/Steam/steamapps/common/Road to Vostok}"
USERDATA="${USERDATA:-$APPDATA/Road to Vostok}"
CFG="$USERDATA/mod_config.cfg"

[[ -d "$GAME/mods" ]] || { echo "ERROR: no mods folder at $GAME/mods"; exit 1; }
[[ -f "$CFG" ]] || { echo "ERROR: no $CFG (launch the loader once first)"; exit 1; }

for mod in B2TestRegistry B2TestHooks; do
    python - "$HERE/mods/$mod" "$GAME/mods/$mod.zip" <<'EOF'
import os, sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as z:
    for root, _dirs, files in os.walk(src):
        for name in files:
            p = os.path.join(root, name)
            z.write(p, os.path.relpath(p, src).replace(os.sep, "/"))
print("wrote", dst)
EOF
done

if [[ ! -f "$CFG.b2backup" ]]; then
    cp "$CFG" "$CFG.b2backup"
    echo "backed up $CFG -> $CFG.b2backup"
fi

# A profile that enables only the two test mods; every other installed mod
# has no entry and stays off. active_profile switches to it.
python - "$CFG" <<'EOF'
import re, sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
t = re.sub(r'(?ms)^\[profile\.Build2Test\.(enabled|priority)\]\n.*?(?=^\[|\Z)', "", t)
t = re.sub(r'^active_profile=.*$', 'active_profile="Build2Test"', t, count=1, flags=re.M)
t = t.rstrip("\n") + """

[profile.Build2Test.enabled]

b2test_registry@1.0.0=true
b2test_hooks@1.0.0=true

[profile.Build2Test.priority]

b2test_registry@1.0.0=0
b2test_hooks@1.0.0=5
"""
open(p, "w", encoding="utf-8", newline="\n").write(t)
print("profile Build2Test written and selected in", p)
EOF
echo "Now launch Road to Vostok, wait for the main menu (the loader restarts once), quit,"
echo "then run: python tests/ingame/build2/evaluate.py"
