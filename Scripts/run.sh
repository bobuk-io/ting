#!/usr/bin/env bash
# Build a local development copy in build/ and start it.
# Development builds are ad-hoc signed, not notarized, and do not check for updates.
# Set TING_CONFIG=/path/to/test.json to keep your real ~/.config/ting/config.json untouched.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$ROOT/build/Ting.app"

# Ask a running development copy to quit; never force-kill it.
if pgrep -f -x "$APP/Contents/MacOS/Ting" >/dev/null; then
  osascript -e "tell application \"$APP\" to quit" >/dev/null 2>&1 || true
  for _ in {1..30}; do
    pgrep -f -x "$APP/Contents/MacOS/Ting" >/dev/null || break
    sleep 0.2
  done
  if pgrep -f -x "$APP/Contents/MacOS/Ting" >/dev/null; then
    echo "The development copy of Ting did not quit; quit it from the menu bar and try again." >&2
    exit 1
  fi
fi

SIGNING_MODE=adhoc "$ROOT/Scripts/package_app.sh" "${1:-debug}"
if [[ -n "${TING_CONFIG:-}" ]]; then
  # `open` does not pass the environment; start the executable directly instead.
  TING_CONFIG="$TING_CONFIG" "$APP/Contents/MacOS/Ting" >/dev/null 2>&1 &
  disown
else
  open "$APP"
fi
echo "Ting started in the menu bar."
