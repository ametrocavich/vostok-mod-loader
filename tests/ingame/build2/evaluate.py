#!/usr/bin/env python3
"""Read the game's logs after a launch with the B2 test mods and grade them.

Usage: python tests/ingame/build2/evaluate.py [--minutes N] [--logs DIR]

Looks at every godot*.log under the game's user data folder that changed in
the last N minutes (default 30): the two-pass boot writes more than one file.
The game log is buffered and a crash at exit loses its tail (this machine's
RTV.exe has crashed on exit with one WER signature since May 2026), so the
test mods also write flushed progress files under user://; those are the
second source of PASS/FAIL. Prints one line per check and exits 1 when
anything failed. Never launches the game.
"""
import argparse
import glob
import os
import re
import sys
import time

DEFAULT_LOGS = os.path.join(os.environ.get("APPDATA", ""), "Road to Vostok", "logs")
EXPECTED = ["R1", "R2", "R3a", "R3b", "R3c", "R4a", "R4b", "R4c", "R5a", "R5b", "R5c", "R5d", "R6", "R7",
            "R8a", "R8b", "R8c", "M1", "M2a", "M2b", "M2c", "M3a", "M3b", "M4a", "M4b", "M4c", "M4d",
            "M5a", "M5b", "M6", "M6b", "M7a", "M8", "H0", "H1"]


def load_logs(folder, minutes):
    cutoff = time.time() - minutes * 60
    files = [p for p in glob.glob(os.path.join(folder, "godot*.log")) if os.path.getmtime(p) >= cutoff]
    files.sort(key=os.path.getmtime)
    text = ""
    for p in files:
        with open(p, encoding="utf-8", errors="replace") as f:
            text += "\n### %s\n" % os.path.basename(p) + f.read()
    return files, text


