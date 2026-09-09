#!/usr/bin/env bash
# Markdown release notes for the current VERSION (from whatsnew.json).
# Se What's New for só o placeholder genérico, deriva das mensagens de commit
# entre a versão anterior e a atual.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(tr -d '[:space:]' < VERSION)"
WHATSNEW="$ROOT/Sources/Alwm/Resources/whatsnew.json"

python3 - "$VERSION" "$WHATSNEW" <<'PY'
import json
import re
import subprocess
import sys
from pathlib import Path

version = sys.argv[1]
path = Path(sys.argv[2])
data = json.loads(path.read_text(encoding="utf-8"))
items = []
for release in data.get("releases", []):
    if release.get("version") == version:
        items = [str(x) for x in (release.get("items") or []) if str(x).strip()]
        break

GENERIC = {"maintenance and fixes"}

def is_generic(xs: list[str]) -> bool:
    if not xs:
        return True
    return all(x.strip().lower() in GENERIC for x in xs)


def subject_to_bullet(msg: str) -> str | None:
    s = msg.strip()
    if not s:
        return None
    lower = s.lower()
    if lower in {"release", "version update"} or lower.startswith("update version"):
        return None
    if lower.startswith("chore: bump") or lower.startswith("merge "):
        return None
    s = re.sub(
        r"^(feat|fix|refactor|chore|docs|style|perf|test|build|ci|rework|improve)(\([^)]*\))?:\s*",
        "",
        s,
        flags=re.I,
    ).strip()
    if not s or len(s) <= 4:
        return None
    return s[:1].upper() + s[1:]


def path_bullets(rng: str) -> list[str]:
    try:
        files = subprocess.check_output(
            ["git", "diff", "--name-only", rng], text=True
        ).strip().splitlines()
    except subprocess.CalledProcessError:
        return []
    mapping = [
        ("Sources/Alwm/Controller/WindowManager", "Window manager improvements"),
        ("Sources/Alwm/Layout", "Layout engine updates"),
        ("Sources/Alwm/UI", "UI updates"),
        ("Sources/Alwm/Plugins", "Plugin updates"),
        ("plugins/", "Plugin updates"),
        ("Sources/Alwm/AX", "Accessibility bridge updates"),
        ("Sources/Alwm/Support", "Runtime support updates"),
        ("scripts/", "Build and release scripts"),
        (".github/", "Build and release scripts"),
    ]
    skip = {
        "VERSION",
        "Info.plist",
        "Sources/Alwm/Resources/whatsnew.json",
        "Sources/Alwm/UI/Settings/AlwmVersion.swift",
        "Sources/Alwm/UI/SettingsWindow.swift",
    }
    out: list[str] = []
    seen: set[str] = set()
    for line in files:
        if line in skip:
            continue
        for prefix, label in mapping:
            if line.startswith(prefix):
                if label not in seen:
                    seen.add(label)
                    out.append(label)
                break
        if len(out) >= 8:
            break
    return out


def commits_for_version(ver: str) -> list[str]:
    """Collect commit subjects between previous VERSION bump and this version's bump."""
    log = subprocess.check_output(
        ["git", "log", "--format=%H\t%s", "--", "VERSION"],
        text=True,
    ).strip().splitlines()
    entries: list[tuple[str, str, str]] = []
    for line in log:
        sha, subj = line.split("\t", 1)
        try:
            v = subprocess.check_output(
                ["git", "show", f"{sha}:VERSION"], text=True
            ).strip()
        except subprocess.CalledProcessError:
            continue
        entries.append((sha, v, subj))

    # Find commit that introduced `ver`
    idx = next((i for i, (_, v, _) in enumerate(entries) if v == ver), None)
    if idx is None:
        return []
    # Previous different version commit
    older_sha = None
    for j in range(idx + 1, len(entries)):
        if entries[j][1] != ver:
            older_sha = entries[j][0]
            break
    newer_sha = entries[idx][0]
    if older_sha:
        rng = f"{older_sha}..{newer_sha}"
    else:
        rng = newer_sha
    try:
        msgs = subprocess.check_output(
            ["git", "log", "--reverse", "--format=%s", rng],
            text=True,
        ).strip().splitlines()
    except subprocess.CalledProcessError:
        return []
    out: list[str] = []
    seen: set[str] = set()
    for msg in msgs:
        b = subject_to_bullet(msg)
        if not b or b in seen:
            continue
        seen.add(b)
        out.append(b)
        if len(out) >= 12:
            break
    if not out:
        out = path_bullets(rng)
    return out


if is_generic(items):
    derived = commits_for_version(version)
    if derived:
        items = derived

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
