#!/usr/bin/env python3
"""Split a build log into GitHub Actions annotations so failures are readable via the API."""
import os, sys

MAX_CHUNK = 6000
MAX_ANNOTATIONS = 9

def escape(text: str) -> str:
    return (text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A"))

def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else "build.log"
    title = sys.argv[2] if len(sys.argv) > 2 else "build"
    if not os.path.exists(path):
        print(f"::warning title={title}::log file {path} not found")
        return 0
    data = open(path, "r", errors="replace").read()
    if len(data) > MAX_CHUNK * MAX_ANNOTATIONS:
        data = data[: MAX_CHUNK * (MAX_ANNOTATIONS - 1)] + "\n...[truncated]...\n" + data[-MAX_CHUNK:]
    chunks = [data[i : i + MAX_CHUNK] for i in range(0, len(data), MAX_CHUNK)][:MAX_ANNOTATIONS]
    for index, chunk in enumerate(chunks):
        print(f"::error title={title} ({index + 1}/{len(chunks)})::{escape(chunk)}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
