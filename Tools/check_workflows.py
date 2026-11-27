#!/usr/bin/env python3
"""Fail when a workflow file contains YAML that GitHub rejects.

The bug this exists for: an unquoted scalar containing ": " (for example
``name: Guard: Xcode project references``) silently invalidates the whole workflow, the run shows up
as ``.github/workflows/ci.yml`` with zero jobs, and no log is produced anywhere.
"""
import re
import sys
from pathlib import Path

WORKFLOWS = Path(".github/workflows")


def check(path: Path) -> list:
    problems = []
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if "\t" in line:
            problems.append(f"{path}:{number}: tab indentation")
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        # A mapping value that is an unquoted scalar may not contain ": " or " #".
        match = re.match(r"^\s*(?:-\s+)?[\w.\"'/-]+:\s+(.*)$", line)
        if match:
            value = match.group(1).strip()
            if value.startswith(('"', "'", "|", ">", "[", "{", "&", "*", "!")):
                continue
            if ": " in value:
                problems.append(f"{path}:{number}: unquoted value contains ': '")
    return problems


def main() -> int:
    files = sorted(WORKFLOWS.glob("*.yml")) + sorted(WORKFLOWS.glob("*.yaml"))
    if not files:
        print("error: no workflow files found")
        return 1
    problems = []
    for path in files:
        problems.extend(check(path))
    if problems:
        for problem in problems:
            print("error:", problem)
        return 1
    print(f"ok: {len(files)} workflow files are structurally valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
