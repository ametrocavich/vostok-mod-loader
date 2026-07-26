#!/usr/bin/env bash
# check.sh -- parse-check the built modloader.gd with the real GDScript compiler.
#
# Why this exists: modloader.gd is 24k+ lines assembled from 39 files that share
# one namespace, and it only ever runs inside the game. Hand-reading catches
# typos but not "this function does not exist" or "this type does not line up"
# -- exactly the errors a refactor introduces. Godot's own front end catches
# both in a couple of seconds.
#
# This NEVER opens a window and NEVER touches the game: --headless, and the
# script is copied into a throwaway project under the system temp dir so Godot
# has no reason to look at this repo (which is not a Godot project) or at the
# Road to Vostok install.
#
# What it does NOT do: run anything. --check-only parses and type-checks, then
# exits. It cannot tell you whether mods actually mount -- that is still a
# smoke test in the real game.
#
# Usage:
#   ./check.sh                      # build.sh must have run first
#   GODOT=/path/to/godot ./check.sh # override the engine binary
#
# Exit code is Godot's: 0 = clean parse, non-zero = errors printed above.

set -uo pipefail
cd "$(dirname "$0")"

OUT=modloader.gd

# Prefer an explicit GODOT, then PATH, then the known local install. Use the
# _console build on Windows: the plain .exe detaches from the terminal and its
# output never reaches us.
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
    echo "ERROR: Godot not found at: $GODOT" >&2
    echo "Set GODOT=/path/to/godot and re-run." >&2
    exit 127
fi

if [[ ! -f "$OUT" ]]; then
    echo "ERROR: $OUT not found -- run ./build.sh first." >&2
    exit 1
fi

# Throwaway project outside the repo. Rebuilt every run so a stale copy can
# never be what gets checked.
WORK="${TMPDIR:-/tmp}/modloader-gdcheck"
rm -rf "$WORK"
mkdir -p "$WORK"
printf 'config_version=5\n\n[application]\n\nconfig/name="gdcheck"\n' > "$WORK/project.godot"
cp "$OUT" "$WORK/$OUT"

"$GODOT" --headless --path "$WORK" --check-only --script "$OUT" 2>&1 | grep -v '^Godot Engine v' | grep -v '^$'
status=${PIPESTATUS[0]}

if [[ $status -eq 0 ]]; then
    echo "OK: $OUT parses clean ($(wc -l < "$OUT") lines)"
else
    echo "FAILED: $OUT has parse/type errors (see above)" >&2
fi
exit $status
