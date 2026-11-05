#!/usr/bin/env bash
# Host-seam harness: normalizers, provider:id grammar, [updates] source format; no network.
# Usage: [GODOT=/path/to/godot] ./check_host.sh [--prove], after ./build.sh.
set -uo pipefail
cd "$(dirname "$0")"
source tests/lib.sh

run_simple_check host host-seam tests/host/runner.gd \
    "the mirror rule broken" \
    $'\tif str(rec.get("provider", "")) != HOST_MODWORKSHOP:' \
    $'\tif false:  # --prove: mirror rule disabled (temp copy only)' \
    "$@"
