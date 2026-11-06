#!/usr/bin/env python3
"""Grade one launch with the LTS test mods from the game's logs and the mods' flushed
progress files. Prints one line per check and exits 1 when anything failed."""
import argparse
import glob
import os
import re
import struct
import sys
import time

TAG = "[LTSTEST]"
CORE_PROGRESS = "ltstest_core_progress.txt"
DEP_PROGRESS = "ltstest_dep_progress.txt"
# The order the mods run them in. Boot phase first, then the menu phase.
BOOT_IDS = ["L0", "D1", "D2", "D3", "D4", "A1", "G1", "G2", "G3", "G4", "G5", "G6", "H1"]
MENU_IDS = ["U1", "U2", "U3", "U4", "U5", "P1", "P2", "P3", "K1", "K2", "N0", "N1", "N2", "N3"]
# IDs whose only line may be INFO: N0 when the network is offline or rate
# limited, N3 when the picked mod has no cover image.
INFO_OK = {"N0", "N3"}
# Excused when N0 reported INFO (offline): they need the network.
NETWORK_IDS = ["N1", "N2", "N3"]
DEP_PATTERN = re.compile(r"ltstestdep|lts_dep", re.I)
CORE_PATTERN = re.compile(r"ltstestcore|lts_core", re.I)
HOIST_LINE = "Load order adjusted: required dependencies load before their dependents."
# Pass 2's first line: the restarted process of a two-pass launch.
RESTART_LINE = "Pass 2 -- "
# Pass 1 arming the restart that the next log belongs to.
ARM_LINE = "Preparing two-pass restart"

STEAM_GAME = "C:/Program Files (x86)/Steam/steamapps/common/Road to Vostok"
# "<ID> <title>: <detail>" after the kind; the title ends at the first colon.
RESULT_RE = re.compile(r"(PASS|FAIL|INFO) ([^\s:]+)(?: ([^:]*?))?(?:: ?(.*))?$")
SUMMARY_RE = re.compile(r"SUMMARY (\S+) (\d+) pass (\d+) fail")


def native_path(p):
    """A Git Bash path (/c/Users/...) as the Windows path Python can open."""
    m = re.match(r"^/([a-zA-Z])(/.*)?$", p or "")
    if m and os.name == "nt":
        return m.group(1).upper() + ":" + (m.group(2) or "/")
    return p


def read_pck_header(path):
    """(pack_format, (major, minor, patch)) from a PCK header, or None.
    Bytes 0..4 are "GDPC", then four little-endian uint32: pack format,
    Godot major, minor, patch."""
    try:
        with open(path, "rb") as f:
            head = f.read(20)
    except OSError:
        return None
    if len(head) < 20 or head[:4] != b"GDPC":
        return None
    fmt, major, minor, patch = struct.unpack("<4I", head[4:20])
    return fmt, (major, minor, patch)


def parse_godot_version(text):
    """(major, minor, patch) from "4.6.3-stable (official)" or "4.6-stable":
    Godot leaves a zero patch out of its version string."""
    m = re.match(r"(\d+)\.(\d+)(?:\.(\d+))?(?![\d])", text)
    if not m:
        return None
    return int(m.group(1)), int(m.group(2)), int(m.group(3) or 0)


