#!/usr/bin/env bash
# ./check_ui.sh [--prove | --update-baseline]: the headless launcher dump must equal tests/ui/baseline.txt.
# --prove changes the selected-tab color and demands a diff; --update-baseline rewrites the baseline.
set -uo pipefail
cd "$(dirname "$0")"
source tests/lib.sh

MODE="${1:-}"
case "$MODE" in
    --prove|--update-baseline|"") ;;
    *) echo "Usage: ./check_ui.sh [--prove | --update-baseline]" >&2; exit 2 ;;
esac
BASELINE=tests/ui/baseline.txt

find_godot
require_build
make_project modloader-ui-check tests/ui/runner.gd
neuter_loader
if [[ $MODE == --prove ]]; then
    mutate_line "the selected-tab color line" \
        $'\tt.set_color("font_selected_color",   "TabContainer", COL_TEXT_HI)' \
        $'\tt.set_color("font_selected_color",   "TabContainer", COL_TEXT)  # --prove: changed (temp copy only)'
    echo "--prove: changed the selected-tab font color in the TEMP modloader copy"
fi
run_runner
status=$?
show_log ui | grep -E '^\[ui\]|SCRIPT ERROR' | head -40
script_error_guard
DUMP="$WORK/ui_dump.txt"
[[ $status -eq 0 && ! -s "$DUMP" ]] && { echo "FAILED: the run wrote no dump ($DUMP)." >&2; status=1; }

# An empty stand-in would differ from any dump and let --prove pass.
if [[ $status -eq 0 && $MODE != --update-baseline && ! -f "$BASELINE" ]]; then
    echo "FAILED: $BASELINE is missing; run ./check_ui.sh --update-baseline and review it." >&2
    status=1
fi
# A Windows checkout may hold the baseline with CRLF endings.
differs=0
if [[ $status -eq 0 ]]; then
    { [[ -f "$BASELINE" ]] && tr -d '\r' < "$BASELINE"; } > "$WORK/baseline_lf.txt"
    diff -u --label baseline --label this-build "$WORK/baseline_lf.txt" "$DUMP" > "$WORK/ui_dump.diff" || differs=1
fi

if [[ $MODE == --update-baseline ]]; then
    [[ $status -ne 0 ]] && { echo "FAILED: the harness failed (exit $status); the baseline was not updated." >&2; exit $status; }
    cat "$WORK/ui_dump.diff"
    cp "$DUMP" "$BASELINE"
    echo "OK: wrote $BASELINE ($(wc -l < "$BASELINE") lines); review the diff above before committing"
    exit 0
fi
if [[ $MODE == --prove ]]; then
    [[ $status -eq 0 && $differs -eq 1 ]] && { echo "PROVE-OK: the dump differs as required with the tab color changed (${SECONDS}s)"; exit 0; }
    [[ $status -eq 0 ]] || { echo "PROVE FAILED: the run failed before the comparison (exit $status)." >&2; exit 1; }
    echo "PROVE FAILED: the dump matched the baseline with the selected-tab color changed." >&2
    exit 1
fi
if [[ $differs -eq 1 ]]; then
    status=1
    echo "FAILED: T9: the launcher dump differs from $BASELINE ($(grep -c '^[-+][^-+]' "$WORK/ui_dump.diff") changed line(s)):" >&2
    head -80 "$WORK/ui_dump.diff" >&2
    echo "  If the change is intended, run ./check_ui.sh --update-baseline and review the diff." >&2
fi
report_result UI "dump matches $BASELINE"
