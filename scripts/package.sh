#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Local iteration defaults to debug (incremental, ~seconds).
# Release / distribution: ALWM_CONFIG=release ./scripts/package.sh
CONFIG="${ALWM_CONFIG:-debug}"
RELAUNCH="${ALWM_RELAUNCH:-1}"
DIST_ONLY="${ALWM_DIST_ONLY:-0}"
FAST_RELEASE="${ALWM_FAST_RELEASE:-0}"

if [[ "$DIST_ONLY" == "1" ]]; then
  RELAUNCH=0
fi

t0="$(date +%s)"
step() {
  local now elapsed
  now="$(date +%s)"
  elapsed=$((now - t0))
  echo "→ $*  (+${elapsed}s)"
}

# Ensure version/What's New hook is installed for this clone.
bash "$ROOT/scripts/install-git-hooks.sh" >/dev/null 2>&1 || true

# Se o último commit alterou Sources sem bump de VERSION, avisa (commits com --no-verify).
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  last_files="$(git diff-tree --no-commit-id --name-only -r HEAD 2>/dev/null || true)"
  if echo "$last_files" | grep -qE '^(Sources/|Tests/)' \
    && ! echo "$last_files" | grep -qx 'VERSION'; then
    echo "AVISO: o último commit mudou código sem atualizar VERSION/What's New." >&2
    echo "  Provável causa: git commit --no-verify (pula o pre-commit)." >&2
    echo "  Corrija com: bash scripts/bump-version.sh \"Short change\" \"Another change\"" >&2
    echo "  Depois: git add VERSION Info.plist Sources/Alwm/Resources/whatsnew.json Sources/Alwm/UI/SettingsWindow.swift && git commit" >&2
  fi
fi

step "Icon (skip if up-to-date)"
bash "$ROOT/scripts/generate-app-icon.sh" "$ROOT/assets/alwm.png" "$ROOT/dist/AppIcon.icns"

BUILD_FLAGS=(-c "$CONFIG")
if [[ "$CONFIG" == "release" && "$FAST_RELEASE" == "1" ]]; then
  # Per-file -O without whole-module — much faster incremental release builds.
  BUILD_FLAGS+=(-Xswiftc -no-whole-module-optimization)
  step "Build release (fast, no WMO)"
else
  step "Build ($CONFIG)"
fi

# Parallelism: use all cores; SPM already does, but make it explicit for clarity.
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 8)"
swift build "${BUILD_FLAGS[@]}" -j "$JOBS"

BIN_ROOT="$ROOT/.build"
# Prefer stable symlinks SPM maintains (.build/debug, .build/release).
if [[ -x "$BIN_ROOT/$CONFIG/ALWM" ]]; then
  ALWM_BIN="$BIN_ROOT/$CONFIG/ALWM"
  CTL_BIN="$BIN_ROOT/$CONFIG/alwmctl"
else
  ALWM_BIN="$(find "$BIN_ROOT" -path "*/$CONFIG/ALWM" -type f -perm +111 2>/dev/null | head -1)"
  CTL_BIN="$(find "$BIN_ROOT" -path "*/$CONFIG/alwmctl" -type f -perm +111 2>/dev/null | head -1)"
fi
if [[ -z "${ALWM_BIN:-}" || ! -x "$ALWM_BIN" ]]; then
  echo "error: ALWM binary not found after build ($CONFIG)" >&2
  exit 1
fi

APP_NAME="ALWM"
DIST="$ROOT/dist/${APP_NAME}.app"
CONTENTS="$DIST/Contents"
MACOS="$CONTENTS/MacOS"
BIN_DIR="${HOME}/.local/bin"
APP_DIR="${HOME}/Applications"
BUNDLE_ID="dev.alwm.ALWM"
INSTALLED="${APP_DIR}/${APP_NAME}.app"

resolve_identity() {
  if [[ -n "${ALWM_SIGN_IDENTITY:-}" ]]; then
    echo "$ALWM_SIGN_IDENTITY"
    return
  fi
  # Always use the stable ALWM local cert (same leaf hash across rebuilds).
  # Preferring Apple Development here used to switch identities and reset TCC.
  bash "$ROOT/scripts/ensure-codesign-identity.sh"
}

