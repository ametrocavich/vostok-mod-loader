#!/usr/bin/env bash
# rehearse_build.sh -- the pre-launch proof for a NEW Road to Vostok build.
# Run it after Steam updates the game and before the first modded launch.
# It never launches the game; it reads RTV.pck, recovers the scripts with
# GDRE and runs the codegen harness on them.
#
# Usage: bash tests/ingame/rehearse_build.sh [--pck PATH] [--out DIR] [--previous DIR]
#   --pck       the game's pack (default $GAME/RTV.pck, GAME as in install.sh)
#   --out       where the recovered scripts go (default
#               /c/Users/ametr/Documents/rtv-<godot version>-<pck date>); must
#               be empty or a previous output of this script
#   --previous  the last build's recovery to diff against (default
#               /c/Users/ametr/Documents/rtv-build2)
#   GDRE        env: gdre_tools.exe (default the v2.5.0-beta.5 download)
#
# Sections:
#   (a) PCK header: pack format and Godot version; a format the loader
#       cannot read stops here
#   (b) GDRE recovery of every script (about 8 s) plus the game's
#       global_script_class_cache.cfg, which the codegen harness needs
#   (c) script inventory against --previous: added, removed, changed
#   (d) registry anchors from src/rewriter_registry_inject.gd against the new
#       scripts, then ./build.sh and ./check_codegen.sh on the new corpus
#   (e) the class cache against the loader's hard-coded fallback class map
#   (f) READY or NOT READY with the reasons; exit 0 only when READY
#
# The new corpus does not replace VANILLA_SRC in .check.env; point it there
# by hand once the build is accepted.
set -uo pipefail
cd "$(dirname "$0")/../.."

GAME="${GAME:-/c/Program Files (x86)/Steam/steamapps/common/Road to Vostok}"
GDRE="${GDRE:-/c/Users/ametr/Downloads/GDRE_tools-v2.5.0-beta.5-windows/gdre_tools.exe}"
PCK="$GAME/RTV.pck"
OUT=""
PREV=/c/Users/ametr/Documents/rtv-build2
MARKER=.rehearse_build
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pck) PCK="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --previous) PREV="$2"; shift 2 ;;
        -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1 (see --help)" >&2; exit 2 ;;
    esac
done

