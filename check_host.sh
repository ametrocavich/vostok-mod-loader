#!/usr/bin/env bash
# check_host.sh -- exercise the host-provider seam and the on-disk source format.
#
# Why this exists: the host seam (host_types.gd + one adapter per host) and
# the provider-qualified [updates] source= format shipped with NO coverage,
# and their guarantees are exactly the kind a refactor silently breaks:
#   - normalizers emit every field with its declared type ("" / -1 sentinels,
#     never absent keys) -- the rule that lets the UI stop shape-checking;
#   - the "provider:id" grammar rejects rather than guesses (a bare number
#     defaulted to ModWorkshop downloads a stranger's upload);
#   - source records of every era (legacy int/float/quoted/null and both new
#     shapes) converge to one stable serialization in a single pass, so
#     mod_config.cfg is not rewritten on every scan;
#   - the legacy modworkshop_id mirror is emitted IFF provider == modworkshop.
#     profile.json is mailed between users, and a mirrored id on a
#     non-ModWorkshop record makes a pre-source loader download whatever mod
#     owns that number on ModWorkshop.
#
# SCOPE, honestly stated: this is the pure translation layer only. No request
# is made, so endpoint URLs, rate-limit dialects and whatever the REAL hosts
# send today are not proven here; the fixture rows are the captured payloads
# the adapters themselves document.
#
# Needs no decompiled vanilla corpus and no network, so it runs anywhere and
# can NEVER skip. Never opens a window and never touches the game install:
# --headless only, against a throwaway project under the system temp dir.
#
# Usage:
#   ./check_host.sh              # build.sh must have run first
#   ./check_host.sh --prove      # self-test: break the mirror rule in the
#                                #   TEMP copy (never src/) by making
#                                #   _source_mws_id accept ANY provider, and
#                                #   require the harness to FAIL; exits 0
#                                #   only if it did
#   GODOT=/path/to/godot ./check_host.sh

set -uo pipefail
cd "$(dirname "$0")"

PROVE=0
if [[ "${1:-}" == "--prove" ]]; then
    PROVE=1
fi

OUT=modloader.gd

# Same engine resolution as check.sh / check_codegen.sh / check_detok.sh.
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

WORK="${TMPDIR:-/tmp}/modloader-host-check"
rm -rf "$WORK"
mkdir -p "$WORK"

cp tests/host/runner.gd "$WORK/runner.gd"

cat > "$WORK/project.godot" <<'EOF'
config_version=5

[application]

config/name="modloader-host-check"
EOF

# Neuter the modloader's static-init boot line, exactly as check_codegen.sh /
# check_detok.sh do and for the same reason: instantiating modloader.gd would
# otherwise mount archives and rewrite override.cfg relative to the GODOT
# BINARY's directory. Exact-line match, required exactly once, so drift fails
# loudly.
INIT_LINE='var _filescope_mounted: Dictionary = _mount_previous_session()'
n=$(grep -cxF "$INIT_LINE" "$OUT" || true)
if [[ "$n" -ne 1 ]]; then
    echo "ERROR: expected exactly 1 occurrence of the static-init initializer line" >&2
    echo "       in $OUT, found $n. boot.gd changed -- update INIT_LINE in" >&2
    echo "       check_host.sh so the harness keeps neutering the right thing." >&2
    exit 1
fi
sed 's|^var _filescope_mounted: Dictionary = _mount_previous_session()$|var _filescope_mounted: Dictionary = {}  # host-check: boot static-init neutralized (test copy only)|' \
    "$OUT" > "$WORK/modloader_neutered.gd"
if [[ $(grep -cxF "$INIT_LINE" "$WORK/modloader_neutered.gd" || true) -ne 0 ]]; then
    echo "ERROR: neutering failed -- initializer line still present in the test copy." >&2
    exit 1
fi

# --prove: break the mirror rule in the TEMP copy only, and demand the
# harness FAIL. _source_mws_id's provider guard is the ONLY thing standing
# between a vostokmods record and a modworkshop_id mirror; with it gone, any
# numeric id mints a mirror and the T6 mirror-rule assertions must trip.
# Without this, a harness that silently stopped exercising the rule would
# still report PASS forever.
if [[ $PROVE -eq 1 ]]; then
    MIRROR_LINE=$'\tif str(rec.get("provider", "")) != HOST_MODWORKSHOP:'
    if [[ $(grep -cxF "$MIRROR_LINE" "$WORK/modloader_neutered.gd" || true) -ne 1 ]]; then
        echo "ERROR: --prove could not find the _source_mws_id provider guard to disable." >&2
        exit 1
    fi
    perl -i -pe 's/^\tif str\(rec\.get\("provider", ""\)\) != HOST_MODWORKSHOP:$/\tif false:  # --prove: mirror rule disabled (temp copy only)/' \
        "$WORK/modloader_neutered.gd"
    echo "--prove: disabled the _source_mws_id provider guard in the TEMP modloader copy"
fi

"$GODOT" --headless --path "$WORK" --script res://runner.gd > "$WORK/run.log" 2>&1
status=$?

awk '/\[host\] harness start/{on=1} on' "$WORK/run.log" | grep -v '^Godot Engine v' | grep -v '^$'
elapsed=$((SECONDS - start_s))

if [[ $PROVE -eq 1 ]]; then
    if [[ $status -ne 0 ]]; then
        echo "PROVE-OK: harness FAILED as required with the mirror rule broken (${elapsed}s). Full log: $WORK/run.log"
        exit 0
    fi
    echo "PROVE FAILED: the harness PASSED with the _source_mws_id provider guard removed." >&2
    echo "              The harness is a rubber stamp -- do not trust it." >&2
    exit 1
fi

# A script error inside a test function aborts that function without failing
# the run, and the assertions after it never execute. A green run logs none.
if [[ $status -eq 0 ]] && grep -q 'SCRIPT ERROR' "$WORK/run.log"; then
    echo "FAILED: the run exited 0 but logged a SCRIPT ERROR, so a test function stopped part-way:" >&2
    grep -m3 -A2 'SCRIPT ERROR' "$WORK/run.log" | sed 's/^/    /' >&2
    status=1
fi
if [[ $status -eq 0 ]]; then
    echo "OK: host-seam harness passed in ${elapsed}s (full log: $WORK/run.log)"
else
    echo "FAILED: host-seam harness (exit $status, ${elapsed}s). Full log: $WORK/run.log" >&2
fi
exit $status
