#!/usr/bin/env bash
# check_dispatch.sh -- prove the generated hook wrappers DISPATCH correctly
# at runtime, with the real engine.
#
# Why this exists: check.sh proves the built loader parses; check_codegen.sh
# proves the rewriter's output COMPILES. Neither proves it BEHAVES. A wrapper
# can compile perfectly and still call the wrong callback, in the wrong
# order, with the wrong arguments, drop a post hook's result mutation, or
# ignore skip_super() -- the loader's entire value proposition (mods hooking
# vanilla methods) with no automated check on it. This harness closes that
# gap: it instantiates the (neutered) loader, runs the REAL rewriter over a
# synthetic fixture, attaches the rewritten script to real Nodes, registers
# hooks through the REAL public API (Engine.get_meta("RTVModLib").hook(...)),
# CALLS the wrapped methods, and asserts on the recorded execution order.
#
# Behaviors covered (contract: docs/wiki/Hooks.md + src/hooks_api.gd; test
# ids T1..T12 in tests/codegen/dispatch_runner.gd):
#   T1  -pre fires before vanilla, with the vanilla arguments
#   T2  replace: before vanilla; vanilla's return wins unless skip_super(),
#       which suppresses vanilla and promotes the callback's return
#   T3  -post: trailing _result, non-null replaces / null passes through,
#       legacy 2-arg observer form, ascending-priority chaining
#   T4  -callback fires deferred, after the method returned
#   T5  pre -> replace-or-vanilla -> post -> deferred; ascending priority
#   T6  replace slot single-owner (second registration -1, first still runs)
#   T7  unhook(id) stops that callback, leaves others intact
#   T8  _lib._caller correct + restored around nested wrapped calls
#   T9  re-entrancy: no recursive dispatch, and the guard key is RELEASED
#       (a leaked key would permanently disable the hook for that instance)
#   T10 two instances of one wrapped script dispatch independently
#   T11 coroutine vanilla methods still await and return their value
#   T12 defaulted parameters flow through when omitted
#
# Unlike check_codegen.sh this needs NO decompiled vanilla source -- the
# fixture is synthetic -- so it runs on every machine with a Godot binary
# and never skips.
#
# NEUTERING: identical recipe to check_codegen.sh (see its header for the
# full rationale). modloader.gd's single static-init boot line
#     var _filescope_mounted: Dictionary = _mount_previous_session()
# is replaced by `= {}` in a TEMP copy, asserted to occur exactly once so
# drift in constants.gd fails loudly; the runner double-checks no boot code
# ran. This NEVER opens a window and NEVER touches the game install:
# --headless only, against a throwaway project under the system temp dir.
#
# Usage:
#   ./check_dispatch.sh             # build.sh must have run first
#   ./check_dispatch.sh --prove     # self-test: three separate mutations of
#                                   #   the TEMP loader copy (never src/),
#                                   #   each must make the harness FAIL on
#                                   #   the specific behavior it breaks:
#                                   #   A. skip_super ignored        -> T2b
#                                   #   B. post result mutation lost -> T3a
#                                   #   C. re-entrancy guard leaks   -> T9
#   GODOT=/path/to/godot ./check_dispatch.sh

set -uo pipefail
cd "$(dirname "$0")"

PROVE=0
if [[ "${1:-}" == "--prove" ]]; then
    PROVE=1
fi

OUT=modloader.gd

# Same engine resolution as check.sh.
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
WORK="${TMPDIR:-/tmp}/modloader-dispatch-check"

# Assemble the throwaway project. Rebuilt from scratch on every call so a
# stale copy (or a previous run's mutation) can never be what gets checked.
prepare_work() {
    rm -rf "$WORK"
    mkdir -p "$WORK/Scripts"
    cp tests/codegen/FixtureDispatch.gd "$WORK/Scripts/"
    cp tests/codegen/dispatch_runner.gd "$WORK/runner.gd"
    printf 'config_version=5\n\n[application]\n\nconfig/name="modloader-dispatch-check"\n' > "$WORK/project.godot"

    # Neuter the modloader's static-init boot line (see the header). Exact-line
    # match, required to appear exactly once -- fails loudly on drift.
    local INIT_LINE='var _filescope_mounted: Dictionary = _mount_previous_session()'
    local n
    n=$(grep -cxF "$INIT_LINE" "$OUT" || true)
    if [[ "$n" -ne 1 ]]; then
        echo "ERROR: expected exactly 1 occurrence of the static-init initializer line" >&2
        echo "       in $OUT, found $n. constants.gd changed -- update INIT_LINE in" >&2
        echo "       check_dispatch.sh so the harness keeps neutering the right thing." >&2
        exit 1
    fi
    sed 's|^var _filescope_mounted: Dictionary = _mount_previous_session()$|var _filescope_mounted: Dictionary = {}  # dispatch-check: boot static-init neutralized (test copy only)|' \
        "$OUT" > "$WORK/modloader_neutered.gd"
    if [[ $(grep -cxF "$INIT_LINE" "$WORK/modloader_neutered.gd" || true) -ne 0 ]]; then
        echo "ERROR: neutering failed -- initializer line still present in the test copy." >&2
        exit 1
    fi
}

