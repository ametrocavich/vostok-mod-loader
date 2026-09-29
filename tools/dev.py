#!/usr/bin/env python3
"""Find loader definitions, translate build lines, and check local doc references."""
import argparse
from pathlib import Path
import re
import sys
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parent.parent
DEFINITION = re.compile(r"^(?:static )?(?:func|var|const|signal|class_name)\s+(\w+)")
MARKER = re.compile(r"^# source: (src/[\w/.-]+\.gd)$")
REPO = "https://github.com/ametrocavich/vostok-mod-loader/"
LINK = re.compile(r"\[([^\]\n]+)\]\(([^\s)]+)\)")


def source_files():
    """Read the build manifest without executing a shell or the loader."""
    text = (ROOT / "build.sh").read_text(encoding="utf-8")
    return ["src/" + name for name in re.findall(r'^\s*"\$SRC/([\w/.-]+\.gd)"', text, re.M)]


def definitions():
    result = []
    for name in source_files():
        for number, line in enumerate((ROOT / name).read_text(encoding="utf-8").splitlines(), 1):
            match = DEFINITION.match(line)
            if match:
                result.append((match[1], name, number, line))
    return result


def locate(lines, number):
    """Map a one-based built line to the fragment and its one-based line."""
    if number < 1 or number > len(lines):
        raise ValueError(f"line must be between 1 and {len(lines)}")
    source = None
    start = 0
    for index, line in enumerate(lines[:number], 1):
        match = MARKER.fullmatch(line)
        if match:
            source, start = match[1], index
    if source is None:
        raise ValueError("this build has no source markers; run ./build.sh first")
    return source, number - start


def prose(text):
    """Examples can contain deliberately incomplete links and source paths."""
    return re.sub(r"^```[^\n]*\n.*?^```[^\n]*$", "", text, flags=re.M | re.S)


def resolve_link(doc, target):
    parts = urlsplit(target)
    path = unquote(parts.path)
    if target.startswith(REPO):
        tail = target[len(REPO):].split("#", 1)[0].split("?", 1)[0]
        match = re.match(r"(?:blob|tree)/(?:development|master|main)/(.+)", tail)
        if match:
            return ROOT / unquote(match[1])
        if tail.startswith("wiki/"):
            return ROOT / "docs/wiki" / (unquote(tail[5:]) + ".md")
        return None
    if parts.scheme or parts.netloc or not path:
        return None
    candidate = doc.parent / path
    if doc.parent == ROOT / "docs/wiki" and not candidate.suffix:
        candidate = candidate.with_suffix(".md")
    return candidate


def document_errors(doc, text, symbols):
    errors = []
    text = prose(text)
    for label, target in LINK.findall(text):
        path = resolve_link(doc, target)
        if path is None:
            continue
        path = path.resolve()
        if not path.is_relative_to(ROOT) or not path.exists():
            errors.append(f"missing link target: {target}")
            continue
        if path.suffix != ".gd":
            continue
        names = re.findall(r"`([A-Za-z_]\w*)(?:\(\))?`", label)
        if not names and re.fullmatch(r"_?[A-Za-z]\w*", label):
            names = [label]
        for name in names:
            owners = symbols.get(name, set())
            relative = path.relative_to(ROOT).as_posix()
            if relative not in owners:
                hint = ", ".join(sorted(owners)) or "no loader definition"
                errors.append(f"{name} does not belong to {relative} ({hint})")
    for reference in re.findall(r"`(src/[\w/*.-]+\.gd)`", text):
        if not list(ROOT.glob(reference)):
            errors.append(f"missing source reference: {reference}")
    return errors


def check_docs():
    symbols = {}
    for name, path, _, _ in definitions():
        symbols.setdefault(name, set()).add(path)
    docs = [ROOT / "README.md", ROOT / "CONTRIBUTING.md", *sorted((ROOT / "docs").rglob("*.md"))]
    errors = []
    for doc in docs:
        for problem in document_errors(doc, doc.read_text(encoding="utf-8"), symbols):
            errors.append(f"{doc.relative_to(ROOT).as_posix()}: {problem}")
    modules = (ROOT / "docs/wiki/Modules.md").read_text(encoding="utf-8")
    for source in source_files():
        if Path(source).name not in modules:
            errors.append(f"docs/wiki/Modules.md: no entry for {source}")
    for problem in errors:
        print(problem, file=sys.stderr)
    if not errors:
        print(f"Documentation references checked: {len(docs)} pages, {len(source_files())} source files")
    return bool(errors)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    find = commands.add_parser("find", help="find a function, constant, signal or state field")
    find.add_argument("name", help="full name or part of a name; case-insensitive")
    location = commands.add_parser("locate", help="translate a line from a modloader.gd error")
    location.add_argument("line", type=int)
    commands.add_parser("check-docs", help="check local links, named definitions and module coverage")
    args = parser.parse_args()
    if args.command == "find":
        matches = [item for item in definitions() if args.name.lower() in item[0].lower()]
        for _, path, line, declaration in matches:
            print(f"{path}:{line}: {declaration}")
        if not matches:
            print(f"No definition matching {args.name}", file=sys.stderr)
        return not matches
    if args.command == "locate":
        artifact = ROOT / "modloader.gd"
        if not artifact.exists():
            parser.error("modloader.gd is missing; run ./build.sh first")
        lines = artifact.read_text(encoding="utf-8").splitlines()
        try:
            path, number = locate(lines, args.line)
        except ValueError as error:
            parser.error(str(error))
        if number == 0:
            print(f"{path}:1: source boundary")
        else:
            print(f"{path}:{number}: {lines[args.line - 1]}")
            current = (ROOT / path).read_text(encoding="utf-8").splitlines()
            if number > len(current) or current[number - 1] != lines[args.line - 1]:
                print("Source differs from this build; rebuild before relying on its line numbers.", file=sys.stderr)
        return 0
    return check_docs()


if __name__ == "__main__":
    raise SystemExit(main())
