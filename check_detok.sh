#!/usr/bin/env bash
# GDSC detokenizer harness on synthetic v100/v101 bytecode; only canary C checks a real .gdc.
# Usage: [GODOT=/path/to/godot] ./check_detok.sh [--prove], after ./build.sh.
set -uo pipefail
cd "$(dirname "$0")"
source tests/lib.sh

run_simple_check detok detokenizer tests/detok/runner.gd \
    "the v100 normalization removed" \
    $'\t\tif version == GDSC_VERSION_V100 and tk_type >= _GDSC_V100_SHIFT_FROM:' \
    $'\t\tif false:  # --prove: v100 index normalization disabled (temp copy only)' \
    "$@"
