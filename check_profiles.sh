#!/usr/bin/env bash
# Profiles harness: profiles, modpack slots and the MCM snapshots beside them; no network.
# Usage: [GODOT=/path/to/godot] ./check_profiles.sh [--prove], after ./build.sh.
set -uo pipefail
cd "$(dirname "$0")"
source tests/lib.sh

run_simple_check profiles profiles tests/profiles/runner.gd \
    "the profile-name strip broken" \
    $'\treturn out.strip_edges()' \
    $'\treturn out  # --prove: final strip disabled (temp copy only)' \
    "$@"
