#!/usr/bin/env python3
"""Loader health report from the game logs of ANY launch (real mods, no test
mods needed). Usage: python tests/ingame/build2/loader_health.py [--minutes N]

Prints the mods the loader listed, the STABILITY lines, the hook
reconciliation result (LOST / PARTIAL lines verbatim), script-override
reports, and every [Critical], [Warning], SCRIPT ERROR and ERROR line, so a
run with third-party mods can be judged without reading the whole log.
Exits 1 on a [Critical] line, a demotion, or a SCRIPT ERROR attributed to
the loader's own file; mod-side script errors are listed, not judged.
"""
import argparse
import glob
import os
import re
import sys
import time

DEFAULT_LOGS = os.path.join(os.environ.get("APPDATA", ""), "Road to Vostok", "logs")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--minutes", type=int, default=30)
    ap.add_argument("--logs", default=DEFAULT_LOGS)
    args = ap.parse_args()
    cutoff = time.time() - args.minutes * 60
    files = sorted((p for p in glob.glob(os.path.join(args.logs, "godot*.log")) if os.path.getmtime(p) >= cutoff),
                   key=os.path.getmtime)
    if not files:
        print("no logs changed in the last %d minutes" % args.minutes)
        return 1
    lines = []
    for p in files:
        with open(p, encoding="utf-8", errors="replace") as f:
            lines += ["[%s] %s" % (os.path.basename(p)[5:24], ln.rstrip()) for ln in f]
    print("Logs: " + ", ".join(os.path.basename(p) for p in files))

    def section(title, pattern, limit=40, flags=0):
        hits = [ln for ln in lines if re.search(pattern, ln, flags)]
        print("\n## %s (%d)" % (title, len(hits)))
        for ln in hits[:limit]:
            print("  " + ln[:220])
        return hits

    section("Mods loaded", r"\[ModLoader\]\[Info\] --- \[\d+\]")
    section("STABILITY", r"\[STABILITY\]")
    section("Wrap surface / activation", r"Wrap surface|Activated \d+/\d+|DEFER \d+|Generated \d+ rewritten")
    recon = section("Hook reconciliation", r"Hook reconciliation|LOST |PARTIAL |will NEVER fire")
    section("Script overrides / take_over_path", r"overrideScript|take_over_path|script override|ScriptOverride", 30, re.I)
    crit = section("[Critical]", r"\[ModLoader\]\[Critical\]")
    section("[Warning]", r"\[ModLoader\]\[Warning\]", 30)
    demoted = section("Probe demotions", r"does not compile against this game build")
    errs = section("SCRIPT ERROR", r"^\[[^\]]+\] SCRIPT ERROR", 30)
    loader_errs = []
    for i, ln in enumerate(lines):
        if "SCRIPT ERROR" in ln:
            ctx = " ".join(lines[i:i + 3])
            if "modloader.gd" in ctx:
                loader_errs.append(ln)
    section("Engine ERROR lines", r"^\[[^\]]+\] ERROR:", 20)
    print("\nVerdict: %d critical, %d demoted, %d script errors (%d in modloader.gd), %d reconciliation lines"
          % (len(crit), len(demoted), len(errs), len(loader_errs), len(recon)))
    return 1 if (crit or demoted or loader_errs) else 0


if __name__ == "__main__":
    sys.exit(main())
