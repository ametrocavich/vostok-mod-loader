#!/usr/bin/env bash
# Mods harness: discovery, identity, load order, downloads and updates; no network.
# Usage: [GODOT=/path/to/godot] ./check_mods.sh [--prove], after ./build.sh.
set -uo pipefail
cd "$(dirname "$0")"
source tests/lib.sh

run_simple_check mods mods tests/mods/runner.gd \
    "the extension rule broken" \
    $'\treturn name.get_extension().to_lower() in MOD_ARCHIVE_EXTENSIONS' \
    $'\treturn true  # --prove: extension rule disabled (temp copy only)' \
    "$@"
