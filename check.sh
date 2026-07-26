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
    exit $status
fi

# ---------------------------------------------------------------------------
# Codegen invariants. These assert on the wrapper TEMPLATES in rewriter.gd,
# not on a running loader: generating a wrapper for real would mean executing
# modloader.gd, and its static-init runs the whole boot sequence against
# whatever directory the engine lives in. Static assertions are the safe way
# to pin a contract the compiler cannot see.
# ---------------------------------------------------------------------------

# INVARIANT: no emitted line may contain a literal `await`.
#
# In GDScript, ANY function whose body contains `await` is a coroutine. A
# hardcoded await in a wrapper template therefore turns every wrapped vanilla
# method into a coroutine, and every existing caller breaks at PARSE time
# ("Function X is a coroutine, so it must be called with await") -- including
# third-party mods calling vanilla correctly. Shipped in 3.3.0 and broke any
# mod pairing with a wide enough hook surface.
#
# The only legitimate way to emit an await is via the `aw` variable, which is
# "await " only when the vanilla target is itself a coroutine.
bad_await=$(grep -n 'out += ' src/rewriter.gd | grep 'await' || true)
if [[ -n "$bad_await" ]]; then
    echo "FAILED: rewriter.gd emits a literal 'await' into generated code." >&2
    echo "        Use the is_coro-gated 'aw' variable instead -- an" >&2
    echo "        unconditional await makes every wrapped method a coroutine." >&2
    echo "$bad_await" >&2
    exit 1
fi
# INVARIANT: the docs must not re-bless the bug either.
#
# The commit that shipped the 3.3.0 await regression ALSO edited Hooks.md to
# document the broken wrapper as intended behavior -- in two separate places.
# That is worse than an undocumented bug: it made the fix look like a contract
# change, and the first pass at correcting the docs missed the second block.
# Pin both, so a future doc sync cannot quietly describe the bug as a feature.
bad_doc=$(grep -n 'await _repl\[0\]' docs/wiki/Hooks.md || true)
bad_doc+=$(grep -in 'replace callback is always awaited' docs/wiki/Hooks.md || true)
if [[ -n "$bad_doc" ]]; then
    echo "FAILED: docs/wiki/Hooks.md documents the 3.3.0 unconditional-await bug" >&2
    echo "        as intended behavior. The wrapper awaits the replace callback" >&2
    echo "        ONLY when the vanilla method is itself a coroutine." >&2
    echo "$bad_doc" >&2
    exit 1
fi
echo "OK: codegen invariants hold (no unconditional await in templates or docs)"

# ---------------------------------------------------------------------------
# Codegen compile harness: run the REAL rewriter over real vanilla scripts,
# then compile both the rewritten output and a generated caller stub with the
# real GDScript compiler. The grep invariant above pins the one template line
# that broke 3.3.0; the harness fails the whole bug class (any wrapper
# becoming a coroutine, signature drift, transform breakage) at build time.
# Skips itself (exit 0, with a banner) on machines without the decompiled
# vanilla source. Self-test: ./check_codegen.sh --prove
# ---------------------------------------------------------------------------
if ! ./check_codegen.sh; then
    echo "FAILED: codegen compile harness (see above)" >&2
    exit 1
fi
exit 0
