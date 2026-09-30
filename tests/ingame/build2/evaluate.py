#!/usr/bin/env python3
"""Read the game's logs after a launch with the B2 test mods and grade them.

Usage: python tests/ingame/build2/evaluate.py [--minutes N] [--logs DIR]

Looks at every godot*.log under the game's user data folder that changed in
the last N minutes (default 30): the two-pass boot writes more than one file.
Prints one line per check and exits 1 when anything failed. Never launches
the game.
"""
import argparse
import glob
import os
import re
import sys
import time

DEFAULT_LOGS = os.path.join(os.environ.get("APPDATA", ""), "Road to Vostok", "logs")


def load_logs(folder, minutes):
    cutoff = time.time() - minutes * 60
    files = [p for p in glob.glob(os.path.join(folder, "godot*.log")) if os.path.getmtime(p) >= cutoff]
    files.sort(key=os.path.getmtime)
    text = ""
    for p in files:
        with open(p, encoding="utf-8", errors="replace") as f:
            text += "\n### %s\n" % os.path.basename(p) + f.read()
    return files, text


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
    lost = re.findall(r"Hook on AISpawner\.gd::spawnwanderer will NEVER fire", text, re.I)
    check(bool(lost), "removed vanilla method reported as lost", "SpawnWanderer warning %s" % ("present" if lost else "missing"))
    crit = [ln for ln in text.splitlines() if "[ModLoader][Critical]" in ln]
    check(not crit, "no [Critical] loader lines", "; ".join(c.strip()[:160] for c in crit[:5]))
    errs = [ln for ln in text.splitlines() if ln.startswith("SCRIPT ERROR")]
    check(not errs, "no SCRIPT ERROR lines", "; ".join(e.strip()[:160] for e in errs[:5]))
    check("Injected Mods button into main menu" in text, "Mods button injected", "")

    # Test-mod lines.
    b2 = [ln.strip() for ln in text.splitlines() if "[B2TEST]" in ln]
    seen = {}
    for ln in b2:
        m = re.match(r".*\[B2TEST\] (PASS|FAIL|INFO) (\S+ [^:]*): ?(.*)", ln)
        if m:
            seen[m.group(2)] = (m.group(1), m.group(3))
    for name in sorted(seen):
        kind, detail = seen[name]
        if kind == "INFO":
            print("INFO %s: %s" % (name, detail))
        else:
            check(kind == "PASS", "mod " + name, detail)
    expected = ["R1", "R2", "R3a", "R3b", "R3c", "R4a", "R4b", "R4c", "R5a", "R5b", "R5c", "R5d", "R6", "R7",
                "R8a", "R8b", "R8c", "M1", "M2a", "M2b", "M2c", "M3a", "M3b", "M4a", "M4b", "M4c", "M4d",
                "M5a", "M5b", "M6", "M6b", "M7a", "H0", "H1"]
    prefixes = {n.split(" ")[0] for n in seen}
    missing = [e for e in expected if e not in prefixes]
    check(not missing, "every expected test reported", "missing: " + ", ".join(missing) if missing else "all %d" % len(expected))

    width = max(len(r[1]) for r in results)
    fails = 0
    for ok, name, detail in results:
        fails += 0 if ok else 1
        print("%s %s  %s" % ("PASS" if ok else "FAIL", name.ljust(width), detail))
    print("\n%d check(s), %d failed" % (len(results), fails))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
