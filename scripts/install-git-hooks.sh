#!/usr/bin/env bash
# Instala o pre-commit de bump de versão (symlink em .git/hooks).
# Não altera git config.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
chmod +x \
  "$ROOT/scripts/bump-version.sh" \
  "$ROOT/scripts/ensure-version-bump.sh" \
  "$ROOT/scripts/sync-push.sh" \
  "$ROOT/scripts/verify-version-bump.sh" \
  "$ROOT/scripts/verify-release-ready.sh" \
  "$ROOT/.githooks/pre-commit" \
  "$ROOT/.githooks/pre-push"

GIT_DIR=""
if [[ -d "$ROOT/.git" ]]; then
  if [[ -f "$ROOT/.git" ]]; then
    # worktree: .git é um arquivo
    GIT_DIR="$(sed -n 's/^gitdir: //p' "$ROOT/.git")"
  else
    GIT_DIR="$ROOT/.git"
  fi
elif [[ -f "$ROOT/.git" ]]; then
  GIT_DIR="$(sed -n 's/^gitdir: //p' "$ROOT/.git")"
fi

if [[ -z "$GIT_DIR" || ! -d "$GIT_DIR" ]]; then
  echo "Aviso: repositório git não encontrado em $ROOT — hooks não instalados." >&2
  echo "Quando o .git existir, rode de novo: bash scripts/install-git-hooks.sh" >&2
  exit 0
fi

mkdir -p "$GIT_DIR/hooks"
ln -sf "$ROOT/.githooks/pre-commit" "$GIT_DIR/hooks/pre-commit"
ln -sf "$ROOT/.githooks/pre-push" "$GIT_DIR/hooks/pre-push"
echo "Instalado: $GIT_DIR/hooks/pre-commit → .githooks/pre-commit"
echo "Instalado: $GIT_DIR/hooks/pre-push → .githooks/pre-push"
echo "Commit: bump VERSION + What's New (pre-commit)"
echo "Push main: bump automático se faltar (pre-push) — prefira: bash scripts/sync-push.sh"
