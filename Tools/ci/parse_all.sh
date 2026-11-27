#!/bin/sh
# Parse every Swift file with the compiler's syntax-only frontend action.
# `-parse` stops before name resolution, so SwiftUI/UIKit imports are not required — this still catches
# real syntax errors (unbalanced statements, broken string interpolation, bad attribute placement...)
# in files that can only be fully built on macOS.
set -u
failures=0
count=0
for file in "$@"; do
  count=$((count + 1))
  if ! output=$(swiftc -frontend -parse "$file" 2>&1); then
    echo "error: syntax error in $file"
    printf '%s\n' "$output" | grep -E "error:" | head -5
    failures=$((failures + 1))
  fi
done
if [ "$failures" -gt 0 ]; then
  echo "error: $failures of $count files failed to parse"
  exit 1
fi
echo "ok: all $count Swift files passed syntax parsing"
