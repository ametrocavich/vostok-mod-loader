#!/usr/bin/env bash
# selfcheck.sh -- parse-check the LTS test mods without game classes and prove evaluate.py
# on its fixtures. Never launches the game; ./build.sh must have run. check.sh does not run it.
set -uo pipefail
cd "$(dirname "$0")/../../.."
source tests/lib.sh

KIT=tests/ingame/lts
PY=$(command -v python || command -v python3 || true)
[[ -n "$PY" ]] || { echo "ERROR: python not found" >&2; exit 127; }
find_godot
require_build
make_project ltstest-selfcheck
neuter_loader
status=0
SECONDS=0

fail() {
    echo "  FAIL: $*" >&2
    status=1
}

# Each mod's files sit at the res:// paths its mounted zip gives them.
scripts=()
for mod in "$KIT"/mods/*/; do
    [[ -d "$mod" ]] || continue
    cp -r "$mod". "$WORK/"
    while IFS= read -r gd; do
        scripts+=("${gd#"$mod"}")
    done < <(find "$mod" -name '*.gd' | sort)
done
if [[ ${#scripts[@]} -eq 0 ]]; then
    fail "no .gd files under $KIT/mods"
fi
for rel in "${scripts[@]}"; do
    log="$WORK/parse_$(echo "$rel" | tr '/' '_').log"
    "$GODOT" --headless --path "$WORK" --check-only --script "res://$rel" > "$log" 2>&1
    rc=$?
    if [[ $rc -ne 0 ]] || grep -qE 'SCRIPT ERROR|Parse Error' "$log"; then
        fail "res://$rel does not parse standalone (exit $rc):"
        grep -E 'SCRIPT ERROR|Parse Error|ERROR' "$log" | head -5 | sed 's/^/        /' >&2
    else
        echo "  parsed res://$rel"
    fi
done

"$PY" -c "import struct, sys
for path, patch in ((sys.argv[1], 3), (sys.argv[2], 0)):
    open(path, 'wb').write(b'GDPC' + struct.pack('<4I', 3, 4, 6, patch))" "$WORK/pck463.pck" "$WORK/pck460.pck"
mkdir -p "$WORK/empty"

# grade NAME WANT_EXIT LOG USERDATA PCK [ARGS...] -> output in $WORK/grade_NAME.txt
grade() {
    local out="$WORK/grade_$1.txt" rc
    "$PY" "$KIT/evaluate.py" --logs "$3" --userdata "$4" --pck "$5" "${@:6}" > "$out" 2>&1
    rc=$?
    if [[ $rc -ne $2 ]]; then
        fail "evaluate.py on $1 exited $rc, want $2 (output: $out)"
        grep -E '^(FAIL|Traceback)|Error' "$out" | head -8 | sed 's/^/        /' >&2
    fi
}

# only_fails NAME EXPECTED...: the FAIL check names in grade_NAME.txt are
# exactly EXPECTED (a grader that fails for the wrong reason is wrong too).
only_fails() {
    local name="$1"; shift
    local got want
    got=$(sed -n 's/^FAIL \([^ ]\([^ ]\| [^ ]\)*\)  .*$/\1/p' "$WORK/grade_$name.txt" | sort)
    want=$(printf '%s\n' "$@" | sort)
    if [[ "$got" != "$want" ]]; then
        fail "evaluate.py on $name failed on the wrong checks"
        diff <(echo "$want") <(echo "$got") | sed 's/^/        /' >&2
    fi
}

F="$KIT/fixtures"
grade pass 0 "$F/sample_pass.log" "$F" "$WORK/pck463.pck"
grep -q '^39 check(s), 0 failed$' "$WORK/grade_pass.txt" || fail "pass case: no '39 check(s), 0 failed' line"
grep -q '^WARN the game log ends early' "$WORK/grade_pass.txt" || fail "pass case: the truncated log was not noticed"
grep -q '^PASS mod K2 ' "$WORK/grade_pass.txt" || fail "pass case: K2 (progress file only) was not read"

grade version 1 "$F/sample_pass.log" "$F" "$WORK/pck460.pck"
only_fails version "STABILITY detokenizer line on the PCK's Godot"

grade nopck 0 "$F/sample_pass.log" "$F" "$WORK/no_such.pck"
grep -q '^INFO pck: no readable PCK header' "$WORK/grade_nopck.txt" || fail "no-PCK case: the skipped pin was not reported"

grade fail 1 "$F/sample_fail.log" "$WORK/empty" "$WORK/pck463.pck"
only_fails fail "mod D4" "no SCRIPT ERROR lines" "no probe demotions" "no [Critical] loader lines" \
    "core mod ran to the end (progress file)" "dep mod wrote its progress file"
grep -q '^INFO N0 offline' "$WORK/grade_fail.txt" || fail "fail case: the offline N0 was not reported"

# Priority order alone (no hoist line, lts_core listed with the higher priority) is not proof.
grep -v '^\[ModLoader\]\[Info\] Load order adjusted' "$F/sample_pass.log" > "$WORK/nohoist.log"
grade nohoist 1 "$WORK/nohoist.log" "$F" "$WORK/pck463.pck"
only_fails nohoist "dependency hoist ordered lts_dep first"
sed 's/LTSTestDep.zip \[priority=5\]/LTSTestDep.zip [priority=-1]/' "$F/sample_pass.log" > "$WORK/byprio.log"
grade byprio 1 "$WORK/byprio.log" "$F" "$WORK/pck463.pck"
only_fails byprio "dependency hoist ordered lts_dep first"

# A logs folder grades its newest run only: Pass 1 armed the restart, godot.log is Pass 2.
# runs_KIND: an older run with the other outcome, then a newer KIND run.
for kind in pass fail; do
    R="$WORK/runs_$kind"
    old=fail; [[ $kind == fail ]] && old=pass
    mkdir -p "$R"
    cp "$F/sample_pass1.log" "$R/godot2026-01-01T10.00.00.log"
    cp "$F/sample_$old.log" "$R/godot2026-01-01T10.05.00.log"
    cp "$F/sample_pass1.log" "$R/godot2026-01-01T11.00.00.log"
    cp "$F/sample_$kind.log" "$R/godot.log"
    touch -d "2026-01-01 10:00:00" "$R/godot2026-01-01T10.00.00.log"
    touch -d "2026-01-01 10:05:00" "$R/godot2026-01-01T10.05.00.log"
    touch -d "2026-01-01 11:00:00" "$R/godot2026-01-01T11.00.00.log"
    touch -d "2026-01-01 11:05:00" "$R/godot.log"
done
grade runs_pass 0 "$WORK/runs_pass" "$F" "$WORK/pck463.pck"
grep -q '^Logs read: godot2026-01-01T11.00.00.log, godot.log$' "$WORK/grade_runs_pass.txt" \
    || fail "runs_pass: did not read the newest run's two logs only"
grade runs_fail 1 "$WORK/runs_fail" "$F" "$WORK/pck463.pck"
only_fails runs_fail "no SCRIPT ERROR lines" "no probe demotions" "no [Critical] loader lines"
grade runs_minutes 1 "$WORK/runs_pass" "$F" "$WORK/pck463.pck" --minutes 99999999
grep -q '^Logs read: .*10.00.00.log, .*10.05.00.log, .*11.00.00.log, godot.log$' "$WORK/grade_runs_minutes.txt" \
    || fail "runs_minutes: --minutes did not read every log in the window"

# Dry runs of install.sh and restore.sh on fake GAME and USERDATA trees under $WORK. A fake
# tasklist on PATH answers the game-running check (RTV.exe while $D/bin/running exists).
D="$WORK/dry"
mkdir -p "$D/bin"
printf '#!/usr/bin/env bash\n[[ -f "%s/running" ]] && echo "RTV.exe 1234 Console"\nexit 0\n' "$D/bin" > "$D/bin/tasklist"
chmod +x "$D/bin/tasklist"
dry_runs=0

# kit NAME WANT_EXIT SCRIPT: run SCRIPT on $D/game and $D/user, output in $D/NAME.txt
kit() {
    local rc
    GAME="$D/game" USERDATA="$D/user" PATH="$D/bin:$PATH" bash "$KIT/$3" > "$D/$1.txt" 2>&1
    rc=$?
    dry_runs=$((dry_runs + 1))
    if [[ $rc -ne $2 ]]; then
        fail "$3 ($1) exited $rc, want $2:"
        sed 's/^/        /' "$D/$1.txt" >&2
    fi
}
expect() {
    grep -qE "$2" "$D/$1.txt" || fail "$1: no line matching '$2'"
}
same_tree() {
    diff -r "$1" "$2" > "$D/diff.txt" 2>&1 || { fail "$3:"; sed 's/^/        /' "$D/diff.txt" >&2; }
}
# A launch: the loader saves the cfg and rolls the .bak, mods rewrite MCM, profile switches
# fill and drop snapshot slots, the kit writes its progress files.
fake_run() {
    echo "lts_marker=true" >> "$D/user/mod_config.cfg"
    cp "$D/user/mod_config.cfg" "$D/user/mod_config.cfg.bak"
    mkdir -p "$D/user/MCM/FakeMod" "$D/user/MCM/LTSMod" "$D/user/.profile_snapshots/LTSTemp/MCM"
    echo "run" > "$D/user/MCM/FakeMod/config.ini"
    echo "run" > "$D/user/MCM/LTSMod/config.ini"
    rm -rf "$D/user/.profile_snapshots/_before_modpack_Fake Pack"
    echo "step D0" > "$D/user/ltstest_dep_progress.txt"
}

# A player with a pack applied: its flag and backup keys, both managed sections, the pack's
# MCM live and two snapshot slots.
rm -rf "$D/game" "$D/user" "$D/orig"
S="$D/user/.profile_snapshots"
mkdir -p "$D/game/mods" "$D/user/MCM/FakeMod" "$S/Default/MCM/FakeMod" "$S/_before_modpack_Fake Pack/MCM/FakeMod"
cat > "$D/user/mod_config.cfg" <<'EOF'
[settings]

active_profile="modpack__Fake Pack"
ui_scale=1.0
active_modpack="Fake Pack"
modpack_backup_profile="Default"
modpack_backup_valid=true

[profile.Default.enabled]

fake@1.0.0=true

[profile._before_modpack_Fake Pack.enabled]

fake@1.0.0=true

[profile.modpack__Fake Pack.enabled]

fake@1.0.0=false
EOF
cp "$D/user/mod_config.cfg" "$D/user/mod_config.cfg.bak"
echo "pack" > "$D/user/MCM/FakeMod/config.ini"
echo "default" > "$S/Default/MCM/FakeMod/config.ini"
echo "before" > "$S/_before_modpack_Fake Pack/MCM/FakeMod/config.ini"
cp -a "$D/user" "$D/orig"

touch "$D/bin/running"
kit running 1 install.sh
expect running 'Road to Vostok is running'
rm -f "$D/bin/running"
[[ -e "$D/user/ltstest_backup" ]] && fail "install made a backup while the game ran"

kit pack_install 0 install.sh
expect pack_install '^modpack "Fake Pack" unloaded for the run'
same_tree "$D/orig" "$D/user/ltstest_backup" "the backup differs from the player's files"
cp "$D/user/mod_config.cfg" "$WORK/dry_cfg.cfg"
cat > "$WORK/dry_cfg.gd" <<'EOF'
extends SceneTree
func _init() -> void:
	var cfg := ConfigFile.new()
	var err := cfg.load("res://dry_cfg.cfg")
	var slots := cfg.has_section("profile.modpack__Fake Pack.enabled") \
			and cfg.has_section("profile._before_modpack_Fake Pack.enabled")
	print("DRYCFG err=%d profile=%s settings=%s slots=%s" % [err,
			cfg.get_value("settings", "active_profile", ""), ",".join(cfg.get_section_keys("settings")), slots])
	quit()
EOF
"$GODOT" --headless --path "$WORK" --script res://dry_cfg.gd > "$D/cfg.txt" 2>&1
expect cfg '^DRYCFG err=0 profile=LTSTest settings=active_profile,ui_scale slots=true$'

fake_run
kit pack_install2 1 install.sh
expect pack_install2 'run tests/ingame/lts/restore.sh first'
same_tree "$D/orig" "$D/user/ltstest_backup" "a second install changed the backup"

kit pack_restore 0 restore.sh
same_tree "$D/orig" "$D/user" "restore did not bring the player's files back"
[[ -z "$(ls -A "$D/game/mods")" ]] || fail "restore left files in the mods folder"
kit pack_restore2 0 restore.sh
expect pack_restore2 'nothing to restore'

# A player with only mod_config.cfg: everything else the run made goes away.
rm -rf "$D/game" "$D/user" "$D/orig"
mkdir -p "$D/game/mods" "$D/user"
printf '[settings]\n\nactive_profile="Default"\n' > "$D/user/mod_config.cfg"
cp -a "$D/user" "$D/orig"
kit bare_install 0 install.sh
fake_run
kit bare_restore 0 restore.sh
same_tree "$D/orig" "$D/user" "restore left what the run created"

printf '\n[profile.LTSTemp.enabled]\n\nx=true\n' >> "$D/user/mod_config.cfg"
kit taken 1 install.sh
expect taken 'already has a profile named LTSTest or LTSTemp'
[[ -e "$D/user/ltstest_backup" ]] && fail "install made a backup for a taken profile name"
echo "  dry runs: $dry_runs (pack applied, bare player, refusals)"

if [[ $status -eq 0 ]]; then
    echo "OK: LTS kit self-check (${#scripts[@]} mod script(s) parsed, 9 grader cases, $dry_runs install/restore dry runs, ${SECONDS}s)"
else
    echo "FAILED: LTS kit self-check (${SECONDS}s). Outputs in $WORK" >&2
fi
exit "$status"
