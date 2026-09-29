#!/usr/bin/env bash
# check_boot_state.sh -- exercise the boot-state files and the crash-loop
# breaker. Gate six of check.sh.
#
# tests/boot_state/runner.gd drives the real boot functions (_write_pass_state,
# _check_crash_recovery, _clear_restart_counter, _static_force_vanilla_state)
# and the real state files, in production order, and asserts the invariant the
# breaker provides: a crashed Pass 2 bumps the streak, the crash-recovery wipe
# leaves the streak alone, two consecutive crashes trip the breaker, and any
# clean finish resets it.
#
# What it cannot prove: that _run_pass_1 honors the tripped breaker. That
# decision is inline in a function that shows the launcher window, mounts
# archives and relaunches the process, so it cannot run headlessly. The one
# ordering fact the breaker depends on (the streak is not cleared before the
# crash window) is checked against the built source text instead, and the
# assertion says so.
#
# Needs no decompiled vanilla corpus and no network, so it runs anywhere and
# never skips. Never opens a window and never touches the game install:
# --headless only, against a throwaway project under the system temp dir. The
# harness writes its own user:// state and briefly writes override.cfg beside
# the Godot binary. It refuses to start if that override.cfg already exists;
# the breaker tests remove the file they create.
#
# Usage:
#   ./check_boot_state.sh              # build.sh must have run first
#   ./check_boot_state.sh --prove      # self-test: run the harness clean, then
#                                      #   neuter _clear_restart_counter in the
#                                      #   TEMP copy (never src/) and require
#                                      #   the harness to FAIL.
#   GODOT=/path/to/godot ./check_boot_state.sh

set -uo pipefail
cd "$(dirname "$0")"

PROVE=0
if [[ "${1:-}" == "--prove" ]]; then
    PROVE=1
fi

OUT=modloader.gd

# Same engine resolution as check.sh / check_codegen.sh / check_detok.sh /
# check_host.sh.
DEFAULT_GODOT="/c/Users/ametr/Downloads/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe"
GODOT="${GODOT:-}"
if [[ -z "$GODOT" ]]; then
    if command -v godot >/dev/null 2>&1; then
        GODOT=$(command -v godot)
    else
        GODOT="$DEFAULT_GODOT"
    fi
fi
if [[ ! -x "$GODOT" && ! -f "$GODOT" ]]; then
    echo "ERROR: Godot not found at: $GODOT (set GODOT=/path/to/godot)" >&2
    exit 127
fi

if [[ ! -f "$OUT" ]]; then
    echo "ERROR: $OUT not found -- run ./build.sh first." >&2
    exit 1
fi

start_s=$SECONDS

WORK="${TMPDIR:-/tmp}/modloader-boot-state-check"
rm -rf "$WORK"
mkdir -p "$WORK"

cp tests/boot_state/runner.gd "$WORK/runner.gd"

# config/name decides where user:// lands, so this harness gets its own
# app_userdata dir and can wipe it between tests without touching any other
# gate's scratch state.
cat > "$WORK/project.godot" <<'EOF'
config_version=5

[application]

config/name="modloader-boot-state-check"
EOF

# Neuter the modloader's static-init boot line, exactly as check_codegen.sh /
# check_detok.sh / check_host.sh do and for the same reason: instantiating
# modloader.gd would otherwise mount archives and rewrite override.cfg relative
# to the GODOT BINARY's directory. It matters more here than anywhere else --
# static init IS the boot sequence this harness drives by hand, and letting it
# run would trample the state files mid-test. Exact-line match, required
# exactly once, so drift fails loudly.
INIT_LINE='var _filescope_mounted: Dictionary = _mount_previous_session()'
n=$(grep -cxF "$INIT_LINE" "$OUT" || true)
if [[ "$n" -ne 1 ]]; then
    echo "ERROR: expected exactly 1 occurrence of the static-init initializer line" >&2
    echo "       in $OUT, found $n. boot.gd changed -- update INIT_LINE in" >&2
    echo "       check_boot_state.sh so the harness keeps neutering the right thing." >&2
    exit 1
