#!/usr/bin/env bash
# Garante bump de VERSION antes de sincronizar commits com código novo.
# Uso:
#   scripts/ensure-version-bump.sh [REMOTE_SHA] [LOCAL_SHA]
#   scripts/ensure-version-bump.sh            # usa origin/main..HEAD
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

log() { printf 'ALWM ensure-version-bump: %s\n' "$*" >&2; }

VERSION_PATHS=(
  VERSION
  Info.plist
  Sources/Alwm/Resources/whatsnew.json
  Sources/Alwm/UI/SettingsWindow.swift
)

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

REMOTE_SHA="${1:-}"
LOCAL_SHA="${2:-}"

if [[ -z "$REMOTE_SHA" || -z "$LOCAL_SHA" ]]; then
  UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
  if [[ -z "$UPSTREAM" ]]; then
    UPSTREAM="origin/main"
  fi
  if ! REMOTE_SHA="$(git rev-parse "$UPSTREAM" 2>/dev/null)"; then
    log "upstream $UPSTREAM não encontrado — skip"
    exit 0
  fi
  LOCAL_SHA="$(git rev-parse HEAD)"
fi

if [[ "$REMOTE_SHA" == "$LOCAL_SHA" ]]; then
  LOCAL_VER="$(tr -d '[:space:]' < VERSION)"
  TAG="v${LOCAL_VER}"
  if git rev-parse "$TAG" >/dev/null 2>&1; then
    TAG_SHA="$(git rev-parse "$TAG")"
    if [[ "$TAG_SHA" != "$LOCAL_SHA" ]]; then
      RANGE="$TAG_SHA..$LOCAL_SHA"
      CHANGED="$(collect_non_version_changes "$RANGE" || true)"
      if [[ -n "$CHANGED" ]]; then
        log "mudanças desde $TAG sem bump — gerando versão nova…"
        bash "$ROOT/scripts/bump-version.sh" --from-range "$RANGE"
        git add "${VERSION_PATHS[@]}"
        NEW_VER="$(tr -d '[:space:]' < VERSION)"
        git commit -m "chore: bump versão para ${NEW_VER}"
        log "commit de versão criado: ${NEW_VER}"
        exit 0
      fi
    fi
  fi
  log "nada para sincronizar — skip"
  exit 0
fi

RANGE="$REMOTE_SHA..$LOCAL_SHA"
CHANGED="$(collect_non_version_changes "$RANGE" || true)"
if [[ -z "$CHANGED" ]]; then
  log "sem mudanças de código no intervalo — skip"
  exit 0
fi

REMOTE_VER="$(git show "$REMOTE_SHA:VERSION" 2>/dev/null | tr -d '[:space:]' || true)"
LOCAL_VER="$(tr -d '[:space:]' < VERSION)"

if [[ -n "$REMOTE_VER" && "$LOCAL_VER" != "$REMOTE_VER" ]]; then
  log "versão já subiu ($REMOTE_VER → $LOCAL_VER)"
  exit 0
fi

log "mudanças de código sem bump — gerando versão nova…"
bash "$ROOT/scripts/bump-version.sh" --from-range "$RANGE"

git add "${VERSION_PATHS[@]}"
NEW_VER="$(tr -d '[:space:]' < VERSION)"
git commit -m "chore: bump versão para ${NEW_VER}"
log "commit de versão criado: ${NEW_VER}"
