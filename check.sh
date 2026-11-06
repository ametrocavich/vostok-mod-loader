#!/usr/bin/env bash
# check.sh -- parse-check modloader.gd, hold the source invariants, run the nine harnesses.
# Usage: ./build.sh && ./check.sh (GODOT, PYTHON, or GODOT/VANILLA_SRC in .check.env).

set -uo pipefail
cd "$(dirname "$0")"
source tests/lib.sh

find_godot
require_build
make_project modloader-gdcheck
cp "$OUT" "$WORK/$OUT"

"$GODOT" --headless --path "$WORK" --check-only --script "$OUT" 2>&1 | grep -v '^Godot Engine v' | grep -v '^$'
status=${PIPESTATUS[0]}
if [[ $status -ne 0 ]]; then
    echo "FAILED: $OUT has parse/type errors (see above)" >&2
    exit $status
fi
echo "OK: $OUT parses clean ($(wc -l < "$OUT") lines)"

# The release is built on Linux from LF blobs; what is tested here must match it.
cr_count=$(LC_ALL=C tr -cd '\r' < "$OUT" | wc -c)
if [[ $cr_count -ne 0 ]]; then
    echo "FAILED: $OUT holds $cr_count CR byte(s) -- a local build must match the LF release build. Run ./build.sh." >&2
    exit 1
fi

# An unconditional await in emitted code makes every wrapped method a coroutine.
if ! ls src/rewriter*.gd >/dev/null 2>&1; then
    echo "FAILED: no src/rewriter*.gd found -- the await invariant has nothing to check (emitter files renamed?)" >&2
    exit 1
fi
find_python
# Every string literal is a candidate emission (out += lines and template arrays alike);
# the is_coro-gated aw line and begins_with() tests on parsed source are not emissions.
scan_await() {
    "$PYTHON" - "$@" <<'PY'
import re, sys
aw_line = '\tvar aw: String = "await " if is_coro else ""'
lit = re.compile(r'"(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\'')
for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f.read().split("\n"), 1):
            if line == aw_line or line.lstrip().startswith("#"):
                continue
            for m in lit.finditer(line):
                if "await " in m.group() and not line[:m.start()].endswith("begins_with("):
                    print("%s:%d:%s" % (path, n, line.strip()))
                    break
PY
}
bad_await=$(scan_await src/rewriter*.gd) || { echo "FAILED: the await scan did not run" >&2; exit 1; }
if [[ -n "$bad_await" ]]; then
    echo "FAILED: a rewriter_*.gd file emits a literal 'await' into generated code." >&2
    echo "        Use the is_coro-gated 'aw' variable instead." >&2
    echo "$bad_await" >&2
    exit 1
fi
bad_doc=$(grep -n 'await _\(rtv_\)\?repl\[0\]' docs/wiki/Hook*.md || true)
bad_doc+=$(grep -in 'replace callback is always awaited' docs/wiki/Hook*.md || true)
if [[ -n "$bad_doc" ]]; then
    echo "FAILED: a docs/wiki/Hook*.md page documents the 3.3.0 unconditional await as intended." >&2
    echo "        The wrapper awaits the replace callback only for a coroutine method." >&2
    echo "$bad_doc" >&2
    exit 1
fi
if ! "$PYTHON" tools/dev.py check-docs; then
    echo "FAILED: documentation references (see above)" >&2
    exit 1
fi
echo "OK: codegen and documentation invariants hold"

for c in codegen dispatch detok identity host profiles mods boot_state ui; do
    if ! "./check_$c.sh"; then
        echo "FAILED: check_$c.sh (see above)" >&2
        exit 1
    fi
done