def read_text(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def latest_run(found):
    """The newest launch among found logs: the newest file, plus the Pass 1 log
    before it when the newest is that launch's Pass 2 restart."""
    found = sorted(found, key=os.path.getmtime, reverse=True)
    if not found:
        return []
    run = [found[0]]
    if RESTART_LINE in read_text(found[0]):
        if len(found) > 1 and ARM_LINE in read_text(found[1]):
            run.append(found[1])
        else:
            print("WARN the newest log is a Pass 2 restart, but the log before it did not arm one;"
                  " grading the newest log only")
    return run


def load_logs(paths, minutes):
    """Files named directly are read as given; a folder gives its latest run, or
    every godot*.log changed in the last `minutes` when that is set."""
    files = []
    for p in paths:
        p = native_path(p)
        if os.path.isfile(p):
            files.append(p)
            continue
        found = glob.glob(os.path.join(p, "godot*.log"))
        if minutes is None:
            files += latest_run(found)
        else:
            cutoff = time.time() - minutes * 60
            files += [q for q in found if os.path.getmtime(q) >= cutoff]
    files = sorted(set(files), key=os.path.getmtime)
    lines = []
    for p in files:
        with open(p, encoding="utf-8", errors="replace") as f:
            lines += [ln.rstrip("\r\n") for ln in f]
    return files, lines


def read_progress(path):
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8", errors="replace") as f:
        return [ln.strip() for ln in f if ln.strip()]


def collect(lines, from_progress, entries, summaries):
    """Result lines into entries {(id, title, detail): kind}. A progress line
    is the log line prefixed by the time; the tag may or may not be kept."""
    for ln in lines:
        body = ln.strip()
        if from_progress:
            body = re.sub(r"^\d{1,2}:\d{2}:\d{2} ", "", body)
            if body.startswith(TAG + " "):
                body = body[len(TAG) + 1:]
        else:
            i = body.find(TAG + " ")
            if i < 0:
                continue
            body = body[i + len(TAG) + 1:]
        m = SUMMARY_RE.match(body)
        if m:
            summaries[m.group(1)] = (int(m.group(2)), int(m.group(3)))
            continue
        m = RESULT_RE.match(body)
        if m:
            key = (m.group(2), (m.group(3) or "").strip(), (m.group(4) or "").strip())
            # Same line in the log and the progress file: one entry. A FAIL
            # copy of a line wins over a PASS copy.
            if entries.get(key) != "FAIL":
                entries[key] = m.group(1)


def health_checks(lines, text, header):
    """The loader's own health lines: stability, rewrites, errors, the Mods button."""
    out = []
    m = re.search(r"\[STABILITY\] Detokenizer compatible: GDSC v(\d+) on Godot (.+)$", text, re.M)
    if not m:
        out.append((False, "STABILITY detokenizer line", "missing"))
    elif header:
        out.append((parse_godot_version(m.group(2)) == header[1], "STABILITY detokenizer line on the PCK's Godot",
                    "%s; RTV.pck says %d.%d.%d" % (m.group(0).strip(), header[1][0], header[1][1], header[1][2])))
    else:
        out.append((True, "STABILITY detokenizer line", m.group(0).strip() + " (no PCK to pin the version)"))
    out.append(("VFS canary OK" in text, "STABILITY VFS canary", "present" if "VFS canary OK" in text else "missing"))
    m = re.search(r"COMPILE-PROOF summary: (\d+)/(\d+) rewrites active", text)
    out.append((bool(m) and m.group(1) == m.group(2) and int(m.group(1)) > 0,
                "COMPILE-PROOF all rewrites active", m.group(0) if m else "missing"))
    demoted = [ln.strip() for ln in lines if "does not compile against this game build" in ln
               or "Repeating the last probe's verdicts" in ln]
    for pm in re.finditer(r"Probe-compiled \d+ rewrite\(s\).*?(\d+) without registry code, (\d+) left vanilla", text):
        if pm.group(1) != "0" or pm.group(2) != "0":
            demoted.append(pm.group(0))
    crit = [ln.strip() for ln in lines if "[ModLoader][Critical]" in ln]
    errs = [ln.strip() for ln in lines if ln.lstrip().startswith("SCRIPT ERROR")]
    for found, name in ((demoted, "no probe demotions"), (crit, "no [Critical] loader lines"),
                        (errs, "no SCRIPT ERROR lines")):
        out.append((not found, name, "; ".join(x[:160] for x in found[:3]) or "none"))
    out.append(("Injected Mods button into main menu" in text, "Mods button injected",
                "present" if "Injected Mods button into main menu" in text else "missing"))
    return out


def load_order_checks(lines):
    """In every load-order listing (one per pass) lts_dep comes before lts_core, and
    only because the dependency hoist moved it: lts_core has the lower priority."""
    blocks, cur = [], None
    for ln in lines:
        if "=== Load Order" in ln:
            cur = {}
            blocks.append(cur)
            continue
        om = re.search(r"\[ModLoader\]\[Info\] (?:  |--- )\[(\d+)\] (.*)$", ln)
        if om and cur is not None:
            pm = re.search(r"\[priority=(-?\d+)\]\s*$", om.group(2))
            for key, pat in (("dep", DEP_PATTERN), ("core", CORE_PATTERN)):
                if pat.search(om.group(2)):
                    cur.setdefault(key, int(om.group(1)))
                    if pm:
                        cur.setdefault(key + "_priority", int(pm.group(1)))
    both = [b for b in blocks if "dep" in b and "core" in b]
    prio = [b for b in both if "dep_priority" in b and "core_priority" in b]
    hoisted = any(HOIST_LINE in ln for ln in lines)
    cycles = [ln.strip() for ln in lines if "cycle" in ln.lower() and re.search(r"lts_|ltstest", ln, re.I)]
    return [(bool(both) and all(b["dep"] < b["core"] for b in both), "load order lists lts_dep before lts_core",
             "; ".join("dep [%d] core [%d]" % (b["dep"], b["core"]) for b in both)
             or "no load-order listing names both test mods"),
            (hoisted and bool(prio) and all(b["core_priority"] <= b["dep_priority"] for b in prio),
             "dependency hoist ordered lts_dep first",
             "; ".join("priority core %d dep %d" % (b["core_priority"], b["dep_priority"]) for b in prio)
             + ("; hoist line present" if hoisted else "; no '%s' line" % HOIST_LINE)),
            (not cycles, "no dependency cycle reported for the test mods",
             "; ".join(c[:160] for c in cycles[:3]) or "none")]


def mod_checks(lines, text, userdata):
    """The test mods' own result lines, from the log and the progress files merged."""
    out = []
    entries, summaries = {}, {}
    collect(lines, False, entries, summaries)
    core_steps = read_progress(os.path.join(userdata, CORE_PROGRESS))
    dep_steps = read_progress(os.path.join(userdata, DEP_PROGRESS))
    for steps in (core_steps, dep_steps):
        if steps:
            collect(steps, True, entries, summaries)
    out.append((core_steps is not None and bool(core_steps) and core_steps[-1].endswith("menu tests done"),
                "core mod ran to the end (progress file)",
                ("last line: " + core_steps[-1]) if core_steps else "%s missing or empty" % CORE_PROGRESS))
    out.append((dep_steps is not None, "dep mod wrote its progress file",
                DEP_PROGRESS + (" present" if dep_steps is not None else " missing")))
    if entries and not re.search(r"\[LTSTEST\] SUMMARY menu", text):
        print("WARN the game log ends early (%d lines): it was not flushed at exit; the progress files fill the gap"
              % len(lines))
    for phase in ("boot", "menu"):
        if phase in summaries:
            print("INFO mod summary %s: %d pass, %d fail" % ((phase,) + summaries[phase]))

    by_id = {}
    for (rid, title, detail), kind in entries.items():
        by_id.setdefault(rid, []).append((kind, title, detail))
    offline = [d for k, t, d in by_id.get("N0", []) if k == "INFO"] and not any(
        k == "PASS" for k, _t, _d in by_id.get("N0", []))
    if offline:
        n0 = [(t + ": " + d).strip(": ") for k, t, d in by_id["N0"] if k == "INFO"]
        print("INFO N0 offline, N1-N3 not required: " + "; ".join(n0))
    for rid in BOOT_IDS + MENU_IDS:
        got = by_id.get(rid, [])
        if not got:
            if not (offline and rid in NETWORK_IDS):
                out.append((False, "mod " + rid, "not reported"))
            continue
        fails = [g for g in got if g[0] == "FAIL"]
        shown = "; ".join("%s %s: %s" % g for g in (fails or got)[:3])
        if fails:
            out.append((False, "mod " + rid, shown))
        elif not any(g[0] == "PASS" for g in got) and rid not in INFO_OK:
            out.append((False, "mod " + rid, "reported only as INFO: " + shown))
        elif rid == "H1" and len(got) < 2:
            out.append((False, "mod H1", "one H1 line; the menu callback never reported (%s)" % shown))
        else:
            out.append((True, "mod " + rid, shown))
    for rid in sorted(set(by_id) - set(BOOT_IDS + MENU_IDS)):
        for kind, title, detail in by_id[rid]:
            if kind == "FAIL":
                out.append((False, "mod " + rid, "%s: %s" % (title, detail)))
            else:
                print("INFO mod %s %s %s: %s" % (rid, kind, title, detail))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--minutes", type=int, default=None,
                    help="read every log changed in the last N minutes instead of the latest run")
    ap.add_argument("--logs", action="append", default=None,
                    help="log folder or file (repeatable); default <userdata>/logs")
    ap.add_argument("--userdata", default=None,
                    help="folder that holds the progress files (default $USERDATA or %%APPDATA%%/Road to Vostok)")
    ap.add_argument("--pck", default=None, help="the game's RTV.pck (default $GAME/RTV.pck)")
    args = ap.parse_args()
    userdata = (native_path(args.userdata or os.environ.get("USERDATA") or "")
                or os.path.join(os.environ.get("APPDATA", ""), "Road to Vostok"))
    log_paths = args.logs or [os.path.join(userdata, "logs")]
    pck = native_path(args.pck or "") or os.path.join(native_path(os.environ.get("GAME", "")) or STEAM_GAME, "RTV.pck")

    files, lines = load_logs(log_paths, args.minutes)
    if not files:
        since = "" if args.minutes is None else "changed in the last %d minutes " % args.minutes
        print("FAIL no godot*.log %sunder %s" % (since, ", ".join(log_paths)))
        return 1
    text = "\n".join(lines)
    print("Logs read: " + ", ".join(os.path.basename(p) for p in files))

    header = read_pck_header(pck)
    if header:
        fmt, ver = header
        print("INFO pck: %s, pack format %d, Godot %d.%d.%d" % (pck, fmt, ver[0], ver[1], ver[2]))
    else:
        print("INFO pck: no readable PCK header at %s; the Godot version pin is skipped" % pck)
    for pat in (r"^Godot Engine v\S+", r"Metro Mod Loader v\S+", r"\[FileScope\] Engine: .*"):
        m = re.search(pat, text, re.M)
        if m:
            print("INFO build: " + m.group(0))
    for ln in lines:
        if "[STABILITY]" in ln:
            print("INFO " + ln.strip())

    results = health_checks(lines, text, header) + load_order_checks(lines) + mod_checks(lines, text, userdata)
    width = max(len(r[1]) for r in results)
    for ok, name, detail in results:
        print("%s %s  %s" % ("PASS" if ok else "FAIL", name.ljust(width), detail))
    fails = sum(1 for r in results if not r[0])
    print("\n%d check(s), %d failed" % (len(results), fails))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
