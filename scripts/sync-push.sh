#!/usr/bin/env bash
# Sincroniza com o remoto garantindo bump de versão antes do push.
# Uso: bash scripts/sync-push.sh [git push args…]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
if [[ -z "$UPSTREAM" ]]; then
  UPSTREAM="origin/main"
fi

if git rev-parse "$UPSTREAM" >/dev/null 2>&1; then
  REMOTE_SHA="$(git rev-parse "$UPSTREAM")"
  LOCAL_SHA="$(git rev-parse HEAD)"
  bash "$ROOT/scripts/ensure-version-bump.sh" "$REMOTE_SHA" "$LOCAL_SHA"
fi

if ((${#@} > 0)); then
  exec git push "$@"
fi

exec git push