# Mutate the TEMP loader copy. $1 = perl -pe expression, $2 = substring the
# expression targets, $3 = how many times that substring must exist BEFORE
# mutation (so template drift in rewriter.gd fails loudly instead of the
# mutation silently matching nothing and the prove run rubber-stamping).
mutate() {
    local expr="$1" needle="$2" want="$3"
    local have
    have=$(grep -cF "$needle" "$WORK/modloader_neutered.gd" || true)
    if [[ "$have" -ne "$want" ]]; then
        echo "ERROR: --prove expected $want occurrence(s) of '$needle' in the loader," >&2
        echo "       found $have. The wrapper template drifted -- update check_dispatch.sh." >&2
        exit 1
    fi
    perl -i -pe "$expr" "$WORK/modloader_neutered.gd"
    if [[ $(grep -cF "$needle" "$WORK/modloader_neutered.gd" || true) -ne 0 ]]; then
        echo "ERROR: --prove mutation did not apply ('$needle' still present)." >&2
        exit 1
    fi
}

run_harness() {
    "$GODOT" --headless --path "$WORK" --script res://runner.gd > "$WORK/run.log" 2>&1
    return $?
}

show_log() {
    awk '/\[dispatch\] harness start/{on=1} on' "$WORK/run.log" | grep -v '^Godot Engine v' | grep -v '^$'
}

if [[ $PROVE -eq 0 ]]; then
    prepare_work
    run_harness
    status=$?
    show_log
    elapsed=$((SECONDS - start_s))
    if [[ $status -eq 0 ]]; then
        echo "OK: dispatch harness passed in ${elapsed}s (full log: $WORK/run.log)"
    else
        echo "FAILED: dispatch harness (exit $status, ${elapsed}s). Full log: $WORK/run.log" >&2
    fi
    exit $status
fi

# ---------------------------------------------------------------------------
# --prove: three separate runs, each with ONE behavior broken in the TEMP
# loader copy. Every run must FAIL, and the log must name the test that
# guards that exact behavior -- otherwise the harness is a rubber stamp.
# ---------------------------------------------------------------------------
prove_failed=0

# Each entry: label | perl mutation | pre-mutation needle | needle count |
# test marker that must appear in the failing log.
run_prove() {
    local label="$1" expr="$2" needle="$3" want="$4" marker="$5"
    prepare_work
    mutate "$expr" "$needle" "$want"
    echo "--prove [$label]: mutated the TEMP loader copy"
    run_harness
    local status=$?
    if [[ $status -eq 0 ]]; then
        echo "PROVE FAILED [$label]: the harness PASSED with the behavior broken." >&2
        echo "                       That assertion is a rubber stamp -- do not trust it." >&2
        prove_failed=1
        return
    fi
    if ! grep -qF "FAIL $marker" "$WORK/run.log"; then
        echo "PROVE FAILED [$label]: the harness failed, but NOT on $marker (the test" >&2
        echo "                       guarding this behavior). See $WORK/run.log" >&2
        prove_failed=1
        return
    fi
    echo "PROVE-OK [$label]: harness FAILED on $marker as required:"
    grep -F "FAIL $marker" "$WORK/run.log" | head -2 | sed 's/^/    /'
}

# A. skip_super ignored: the wrapper template's _did_skip capture is forced
#    false, so vanilla always runs and the replace return is discarded.
run_prove "skip_super ignored" \
    's/var _did_skip = _lib\._skip_super/var _did_skip = false/g' \
    'var _did_skip = _lib._skip_super' 2 \
    'T2b'

# B. post-hook result mutation dropped: the template still CALLS
#    _dispatch_post (observers fire) but discards its return.
run_prove "post result mutation dropped" \
    's/_result = _lib\._dispatch_post/var _rtv_mut_ignored = _lib._dispatch_post/' \
    '_result = _lib._dispatch_post' 1 \
    'T3a'

# C. re-entrancy guard leaks its key: the erase at the end of the wrapper
#    becomes a read, so the first dispatch permanently disables hooks for
#    that (instance, method) pair.
run_prove "re-entrancy guard leaks" \
    's/_lib\._wrapper_active\.erase\(_rtv_wa_key\)/_lib._wrapper_active.get(_rtv_wa_key)/g' \
    '_lib._wrapper_active.erase(_rtv_wa_key)' 2 \
    'T9'

elapsed=$((SECONDS - start_s))
if [[ $prove_failed -eq 0 ]]; then
    echo "PROVE-OK: all 3 mutations caught by their guarding tests (${elapsed}s total)"
    exit 0
fi
echo "PROVE FAILED: see above (${elapsed}s total)" >&2
exit 1
