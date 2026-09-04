#!/usr/bin/env bash
# Build a distributable .dmg from dist/ALWM.app (run after scripts/package.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(tr -d '[:space:]' < VERSION)"
APP="$ROOT/dist/ALWM.app"
OUT="$ROOT/dist/ALWM-${VERSION}.dmg"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/alwm-dmg.XXXXXX")"

cleanup() { rm -rf "$STAGING"; }
trap cleanup EXIT

if [[ ! -d "$APP" ]]; then
  echo "error: $APP not found — run ALWM_DIST_ONLY=1 ALWM_CONFIG=release scripts/package.sh first" >&2
  exit 1
fi

cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
if [[ -x "$ROOT/dist/alwmctl" ]]; then
  mkdir -p "$STAGING/extras"
  install -m 755 "$ROOT/dist/alwmctl" "$STAGING/extras/alwmctl"
fi

rm -f "$OUT"
hdiutil create \
  -volname "ALWM ${VERSION}" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$OUT" >/dev/null

echo "Created $OUT"
