#!/usr/bin/env bash
# Falha se commits no intervalo alteram código sem subir VERSION.
# Uso: scripts/verify-version-bump.sh [BASE_SHA] [HEAD_SHA]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

is_version_only_path() {
  local f="$1"
  case "$f" in
    VERSION|Info.plist|Sources/Alwm/Resources/whatsnew.json|Sources/Alwm/UI/SettingsWindow.swift) return 0 ;;
    .githooks/*|scripts/*|.cursor/*|.github/*|docs/*|assets/*|README.md|LICENSE*) return 0 ;;
    *) return 1 ;;
  esac
}

collect_non_version_changes() {
  local range="$1"
  local f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    is_version_only_path "$f" && continue
    printf '%s\n' "$f"
  done < <(git diff --name-only "$range" 2>/dev/null || true)
}

BASE_SHA="${1:-${GITHUB_EVENT_BEFORE:-}}"
HEAD_SHA="${2:-${GITHUB_SHA:-HEAD}}"

if [[ -z "$BASE_SHA" || "$BASE_SHA" == "0000000000000000000000000000000000000000" ]]; then
  echo "verify-version-bump: base desconhecida — skip"
  exit 0
fi

if ! git cat-file -e "$BASE_SHA^{commit}" 2>/dev/null; then
  echo "verify-version-bump: base $BASE_SHA não encontrada — skip"
  exit 0
fi

RANGE="$BASE_SHA..$HEAD_SHA"
CHANGED="$(collect_non_version_changes "$RANGE" || true)"
if [[ -z "$CHANGED" ]]; then
  echo "verify-version-bump: só metadados/version — ok"
  exit 0
fi

BASE_VER="$(git show "$BASE_SHA:VERSION" 2>/dev/null | tr -d '[:space:]' || true)"
HEAD_VER="$(git show "$HEAD_SHA:VERSION" 2>/dev/null | tr -d '[:space:]' || tr -d '[:space:]' < VERSION)"

if [[ -n "$BASE_VER" && "$HEAD_VER" != "$BASE_VER" ]]; then
  echo "verify-version-bump: VERSION $BASE_VER → $HEAD_VER — ok"
  exit 0
fi

echo "::error::Push alterou código mas VERSION continua em $HEAD_VER. Rode scripts/ensure-version-bump.sh ou bash scripts/sync-push.sh antes de enviar."
exit 1
