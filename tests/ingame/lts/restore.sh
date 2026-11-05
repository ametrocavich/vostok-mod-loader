#!/usr/bin/env bash
# Undo install.sh: put mod_config.cfg, its .bak, MCM and .profile_snapshots back from the
# kit backup, then remove the zips and progress files. Safe to run twice; never launches the game.
set -euo pipefail
GAME="${GAME:-/c/Program Files (x86)/Steam/steamapps/common/Road to Vostok}"
USERDATA="${USERDATA:-$APPDATA/Road to Vostok}"
BACKUP="$USERDATA/ltstest_backup"

if command -v tasklist >/dev/null 2>&1 && tasklist //FI "IMAGENAME eq RTV.exe" 2>/dev/null | grep -qi "rtv.exe"; then
    echo "ERROR: Road to Vostok is running; quit it first (the loader rewrites mod_config.cfg)"
    exit 1
fi
# Left by an install.sh that stopped while copying; the live files were not touched yet.
rm -rf "$BACKUP.partial"
if [[ ! -d "$BACKUP" ]]; then
    echo "no kit backup at $BACKUP; nothing to restore"
    exit 0
fi

# An item the backup lacks did not exist before the run. The backup goes last, so an
# interrupted restore can run again.
for name in mod_config.cfg mod_config.cfg.bak MCM .profile_snapshots; do
    if [[ -e "$BACKUP/$name" ]]; then
        rm -rf "${USERDATA:?}/$name"
        cp -a "$BACKUP/$name" "$USERDATA/$name"
        echo "restored $name"
    elif [[ -e "$USERDATA/$name" ]]; then
        rm -rf "${USERDATA:?}/$name"
        echo "removed $name (the run created it)"
    fi
done

rm -f "$GAME/mods/LTSTestDep.zip" "$GAME/mods/LTSTestCore.zip" "$GAME/mods/LTSTestPack.zip"
echo "test mods and test pack removed from $GAME/mods"
rm -f "$USERDATA/ltstest_core_progress.txt" "$USERDATA/ltstest_dep_progress.txt"
rm -rf "$BACKUP"
echo "done"
