#!/usr/bin/env python3
"""Verify that the committed Xcode project references every source/resource exactly once.

This catches the most common cause of a broken build: adding a Swift file and forgetting to regenerate
the project. It also checks the pbxproj is structurally balanced enough for Xcode to open it.
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PBX = ROOT / "NexusStore.xcodeproj/project.pbxproj"


def main() -> int:
    if not PBX.exists():
        print("error: NexusStore.xcodeproj/project.pbxproj is missing")
        return 1
    text = PBX.read_text()

    sources = sorted((ROOT / "NexusStore").rglob("*.swift"))
    missing = []
    for path in sources:
        rel = path.relative_to(ROOT).as_posix()
        if f"path = {rel};" not in text:
            missing.append(rel)

    duplicated = []
    for path in sources:
        rel = path.relative_to(ROOT).as_posix()
        count = text.count(f"path = {rel};")
        if count > 1:
            duplicated.append((rel, count))

    expected = len(sources)
    in_sources_phase = len(re.findall(r"in Sources \*/,$", text, flags=re.MULTILINE))

    seed = "NexusStore/Resources/Seed/seed-catalog.json"
    if seed not in text:
        missing.append(seed)
    if "Assets.xcassets in Resources" not in text:
        missing.append("Assets.xcassets")

    problems = []
    if missing:
        problems.append("missing from project: " + ", ".join(missing))
    if duplicated:
        problems.append("duplicated references: " + ", ".join(f"{p} x{n}" for p, n in duplicated))
    if in_sources_phase != expected:
        problems.append(f"Sources phase has {in_sources_phase} entries, expected {expected}")

    # Balanced braces/parens (a cheap structural sanity check).
    if text.count("{") != text.count("}"):
        problems.append("brace mismatch in pbxproj")
    if text.count("(") != text.count(")"):
        problems.append("paren mismatch in pbxproj")

    # The project must stay in sync with the generator output.
    generated = subprocess.run([sys.executable, str(ROOT / "Tools/generate_xcodeproj.py")], capture_output=True, text=True)
    if generated.returncode != 0:
        problems.append("generator failed: " + generated.stderr.strip())
    elif PBX.read_text() != text:
        problems.append("project.pbxproj is stale - run Tools/generate_xcodeproj.py")

    if problems:
        for problem in problems:
            print("error: " + problem)
        return 1
    print(f"ok: {expected} Swift files and resources are correctly referenced")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