fi
sed 's|^var _filescope_mounted: Dictionary = _mount_previous_session()$|var _filescope_mounted: Dictionary = {}  # boot-state-check: boot static-init neutralized (test copy only)|' \
    "$OUT" > "$WORK/modloader_neutered.gd"
if [[ $(grep -cxF "$INIT_LINE" "$WORK/modloader_neutered.gd" || true) -ne 0 ]]; then
    echo "ERROR: neutering failed -- initializer line still present in the test copy." >&2
    exit 1
fi

run_harness() {
    # $1 = log file
    "$GODOT" --headless --path "$WORK" --script res://runner.gd > "$1" 2>&1
}

show_log() {
    # $1 = log file
    awk '/\[boot-state\] harness start/{on=1} on' "$1" | grep -v '^Godot Engine v' | grep -v '^$'
}

if [[ $PROVE -eq 1 ]]; then
    # Phase 1: the unmutated build must PASS, or there is nothing to prove --
    # a harness that already fails would "fail with the mutation" for reasons
    # that have nothing to do with the mutation.
    run_harness "$WORK/run_baseline.log"
    base_status=$?
    if [[ $base_status -ne 0 ]]; then
        show_log "$WORK/run_baseline.log"
        elapsed=$((SECONDS - start_s))
        echo "INCONCLUSIVE: the harness already FAILS against the unmutated build (${elapsed}s)." >&2
        echo "              Fix the baseline failure first; --prove cannot demonstrate anything until then." >&2
        echo "              Full log: $WORK/run_baseline.log" >&2
        exit 1
    fi

    # Phase 2: break the clean-finish reset in the TEMP copy only, and demand
    # the harness FAIL. _clear_restart_counter is the one function that turns a
    # streak back to zero; with it gone, the breaker latches on forever and
    # T5's "a clean finish resets the streak" assertions must trip. The anchor
    # is the function's SIGNATURE line, which survives whatever the fix does to
    # the body (the streak may well move out of pass state entirely).
    SIG_LINE='func _clear_restart_counter() -> void:'
    if [[ $(grep -cxF "$SIG_LINE" "$WORK/modloader_neutered.gd" || true) -ne 1 ]]; then
        echo "ERROR: --prove could not find _clear_restart_counter's signature line to" >&2
        echo "       disable (expected exactly 1 occurrence). It was renamed -- update" >&2
        echo "       SIG_LINE in check_boot_state.sh." >&2
        exit 1
    fi
    perl -i -pe 's/^func _clear_restart_counter\(\) -> void:$/func _clear_restart_counter() -> void:\n\treturn  # --prove: clean-finish reset disabled (temp copy only)/' \
        "$WORK/modloader_neutered.gd"
    echo "--prove: disabled _clear_restart_counter in the TEMP modloader copy"

    run_harness "$WORK/run_prove.log"
    status=$?
    show_log "$WORK/run_prove.log"
    elapsed=$((SECONDS - start_s))
    if [[ $status -ne 0 ]]; then
        echo "PROVE-OK: harness FAILED as required with the clean-finish reset broken (${elapsed}s). Full log: $WORK/run_prove.log"
        exit 0
    fi
    echo "PROVE FAILED: the harness PASSED with _clear_restart_counter neutered." >&2
    echo "              The harness is a rubber stamp -- do not trust it." >&2
    exit 1
fi

run_harness "$WORK/run.log"
status=$?

show_log "$WORK/run.log"
elapsed=$((SECONDS - start_s))

# A script error inside a test function aborts that function without failing
# the run, and the assertions after it never execute. A green run logs none.
if [[ $status -eq 0 ]] && grep -q 'SCRIPT ERROR' "$WORK/run.log"; then
    echo "FAILED: the run exited 0 but logged a SCRIPT ERROR, so a test function stopped part-way:" >&2
    grep -m3 -A2 'SCRIPT ERROR' "$WORK/run.log" | sed 's/^/    /' >&2
    status=1
fi
if [[ $status -eq 0 ]]; then
    echo "OK: boot-state harness passed in ${elapsed}s (full log: $WORK/run.log)"
else
    echo "FAILED: boot-state harness (exit $status, ${elapsed}s). Full log: $WORK/run.log" >&2
fi
exit $status
