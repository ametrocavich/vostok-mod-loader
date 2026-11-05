#!/usr/bin/env bash
# check_dispatch.sh [--prove]: runs the hook wrappers the real rewriter emits (tests/codegen/dispatch_runner.gd).
# --prove breaks the wrapper template three ways in the TEMP loader copy; each must fail its guarding test.
set -uo pipefail
cd "$(dirname "$0")"
source tests/lib.sh

find_godot
require_build

prepare_work() {
    make_project modloader-dispatch-check tests/codegen/dispatch_runner.gd
    mkdir -p "$WORK/Scripts"
    cp tests/codegen/FixtureDispatch.gd "$WORK/Scripts/"
    neuter_loader
}

if [[ "${1:-}" != "--prove" ]]; then
    prepare_work
    run_runner
    status=$?
    show_log dispatch
    report_result dispatch
fi

# The template's skip_super capture is forced false: vanilla always runs.
prove_mutation prepare_work "skip_super ignored" 'var _rtv_did_skip = _rtv_lib._skip_super' 2 \
    's/var _rtv_did_skip = _rtv_lib\._skip_super/var _rtv_did_skip = false/g' T2b
# _dispatch_post still runs (observers fire) but its return is discarded.
prove_mutation prepare_work "post result mutation dropped" '_rtv_result = _rtv_lib._dispatch_post' 1 \
    's/_rtv_result = _rtv_lib\._dispatch_post/var _rtv_mut_ignored = _rtv_lib._dispatch_post/' T3a
# The re-entry key is read instead of erased, so the first dispatch disables the hooks for good.
prove_mutation prepare_work "re-entrancy guard leaks" '_rtv_lib._wrapper_active.erase(_rtv_wa_key)' 2 \
    's/_rtv_lib\._wrapper_active\.erase\(_rtv_wa_key\)/_rtv_lib._wrapper_active.get(_rtv_wa_key)/g' T9
report_proves
