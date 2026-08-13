#!/usr/bin/env bash
# check_identity.sh -- exercise mod identity and duplicate collapsing.
#
# Why this exists: a mod whose mod.txt declares no id= is identified by its
# filename. Re-packaging it under a different extension or version suffix used
# to mint a second identity, so two copies of the same mod both mounted and
# load order decided which body of code actually ran. The reported symptom was
# "I edited my mod and it keeps running the old code, but renaming it back
# fixes it".
#
# The fix normalizes the filename to a stem, which is a heuristic with a
# failure mode on each side: too greedy merges two genuinely different mods,
# too strict brings the original bug back. This harness pins both directions.
#
# Needs no decompiled vanilla corpus, so it runs anywhere. Never opens a window
# and never touches the game install: --headless only, against a throwaway
# project under the system temp dir.
#
# Usage:
#   ./check_identity.sh              # build.sh must have run first
#   ./check_identity.sh --prove      # self-test: defeat stem normalization in
#                                    #   the TEMP copy (never src/) and require
#                                    #   the harness to FAIL; exits 0 only if
#                                    #   it did
#   GODOT=/path/to/godot ./check_identity.sh

set -uo pipefail
cd "$(dirname "$0")"

PROVE=0
if [[ "${1:-}" == "--prove" ]]; then
    PROVE=1
fi

OUT=modloader.gd

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

WORK="${TMPDIR:-/tmp}/modloader-identity-check"
rm -rf "$WORK"
mkdir -p "$WORK"

cp tests/identity/runner.gd "$WORK/runner.gd"

cat > "$WORK/project.godot" <<'EOF'
config_version=5

[application]

config/name="modloader-identity-check"
EOF

# Neuter the modloader's static-init boot line, exactly as the other harnesses
# do and for the same reason: instantiating modloader.gd would otherwise mount
# archives and rewrite override.cfg relative to the GODOT BINARY's directory.
# Exact-line match, required exactly once, so drift fails loudly.
INIT_LINE='var _filescope_mounted: Dictionary = _mount_previous_session()'
n=$(grep -cxF "$INIT_LINE" "$OUT" || true)
if [[ "$n" -ne 1 ]]; then
    echo "ERROR: expected exactly 1 occurrence of the static-init initializer line" >&2
    echo "       in $OUT, found $n. constants.gd changed -- update INIT_LINE in" >&2
    echo "       check_identity.sh so the harness keeps neutering the right thing." >&2
    exit 1
fi
sed 's|^var _filescope_mounted: Dictionary = _mount_previous_session()$|var _filescope_mounted: Dictionary = {}  # identity-check: boot static-init neutralized (test copy only)|' \
    "$OUT" > "$WORK/modloader_neutered.gd"
if [[ $(grep -cxF "$INIT_LINE" "$WORK/modloader_neutered.gd" || true) -ne 0 ]]; then
    echo "ERROR: neutering failed -- initializer line still present in the test copy." >&2
    exit 1
fi

# --prove: make _normalized_mod_stem skip its version-suffix strip in the TEMP
# copy only, which restores the "CoolMod.vmz and CoolMod_v1.1.zip are separate
# mods" behavior, and demand the harness FAIL.
if [[ $PROVE -eq 1 ]]; then
    STEM_LINE='	var m := re.search(stem)'
    if [[ $(grep -cxF "$STEM_LINE" "$WORK/modloader_neutered.gd" || true) -ne 1 ]]; then
        echo "ERROR: --prove could not find the stem-match line to neuter." >&2
        echo "       _normalized_mod_stem changed shape; update STEM_LINE." >&2
        exit 1
    fi
    sed -i 's|^\tvar m := re\.search(stem)$|\tvar m: RegExMatch = null  # --prove: stem normalization disabled (temp copy only)|' \
        "$WORK/modloader_neutered.gd"
    if [[ $(grep -cxF "$STEM_LINE" "$WORK/modloader_neutered.gd" || true) -ne 0 ]]; then
        echo "ERROR: --prove substitution did not apply." >&2
        exit 1
    fi
    echo "--prove: disabled filename-stem normalization in the TEMP modloader copy"
fi

"$GODOT" --headless --path "$WORK" --script res://runner.gd > "$WORK/run.log" 2>&1
status=$?

awk '/\[identity\] harness start/{on=1} on' "$WORK/run.log" | grep -v '^Godot Engine v' | grep -v '^$'
elapsed=$((SECONDS - start_s))

if [[ $PROVE -eq 1 ]]; then
    if [[ $status -ne 0 ]]; then
        echo "PROVE-OK: harness FAILED as required with stem normalization removed (${elapsed}s). Full log: $WORK/run.log"
        exit 0
    fi
    echo "PROVE FAILED: the harness PASSED with stem normalization removed." >&2
    echo "              The harness is a rubber stamp -- do not trust it." >&2
    exit 1
fi

if [[ $status -eq 0 ]]; then
    echo "OK: mod-identity harness passed in ${elapsed}s (full log: $WORK/run.log)"
else
    echo "FAILED: mod-identity harness (exit $status, ${elapsed}s). Full log: $WORK/run.log" >&2
fi
exit $status