IDENTITY="$(resolve_identity)"
step "Stage app (sign: ${IDENTITY:0:24}…)"

mkdir -p "$MACOS" "$CONTENTS/Resources"
# Replace binary in place when possible — avoids full tree rebuild cost.
if [[ ! -d "$DIST" ]]; then
  mkdir -p "$MACOS" "$CONTENTS/Resources"
fi
cp -f "$ALWM_BIN" "$MACOS/ALWM"
cp -f Info.plist "$CONTENTS/Info.plist"
cp -f Alwm.entitlements "$CONTENTS/Resources/Alwm.entitlements" 2>/dev/null || true
cp -f "$ROOT/dist/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
cp -f "$ROOT/assets/alwm.png" "$CONTENTS/Resources/alwm.png"
# SPM resource bundle (whatsnew.json, donors.json, …). Without this, Bundle.module
# asserts on launch and the post-update relaunch dies immediately.
SPM_BUNDLE="$(find "$BIN_ROOT" -path "*/$CONFIG/ALWM_Alwm.bundle" -type d 2>/dev/null | head -1)"
if [[ -z "${SPM_BUNDLE:-}" || ! -d "$SPM_BUNDLE" ]]; then
  SPM_BUNDLE="$BIN_ROOT/$CONFIG/ALWM_Alwm.bundle"
fi
if [[ -d "$SPM_BUNDLE" ]]; then
  rm -rf "$CONTENTS/Resources/ALWM_Alwm.bundle"
  cp -R "$SPM_BUNDLE" "$CONTENTS/Resources/ALWM_Alwm.bundle"
fi
# Flat copies so Bundle.main can find them even without the SPM bundle.
cp -f "$ROOT/Sources/Alwm/Resources/whatsnew.json" "$CONTENTS/Resources/whatsnew.json" 2>/dev/null || true
cp -f "$ROOT/Sources/Alwm/Resources/donors.json" "$CONTENTS/Resources/donors.json" 2>/dev/null || true
printf 'APPL????' > "$CONTENTS/PkgInfo"
chmod +x "$MACOS/ALWM"

# --- PlugIns ---
step "Package PlugIns"
FRAMEWORKS="$CONTENTS/Frameworks"
PLUGINS_DIR="$CONTENTS/PlugIns"
mkdir -p "$FRAMEWORKS" "$PLUGINS_DIR"
rm -rf "$PLUGINS_DIR"/*.alwmplugin 2>/dev/null || true

API_DYLIB="$(find "$BIN_ROOT" -path "*/$CONFIG/libAlwmPluginAPI.dylib" -type f 2>/dev/null | head -1)"
if [[ -z "${API_DYLIB:-}" || ! -f "$API_DYLIB" ]]; then
  API_DYLIB="$BIN_ROOT/$CONFIG/libAlwmPluginAPI.dylib"
fi

stage_shared_dylib() {
  local name="$1"   # e.g. libAlwmStatsKit.dylib
  local src
  src="$(find "$BIN_ROOT" -path "*/$CONFIG/${name}" -type f 2>/dev/null | head -1)"
  if [[ -z "${src:-}" || ! -f "$src" ]]; then
    src="$BIN_ROOT/$CONFIG/${name}"
  fi
  if [[ ! -f "$src" ]]; then
    echo "AVISO: shared dylib ausente: ${name}" >&2
    return 0
  fi
  cp -f "$src" "$FRAMEWORKS/${name}"
  install_name_tool -id "@rpath/${name}" "$FRAMEWORKS/${name}" 2>/dev/null || true
  # Host binary may link these too.
  otool -L "$MACOS/ALWM" | awk -v n="$name" 'index($1, n) {print $1}' | while read -r old; do
    install_name_tool -change "$old" "@rpath/${name}" "$MACOS/ALWM" 2>/dev/null || true
  done
  echo "  Framework: ${name}"
}

