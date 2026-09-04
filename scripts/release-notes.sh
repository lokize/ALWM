#!/usr/bin/env bash
# Markdown release notes for the current VERSION (from whatsnew.json).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(tr -d '[:space:]' < VERSION)"
WHATSNEW="$ROOT/Sources/Alwm/Resources/whatsnew.json"

python3 - "$VERSION" "$WHATSNEW" <<'PY'
import json
import sys
from pathlib import Path

version = sys.argv[1]
path = Path(sys.argv[2])
data = json.loads(path.read_text(encoding="utf-8"))
items = []
for release in data.get("releases", []):
    if release.get("version") == version:
        items = release.get("items") or []
        break

print(f"## ALWM {version}\n")
if items:
    print("### What's New\n")
    for item in items[:20]:
        print(f"- {item}")
    if len(items) > 20:
        print(f"- … and {len(items) - 20} more")
else:
    print("Build from commit on `main`.\n")

print(
    "\n### Install\n\n"
    f"1. Download `ALWM-{version}.dmg` below\n"
    "2. Open the DMG and drag **ALWM** to **Applications**\n"
    "3. First launch: right-click → **Open** (ad-hoc signed build)\n"
    "4. Grant **Accessibility** and **Input Monitoring** when prompted\n\n"
    "Optional CLI: copy `extras/alwmctl` from the DMG to `~/.local/bin/alwmctl`.\n"
)
PY
