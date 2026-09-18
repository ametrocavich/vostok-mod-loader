#!/usr/bin/env bash
# check.sh -- parse-check the built modloader.gd with the real GDScript compiler.
#
# Run the parse check, static invariants and six headless harnesses.
# Harness copies replace the boot initializer before creating a loader.
# The boot-state runner also creates and removes override.cfg beside the test
# Godot binary; it refuses an existing file there. Use a dedicated engine.
# No game process or editor is started. See docs/wiki/Build.md for coverage.
#
# Usage: ./build.sh && ./check.sh
# GODOT=/path/to/godot and PYTHON=/path/to/python3 override tool discovery.

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

# Wrapper templates emit await only through the coroutine-gated aw variable.
if ! ls src/rewriter*.gd >/dev/null 2>&1; then
    echo "FAILED: no src/rewriter*.gd found -- the await invariant has nothing to check (emitter files renamed?)" >&2
    exit 1
fi
bad_await=$(grep -n 'out += ' src/rewriter*.gd | grep 'await' || true)
if [[ -n "$bad_await" ]]; then
    echo "FAILED: a rewriter_*.gd file emits a literal 'await' into generated code." >&2
    echo "        Use the is_coro-gated 'aw' variable instead -- an" >&2
    echo "        unconditional await makes every wrapped method a coroutine." >&2
    echo "$bad_await" >&2
    exit 1
fi
# The hook documentation must describe the same await contract.
bad_doc=$(grep -n 'await _repl\[0\]' docs/wiki/Hooks.md || true)
bad_doc+=$(grep -in 'replace callback is always awaited' docs/wiki/Hooks.md || true)
if [[ -n "$bad_doc" ]]; then
    echo "FAILED: docs/wiki/Hooks.md documents the 3.3.0 unconditional-await bug" >&2
    echo "        as intended behavior. The wrapper awaits the replace callback" >&2
    echo "        ONLY when the vanilla method is itself a coroutine." >&2
    echo "$bad_doc" >&2
    exit 1
fi
# Check documentation targets and source ownership with the build manifest.
if [[ -z "${PYTHON:-}" ]]; then
    for candidate in python python3; do
        if command -v "$candidate" >/dev/null 2>&1 && \
                "$candidate" -c 'import sys; sys.exit(sys.version_info < (3, 9))' >/dev/null 2>&1; then
            PYTHON="$candidate"
            break
        fi
    done
fi
if [[ -z "${PYTHON:-}" ]]; then
    echo "FAILED: Python 3.9+ is required for documentation checks; set PYTHON." >&2
    exit 1
fi
if ! "$PYTHON" tools/dev.py check-docs; then
    echo "FAILED: documentation references (see above)" >&2
    exit 1
fi
echo "OK: codegen and documentation invariants hold"

# Compile generated source and caller stubs; synthetic fixtures always run.
if ! ./check_codegen.sh; then
    echo "FAILED: codegen compile harness (see above)" >&2
    exit 1
fi

# Exercise hook dispatch, registry operations and syntax compatibility.
if ! ./check_dispatch.sh; then
    echo "FAILED: runtime dispatch harness (see above)" >&2
    exit 1
fi

# Reconstruct v100/v101 tokens and check cache precedence.
if ! ./check_detok.sh; then
    echo "FAILED: detokenizer harness (see above)" >&2
    exit 1
fi

# Check duplicate selection and profile identity.
if ! ./check_identity.sh; then
    echo "FAILED: mod-identity harness (see above)" >&2
    exit 1
fi

# Check host records, downloads and pack/profile state transitions.
if ! ./check_host.sh; then
    echo "FAILED: host-seam harness (see above)" >&2
    exit 1
fi

# Check boot persistence, crash recovery and filesystem guards.
if ! ./check_boot_state.sh; then
    echo "FAILED: boot-state harness (see above)" >&2
    exit 1
fi
exit 0
