#!/usr/bin/env bash
# check_detok.sh -- exercise the GDSC detokenizer against synthetic bytecode.
#
# Why this exists: src/gdsc_detokenizer.gd had NO test coverage. Its only
# correctness check was STABILITY canary C, which runs at game launch on the
# user's machine -- far too late, and only on whatever bytecode version that
# user's game happens to ship. That is how the v100 token-index shift went
# unnoticed: the version gate accepts bytecode 100, but the token table is
# v101-only, so every index from 83 up decoded one slot off. A v100 .gdc came
# out as garbage and was then cached as "pristine vanilla".
#
# This harness builds GDSC buffers in memory, twice over -- once with v101
# indices under a v101 header, once with v100 indices under a v100 header --
# and requires both to reconstruct to byte-identical source.
#
# SCOPE, honestly stated: the fixtures are synthesized against this repo's own
# reader, so this proves index normalization and the reconstruction pass, NOT
# that our understanding of the container layout matches the real engine. A
# shared misreading of the header would be invisible here. Canary C round-trips
# a real .gdc from the shipped PCK and remains the only check of that. Do not
# retire canary C on the strength of this harness.
#
# Needs no decompiled vanilla corpus (unlike check_codegen.sh), so it runs
# anywhere. Never opens a window and never touches the game install:
# --headless only, against a throwaway project under the system temp dir.
#
# Usage:
#   ./check_detok.sh              # build.sh must have run first
#   ./check_detok.sh --prove      # self-test: strip the v100 index
#                                 #   normalization from the TEMP copy
#                                 #   (never src/) and require the harness to
#                                 #   FAIL; exits 0 only if it did
#   GODOT=/path/to/godot ./check_detok.sh

set -uo pipefail
cd "$(dirname "$0")"

PROVE=0
if [[ "${1:-}" == "--prove" ]]; then
    PROVE=1
fi

OUT=modloader.gd

# Same engine resolution as check.sh / check_codegen.sh.
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

WORK="${TMPDIR:-/tmp}/modloader-detok-check"
rm -rf "$WORK"
mkdir -p "$WORK"

cp tests/detok/runner.gd "$WORK/runner.gd"

cat > "$WORK/project.godot" <<'EOF'
config_version=5

[application]

config/name="modloader-detok-check"
EOF

# Neuter the modloader's static-init boot line, exactly as check_codegen.sh
# does and for the same reason: instantiating modloader.gd would otherwise
# mount archives and rewrite override.cfg relative to the GODOT BINARY's
# directory. Exact-line match, required exactly once, so drift fails loudly.
INIT_LINE='var _filescope_mounted: Dictionary = _mount_previous_session()'
n=$(grep -cxF "$INIT_LINE" "$OUT" || true)
if [[ "$n" -ne 1 ]]; then
    echo "ERROR: expected exactly 1 occurrence of the static-init initializer line" >&2
    echo "       in $OUT, found $n. boot.gd changed -- update INIT_LINE in" >&2
    echo "       check_detok.sh so the harness keeps neutering the right thing." >&2
    exit 1
fi
sed 's|^var _filescope_mounted: Dictionary = _mount_previous_session()$|var _filescope_mounted: Dictionary = {}  # detok-check: boot static-init neutralized (test copy only)|' \
    "$OUT" > "$WORK/modloader_neutered.gd"
if [[ $(grep -cxF "$INIT_LINE" "$WORK/modloader_neutered.gd" || true) -ne 0 ]]; then
    echo "ERROR: neutering failed -- initializer line still present in the test copy." >&2
    exit 1
fi

# --prove: remove the v100 index normalization in the TEMP copy only, and
# demand the harness FAIL. Without this, a harness that silently stopped
# exercising the shift would still report PASS forever.
if [[ $PROVE -eq 1 ]]; then
    SHIFT_LINE=$'\t\tif version == GDSC_VERSION_V100 and tk_type >= _GDSC_V100_SHIFT_FROM:'
    if [[ $(grep -cxF "$SHIFT_LINE" "$WORK/modloader_neutered.gd" || true) -ne 1 ]]; then
        echo "ERROR: --prove could not find the v100 normalization line to disable." >&2
        exit 1
    fi
    perl -i -pe 's/^\t\tif version == GDSC_VERSION_V100 and tk_type >= _GDSC_V100_SHIFT_FROM:$/\t\tif false:  # --prove: v100 index normalization disabled (temp copy only)/' \
        "$WORK/modloader_neutered.gd"
    echo "--prove: disabled the v100 index normalization in the TEMP modloader copy"
fi

"$GODOT" --headless --path "$WORK" --script res://runner.gd > "$WORK/run.log" 2>&1
status=$?

awk '/\[detok\] harness start/{on=1} on' "$WORK/run.log" | grep -v '^Godot Engine v' | grep -v '^$'
elapsed=$((SECONDS - start_s))

if [[ $PROVE -eq 1 ]]; then
    if [[ $status -ne 0 ]]; then
        echo "PROVE-OK: harness FAILED as required with the normalization removed (${elapsed}s). Full log: $WORK/run.log"
        exit 0
    fi
    echo "PROVE FAILED: the harness PASSED with the v100 normalization removed." >&2
    echo "              The harness is a rubber stamp -- do not trust it." >&2
    exit 1
fi

if [[ $status -eq 0 ]]; then
    echo "OK: detokenizer harness passed in ${elapsed}s (full log: $WORK/run.log)"
else
    echo "FAILED: detokenizer harness (exit $status, ${elapsed}s). Full log: $WORK/run.log" >&2
fi
exit $status