PY=$(command -v python || command -v python3 || true)
[[ -n "$PY" ]] || { echo "ERROR: python not found" >&2; exit 127; }
# Windows python ends its lines with CRLF; the shell reads its output.
py() { "$PY" "$@" | tr -d '\r'; }
# Paths handed to Windows programs (python, GDRE) in C:/... form.
native() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}
reasons=()
not_ready() { reasons+=("$1"); }
section() { printf '\n== %s ==\n' "$1"; }
verdict() {
    section "(f) verdict"
    if [[ ${#reasons[@]} -eq 0 ]]; then
        echo "READY: the loader's rewrites compile against this build. Next: the in-game kit (tests/ingame/lts/README.md)."
        exit 0
    fi
    echo "NOT READY:"
    printf '  - %s\n' "${reasons[@]}"
    exit 1
}

# --- (a) -------------------------------------------------------------------
section "(a) PCK header"
if [[ ! -f "$PCK" ]]; then
    echo "no pack at $PCK (pass --pck)"
    not_ready "no RTV.pck at $PCK"
    verdict
fi
# Prints "FORMAT MAJOR MINOR PATCH FLAGS" or one ERROR line.
read -r FMT MAJ MIN PAT FLAGS < <(py - "$(native "$PCK")" <<'PYEOF'
import struct, sys
with open(sys.argv[1], "rb") as f:
    head = f.read(24)
if len(head) < 24 or head[:4] != b"GDPC":
    print("ERROR 0 0 0 0")
else:
    print("%d %d %d %d %d" % struct.unpack("<5I", head[4:24]))
PYEOF
)
if [[ "$FMT" == "ERROR" ]]; then
    echo "$PCK does not start with GDPC: an embedded or foreign pack, which the loader's PCK reader refuses"
    not_ready "RTV.pck is not a standalone GDPC pack"
    verdict
fi
GODOT_VER="$MAJ.$MIN.$PAT"
PCK_DATE=$(date -r "$PCK" +%F)
echo "pack: $PCK ($PCK_DATE)"
echo "pack format $FMT, Godot $GODOT_VER, flags $FLAGS"
if [[ "$FMT" == "4" ]]; then
    echo "Pack format 4 is a Godot 4.7+ export. The loader's PCK reader takes formats 2 and 3 only"
    echo "(src/pck_enumeration.gd), so script enumeration and the detokenizer's offset index come back empty."
    not_ready "pack format 4 (Godot $GODOT_VER): the loader needs PACK_FORMAT_V4 support first"
    verdict
elif [[ "$FMT" != "2" && "$FMT" != "3" ]]; then
    not_ready "unknown pack format $FMT: the loader reads formats 2 and 3 only"
    verdict
fi
if (( FLAGS & 1 )); then
    not_ready "the pack directory is encrypted: neither GDRE nor the loader's PCK reader can list it"
    verdict
fi
if [[ "$MAJ.$MIN" != "4.5" && "$MAJ.$MIN" != "4.6" ]]; then
    echo "NOTE: the detokenizer is verified on GDSC v101 (Godot 4.5-4.6); this is Godot $GODOT_VER."
    echo "      The in-game [STABILITY] Detokenizer line decides; expect it to refuse an unknown tokenizer."
fi

# --- (b) -------------------------------------------------------------------
section "(b) GDRE recovery"
[[ -n "$OUT" ]] || OUT="/c/Users/ametr/Documents/rtv-$GODOT_VER-$PCK_DATE"
if [[ -d "$OUT" && -n "$(ls -A "$OUT" 2>/dev/null)" ]]; then
    if [[ -f "$OUT/$MARKER" ]]; then
        echo "replacing the previous rehearsal output in $OUT"
        rm -rf "$OUT"
    else
        echo "ERROR: $OUT exists and is not a rehearse_build.sh output; pass an empty --out" >&2
        exit 2
    fi
fi
if [[ ! -f "$GDRE" ]]; then
    not_ready "GDRE not found at $GDRE (set GDRE=...)"
    verdict
fi
mkdir -p "$OUT"
GDRE_LOG=$(mktemp)
SECONDS=0
"$GDRE" --headless --recover="$(native "$PCK")" --scripts-only --output="$(native "$OUT")" > "$GDRE_LOG" 2>&1
rc=$?
touch "$OUT/$MARKER"
mv "$GDRE_LOG" "$OUT/gdre_recover.out"
NSCRIPTS=$(find "$OUT" -name '*.gd' -not -path '*/.*' | wc -l)
echo "GDRE exit $rc in ${SECONDS}s: $NSCRIPTS script(s) recovered into $OUT"
if [[ $rc -ne 0 || $NSCRIPTS -eq 0 ]]; then
    tr '\r' '\n' < "$OUT/gdre_recover.out" | grep -iE 'error|fail' | tail -5 | sed 's/^/  /'
    not_ready "GDRE recovery failed (exit $rc, $NSCRIPTS scripts; log $OUT/gdre_recover.out)"
    verdict
fi
CC_TMP=$(mktemp -d)
"$GDRE" --headless --extract="$(native "$PCK")" --include="res://.godot/global_script_class_cache.cfg" \
    --output="$(native "$CC_TMP")" > "$OUT/gdre_extract.out" 2>&1
if [[ -f "$CC_TMP/.godot/global_script_class_cache.cfg" ]]; then
    mkdir -p "$OUT/.godot"
    cp "$CC_TMP/.godot/global_script_class_cache.cfg" "$OUT/.godot/"
    echo "class cache: $OUT/.godot/global_script_class_cache.cfg"
else
    echo "class cache: not in the pack (log $OUT/gdre_extract.out)"
    not_ready "res://.godot/global_script_class_cache.cfg could not be extracted; the codegen harness needs it"
fi
rm -rf "$CC_TMP"

# --- (c) -------------------------------------------------------------------
section "(c) script inventory against $PREV"
if [[ -d "$PREV" ]]; then
    py - "$(native "$PREV")" "$(native "$OUT")" <<'PYEOF'
import hashlib, os, sys

def inventory(root):
    out = {}
    for d, dirs, files in os.walk(root):
        dirs[:] = [x for x in dirs if not x.startswith(".")]
        for name in files:
            if name.endswith(".gd"):
                p = os.path.join(d, name)
                with open(p, "rb") as f:
                    out[os.path.relpath(p, root).replace(os.sep, "/")] = hashlib.sha256(f.read()).hexdigest()
    return out

old, new = inventory(sys.argv[1]), inventory(sys.argv[2])
added = sorted(set(new) - set(old))
removed = sorted(set(old) - set(new))
changed = sorted(k for k in set(old) & set(new) if old[k] != new[k])
print("previous %d, new %d: %d added, %d removed, %d changed, %d identical"
      % (len(old), len(new), len(added), len(removed), len(changed), len(set(old) & set(new)) - len(changed)))
for title, rows in (("removed", removed), ("changed", changed), ("added", added)):
    for r in rows:
        print("  %-8s %s" % (title, r))
PYEOF
else
    echo "no previous recovery at $PREV; inventory diff skipped (pass --previous)"
fi

# --- (d) -------------------------------------------------------------------
section "(d) registry anchors and the codegen harness"
ANCHORS=$(py - "$(native src/rewriter_registry_inject.gd)" "$(native "$OUT")" <<'PYEOF'
import os, re, sys

src, out = sys.argv[1], sys.argv[2]
scripts = {}
for d, dirs, files in os.walk(out):
    dirs[:] = [x for x in dirs if not x.startswith(".")]
    for name in files:
        if name.endswith(".gd"):
            scripts.setdefault(name, os.path.join(d, name))
lines = open(src, encoding="utf-8").read().splitlines()
missing = 0
for i, ln in enumerate(lines):
    if not ln.startswith("# Vanilla anchor:"):
        continue
    block = [ln[1:].strip()]
    for nxt in lines[i + 1:]:
        if not nxt.startswith("#"):
            break
        block.append(nxt[1:].strip())
    text = " ".join(block)
    print("  line %d: %s" % (i + 1, text[len("Vanilla anchor: "):][:150]))
    for name in sorted(set(re.findall(r"\b([A-Z]\w*\.gd)\b", text))):
        if name not in scripts:
            print("    MISSING script %s" % name)
            missing += 1
            continue
        found = "present"
        body = open(scripts[name], encoding="utf-8", errors="replace").read()
        for method in re.findall(re.escape(name) + r"::(\w+)", text):
            if not re.search(r"^func %s\(" % re.escape(method), body, re.M):
                print("    MISSING method %s::%s" % (name, method))
                missing += 1
                found = None
        if found:
            print("    %s %s" % (name, found))
print("ANCHORS_MISSING %d" % missing)
PYEOF
)
echo "$ANCHORS" | grep -v '^ANCHORS_MISSING'
n_missing=$(echo "$ANCHORS" | sed -n 's/^ANCHORS_MISSING //p')
[[ "${n_missing:-1}" == "0" ]] || not_ready "$n_missing registry anchor target(s) missing from the new scripts"

CODEGEN_LOG="$OUT/codegen.log"
echo
echo "running VANILLA_SRC=$OUT ./build.sh && ./check_codegen.sh (log $CODEGEN_LOG)"
{ VANILLA_SRC="$OUT" ./build.sh && VANILLA_SRC="$OUT" ./check_codegen.sh; } > "$CODEGEN_LOG" 2>&1
codegen_rc=$?
# Quote the result lines and every probe verdict. The harness renames one
# member per registry target on purpose (GAME_RENAMES in
# tests/codegen/runner.gd) and feeds the synthetic fixtures and a Database.gd
# without const preloads to the probe, so one such verdict per case is
# expected; any other verdict means the new build demoted a rewrite. The
# labels only help reading: a demoted real rewrite also fails the harness
# itself ("VET: the probe demoted a good rewrite"), which is the verdict.
VERDICTS=$(py - "$(native "$CODEGEN_LOG")" "$(native tests/codegen/runner.gd)" <<'PYEOF'
import re, sys

log = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()
runner = open(sys.argv[2], encoding="utf-8").read()
m = re.search(r"const GAME_RENAMES := \{(.*?)\}", runner, re.S)
renames = dict(re.findall(r'"(\w+\.gd)":\s*"(\w+)"', m.group(1))) if m else {}
used = {}
errors = []
unexpected = 0
for ln in log:
    s = ln.strip()
    if s.startswith("SCRIPT ERROR"):
        errors.append(s)
        continue
    if s.startswith("[codegen] PASS") or s.startswith("[codegen] FAIL") or s.startswith("[codegen] FAILED") \
            or s.startswith("OK: codegen") or s.startswith("FAILED: codegen") or s.startswith("NOTE:"):
        print("  " + s)
        continue
    v = re.search(r"\[(?:STABILITY|RTVCodegen)\] (\w+\.gd): (.*)", s)
    if not v or not re.search(r"does not compile against this game build|const layout changed|internal rename failure", s):
        continue
    name, why = v.group(1), ""
    if name.startswith("Fixture"):
        why = "synthetic fixture case"
    elif name in renames and "does not compile" in s and any('"%s"' % renames[name] in e for e in errors) \
            and not used.get(name):
        why = "harness case: %s renamed" % renames[name]
        used[name] = True
    elif name == "Database.gd" and "const layout changed" in s and not used.get("db"):
        why = "harness case: Database.gd without const preloads"
        used["db"] = True
    if why:
        print("  expected (%s): %s" % (why, s[:200]))
    else:
        print("  UNEXPECTED: %s" % s[:200])
        unexpected += 1
    errors = []
print("VERDICTS_UNEXPECTED %d" % unexpected)
PYEOF
)
echo "$VERDICTS" | grep -v '^VERDICTS_UNEXPECTED'
n_unexpected=$(echo "$VERDICTS" | sed -n 's/^VERDICTS_UNEXPECTED //p')
if [[ $codegen_rc -ne 0 ]] || ! grep -q '^\[codegen\] PASS' "$CODEGEN_LOG"; then
    not_ready "the codegen harness failed on the new scripts (exit $codegen_rc; $CODEGEN_LOG)"
elif grep -q 'synthetic fixtures only' "$CODEGEN_LOG"; then
    not_ready "the codegen harness ran the synthetic fixtures only: the recovered corpus was not used"
fi
[[ "${n_unexpected:-1}" == "0" ]] || not_ready "$n_unexpected unexpected probe demotion(s) in the codegen run"

# --- (e) -------------------------------------------------------------------
section "(e) class cache against the hard-coded class map (src/pck_enumeration.gd)"
CACHE="$OUT/.godot/global_script_class_cache.cfg"
if [[ -f "$CACHE" ]]; then
    py - "$(native "$CACHE")" "$(native src/pck_enumeration.gd)" <<'PYEOF'
import re, sys

cache = open(sys.argv[1], encoding="utf-8").read()
src = open(sys.argv[2], encoding="utf-8").read()
game = {}
for block in re.split(r"\}\s*,\s*\{", cache):
    c = re.search(r'"class":\s*&"(\w+)"', block)
    p = re.search(r'"path":\s*"([^"]+)"', block)
    if c and p:
        game[c.group(1)] = p.group(1)
m = re.search(r"func _get_hardcoded_class_map\(\).*?return \{(.*?)\n\t\}", src, re.S)
fallback = dict(re.findall(r'"(\w+)":\s*"(res://[^"]+)"', m.group(1))) if m else {}
added = sorted(set(game) - set(fallback))
removed = sorted(set(fallback) - set(game))
moved = sorted(k for k in set(game) & set(fallback) if game[k] != fallback[k])
print("game cache %d classes, fallback map %d: %d added, %d removed, %d moved"
      % (len(game), len(fallback), len(added), len(removed), len(moved)))
for k in added:
    print("  added    %s -> %s" % (k, game[k]))
for k in removed:
    print("  removed  %s (was %s)" % (k, fallback[k]))
for k in moved:
    print("  moved    %s: %s -> %s" % (k, fallback[k], game[k]))
if added or removed or moved:
    print("The map is the fallback used when the cache cannot be read; re-capture it from this cache.")
PYEOF
else
    echo "no class cache in $OUT; skipped"
fi

verdict