def read_progress(path, results):
    """Flushed per-step file: '<time> PASS|FAIL <name>: <detail>' lines."""
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8", errors="replace") as f:
        steps = [ln.strip() for ln in f if ln.strip()]
    for ln in steps:
        m = re.match(r"[\d:]+ (PASS|FAIL|INFO) (\S+ [^:]*)(?:: ?(.*))?$", ln)
        if m and m.group(1) == "INFO":
            results.setdefault("_info", []).append((m.group(2), m.group(3) or ""))
        elif m:
            results[m.group(2)] = (m.group(1), (m.group(3) or "") + " (from progress file)")
    return steps


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--minutes", type=int, default=30)
    ap.add_argument("--logs", default=DEFAULT_LOGS)
    args = ap.parse_args()
    files, text = load_logs(args.logs, args.minutes)
    results = []

    def check(ok, name, detail=""):
        results.append((ok, name, detail))

    if not files:
        print("FAIL no godot*.log changed in the last %d minutes under %s" % (args.minutes, args.logs))
        return 1
    print("Logs read: " + ", ".join(os.path.basename(p) for p in files))

    # Loader health lines.
    m = re.search(r"\[STABILITY\] Detokenizer compatible: GDSC v(\d+) on Godot ([\w.\-]+)", text)
    check(bool(m) and m.group(1) == "101" and m.group(2).startswith("4.6.3"),
          "STABILITY detokenizer line", m.group(0) if m else "missing")
    check("VFS canary OK" in text, "STABILITY VFS canary", "present" if "VFS canary OK" in text else "missing")
    m = re.search(r"COMPILE-PROOF summary: (\d+)/(\d+) rewrites active", text)
    check(bool(m) and m.group(1) == m.group(2) and int(m.group(1)) > 0,
          "COMPILE-PROOF all rewrites active", m.group(0) if m else "missing")
    demoted = re.findall(r"does not compile against this game build", text)
    check(not demoted, "no probe demotions", "%d demotion line(s)" % len(demoted))
    lost = re.findall(r"Hook on AISpawner\.gd::spawnwanderer will NEVER fire|PARTIAL .*AISpawner\.gd.*spawnwanderer", text, re.I)
    check(bool(lost), "removed vanilla method reported as lost", "SpawnWanderer warning/ledger line %s" % ("present" if lost else "missing"))
    crit = [ln for ln in text.splitlines() if "[ModLoader][Critical]" in ln]
    check(not crit, "no [Critical] loader lines", "; ".join(c.strip()[:160] for c in crit[:5]))
    errs = [ln for ln in text.splitlines() if ln.startswith("SCRIPT ERROR")]
    check(not errs, "no SCRIPT ERROR lines", "; ".join(e.strip()[:160] for e in errs[:5]))

    # Test-mod results: progress files first, log lines override with detail.
    userdata = os.path.dirname(args.logs)
    seen = {}
    steps = read_progress(os.path.join(userdata, "b2test_progress.txt"), seen)
    if steps:
        check(steps[-1].endswith("menu tests done"), "test mod ran to the end (progress file)", "last step: " + steps[-1])
    read_progress(os.path.join(userdata, "b2test_hooks_progress.txt"), seen)
    for ln in text.splitlines():
        m = re.match(r".*\[B2TEST\] (PASS|FAIL|INFO) (\S+ [^:]*): ?(.*)", ln.strip())
        if m:
            seen[m.group(2)] = (m.group(1), m.group(3))
    if seen and not re.search(r"\[B2TEST\] SUMMARY menu", text):
        print("WARN game log ends early (%d lines): the game did not flush it at exit; progress files fill the gap"
              % text.count("\n"))
    button = "Injected Mods button into main menu" in text or \
        any(k.startswith("M8") and v[0] == "PASS" for k, v in seen.items())
    check(button, "Mods button injected", "log line or M8 check")
    infos = seen.pop("_info", [])
    for name in sorted(seen):
        kind, detail = seen[name]
        if kind == "INFO":
            infos.append((name, detail))
        else:
            check(kind == "PASS", "mod " + name, detail)
    # Optional map section: only when a map was loaded with the test profile.
    map_lines = [d for n, d in infos if n.startswith("map ")]
    if map_lines:
        selects = [d for n, d in infos if n.startswith("map AI.SelectWeapon")]
        inits = [d for n, d in infos if n.startswith("map AISpawner.Initialize")]
        print("MAP  %d Initialize / %d SelectWeapon hook line(s) from a real map" % (len(inits), len(selects)))
        for d in inits[:3]:
            print("MAP  spawner: " + d)
        variants = {}
        for d in selects:
            v = d.split(" ")[0]
            variants[v] = variants.get(v, 0) + 1
        print("MAP  AI variants seen: " + ", ".join("%s x%d" % kv for kv in sorted(variants.items())))
        guard_in_area05 = any("zone=0" in d and "AI_Guard" in d for d in inits)
        if any("zone=0" in d for d in inits):
            check(guard_in_area05, "map: Area05 spawner uses the ai_types override (AI_Guard)", "; ".join(inits[:2]))
            check("variant=Guard" in " ".join(selects), "map: guards spawned in Area05 (override took effect in play)", "%d SelectWeapon lines" % len(selects))
        boss = [d for d in selects if "variant=Punisher" in d or "variant=Bogeyman" in d]
        if boss:
            check(all("Makarov" in d for d in boss), "map: boss carries the injected Makarov", "; ".join(boss[:2]))
        else:
            print("INFO map: no boss SelectWeapon line (bosses pool at map load; none seen)")
    else:
        for n, d in infos:
            print("INFO %s: %s" % (n, d))
    prefixes = {n.split(" ")[0] for n in seen}
    missing = [e for e in EXPECTED if e not in prefixes]
    check(not missing, "every expected test reported", "missing: " + ", ".join(missing) if missing else "all %d" % len(EXPECTED))

    width = max(len(r[1]) for r in results)
    fails = 0
    for ok, name, detail in results:
        fails += 0 if ok else 1
        print("%s %s  %s" % ("PASS" if ok else "FAIL", name.ljust(width), detail))
    print("\n%d check(s), %d failed" % (len(results), fails))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
