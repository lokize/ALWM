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
#
# Sem bullets explícitos, deriva What's New das mensagens de commit desde
# o último bump de VERSION (não usa mais o fallback genérico cego).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION_FILE="$ROOT/VERSION"
PLIST="$ROOT/Info.plist"
SWIFT_SETTINGS="$ROOT/Sources/Alwm/UI/Settings/AlwmVersion.swift"
WHATSNEW="$ROOT/Sources/Alwm/Resources/whatsnew.json"

DRY_RUN=0
FROM_DIFF=0
FROM_COMMIT=""
FROM_RANGE=""
BULLETS=()
EXPLICIT_BULLETS=0

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
    *) BULLETS+=("$1"); EXPLICIT_BULLETS=1; shift ;;
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

# Converte subject de commit em bullet de release notes (EN, user-facing).
subject_to_bullet() {
  local s="$1"
  s="$(printf '%s' "$s" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  [[ -z "$s" ]] && return 1

  local lower
  lower="$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    release|version\ update|wip|tmp|temp)
      return 1
      ;;
  esac
  # Ignore auto bump / merge noise (PT/EN)
  if [[ "$lower" == update\ version* \
     || "$lower" == chore:\ bump* \
     || "$lower" == merge\ * ]]; then
    return 1
  fi

  # Strip conventional-commit prefix
  s="$(printf '%s' "$s" | sed -E 's/^(feat|fix|refactor|chore|docs|style|perf|test|build|ci|rework|improve)(\([^)]*\))?:\s*//i')"
  s="$(printf '%s' "$s" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  [[ -z "$s" ]] && return 1
  # Too cryptic for release notes (e.g. "wrs") — let path fallback handle it
  if ((${#s} <= 4)); then
    return 1
  fi

  # Capitalize first letter
  local first rest
  first="$(printf '%s' "$s" | cut -c1 | tr '[:lower:]' '[:upper:]')"
  rest="$(printf '%s' "$s" | cut -c2-)"
  printf '%s%s\n' "$first" "$rest"
}

# Bullets a partir de mensagens de commit no intervalo (mais antigas primeiro).
collect_from_commits() {
  local range="$1"
  local msg bullet
  while IFS= read -r msg; do
    [[ -z "$msg" ]] && continue
    bullet="$(subject_to_bullet "$msg" || true)"
    [[ -n "${bullet:-}" ]] && BULLETS+=("$bullet")
  done < <(git log --reverse --format=%s "$range" 2>/dev/null || true)
}

# Bullets a partir do diff de paths (fallback quando não há subjects úteis).
collect_from_paths() {
  local src="$1"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # Ignorar artefatos de versão neste commit
    case "$line" in
      VERSION|Info.plist|Sources/Alwm/Resources/whatsnew.json|Sources/Alwm/UI/Settings/AlwmVersion.swift) continue ;;
      .githooks/*|scripts/bump-version.sh|.cursor/*) continue ;;
    esac
    base="$(basename "$line")"
    case "$line" in
      plugins/github/*) BULLETS+=("GitHub plugin: notifications, PRs, issues, and stars on the workspace bar") ;;
      plugins/steam-price-watcher/*) BULLETS+=("Steam Price Watcher plugin updates") ;;
      plugins/nintendo-price-watcher/*) BULLETS+=("Nintendo Price Watcher plugin updates") ;;
      plugins/sample-clock/*) BULLETS+=("Sample Clock plugin updates") ;;
      plugins/*) BULLETS+=("Plugins: ${line#plugins/}") ;;
      Sources/AlwmL10n/*) BULLETS+=("Localization updates") ;;
      Sources/Alwm/Input/*) BULLETS+=("Input handling updates") ;;
      Sources/Alwm/UI/Settings/*|Sources/Alwm/UI/SettingsWindow.swift) BULLETS+=("Settings UI updates") ;;
      Sources/Alwm/UI/WorkspaceBar/*) BULLETS+=("Workspace bar updates") ;;
      Sources/Alwm/UI/*) BULLETS+=("UI updates") ;;
      Sources/Alwm/Controller/WindowManager/*|Sources/Alwm/Controller/WindowManager.swift)
        BULLETS+=("Window manager improvements")
        ;;
      Sources/Alwm/Controller/*) BULLETS+=("Window manager improvements") ;;
      Sources/Alwm/AX/*) BULLETS+=("Accessibility bridge updates") ;;
      Sources/Alwm/Layout/*) BULLETS+=("Layout engine updates") ;;
      Sources/Alwm/Config/*) BULLETS+=("Config updates") ;;
      Sources/Alwm/Support/*) BULLETS+=("Runtime support updates") ;;
      Sources/Alwm/Notes/*) BULLETS+=("Notepad updates") ;;
      Sources/Alwm/Plugins/*) BULLETS+=("Plugin host updates") ;;
      docs/*) BULLETS+=("Documentation updates") ;;
      scripts/*) BULLETS+=("Build and release scripts") ;;
      *) BULLETS+=("Update ${base%.swift}") ;;
    esac
  done <<<"$src"
}

last_version_commit() {
  git log -1 --format=%H -- VERSION 2>/dev/null || true
}

if (( EXPLICIT_BULLETS == 0 )); then
  if [[ -n "$FROM_RANGE" ]]; then
    collect_from_commits "$FROM_RANGE"
    if ((${#BULLETS[@]} == 0)); then
      collect_from_paths "$(git diff --name-only "$FROM_RANGE" 2>/dev/null || true)"
    fi
  elif [[ -n "$FROM_COMMIT" ]]; then
    collect_from_commits "${FROM_COMMIT}^..${FROM_COMMIT}"
    if ((${#BULLETS[@]} == 0)); then
      collect_from_paths "$(git diff-tree --no-commit-id --name-only -r "$FROM_COMMIT" 2>/dev/null || true)"
    fi
  elif (( FROM_DIFF )); then
    # Prefira commits desde o último bump; paths staged complementam se vazio.
    LAST_VER_SHA="$(last_version_commit)"
    if [[ -n "$LAST_VER_SHA" ]]; then
      collect_from_commits "${LAST_VER_SHA}..HEAD"
    fi
    DIFF_SRC="$(git diff --cached --name-only 2>/dev/null || true)"
    if [[ -z "$DIFF_SRC" ]]; then
      DIFF_SRC="$(git diff --name-only 2>/dev/null || true)"
    fi
    if ((${#BULLETS[@]} == 0)); then
      collect_from_paths "$DIFF_SRC"
    fi
  else
    # bump sem args (ex.: commit "release") — commits desde o último VERSION
    LAST_VER_SHA="$(last_version_commit)"
    if [[ -n "$LAST_VER_SHA" ]]; then
      collect_from_commits "${LAST_VER_SHA}..HEAD"
      if ((${#BULLETS[@]} == 0)); then
        collect_from_paths "$(git diff --name-only "${LAST_VER_SHA}..HEAD" 2>/dev/null || true)"
      fi
    fi
    if ((${#BULLETS[@]} == 0)); then
      DIFF_SRC="$(git diff --cached --name-only 2>/dev/null || true)"
      if [[ -z "$DIFF_SRC" ]]; then
        DIFF_SRC="$(git diff --name-only 2>/dev/null || true)"
      fi
      collect_from_paths "$DIFF_SRC"
    fi
  fi
fi

# Deduplicar bullets preservando ordem
if ((${#BULLETS[@]} > 0)); then
  DEDUPED=()
  SEEN=$'\n'
  for b in "${BULLETS[@]}"; do
    [[ -z "$b" ]] && continue
    # Descarta o placeholder genérico se houver outros
    if [[ "$b" == "Maintenance and fixes" ]]; then
      continue
    fi
    case "$SEEN" in
      *$'\n'"$b"$'\n'*) continue ;;
    esac
    DEDUPED+=("$b")
    SEEN+="$b"$'\n'
  done
  BULLETS=("${DEDUPED[@]}")
fi

# Limitar tamanho do What's New
if ((${#BULLETS[@]} > 12)); then
  BULLETS=("${BULLETS[@]:0:12}")
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
