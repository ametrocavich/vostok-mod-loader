# Sourced by check.sh and check_*.sh from the repo root; sets GODOT, WORK, status, PYTHON, VANILLA_SRC.
# run_simple_check TAG LABEL RUNNER BROKEN OLD NEW "$@" is a whole check script; the rest are its parts.

OUT=modloader.gd

# The one static-init line that runs the boot sequence. It mounts archives and
# rewrites override.cfg relative to OS.get_executable_path(), the GODOT binary.
INIT_LINE='var _filescope_mounted: Dictionary = _mount_previous_session()'

# check_env_value NAME: NAME from the untracked .check.env, read in a subshell
# so it never overrides the caller's environment.
check_env_value() {
    [[ -f .check.env ]] || return 0
    (
        unset GODOT VANILLA_SRC
        # shellcheck disable=SC1091
        source ./.check.env >/dev/null
        printf '%s' "${!1:-}"
    )
}

# find_godot: GODOT, then `godot` on PATH, then .check.env. On Windows use the
# _console build: the plain .exe detaches and its output never reaches us.
find_godot() {
    GODOT="${GODOT:-}"
    if [[ -z "$GODOT" ]]; then
        if command -v godot >/dev/null 2>&1; then
            GODOT=$(command -v godot)
        else
            GODOT=$(check_env_value GODOT)
        fi
    fi
    if [[ -z "$GODOT" || ( ! -x "$GODOT" && ! -f "$GODOT" ) ]]; then
        echo "ERROR: Godot not found${GODOT:+ at: $GODOT}" >&2
        echo "Set GODOT=/path/to/godot (or put it in .check.env) and re-run." >&2
        exit 127
    fi
}

# find_python: PYTHON, else the first of python, python3 that is 3.9 or newer.
find_python() {
    if [[ -z "${PYTHON:-}" ]]; then
        local candidate
        for candidate in python python3; do
            if command -v "$candidate" >/dev/null 2>&1 && \
                    "$candidate" -c 'import sys; sys.exit(sys.version_info < (3, 9))' >/dev/null 2>&1; then
                PYTHON="$candidate"
                break
            fi
        done
    fi
    if [[ -z "${PYTHON:-}" ]]; then
        echo "FAILED: Python 3.9+ is required; set PYTHON." >&2
        exit 1
    fi
}

require_build() {
    if [[ ! -f "$OUT" ]]; then
        echo "ERROR: $OUT not found -- run ./build.sh first." >&2
        exit 1
    fi
}

