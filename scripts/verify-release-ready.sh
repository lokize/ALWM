#!/usr/bin/env bash
# Falha se há mudanças de app desde a tag da VERSION atual (release já publicado).
# Uso: scripts/verify-release-ready.sh
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

VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="v${VERSION}"
HEAD_SHA="$(git rev-parse HEAD)"

if ! git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "verify-release-ready: tag $TAG inexistente — nova versão, ok"
  exit 0
fi

TAG_SHA="$(git rev-parse "$TAG")"
if [[ "$TAG_SHA" == "$HEAD_SHA" ]]; then
  echo "verify-release-ready: HEAD já é $TAG — ok"
  exit 0
fi

RANGE="$TAG_SHA..$HEAD_SHA"
CHANGED="$(collect_non_version_changes "$RANGE" || true)"
if [[ -z "$CHANGED" ]]; then
  echo "verify-release-ready: só infra desde $TAG — ok atualizar release existente"
  exit 0
fi

echo "::error::Há mudanças de app desde $TAG mas VERSION continua em ${VERSION}. Bump VERSION (ex.: bash scripts/sync-push.sh) para criar release novo."
exit 1
