#!/usr/bin/env bash
# Build a release DMG locally and publish it to GitHub Releases.
# Requires: gh auth login (or GH_TOKEN with repo scope).
#
# This is what CI does on push to main. Running package.sh + create-dmg.sh alone
# only creates dist/ALWM-{VERSION}.dmg — it does not upload to GitHub.
#
# Usage:
#   bash scripts/publish-github-release.sh           # new version only
#   bash scripts/publish-github-release.sh --update  # refresh notes/DMG for existing tag
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ALLOW_UPDATE=0
if [[ "${1:-}" == "--update" ]]; then
  ALLOW_UPDATE=1
fi

VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="v${VERSION}"
DMG="dist/ALWM-${VERSION}.dmg"

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh CLI not found — install from https://cli.github.com/" >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "error: gh not authenticated — run: gh auth login" >&2
  exit 1
fi

# Refuse republishing the same VERSION unless --update (that was masking missed bumps).
if gh release view "$TAG" >/dev/null 2>&1; then
  if (( ! ALLOW_UPDATE )); then
    echo "error: GitHub release $TAG already exists." >&2
    echo "  VERSION is still $VERSION — bump first, then publish:" >&2
    echo "    bash scripts/bump-version.sh \"Short user-facing change\" \"Another change\"" >&2
    echo "    git add VERSION Info.plist Sources/Alwm/Resources/whatsnew.json Sources/Alwm/UI/SettingsWindow.swift" >&2
    echo "    git commit -m \"chore: bump version to \$(cat VERSION)\"" >&2
    echo "    bash scripts/publish-github-release.sh" >&2
    echo "  Or refresh this tag's DMG/notes only: bash scripts/publish-github-release.sh --update" >&2
    exit 1
  fi
fi

# Working tree must include VERSION files consistent with what's on disk.
if ! git diff --quiet -- VERSION Info.plist Sources/Alwm/Resources/whatsnew.json Sources/Alwm/UI/SettingsWindow.swift 2>/dev/null; then
  echo "error: version files have uncommitted changes — commit the bump before publishing." >&2
  git status -sb -- VERSION Info.plist Sources/Alwm/Resources/whatsnew.json Sources/Alwm/UI/SettingsWindow.swift >&2 || true
  exit 1
fi

echo "→ Building release ${VERSION} (dist only)…"
ALWM_CONFIG=release \
ALWM_FAST_RELEASE=1 \
ALWM_RELAUNCH=0 \
ALWM_DIST_ONLY=1 \
ALWM_SIGN_IDENTITY="-" \
  bash scripts/package.sh

echo "→ Creating DMG…"
bash scripts/create-dmg.sh

test -f "$DMG"

NOTES_FILE="$(mktemp)"
cleanup() { rm -f "$NOTES_FILE"; }
trap cleanup EXIT

bash scripts/release-notes.sh > "$NOTES_FILE"

if gh release view "$TAG" >/dev/null 2>&1; then
  echo "→ Release $TAG exists — uploading DMG and refreshing notes (--update)"
  gh release upload "$TAG" "$DMG" --clobber
  gh release edit "$TAG" --notes-file "$NOTES_FILE"
else
  echo "→ Creating release $TAG"
  # Ensure annotated/lightweight tag exists for the release target
  if ! git rev-parse "$TAG" >/dev/null 2>&1; then
    git tag "$TAG"
    git push origin "$TAG" 2>/dev/null || true
  fi
  gh release create "$TAG" "$DMG" \
    --title "ALWM ${VERSION}" \
    --notes-file "$NOTES_FILE" \
    --latest
fi

echo "Done: $(gh release view "$TAG" --json url -q .url)"
