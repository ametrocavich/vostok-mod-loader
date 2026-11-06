#!/usr/bin/env bash
# Mod identity harness: filename stems collapse repackaged duplicates without merging distinct mods.
# Usage: [GODOT=/path/to/godot] ./check_identity.sh [--prove], after ./build.sh.
set -uo pipefail
cd "$(dirname "$0")"
source tests/lib.sh

run_simple_check identity mod-identity tests/identity/runner.gd \
    "stem normalization removed" \
    $'\tvar m := _re_mod_stem_version.search(stem)' \
    $'\tvar m: RegExMatch = null  # --prove: stem normalization disabled (temp copy only)' \
    "$@"
