#!/usr/bin/env bash
# check_codegen.sh -- COMPILE the rewriter's generated output with the real
# GDScript compiler, against real vanilla game source.
#
# Why this exists: the loader rewrites vanilla scripts by string manipulation
# (src/rewriter.gd) and the result was historically never compiled outside a
# running game. 3.3.0 shipped a one-character-class bug -- an unconditional
# `await` in a wrapper template -- that made every wrapped vanilla method a
# coroutine and broke every third-party mod calling them AT PARSE TIME.
# check.sh's grep invariants pin that exact template line; THIS harness runs
# the real rewriter over real vanilla scripts and compiles what comes out,
# so the whole bug class (not just the known instance) fails the build.
#
# Pipeline (details in tests/codegen/runner.gd):
#   1. Assemble a THROWAWAY Godot project under the system temp dir:
#      decompiled vanilla Scripts/*.gd, the game's own global class cache,
#      generated stub .tres/.tscn for every preload() target, the game's
#      three autoload singletons pointed at the copied scripts, the
#      synthetic tests/codegen/Fixture*.gd, and a NEUTERED copy of the
#      built modloader.gd (see below).
#   2. Run runner.gd headless in that project. Per fixture it compiles the
#      pristine source (baseline), rewrites it with the real
#      _rtv_rewrite_vanilla_source (wrap-all AND masked), asserts output
#      properties (no await in non-coroutine wrappers, body preserved under
#      _rtv_vanilla_<name>, wrapper signature byte-identical, masked set
#      exact), recompiles the rewritten file at its canonical path, and
#      compiles a generated CALLER stub that invokes every wrapped method
#      without `await` -- the call-site check that actually catches a
#      wrapper silently becoming a coroutine.
#
# WHY LOADING THE MODLOADER HERE IS SAFE: merely instantiating modloader.gd
# executes its boot sequence, because constants.gd declares
#     var _filescope_mounted: Dictionary = _mount_previous_session()
# and _mount_previous_session() mounts archives, rewrites override.cfg and
# wipes hook caches relative to OS.get_executable_path() -- which in a test
# is the GODOT BINARY's directory. This script therefore builds
# modloader_neutered.gd: a byte-identical copy with that ONE initializer
# mechanically replaced by `= {}` (verified to match exactly once, so the
# harness fails loudly if constants.gd drifts). No boot code can run; the
# runner double-checks _filescope_mounted is empty after new().
#
# HOW TO ADD A FIXTURE:
#   - Real vanilla script: add {"file": "Name.gd"} to FIXTURES in
#     tests/codegen/runner.gd. The script must compile PRISTINE in the
#     harness project (the baseline step tells you if it does not -- usually
#     a preload of an asset type this script cannot stub, or a missing
#     autoload). Add a "mask": [...] entry to also exercise the partial
#     rename path. If the rewriter modifies the method's body on purpose
#     (prelude injection), list it in BODY_MODIFIED.
#   - Synthetic script: drop a FixtureName.gd in tests/codegen/ (it is
#     copied into res://Scripts/), add it to FIXTURES. Use
#     {"baseline": false} if the pristine source is intentionally invalid
#     (legacy-autofix fixtures).
#
# Usage:
#   ./check_codegen.sh              # build.sh must have run first
#   ./check_codegen.sh --prove      # self-test: reintroduce the 3.3.0
#                                   #   unconditional await in the TEMP copy
#                                   #   (never src/) and require the harness
#                                   #   to FAIL; exits 0 only if it did
#   GODOT=... VANILLA_SRC=... ./check_codegen.sh   # override paths
#
# This NEVER opens a window and NEVER touches the game install: --headless
# only, against the throwaway project. If the decompiled vanilla source is
# not present on this machine the harness SKIPS (exit 0) with a banner, so
# check.sh still works for contributors without it.

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

# Decompiled vanilla game source (plain .gd) -- the input corpus.
VANILLA_SRC="${VANILLA_SRC:-/c/Users/ametr/Documents/Road to Vostok}"
if [[ ! -d "$VANILLA_SRC/Scripts" ]]; then
    echo "SKIPPED: codegen compile harness needs the decompiled vanilla source at:"
    echo "         $VANILLA_SRC/Scripts  (override with VANILLA_SRC=...)"
    echo "         Machines without it skip this check; the template grep invariants"
    echo "         in check.sh still apply."
    exit 0
fi
if [[ ! -f "$VANILLA_SRC/.godot/global_script_class_cache.cfg" ]]; then
    echo "ERROR: $VANILLA_SRC/.godot/global_script_class_cache.cfg missing -- the" >&2
    echo "       harness reuses the game's own class_name cache verbatim." >&2
    exit 1
fi

start_s=$SECONDS

# Throwaway project outside the repo. Rebuilt every run so a stale copy can
# never be what gets checked.
WORK="${TMPDIR:-/tmp}/modloader-codegen-check"
rm -rf "$WORK"
mkdir -p "$WORK/Scripts" "$WORK/.godot" "$WORK/callers"

