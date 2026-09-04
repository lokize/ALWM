#!/usr/bin/env bash
# Incrementa a versão ALWM (MAJOR.MINOR.PATCH).
# Patch sobe de 1 em 1; ao chegar em 10 → MINOR+1 e PATCH=0;
# MINOR ao chegar em 10 → MAJOR+1 e MINOR=0.
#
# Uso:
#   scripts/bump-version.sh "Bullet one" "Bullet two"
#   scripts/bump-version.sh --from-diff
#   scripts/bump-version.sh --from-range origin/main..HEAD
#   scripts/bump-version.sh --dry-run "Only print"
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION_FILE="$ROOT/VERSION"
PLIST="$ROOT/Info.plist"
SWIFT_SETTINGS="$ROOT/Sources/Alwm/UI/SettingsWindow.swift"
WHATSNEW="$ROOT/Sources/Alwm/Resources/whatsnew.json"

DRY_RUN=0
FROM_DIFF=0
FROM_COMMIT=""
FROM_RANGE=""
BULLETS=()

usage() {
  echo "Usage: $0 [--dry-run] [--from-diff] [--from-commit HEAD] [--from-range A..B] [\"changelog bullet\" ...]" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --from-diff) FROM_DIFF=1; shift ;;
    --from-commit)
      FROM_COMMIT="${2:-HEAD}"
      shift 2
      ;;
    --from-range)
      FROM_RANGE="${2:-}"
      shift 2
      ;;
    -h|--help) usage ;;
    *) BULLETS+=("$1"); shift ;;
  esac
done

if [[ ! -f "$VERSION_FILE" ]]; then
  echo "0.0.1" > "$VERSION_FILE"
fi

CURRENT="$(tr -d '[:space:]' < "$VERSION_FILE")"
IFS=. read -r MAJOR MINOR PATCH <<<"$CURRENT"
MAJOR=${MAJOR:-0}
MINOR=${MINOR:-0}
PATCH=${PATCH:-0}

# Validar números
[[ "$MAJOR" =~ ^[0-9]+$ && "$MINOR" =~ ^[0-9]+$ && "$PATCH" =~ ^[0-9]+$ ]] || {
  echo "error: invalid VERSION '$CURRENT' (expected MAJOR.MINOR.PATCH)" >&2
  exit 1
}

PATCH=$((PATCH + 1))
if (( PATCH >= 10 )); then
  PATCH=0
  MINOR=$((MINOR + 1))
fi
if (( MINOR >= 10 )); then
  MINOR=0
  MAJOR=$((MAJOR + 1))
fi

NEW="${MAJOR}.${MINOR}.${PATCH}"
BUILD=$((MAJOR * 100 + MINOR * 10 + PATCH))

