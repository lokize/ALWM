#!/usr/bin/env bash
# Reconstrói Sources/Alwm/Resources/whatsnew.json a partir do histórico de VERSION
# e das mensagens de commit entre bumps. Não altera VERSION.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

python3 - "$ROOT/Sources/Alwm/Resources/whatsnew.json" <<'PY'
import json
import re
import subprocess
import sys
from pathlib import Path

out = Path(sys.argv[1])

def subject_to_bullet(msg: str) -> str | None:
    s = msg.strip()
    if not s:
        return None
    lower = s.lower()
    if lower in {"release", "version update", "wip", "tmp", "temp"}:
        return None
    if lower.startswith("update version") or lower.startswith("chore: bump") or lower.startswith("merge "):
        return None
    s = re.sub(
        r"^(feat|fix|refactor|chore|docs|style|perf|test|build|ci|rework|improve)(\([^)]*\))?:\s*",
        "",
        s,
        flags=re.I,
    ).strip()
    if not s:
        return None
    return s[:1].upper() + s[1:]

log = subprocess.check_output(
    ["git", "log", "--format=%H\t%s", "--", "VERSION"], text=True
).strip().splitlines()

entries: list[tuple[str, str]] = []
for line in log:
    sha, _ = line.split("\t", 1)
    ver = subprocess.check_output(["git", "show", f"{sha}:VERSION"], text=True).strip()
    if not re.match(r"^\d+\.\d+\.\d+$", ver):
        continue
    if entries and entries[-1][1] == ver:
        continue
    entries.append((sha, ver))

def path_bullets(rng: str) -> list[str]:
    try:
        files = subprocess.check_output(
            ["git", "diff", "--name-only", rng], text=True
        ).strip().splitlines()
    except subprocess.CalledProcessError:
        return []
    out: list[str] = []
    seen: set[str] = set()

    def add(b: str) -> None:
        if b not in seen:
            seen.add(b)
            out.append(b)

    for line in files:
        if line in {
            "VERSION",
            "Info.plist",
            "Sources/Alwm/Resources/whatsnew.json",
            "Sources/Alwm/UI/Settings/AlwmVersion.swift",
            "Sources/Alwm/UI/SettingsWindow.swift",
        }:
            continue
        if line.startswith("Sources/Alwm/Controller/WindowManager"):
            add("Window manager improvements")
        elif line.startswith("Sources/Alwm/Layout"):
            add("Layout engine updates")
        elif line.startswith("Sources/Alwm/UI"):
            add("UI updates")
        elif line.startswith("Sources/Alwm/Plugins") or line.startswith("plugins/"):
            add("Plugin updates")
        elif line.startswith("Sources/Alwm/AX"):
            add("Accessibility bridge updates")
        elif line.startswith("Sources/Alwm/Support"):
            add("Runtime support updates")
        elif line.startswith("scripts/") or line.startswith(".github/"):
            add("Build and release scripts")
    return out[:8]

releases = []
for i, (sha, ver) in enumerate(entries[:40]):
    older_sha = entries[i + 1][0] if i + 1 < len(entries) else None
    if older_sha:
        rng = f"{older_sha}..{sha}"
        msgs = subprocess.check_output(
            ["git", "log", "--reverse", "--format=%s", rng], text=True
        ).strip().splitlines()
    else:
        rng = sha
        msgs = subprocess.check_output(
            ["git", "log", "-5", "--reverse", "--format=%s", sha], text=True
        ).strip().splitlines()

    items: list[str] = []
    seen: set[str] = set()
    for msg in msgs:
        b = subject_to_bullet(msg)
        if not b or b in seen:
            continue
        # Subjects too cryptic (e.g. "wrs") → prefer path summary later
        if len(b) <= 4:
            continue
        seen.add(b)
        items.append(b)
        if len(items) >= 12:
            break
    if not items:
        items = path_bullets(rng) or ["Maintenance and fixes"]
    releases.append({"version": ver, "items": items})

out.write_text(json.dumps({"releases": releases}, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
print(f"Rebuilt {len(releases)} entries → {out}")
for r in releases[:6]:
    print(f"  {r['version']}: {', '.join(r['items'])}")
PY
