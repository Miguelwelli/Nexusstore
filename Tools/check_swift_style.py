#!/usr/bin/env python3
"""Lightweight guard rails on the Swift sources (no external tooling required).

Checks that would otherwise only be caught by a macOS build:
  * implicit `self.` usage is fine (Swift allows it), but unbalanced braces are not;
  * every SwiftUI `some View` file keeps its top-level braces balanced;
  * forbidden placeholders that would mean fake functionality (`TODO`, `fatalError` in features,
    `simulat`, `mock transfer`) do not creep in;
  * file length stays reasonable (a 2,000-line view is a maintenance smell).
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FORBIDDEN = ["TODO:", "FIXME:", "fatalError(", "simulated transfer", "fake progress"]
MAX_LINES = 900


def strip_strings_and_comments(source: str) -> str:
    """Remove // comments, /* */ comments and string literals so brace counting is reliable."""
    out = []
    index = 0
    length = len(source)
    while index < length:
        char = source[index]
        if char == "/" and index + 1 < length and source[index + 1] == "/":
            while index < length and source[index] != "\n":
                index += 1
        elif char == "/" and index + 1 < length and source[index + 1] == "*":
            index += 2
            while index + 1 < length and not (source[index] == "*" and source[index + 1] == "/"):
                index += 1
            index += 2
        elif char == '"':
            # naive handling of interpolation is fine for brace counting
            index += 1
            while index < length and source[index] != '"':
                if source[index] == "\\":
                    index += 1
                index += 1
            index += 1
        else:
            out.append(char)
            index += 1
    return "".join(out)


def main() -> int:
    problems: list[str] = []
    files = sorted((ROOT / "NexusStore").rglob("*.swift")) + sorted((ROOT / "Tests").rglob("*.swift"))
    for path in files:
        rel = path.relative_to(ROOT).as_posix()
        source = path.read_text()
        stripped = strip_strings_and_comments(source)
        if stripped.count("{") != stripped.count("}"):
            problems.append(f"{rel}: unbalanced braces ({stripped.count('{')} open / {stripped.count('}')} close)")
        if stripped.count("(") != stripped.count(")"):
            problems.append(f"{rel}: unbalanced parentheses")
        line_count = source.count("\n") + 1
        if line_count > MAX_LINES:
            problems.append(f"{rel}: {line_count} lines (limit {MAX_LINES}) - split the file")
        if rel.startswith("NexusStore/Features/") or rel.startswith("NexusStore/App/"):
            for needle in FORBIDDEN:
                if needle in source:
                    problems.append(f"{rel}: forbidden placeholder '{needle}'")
    if problems:
        for problem in problems:
            print("error: " + problem)
        return 1
    print(f"ok: {len(files)} Swift files passed the style checks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