cp "$VANILLA_SRC"/Scripts/*.gd "$WORK/Scripts/"
cp "$VANILLA_SRC/.godot/global_script_class_cache.cfg" "$WORK/.godot/"
cp tests/codegen/Fixture*.gd "$WORK/Scripts/"
cp tests/codegen/runner.gd "$WORK/runner.gd"

# Mirror the game's real autoload singletons (project.godot [autoload] in the
# decompile lists Loader/Database/Simulation as scenes; the scripts are what
# the analyzer needs, and headless --script runs instantiate them, which is
# harmless -- a few missing-node lines of startup noise, filtered below).
cat > "$WORK/project.godot" <<'EOF'
config_version=5

[application]

config/name="modloader-codegen-check"

[autoload]

Loader="*res://Scripts/Loader.gd"
Database="*res://Scripts/Database.gd"
Simulation="*res://Scripts/Simulation.gd"
EOF

# Stub every preload() target so pristine vanilla compiles. The corpus only
# preloads .tres and .tscn (both representable as text); anything else is a
# hard error so a future corpus change cannot silently weaken the baseline.
preload_list="$WORK/preload_paths.txt"
grep -hoE 'preload\("res://[^"]+"' "$WORK"/Scripts/*.gd | sed 's/^preload("//; s/"$//' | sort -u > "$preload_list"
# Create all needed directories in one call, then the stub files.
sed "s|^res://|$WORK/|" "$preload_list" | xargs -r -d '\n' -n 64 dirname | sort -u | tr '\n' '\0' | xargs -0 -r mkdir -p
while IFS= read -r p; do
    rel="${p#res://}"
    tgt="$WORK/$rel"
    [[ -f "$tgt" ]] && continue
    case "$p" in
        *.tres) printf '[gd_resource type="Resource" format=3]\n\n[resource]\n' > "$tgt" ;;
        *.tscn) printf '[gd_scene format=3]\n\n[node name="Root" type="Node"]\n' > "$tgt" ;;
        *)
            echo "ERROR: unstubbable preload target in vanilla corpus: $p" >&2
            echo "       Extend the stub generator in check_codegen.sh." >&2
            exit 1
            ;;
    esac
done < "$preload_list"

# Neuter the modloader's static-init boot line (see the header). Exact-line
# match, required to appear exactly once -- fails loudly on drift.
INIT_LINE='var _filescope_mounted: Dictionary = _mount_previous_session()'
n=$(grep -cxF "$INIT_LINE" "$OUT" || true)
if [[ "$n" -ne 1 ]]; then
    echo "ERROR: expected exactly 1 occurrence of the static-init initializer line" >&2
    echo "       in $OUT, found $n. constants.gd changed -- update INIT_LINE in" >&2
    echo "       check_codegen.sh so the harness keeps neutering the right thing." >&2
    exit 1
fi
sed 's|^var _filescope_mounted: Dictionary = _mount_previous_session()$|var _filescope_mounted: Dictionary = {}  # codegen-check: boot static-init neutralized (test copy only)|' \
    "$OUT" > "$WORK/modloader_neutered.gd"
if [[ $(grep -cxF "$INIT_LINE" "$WORK/modloader_neutered.gd" || true) -ne 0 ]]; then
    echo "ERROR: neutering failed -- initializer line still present in the test copy." >&2
    exit 1
fi

# --prove: reintroduce the exact 3.3.0 regression (unconditional await in the
# wrapper template) in the TEMP copy only, and demand the harness FAIL.
if [[ $PROVE -eq 1 ]]; then
    AW_LINE=$'\tvar aw: String = "await " if is_coro else ""'
    if [[ $(grep -cxF "$AW_LINE" "$WORK/modloader_neutered.gd" || true) -ne 1 ]]; then
        echo "ERROR: --prove could not find the aw template line to mutate." >&2
        exit 1
    fi
    perl -i -pe 's/^\tvar aw: String = "await " if is_coro else ""$/\tvar aw: String = "await "  # --prove: 3.3.0 unconditional-await regression reintroduced (temp copy only)/' \
        "$WORK/modloader_neutered.gd"
    echo "--prove: reintroduced the unconditional await in the TEMP modloader copy"
fi

"$GODOT" --headless --path "$WORK" --script res://runner.gd > "$WORK/run.log" 2>&1
status=$?

# Show the log from the harness marker onward (drops the expected startup
# noise from instantiating the game's autoloads headless: missing child
# nodes, audio bus lookups). The complete log stays at $WORK/run.log.
awk '/\[codegen\] harness start/{on=1} on' "$WORK/run.log" | grep -v '^Godot Engine v' | grep -v '^$'
elapsed=$((SECONDS - start_s))

if [[ $PROVE -eq 1 ]]; then
    if [[ $status -ne 0 ]]; then
        echo "PROVE-OK: harness FAILED as required with the regression present (${elapsed}s). Full log: $WORK/run.log"
        exit 0
    fi
    echo "PROVE FAILED: the harness PASSED with the unconditional await present." >&2
    echo "              The harness is a rubber stamp -- do not trust it." >&2
    exit 1
fi

if [[ $status -eq 0 ]]; then
    echo "OK: codegen harness passed in ${elapsed}s (full log: $WORK/run.log)"
else
    echo "FAILED: codegen harness (exit $status, ${elapsed}s). Full log: $WORK/run.log" >&2
fi
exit $status
