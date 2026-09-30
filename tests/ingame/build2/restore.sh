#!/usr/bin/env bash
# Undo install.sh: remove the test mod zips and put mod_config.cfg back.
set -euo pipefail
GAME="${GAME:-/c/Program Files (x86)/Steam/steamapps/common/Road to Vostok}"
USERDATA="${USERDATA:-$APPDATA/Road to Vostok}"
CFG="$USERDATA/mod_config.cfg"
rm -f "$GAME/mods/B2TestRegistry.zip" "$GAME/mods/B2TestHooks.zip"
if [[ -f "$CFG.b2backup" ]]; then
    mv -f "$CFG.b2backup" "$CFG"
    echo "restored $CFG"
fi
echo "test mods removed"