if [[ -f "$API_DYLIB" ]]; then
  cp -f "$API_DYLIB" "$FRAMEWORKS/libAlwmPluginAPI.dylib"
  install_name_tool -id "@rpath/libAlwmPluginAPI.dylib" "$FRAMEWORKS/libAlwmPluginAPI.dylib" 2>/dev/null || true
  # rpath so ALWM finds Frameworks/
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS/ALWM" 2>/dev/null || true
  # Rewrite SPM absolute/.build dylib path
  otool -L "$MACOS/ALWM" | awk '/libAlwmPluginAPI\.dylib/ {print $1}' | while read -r old; do
    [[ "$old" == *"libAlwmPluginAPI.dylib"* ]] || continue
    install_name_tool -change "$old" "@rpath/libAlwmPluginAPI.dylib" "$MACOS/ALWM" 2>/dev/null || true
  done
fi
stage_shared_dylib "libAlwmL10n.dylib"
stage_shared_dylib "libAlwmStatsKit.dylib"
package_plugin() {
  local src_dir="$1"
  local product_dylib_name="$2"
  local bundle_name="$3"
  local plugin_id="$4"

  local dylib
  dylib="$(find "$BIN_ROOT" -path "*/$CONFIG/${product_dylib_name}" -type f 2>/dev/null | head -1)"
  if [[ -z "${dylib:-}" || ! -f "$dylib" ]]; then
    dylib="$BIN_ROOT/$CONFIG/${product_dylib_name}"
  fi
  if [[ ! -f "$dylib" ]]; then
    echo "AVISO: plugin dylib ausente: ${product_dylib_name}" >&2
    return 0
  fi

  local bundle="$PLUGINS_DIR/${bundle_name}.alwmplugin"
  local macos_dir="$bundle/Contents/MacOS"
  local resources_dir="$bundle/Contents/Resources"
  rm -rf "$bundle"
  mkdir -p "$macos_dir" "$resources_dir"
  cp -f "$dylib" "$macos_dir/${bundle_name}"
  chmod +x "$macos_dir/${bundle_name}"

  # Catalog metadata under Resources (codesigned)
  cp -f "$src_dir/plugin.json" "$resources_dir/plugin.json"
  for readme in "$src_dir"/README*.md; do
    [[ -f "$readme" ]] || continue
    cp -f "$readme" "$resources_dir/$(basename "$readme")"
  done
  if [[ -d "$src_dir/l10n" ]]; then
    rm -rf "$resources_dir/l10n"
    cp -R "$src_dir/l10n" "$resources_dir/l10n"
  fi
  if [[ -d "$src_dir/previews" ]]; then
    rm -rf "$resources_dir/previews"
    cp -R "$src_dir/previews" "$resources_dir/previews"
  fi
  if [[ -d "$src_dir/Resources" ]]; then
    # Extra assets
    cp -R "$src_dir/Resources/." "$resources_dir/" 2>/dev/null || true
  fi

  cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>${plugin_id}</string>
  <key>CFBundleName</key>
  <string>${bundle_name}</string>
  <key>CFBundleExecutable</key>
  <string>${bundle_name}</string>
  <key>CFBundlePackageType</key>
  <string>BNDL</string>
  <key>CFBundleVersion</key>
  <string>1</string>
</dict>
</plist>
PLIST

  install_name_tool -id "@rpath/${bundle_name}" "$macos_dir/${bundle_name}" 2>/dev/null || true
  install_name_tool -add_rpath "@loader_path/../../../Frameworks" "$macos_dir/${bundle_name}" 2>/dev/null || true
  for shared in libAlwmPluginAPI.dylib libAlwmL10n.dylib libAlwmStatsKit.dylib; do
    otool -L "$macos_dir/${bundle_name}" | awk -v n="$shared" 'index($1, n) {print $1}' | while read -r old; do
      install_name_tool -change "$old" "@rpath/${shared}" "$macos_dir/${bundle_name}" 2>/dev/null || true
    done
  done
  echo "  PlugIn: ${bundle_name}.alwmplugin"
}

# Sample plugins
if [[ -d "$ROOT/plugins/sample-clock" ]]; then
  package_plugin \
    "$ROOT/plugins/sample-clock" \
    "libSampleClockPlugin.dylib" \
    "SampleClock" \
    "dev.alwm.sample-clock"
fi
if [[ -d "$ROOT/plugins/steam-price-watcher" ]]; then
  package_plugin \
    "$ROOT/plugins/steam-price-watcher" \
    "libSteamPriceWatcherPlugin.dylib" \
    "SteamPriceWatcher" \
    "dev.alwm.steam-price-watcher"
