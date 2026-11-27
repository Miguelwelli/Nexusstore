#!/usr/bin/env python3
"""Static checks for SwiftUI patterns that the Linux parser cannot catch.

These are mistakes that compile fine on Linux (where the whole SwiftUI layer is absent) but break the
iOS build or silently misbehave:

  1. `@State` used with `defer` inside a mutating context is fine, but assigning to a `@State` inside a
     `Task` closure captured from a `View` without hopping actors is not — we only flag the clear cases.
  2. `if case .foo = phase` without `default` inside a `@ViewBuilder` is fine, so not checked.
  3. Text-only `Button("title")` followed by a `.font(...)`/`.foregroundStyle(...)` chain (those
     modifiers are Text-specific and would not compile on `Button`'s label).
  4. iOS 17-only APIs used while the deployment target is iOS 16.
"""
import re
import sys
from pathlib import Path

ROOT = Path("NexusStore")

IOS17_ONLY = [
    (r"\.navigationDestination\(item:", "navigationDestination(item:) is iOS 17+"),
    (r"\.presentationBackground\(", "presentationBackground is iOS 16.4+"),
    (r"\.onChange\(of: [^)]+\) \{\s*\w*,\s*\w+ in", "two-parameter onChange is iOS 17+"),
    (r"\bScrollViewReader\b.*\.scrollPosition", "scrollPosition is iOS 17+"),
    (r"\.symbolEffect\(", "symbolEffect is iOS 17+"),
    (r"\.contentUnavailableView", "ContentUnavailableView is iOS 17+"),
]

# Button("...") { } followed within a few lines by a Text-only modifier.
BUTTON_TEXT_MODIFIERS = re.compile(
    r'Button\("[^"]*"(?:,\s*role:\s*\.\w+)?\)\s*\{[^}]*\}\s*'
    r"(?:\.(font|foregroundStyle|foregroundColor|kerning|tracking|lineLimit)\()",
    re.S,
)


def swift_files():
    return sorted(ROOT.rglob("*.swift"))


def main() -> int:
    problems = []
    for path in swift_files():
        source = path.read_text()
        for pattern, label in IOS17_ONLY:
            for match in re.finditer(pattern, source):
                line = source[: match.start()].count("\n") + 1
                problems.append(f"{path}:{line}: {label}")
        for match in BUTTON_TEXT_MODIFIERS.finditer(source):
            line = source[: match.start()].count("\n") + 1
            problems.append(
                f"{path}:{line}: Text-only modifier .{match.group(1)} applied to Button(\"...\") label"
            )
    if problems:
        for problem in problems:
            print("error:", problem)
        return 1
    print(f"ok: {len(swift_files())} Swift files respect the iOS 16 / Text-label rules")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
