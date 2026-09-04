#!/usr/bin/env bash
# Gera AppIcon.icns a partir de assets/alwm.png e sincroniza o resource SPM.
# Skips work when outputs are already newer than the source PNG.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT/assets/alwm.png}"
OUT_ICNS="${2:-$ROOT/dist/AppIcon.icns}"
RES_PNG="$ROOT/Sources/Alwm/Resources/alwm.png"

if [[ ! -f "$SRC" ]]; then
  echo "error: logo not found: $SRC" >&2
  exit 1
fi

mkdir -p "$ROOT/Sources/Alwm/Resources" "$(dirname "$OUT_ICNS")"

# Fast path: resource + icns already match current logo.
if [[ -f "$OUT_ICNS" && -f "$RES_PNG" \
   && "$OUT_ICNS" -nt "$SRC" \
   && "$RES_PNG" -nt "$SRC" ]]; then
  # Keep resource copy in sync if someone deleted only the Resources copy.
  if ! cmp -s "$SRC" "$RES_PNG" 2>/dev/null; then
    cp "$SRC" "$RES_PNG"
  fi
  echo "Icon up-to-date — skip regenerate"
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/alwm-icon.XXXXXX")"
ICONSET="$WORK/AppIcon.iconset"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

cp "$SRC" "$RES_PNG"

mkdir -p "$ICONSET"
MASTER="$WORK/master.png"

SDK="$(xcrun --show-sdk-path --sdk macosx 2>/dev/null || true)"
SWIFT_CMD=(swift)
if [[ -n "$SDK" ]]; then
  SWIFT_CMD+=(-sdk "$SDK")
fi

ALWM_ICON_SRC="$SRC" ALWM_ICON_DST="$MASTER" "${SWIFT_CMD[@]}" - <<'SWIFT'
import AppKit
import Foundation

let srcPath = ProcessInfo.processInfo.environment["ALWM_ICON_SRC"]!
let destPath = ProcessInfo.processInfo.environment["ALWM_ICON_DST"]!
guard let src = NSImage(contentsOfFile: srcPath) else {
    fputs("failed to load \(srcPath)\n", stderr)
    exit(1)
}
let side: CGFloat = 1024
let canvas = NSImage(size: NSSize(width: side, height: side))
canvas.lockFocus()
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: side, height: side).fill()
let srcSize = src.size
let scale = min(side / max(srcSize.width, 1), side / max(srcSize.height, 1)) * 0.88
let draw = NSSize(width: srcSize.width * scale, height: srcSize.height * scale)
let origin = NSPoint(x: (side - draw.width) / 2, y: (side - draw.height) / 2)
NSGraphicsContext.current?.imageInterpolation = .high
src.draw(in: NSRect(origin: origin, size: draw), from: .zero, operation: .sourceOver, fraction: 1)
canvas.unlockFocus()
guard let tiff = canvas.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("failed to encode PNG\n", stderr)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: destPath))
SWIFT

declare -a pairs=(
  "16:icon_16x16.png"
  "32:icon_16x16@2x.png"
  "32:icon_32x32.png"
  "64:icon_32x32@2x.png"
  "128:icon_128x128.png"
  "256:icon_128x128@2x.png"
  "256:icon_256x256.png"
  "512:icon_256x256@2x.png"
  "512:icon_512x512.png"
  "1024:icon_512x512@2x.png"
)

for pair in "${pairs[@]}"; do
  size="${pair%%:*}"
  name="${pair##*:}"
  sips -z "$size" "$size" "$MASTER" --out "$ICONSET/$name" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$OUT_ICNS"
echo "Wrote $OUT_ICNS"