fi
if [[ -d "$ROOT/plugins/github" ]]; then
  package_plugin \
    "$ROOT/plugins/github" \
    "libGitHubPlugin.dylib" \
    "GitHub" \
    "dev.alwm.github"
fi
if [[ -d "$ROOT/plugins/stats-cpu" ]]; then
  package_plugin \
    "$ROOT/plugins/stats-cpu" \
    "libStatsCPUPlugin.dylib" \
    "StatsCPU" \
    "dev.alwm.stats-cpu"
fi
if [[ -d "$ROOT/plugins/stats-memory" ]]; then
  package_plugin \
    "$ROOT/plugins/stats-memory" \
    "libStatsMemoryPlugin.dylib" \
    "StatsMemory" \
    "dev.alwm.stats-memory"
fi
if [[ -d "$ROOT/plugins/stats-network" ]]; then
  package_plugin \
    "$ROOT/plugins/stats-network" \
    "libStatsNetworkPlugin.dylib" \
    "StatsNetwork" \
    "dev.alwm.stats-network"
fi
if [[ -d "$ROOT/plugins/stats-battery" ]]; then
  package_plugin \
    "$ROOT/plugins/stats-battery" \
    "libStatsBatteryPlugin.dylib" \
    "StatsBattery" \
    "dev.alwm.stats-battery"
fi
if [[ -d "$ROOT/plugins/stats-disk" ]]; then
  package_plugin \
    "$ROOT/plugins/stats-disk" \
    "libStatsDiskPlugin.dylib" \
    "StatsDisk" \
    "dev.alwm.stats-disk"
fi
if [[ -d "$ROOT/plugins/stats-gpu" ]]; then
  package_plugin \
    "$ROOT/plugins/stats-gpu" \
    "libStatsGPUPlugin.dylib" \
    "StatsGPU" \
    "dev.alwm.stats-gpu"
fi
if [[ -d "$ROOT/plugins/stats-sensors" ]]; then
  package_plugin \
    "$ROOT/plugins/stats-sensors" \
    "libStatsSensorsPlugin.dylib" \
    "StatsSensors" \
    "dev.alwm.stats-sensors"
fi
if [[ -d "$ROOT/plugins/stats-fans" ]]; then
  package_plugin \
    "$ROOT/plugins/stats-fans" \
    "libStatsFansPlugin.dylib" \
    "StatsFans" \
    "dev.alwm.stats-fans"
fi
if [[ -d "$ROOT/plugins/stats-bluetooth" ]]; then
  package_plugin \
    "$ROOT/plugins/stats-bluetooth" \
    "libStatsBluetoothPlugin.dylib" \
    "StatsBluetooth" \
    "dev.alwm.stats-bluetooth"
fi
if [[ -d "$ROOT/plugins/now-playing" ]]; then
  package_plugin \
    "$ROOT/plugins/now-playing" \
    "libNowPlayingPlugin.dylib" \
    "NowPlaying" \
    "dev.alwm.now-playing"
fi
if [[ -d "$ROOT/plugins/stats-uptime" ]]; then
  package_plugin \
    "$ROOT/plugins/stats-uptime" \
    "libStatsUptimePlugin.dylib" \
    "StatsUptime" \
    "dev.alwm.stats-uptime"
fi

sign_app() {
  local target="$1"
  # Sign nested PlugIns / Frameworks first so --deep / outer seal succeeds.
  if [[ -d "$target/Contents/Frameworks" ]]; then
    find "$target/Contents/Frameworks" -type f \( -name "*.dylib" -o -name "*.framework" \) 2>/dev/null | while read -r f; do
      codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID.frameworks" "$f" 2>/dev/null || true
    done
  fi
  if [[ -d "$target/Contents/PlugIns" ]]; then
    find "$target/Contents/PlugIns" -name "*.alwmplugin" -maxdepth 1 2>/dev/null | while read -r plug; do
      codesign --force --deep --sign "$IDENTITY" --identifier "$(basename "$plug" .alwmplugin)" "$plug" 2>/dev/null || true
    done
  fi
  # Self-signed local cert: omit hardened runtime (needs Apple chain).
  # DR stays cert-anchored (identifier + certificate root/leaf hash) → TCC survives rebuilds.
  codesign --force --deep \
    --sign "$IDENTITY" \
    --identifier "$BUNDLE_ID" \
    --entitlements "$ROOT/Alwm.entitlements" \
    "$target"
}

