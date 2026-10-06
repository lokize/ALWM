#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/ALWM.app"

cat > "$TMP/bin/pkill" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

cat > "$TMP/bin/pgrep" <<'STUB'
#!/usr/bin/env bash
[[ -f "$MOCK_LAUNCHED" ]]
STUB

cat > "$TMP/bin/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

cat > "$TMP/bin/open" <<'STUB'
#!/usr/bin/env bash
count=0
[[ -f "$MOCK_OPEN_COUNT" ]] && count="$(cat "$MOCK_OPEN_COUNT")"
count=$((count + 1))
printf '%s\n' "$count" > "$MOCK_OPEN_COUNT"
if (( count == 1 )); then
  echo "_LSOpenURLsWithCompletionHandler() failed with error -600" >&2
  exit 1
fi
touch "$MOCK_LAUNCHED"
STUB

chmod +x "$TMP/bin/"*

# Run the exact relaunch block from package.sh with a deterministic transient
# Launch Services failure on the first open request.
RELAUNCH_BLOCK="$(sed -n '/^if \[\[ "\$RELAUNCH" == "1" \]\]; then$/,/^fi$/p' "$ROOT/scripts/package.sh")"
[[ -n "$RELAUNCH_BLOCK" ]] || { echo "could not find package relaunch block" >&2; exit 1; }

if PATH="$TMP/bin:$PATH" \
  ROOT="$ROOT" \
  INSTALLED="$TMP/ALWM.app" \
  RELAUNCH=1 \
  MOCK_OPEN_COUNT="$TMP/open-count" \
  MOCK_LAUNCHED="$TMP/launched" \
  RELAUNCH_BLOCK="$RELAUNCH_BLOCK" \
  bash -c 'set -euo pipefail; step() { :; }; eval "$RELAUNCH_BLOCK"'; then
  status=0
else
  status=$?
fi

if (( status != 0 )); then
  echo "package relaunch block did not recover from transient Launch Services error (-600)" >&2
  exit 1
fi

[[ "$(cat "$TMP/open-count")" == "2" ]] || {
  echo "expected two open attempts after transient failure" >&2
  exit 1
}
[[ -f "$TMP/launched" ]] || {
  echo "relaunch returned without the app process becoming available" >&2
  exit 1
}

echo "package relaunch recovered after one transient Launch Services error"