# Bullets a partir do diff staged (ou working tree se nada staged)
collect_from_paths() {
  local src="$1"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # Ignorar artefatos de versão neste commit
    case "$line" in
      VERSION|Info.plist|Sources/Alwm/Resources/whatsnew.json|Sources/Alwm/UI/SettingsWindow.swift) continue ;;
      .githooks/*|scripts/bump-version.sh|.cursor/*) continue ;;
    esac
    base="$(basename "$line")"
    case "$line" in
      plugins/github/*) BULLETS+=("GitHub plugin: notifications, PRs, issues, and stars on the workspace bar") ;;
      plugins/steam-price-watcher/*) BULLETS+=("Steam Price Watcher plugin updates") ;;
      plugins/sample-clock/*) BULLETS+=("Sample Clock plugin updates") ;;
      plugins/*) BULLETS+=("Plugins: ${line#plugins/}") ;;
      Sources/AlwmL10n/*) BULLETS+=("Localization: ${base%.swift}") ;;
      Sources/Alwm/Input/*) BULLETS+=("Input: ${base%.swift}") ;;
      Sources/Alwm/UI/*) BULLETS+=("UI: ${base%.swift}") ;;
      Sources/Alwm/Controller/*) BULLETS+=("Window manager: ${base%.swift}") ;;
      Sources/Alwm/AX/*) BULLETS+=("Accessibility: ${base%.swift}") ;;
      Sources/Alwm/Layout/*) BULLETS+=("Layout: ${base%.swift}") ;;
      Sources/Alwm/Config/*) BULLETS+=("Config: ${base%.swift}") ;;
      Sources/Alwm/Support/*) BULLETS+=("Support: ${base%.swift}") ;;
      Sources/Alwm/Notes/*) BULLETS+=("Notepad: ${base%.swift}") ;;
      Sources/Alwm/Plugins/*) BULLETS+=("Plugin host: ${base%.swift}") ;;
      docs/*) BULLETS+=("Docs: $base") ;;
      scripts/*) BULLETS+=("Scripts: $base") ;;
      *) BULLETS+=("Update $line") ;;
    esac
  done <<<"$src"
}

if [[ -n "$FROM_RANGE" ]]; then
  DIFF_SRC="$(git diff --name-only "$FROM_RANGE" 2>/dev/null || true)"
  collect_from_paths "$DIFF_SRC"
elif [[ -n "$FROM_COMMIT" ]]; then
  DIFF_SRC="$(git diff-tree --no-commit-id --name-only -r "$FROM_COMMIT" 2>/dev/null || true)"
  collect_from_paths "$DIFF_SRC"
elif (( FROM_DIFF )); then
  DIFF_SRC="$(git diff --cached --name-only 2>/dev/null || true)"
  if [[ -z "$DIFF_SRC" ]]; then
    DIFF_SRC="$(git diff --name-only 2>/dev/null || true)"
  fi
  collect_from_paths "$DIFF_SRC"
fi

# Deduplicar bullets preservando ordem
if ((${#BULLETS[@]} > 0)); then
  DEDUPED=()
  SEEN=$'\n'
  for b in "${BULLETS[@]}"; do
    [[ -z "$b" ]] && continue
    case "$SEEN" in
      *$'\n'"$b"$'\n'*) continue ;;
    esac
    DEDUPED+=("$b")
    SEEN+="$b"$'\n'
  done
  BULLETS=("${DEDUPED[@]}")
fi

if ((${#BULLETS[@]} == 0)); then
  BULLETS=("Maintenance and fixes")
fi

echo "VERSION $CURRENT → $NEW (build $BUILD)"
printf '  • %s\n' "${BULLETS[@]}"

if (( DRY_RUN )); then
  exit 0
fi

# Escrever VERSION
printf '%s\n' "$NEW" > "$VERSION_FILE"

# Info.plist
if [[ -f "$PLIST" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW" "$PLIST" 2>/dev/null \
    || plutil -replace CFBundleShortVersionString -string "$NEW" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST" 2>/dev/null \
    || plutil -replace CFBundleVersion -string "$BUILD" "$PLIST"
fi

# AlwmVersion.string no Swift
if [[ -f "$SWIFT_SETTINGS" ]]; then
  perl -i -pe "s/static let string = \"[0-9]+\\.[0-9]+\\.[0-9]+\"/static let string = \"$NEW\"/" "$SWIFT_SETTINGS"
fi

# whatsnew.json — prepend release, keep history (newest first)
python3 - "$WHATSNEW" "$NEW" "${BULLETS[@]}" <<'PY'
import json, sys
path, version, *items = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as f:
        raw = json.load(f)
except Exception:
    raw = {}
releases = []
if isinstance(raw, dict) and isinstance(raw.get("releases"), list):
    releases = [r for r in raw["releases"] if isinstance(r, dict) and r.get("version")]
elif isinstance(raw, dict) and raw.get("version") and isinstance(raw.get("items"), list):
    # Migrate legacy single-release format
    releases = [{"version": raw["version"], "items": raw["items"]}]
# Replace same version if re-bumped; otherwise prepend
releases = [r for r in releases if str(r.get("version")) != version]
releases.insert(0, {"version": version, "items": items})
releases = releases[:40]
with open(path, "w", encoding="utf-8") as f:
    json.dump({"releases": releases}, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY

# Sync SPM resource copy if present
RES_COPY="$ROOT/Sources/Alwm/Resources/whatsnew.json"
mkdir -p "$(dirname "$RES_COPY")"

echo "Updated VERSION, Info.plist, AlwmVersion, whatsnew.json"
