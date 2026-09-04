#!/usr/bin/env bash
# Verifica que cada plugin empacotado tem l10n para todos os idiomas do app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

LANGS=(en zh-Hans hi es fr ar bn pt-BR ru ur)
PLUGINS=(github steam-price-watcher sample-clock)

fail=0
for plugin in "${PLUGINS[@]}"; do
  dir="$ROOT/plugins/$plugin/l10n"
  if [[ ! -d "$dir" ]]; then
    echo "error: missing $dir" >&2
    fail=1
    continue
  fi
  for lang in "${LANGS[@]}"; do
    f="$dir/$lang.md"
    if [[ ! -f "$f" ]]; then
      echo "error: missing $f" >&2
      fail=1
    elif [[ ! -s "$f" ]]; then
      echo "error: empty $f" >&2
      fail=1
    fi
  done
done

if (( fail )); then
  echo "Run: swift scripts/generate-plugin-catalog-l10n.swift" >&2
  exit 1
fi

echo "verify-plugin-l10n: ok (${#PLUGINS[@]} plugins × ${#LANGS[@]} locales)"