if [[ "$DIST_ONLY" == "1" ]]; then
  sign_app "$DIST"
  if [[ -n "${CTL_BIN:-}" && -x "$CTL_BIN" ]]; then
    mkdir -p "$ROOT/dist"
    install -m 755 "$CTL_BIN" "$ROOT/dist/alwmctl"
  fi
  total=$(( $(date +%s) - t0 ))
  echo
  echo "Packaged ($CONFIG) in ${total}s:"
  echo "  $DIST"
  [[ -x "$ROOT/dist/alwmctl" ]] && echo "  $ROOT/dist/alwmctl"
  echo "  identity: $IDENTITY"
  echo
  echo "Pronto."
  exit 0
fi

# Install then sign once at the destination (TCC identity for ~/Applications).
mkdir -p "$APP_DIR" "$BIN_DIR"
# ditto merges — wipe nested PlugIns/Frameworks so old loose files don't break codesign.
rm -rf "$INSTALLED/Contents/PlugIns" "$INSTALLED/Contents/Frameworks"
if command -v ditto >/dev/null 2>&1; then
  ditto "$DIST" "$INSTALLED"
else
  rm -rf "$INSTALLED"
  cp -R "$DIST" "$INSTALLED"
fi
sign_app "$INSTALLED"

# Sanity: designated requirement must be cert-anchored (not cdhash).
DR="$(codesign -d -r- "$INSTALLED" 2>&1 | sed -n 's/^.*designated => //p' | head -1)"
if [[ -z "$DR" ]]; then
  echo "AVISO: não foi possível ler o designated requirement." >&2
elif echo "$DR" | grep -qi 'cdhash'; then
  echo "AVISO: DR ancorado em cdhash — permissões TCC vão resetar a cada build." >&2
  echo "  DR: $DR" >&2
else
  echo "  designated: $DR"
fi

if security find-identity -v -p codesigning 2>/dev/null | grep -F "ALWM Local Signing" | grep -q 'CSSMERR_TP_NOT_TRUSTED'; then
  echo >&2
  echo "AVISO: o certificado 'ALWM Local Signing' ainda NÃO está confiado para Code Signing." >&2
  echo "  Sem isso o macOS pode esquecer Accessibility / Screen Recording a cada rebuild." >&2
  echo "  Faça uma vez:" >&2
  echo "    1. Abra Keychain Access (Acesso às Chaves)" >&2
  echo "    2. Busque: ALWM Local Signing" >&2
  echo "    3. Duplo clique → Trust / Confiar → Code Signing = Always Trust / Sempre Confiar" >&2
  echo "    4. Feche, rode de novo: ./scripts/package.sh" >&2
  echo "    5. Em Ajustes → Gravação de Tela, LIGUE o interruptor do ALWM e reinicie o app" >&2
fi

if [[ -n "${CTL_BIN:-}" && -x "$CTL_BIN" ]]; then
  install -m 755 "$CTL_BIN" "${BIN_DIR}/alwmctl"
fi

total=$(( $(date +%s) - t0 ))
echo
echo "Installed ($CONFIG) in ${total}s:"
echo "  $INSTALLED"
echo "  ${BIN_DIR}/alwmctl"
echo "  identity: $IDENTITY"
if [[ "$CONFIG" == "debug" ]]; then
  echo
  echo "Dica: build local rápido (debug). Para release otimizado:"
  echo "  ALWM_CONFIG=release ./scripts/package.sh"
  echo "  ALWM_CONFIG=release ALWM_FAST_RELEASE=1 ./scripts/package.sh  # release sem WMO"
fi
echo

if [[ "$RELAUNCH" == "1" ]]; then
  step "Relaunch"
  # Quit gracefully first; force only if still alive.
  pkill -x ALWM 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    pgrep -x ALWM >/dev/null 2>&1 || break
    sleep 0.1
  done
  pkill -9 -x ALWM 2>/dev/null || true
  open "$INSTALLED"
fi

echo "Pronto."
