#!/usr/bin/env bash
# Compiles the rewriter's output for the 3 synthetic and, with VANILLA_SRC, 10 vanilla fixtures.
# --prove puts the unconditional wrapper await back into the temp loader copy and must fail.
set -uo pipefail
cd "$(dirname "$0")"
source tests/lib.sh

PROVE=0
[[ "${1:-}" == "--prove" ]] && PROVE=1
find_godot
require_build
find_vanilla_src

make_project modloader-codegen-check tests/codegen/runner.gd
mkdir -p "$WORK/Scripts" "$WORK/.godot"
if [[ $SYNTHETIC_ONLY -eq 1 ]]; then
    : > "$WORK/synthetic_only"
else
    cp "$VANILLA_SRC"/Scripts/*.gd "$WORK/Scripts/"
    cp "$VANILLA_SRC/.godot/global_script_class_cache.cfg" "$WORK/.godot/"
    # The game's autoloads, which the analyzer resolves by name.
    cat >> "$WORK/project.godot" <<'GODOT'

[autoload]

Loader="*res://Scripts/Loader.gd"
Database="*res://Scripts/Database.gd"
Simulation="*res://Scripts/Simulation.gd"
GODOT
fi
cp tests/codegen/Fixture*.gd "$WORK/Scripts/"
stub_preloads
neuter_loader

if [[ $PROVE -eq 1 ]]; then
    mutate_line "the aw template line" \
        $'\tvar aw: String = "await " if is_coro else ""' \
        $'\tvar aw: String = "await "  # --prove: 3.3.0 unconditional-await regression reintroduced (temp copy only)'
    echo "--prove: reintroduced the unconditional await in the TEMP modloader copy"
fi

run_runner
status=$?
# The autoloads print missing-node noise before the harness marker.
show_log codegen
[[ $PROVE -eq 1 ]] && report_prove "the regression present"
# Decompiled game scripts log parse errors outside the game, so script errors are allowed.
if [[ $SYNTHETIC_ONLY -eq 1 ]]; then
    report_result codegen "synthetic fixtures only" --allow-script-errors
fi
report_result codegen --allow-script-errors
