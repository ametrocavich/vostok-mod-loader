#!/usr/bin/env bash
# Install the LTS kit: back up the player's loader state, zip the test mods and pack into the
# game's mods folder, unload any applied pack and select a profile LTSTest. restore.sh undoes it.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GAME="${GAME:-/c/Program Files (x86)/Steam/steamapps/common/Road to Vostok}"
USERDATA="${USERDATA:-$APPDATA/Road to Vostok}"
CFG="$USERDATA/mod_config.cfg"
BACKUP="$USERDATA/ltstest_backup"

[[ -d "$GAME/mods" ]] || { echo "ERROR: no mods folder at $GAME/mods"; exit 1; }
[[ -f "$CFG" ]] || { echo "ERROR: no $CFG (launch the loader once first)"; exit 1; }
if command -v tasklist >/dev/null 2>&1 && tasklist //FI "IMAGENAME eq RTV.exe" 2>/dev/null | grep -qi "rtv.exe"; then
    echo "ERROR: Road to Vostok is running; quit it first (the loader rewrites mod_config.cfg)"
    exit 1
fi
# A second run would back up the kit's own state over the player's.
if [[ -e "$BACKUP" ]]; then
    echo "ERROR: $BACKUP holds an earlier run's backup; run tests/ingame/lts/restore.sh first."
    exit 1
fi
if grep -qE '^\[profile\.LTS(Test|Temp)\.' "$CFG"; then
    echo "ERROR: $CFG already has a profile named LTSTest or LTSTemp; rename it first."
    exit 1
fi

# The loader rolls mod_config.cfg into .bak on every save, and a profile or pack switch
# moves MCM in and out of .profile_snapshots. The backup is renamed into place only when
# complete, so restore.sh never reads half of one; an item it lacks did not exist.
rm -rf "$BACKUP.partial"
mkdir "$BACKUP.partial"
for name in mod_config.cfg mod_config.cfg.bak MCM .profile_snapshots; do
    if [[ -e "$USERDATA/$name" ]]; then
        cp -a "$USERDATA/$name" "$BACKUP.partial/$name"
    fi
done
mv "$BACKUP.partial" "$BACKUP"
echo "backed up mod_config.cfg, its .bak, MCM and .profile_snapshots to $BACKUP"

zip_dir() {
    python -I - "$1" "$2" <<'EOF'
import os, sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as z:
    for root, _dirs, files in os.walk(src):
        for name in sorted(files):
            p = os.path.join(root, name)
            z.write(p, os.path.relpath(p, src).replace(os.sep, "/"))
print("wrote", dst)
EOF
}
zip_dir "$HERE/mods/LTSTestDep" "$GAME/mods/LTSTestDep.zip"
zip_dir "$HERE/mods/LTSTestCore" "$GAME/mods/LTSTestCore.zip"
# A modpack is a zip with profile.json at its root.
zip_dir "$HERE/fixtures/pack" "$GAME/mods/LTSTestPack.zip"

# A stale progress file would let the grader read an earlier run.
rm -f "$USERDATA/ltstest_core_progress.txt" "$USERDATA/ltstest_dep_progress.txt"

# The pack checks need no pack applied: the [settings] modpack keys go, the pack's
# modpack__ and _before_modpack_ sections stay. Profile LTSTest enables only the two
# test mods; every other installed mod has no entry and stays off. lts_core gets the
# lower priority, so only the dependency hoist can load lts_dep first.
python -I - "$CFG" <<'EOF'
import re, sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read().replace("\r\n", "\n")
line = 'active_profile="LTSTest"'
m = re.search(r'(?ms)^\[settings\]\n.*?(?=^\[|\Z)', t)
if m is None:
    t = "[settings]\n\n" + line + "\n\n" + t
else:
    body = m.group(0)
    pack = re.search(r'^active_modpack\s*=\s*"(.+)"\s*$', body, re.M)
    if pack:
        print('modpack "%s" unloaded for the run; restore.sh applies it again' % pack.group(1))
    body = re.sub(r'(?m)^(active_modpack|modpack_\w+)\s*=.*\n?', "", body)
    if re.search(r'^active_profile=.*$', body, re.M):
        body = re.sub(r'^active_profile=.*$', line, body, count=1, flags=re.M)
    else:
        body = "[settings]\n\n" + line + "\n" + body[len("[settings]\n"):].lstrip("\n")
    t = t[:m.start()] + body + t[m.end():]
t = t.rstrip("\n") + """

[profile.LTSTest.enabled]

lts_dep@1.0.0=true
lts_core@1.0.0=true

[profile.LTSTest.priority]

lts_dep@1.0.0=5
lts_core@1.0.0=0
"""
open(p, "w", encoding="utf-8", newline="\n").write(t)
print("profile LTSTest written and selected in", p)
EOF
echo "Now launch Road to Vostok and click Launch in the loader window. The game restarts"
echo "once and reaches the main menu; the launcher window opens and closes by itself while"
echo "the tests run. Wait for the menu to settle (about 30 s), quit, then run:"
echo "  python tests/ingame/lts/evaluate.py"
