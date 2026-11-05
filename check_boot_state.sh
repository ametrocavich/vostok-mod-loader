#!/usr/bin/env bash
# Boot-state and crash-loop breaker harness (not _run_pass_1); refuses an override.cfg beside Godot.
# Usage: [GODOT=/path/to/godot] ./check_boot_state.sh [--prove], after ./build.sh.
set -uo pipefail
cd "$(dirname "$0")"
source tests/lib.sh

# The needle is the signature line, which survives any rewrite of the body.
run_simple_check --baseline-first boot-state boot-state tests/boot_state/runner.gd \
    "the clean-finish reset broken" \
    'func _clear_restart_counter() -> void:' \
    $'func _clear_restart_counter() -> void:\n\treturn  # --prove: clean-finish reset disabled (temp copy only)' \
    "$@"
