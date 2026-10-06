#!/usr/bin/env bash
set -euo pipefail

APP_BUNDLE="${1:?Usage: relaunch-app.sh APP_BUNDLE PROCESS_NAME}"
PROCESS_NAME="${2:?Usage: relaunch-app.sh APP_BUNDLE PROCESS_NAME}"
ATTEMPTS="${ALWM_RELAUNCH_ATTEMPTS:-3}"
POLL_COUNT="${ALWM_RELAUNCH_POLL_COUNT:-30}"
POLL_INTERVAL="${ALWM_RELAUNCH_POLL_INTERVAL:-0.1}"

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "error: app bundle not found: $APP_BUNDLE" >&2
  exit 1
fi

wait_until_stopped() {
  local count="$1"
  local _
  for ((_ = 0; _ < count; _++)); do
    if ! pgrep -x "$PROCESS_NAME" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$POLL_INTERVAL"
  done
  ! pgrep -x "$PROCESS_NAME" >/dev/null 2>&1
}

# Give the running app a chance to shut down cleanly before force-quitting.
pkill -x "$PROCESS_NAME" 2>/dev/null || true
if ! wait_until_stopped 10; then
  pkill -9 -x "$PROCESS_NAME" 2>/dev/null || true
  if ! wait_until_stopped 20; then
    echo "error: $PROCESS_NAME did not stop; refusing to launch a second copy" >&2
    exit 1
  fi
fi

for ((attempt = 1; attempt <= ATTEMPTS; attempt++)); do
  if open "$APP_BUNDLE"; then
    for ((poll = 0; poll < POLL_COUNT; poll++)); do
      if pgrep -x "$PROCESS_NAME" >/dev/null 2>&1; then
        echo "Relaunched $PROCESS_NAME (attempt $attempt/$ATTEMPTS)."
        exit 0
      fi
      sleep "$POLL_INTERVAL"
    done
    echo "Launch Services accepted the request, but $PROCESS_NAME did not start (attempt $attempt/$ATTEMPTS)." >&2
  else
    echo "Launch Services could not open the app (attempt $attempt/$ATTEMPTS); retrying." >&2
  fi

  if (( attempt < ATTEMPTS )); then
    sleep 0.5
  fi
done

echo "error: could not relaunch $PROCESS_NAME after $ATTEMPTS attempts" >&2
exit 1