# make_project NAME [RUNNER]: a fresh project at $WORK with RUNNER as
# res://runner.gd and tests/common/*.gd beside it. config/name picks user://.
make_project() {
    WORK="${TMPDIR:-/tmp}/$1"
    rm -rf "$WORK"
    mkdir -p "$WORK"
    printf 'config_version=5\n\n[application]\n\nconfig/name="%s"\n' "$1" > "$WORK/project.godot"
    if [[ -n "${2:-}" ]]; then
        cp "$2" "$WORK/runner.gd"
        cp tests/common/*.gd "$WORK/"
    fi
}

# find_vanilla_src: VANILLA_SRC from the environment or .check.env, and
# SYNTHETIC_ONLY=1 when it holds no decompiled Scripts/.
find_vanilla_src() {
    VANILLA_SRC="${VANILLA_SRC:-$(check_env_value VANILLA_SRC)}"
    SYNTHETIC_ONLY=0
    if [[ -z "$VANILLA_SRC" || ! -d "$VANILLA_SRC/Scripts" ]]; then
        SYNTHETIC_ONLY=1
        if [[ -z "$VANILLA_SRC" ]]; then
            echo "NOTE: VANILLA_SRC is not set (environment or .check.env);"
        else
            echo "NOTE: no decompiled vanilla source at $VANILLA_SRC/Scripts"
            echo "      (override with VANILLA_SRC=...);"
        fi
        echo "      running the synthetic fixtures only."
    elif [[ ! -f "$VANILLA_SRC/.godot/global_script_class_cache.cfg" ]]; then
        echo "ERROR: $VANILLA_SRC/.godot/global_script_class_cache.cfg missing -- the" >&2
        echo "       harness reuses the game's own class_name cache verbatim." >&2
        exit 1
    fi
}

# stub_preloads: an empty .tres or .tscn in $WORK for every preload() target of
# $WORK/Scripts/*.gd, so pristine vanilla compiles; any other type is an error.
stub_preloads() {
    local list="$WORK/preload_paths.txt" p tgt
    grep -hoE 'preload\("res://[^"]+"' "$WORK"/Scripts/*.gd | sed 's/^preload("//; s/"$//' | sort -u > "$list"
    sed "s|^res://|$WORK/|" "$list" | xargs -r -d '\n' -n 64 dirname | sort -u | tr '\n' '\0' | xargs -0 -r mkdir -p
    while IFS= read -r p; do
        tgt="$WORK/${p#res://}"
        [[ -f "$tgt" ]] && continue
        case "$p" in
            *.tres) printf '[gd_resource type="Resource" format=3]\n\n[resource]\n' > "$tgt" ;;
            *.tscn) printf '[gd_scene format=3]\n\n[node name="Root" type="Node"]\n' > "$tgt" ;;
            *)
                echo "ERROR: unstubbable preload target in vanilla corpus: $p" >&2
                echo "       Extend stub_preloads in tests/lib.sh." >&2
                exit 1
                ;;
        esac
    done < "$list"
}

# neuter_loader: $WORK/modloader_neutered.gd with INIT_LINE's initializer
# replaced by {}. The line must occur exactly once, or boot code would run.
neuter_loader() {
    local n
    n=$(grep -cxF "$INIT_LINE" "$OUT" || true)
    if [[ "$n" -ne 1 ]]; then
        echo "ERROR: expected exactly 1 occurrence of the static-init initializer line" >&2
        echo "       in $OUT, found $n. boot.gd changed -- update INIT_LINE in" >&2
        echo "       tests/lib.sh so the harnesses keep neutering the right thing." >&2
        exit 1
    fi
    sed 's|^var _filescope_mounted: Dictionary = _mount_previous_session()$|var _filescope_mounted: Dictionary = {}  # check: boot static-init neutralized (test copy only)|' \
        "$OUT" > "$WORK/modloader_neutered.gd"
    if [[ $(grep -cxF "$INIT_LINE" "$WORK/modloader_neutered.gd" || true) -ne 0 ]]; then
        echo "ERROR: neutering failed -- initializer line still present in the test copy." >&2
        exit 1
    fi
}

# mutate_line WHAT OLD NEW: replace the one line of the test copy equal to OLD
# with NEW (may span lines). A missing or repeated OLD fails loudly.
mutate_line() {
    local what="$1" old="$2" new="$3" f="$WORK/modloader_neutered.gd"
    if [[ $(grep -cxF -- "$old" "$f" || true) -ne 1 ]]; then
        echo "ERROR: --prove could not find $what to change (expected exactly one line:" >&2
        echo "       $old" >&2
        echo "       ). The source changed shape -- update the --prove line in $0." >&2
        exit 1
    fi
    OLD="$old" NEW="$new" awk '$0 == ENVIRON["OLD"] { print ENVIRON["NEW"]; next } { print }' \
        "$f" > "$f.mutated"
    if cmp -s "$f" "$f.mutated"; then
        echo "ERROR: --prove substitution for $what did not apply." >&2
        exit 1
    fi
    mv "$f.mutated" "$f"
}

# mutate_all NEEDLE COUNT PERL_EXPR: apply PERL_EXPR to the test copy, which
# must hold NEEDLE COUNT times before and never after.
mutate_all() {
    local needle="$1" want="$2" expr="$3" f="$WORK/modloader_neutered.gd" have
    have=$(grep -cF -- "$needle" "$f" || true)
    if [[ "$have" -ne "$want" ]]; then
        echo "ERROR: --prove expected $want occurrence(s) of '$needle' in the loader," >&2
        echo "       found $have. The template drifted -- update $0." >&2
        exit 1
    fi
    perl -i -pe "$expr" "$f"
    if [[ $(grep -cF -- "$needle" "$f" || true) -ne 0 ]]; then
        echo "ERROR: --prove mutation did not apply ('$needle' still present)." >&2
        exit 1
    fi
}

# run_runner [LOG]: run res://runner.gd headless in $WORK; returns its exit.
run_runner() {
    "$GODOT" --headless --path "$WORK" --script res://runner.gd > "${1:-$WORK/run.log}" 2>&1
}

# show_log TAG [LOG]: LOG from the "[TAG] harness start" marker on, without
# blank lines and the engine banner.
show_log() {
    awk -v start="[$1] harness start" 'index($0, start) { on = 1 } on' "${2:-$WORK/run.log}" \
        | grep -v '^Godot Engine v' | grep -v '^$'
}

# script_error_guard [LOG]: a script error aborts its test function without
# failing the run, so the assertions after it never ran; it turns 0 into 1.
script_error_guard() {
    local log="${1:-$WORK/run.log}"
    if [[ $status -eq 0 ]] && grep -q 'SCRIPT ERROR' "$log"; then
        echo "FAILED: the run exited 0 but logged a SCRIPT ERROR, so a test function stopped part-way:" >&2
        grep -m3 -A2 'SCRIPT ERROR' "$log" | sed 's/^/    /' >&2
        status=1
    fi
}

# report_result LABEL [DETAIL] [--allow-script-errors]: the OK or FAILED line
# for $status, then exit with it. Codegen allows script errors (decompiled game).
report_result() {
    local label="" detail="" guard=1 arg
    for arg in "$@"; do
        if [[ "$arg" == "--allow-script-errors" ]]; then
            guard=0
        elif [[ -z "$label" ]]; then
            label="$arg"
        else
            detail=", $arg"
        fi
    done
    [[ $guard -eq 1 ]] && script_error_guard
    if [[ $status -eq 0 ]]; then
        echo "OK: $label harness passed in ${SECONDS}s$detail (full log: $WORK/run.log)"
    else
        echo "FAILED: $label harness (exit $status, ${SECONDS}s). Full log: $WORK/run.log" >&2
        if [[ $status -gt 128 ]]; then
            echo "  The engine died on signal $((status - 128)); the log ends:" >&2
            tail -n 60 "$WORK/run.log" | sed 's/^/    /' >&2
        fi
    fi
    exit "$status"
}

# report_prove WHAT [LOG]: a --prove run must have FAILED with WHAT in place.
report_prove() {
    local log="${2:-$WORK/run.log}"
    if [[ $status -ne 0 ]]; then
        echo "PROVE-OK: harness FAILED as required with $1 (${SECONDS}s). Full log: $log"
        exit 0
    fi
    echo "PROVE FAILED: the harness PASSED with $1." >&2
    echo "              The harness is a rubber stamp -- do not trust it." >&2
    exit 1
}

# prove_mutation SETUP LABEL NEEDLE COUNT PERL_EXPR MARKER: run SETUP (a function
# that rebuilds $WORK), mutate, run; the log must name MARKER after "FAIL" or "FAIL:".
prove_runs=0
prove_failed=0
prove_mutation() {
    local setup="$1" label="$2" needle="$3" want="$4" expr="$5" marker="$6" pattern
    pattern="FAIL:? $marker([^0-9A-Za-z]|$)"
    prove_runs=$((prove_runs + 1))
    "$setup"
    mutate_all "$needle" "$want" "$expr"
    echo "--prove [$label]: mutated the TEMP loader copy"
    run_runner
    if [[ $? -eq 0 ]]; then
        echo "PROVE FAILED [$label]: the harness PASSED with the behavior broken." >&2
        prove_failed=1
    elif ! grep -qE -- "$pattern" "$WORK/run.log"; then
        echo "PROVE FAILED [$label]: the harness failed, but not on $marker. See $WORK/run.log" >&2
        prove_failed=1
    else
        echo "PROVE-OK [$label]: harness FAILED on $marker as required:"
        grep -E -- "$pattern" "$WORK/run.log" | head -2 | sed 's/^/    /'
    fi
}

# report_proves: the end of a run of prove_mutation calls; exits.
report_proves() {
    if [[ $prove_failed -eq 0 ]]; then
        echo "PROVE-OK: all $prove_runs mutations caught by their guarding tests (${SECONDS}s total)"
        exit 0
    fi
    echo "PROVE FAILED: see above (${SECONDS}s total)" >&2
    exit 1
}

# run_simple_check [--baseline-first] TAG LABEL RUNNER BROKEN OLD NEW [--prove]:
# a whole check script. Project modloader-TAG-check, log marker [TAG]; --prove
# replaces line OLD with NEW and demands a failure ("BROKEN" names the change).
# --baseline-first runs the unmutated build first and stops if it already fails.
run_simple_check() {
    local baseline=0 prove=0
    if [[ "$1" == "--baseline-first" ]]; then
        baseline=1
        shift
    fi
    local tag="$1" label="$2" runner="$3" broken="$4" old="$5" new="$6"
    [[ "${7:-}" == "--prove" ]] && prove=1
    find_godot
    require_build
    make_project "modloader-$tag-check" "$runner"
    neuter_loader
    if [[ $prove -eq 0 ]]; then
        run_runner
        status=$?
        show_log "$tag"
        report_result "$label"
    fi
    local log="$WORK/run.log"
    if [[ $baseline -eq 1 ]]; then
        run_runner "$WORK/run_baseline.log"
        if [[ $? -ne 0 ]]; then
            show_log "$tag" "$WORK/run_baseline.log"
            echo "INCONCLUSIVE: the harness already FAILS against the unmutated build (${SECONDS}s)." >&2
            echo "              Fix the baseline failure first; --prove cannot demonstrate anything until then." >&2
            echo "              Full log: $WORK/run_baseline.log" >&2
            exit 1
        fi
        log="$WORK/run_prove.log"
    fi
    mutate_line "the --prove line for $broken" "$old" "$new"
    echo "--prove: $broken in the TEMP modloader copy"
    run_runner "$log"
    status=$?
    show_log "$tag" "$log"
    report_prove "$broken" "$log"
}
