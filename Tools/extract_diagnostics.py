#!/usr/bin/env python3
"""Reduce a verbose Swift build log to the lines that matter (errors/warnings), de-duplicated."""
import re, sys

ANSI = re.compile(r"\x1b\[[0-9;]*m")

def main() -> int:
    source, target = sys.argv[1], sys.argv[2]
    try:
        text = ANSI.sub("", open(source, "r", errors="replace").read())
    except FileNotFoundError:
        return 0
    keep = []
    for line in text.splitlines():
        stripped = line.strip()
        if re.search(r"(^|\s)(error|warning|note):\s", stripped) or stripped.startswith("Test Case") or "Executed " in stripped or stripped.startswith("XCTAssert") or "failed" in stripped.lower() and "error" in stripped.lower():
            if len(stripped) > 400:
                stripped = stripped[:400] + "…"
            if stripped not in keep:
                keep.append(stripped)
    open(target, "w").write("\n".join(keep[-400:]) or "build failed (no diagnostic lines were extracted)")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
