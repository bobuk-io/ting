#!/usr/bin/env bash
# Install only a verified release, then restart all local Ting instances.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SOURCE=${1:-"$ROOT/dist/Ting.app"}
DEST=/Applications/Ting.app

if [[ ! -f "$SOURCE/Contents/Info.plist" || -L "$DEST" ]]; then
  echo "ERROR: Missing source app metadata or destination is a symlink." >&2
  exit 1
fi
SOURCE=$(cd "$SOURCE" && pwd -P)
if [[ "$SOURCE" == "$DEST" ]]; then
  echo "ERROR: Source and destination must be different." >&2
  exit 1
fi
if [[ ! -w /Applications ]]; then
  echo "ERROR: /Applications is not writable; no changes made." >&2
  exit 1
fi
ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE/Contents/Info.plist")
if [[ "$ID" != io.bobuk.ting ]]; then
  echo "ERROR: Refusing to install an unexpected bundle identifier: $ID" >&2
  exit 1
fi
if [[ -e "$DEST" ]]; then
  if [[ ! -f "$DEST/Contents/Info.plist" ]]; then
    echo "ERROR: Destination is not a recognized app; no changes made." >&2
    exit 1
  fi
  OLD_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist")
  if [[ "$OLD_ID" != io.bobuk.ting ]]; then
    echo "ERROR: Destination belongs to a different application; no changes made." >&2
    exit 1
  fi
fi
codesign --verify --deep --strict "$SOURCE"
xcrun stapler validate "$SOURCE"
spctl --assess --type execute "$SOURCE"
swift "$ROOT/Scripts/check_bundle.swift" "$SOURCE"
swift "$ROOT/Scripts/check_release_privacy.swift" "$SOURCE"

# Stage on the destination volume before stopping the running app. Retain an
# existing installation until copying, verification and launch have succeeded.
WORK=$(mktemp -d /Applications/.Ting-install.XXXXXX)
INSTALLED=0
cleanup() {
  result=$?
  trap - EXIT
  if [[ "$result" -ne 0 ]]; then
    if [[ "$INSTALLED" == 1 && -d "$DEST" ]]; then
      mv "$DEST" "$WORK/failed.app" || true
    fi
    if [[ -d "$WORK/previous.app" ]]; then
      mv "$WORK/previous.app" "$DEST"
      open -g "$DEST" || true
      echo "Restored the previous installation." >&2
    fi
  fi
  rm -rf "$WORK"
  exit "$result"
}
trap cleanup EXIT
ditto "$SOURCE" "$WORK/Ting.app"
codesign --verify --deep --strict "$WORK/Ting.app"

# Request a normal AppKit termination, never force-kill an unresponsive app.
# Match bundle identifiers, not process names, so unrelated apps are untouched.
swift -e '
import AppKit
let ids = Set(["io.bobuk.ting"])
let apps = NSWorkspace.shared.runningApplications.filter { ids.contains($0.bundleIdentifier ?? "") }
for app in apps { _ = app.terminate() }
for _ in 0..<100 {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    if apps.allSatisfy({ $0.isTerminated }) { exit(0) }
}
fputs("Ting did not quit; installation aborted without forcing termination.\n", stderr)
exit(1)
'
if [[ -d "$DEST" ]]; then mv "$DEST" "$WORK/previous.app"; fi
mv "$WORK/Ting.app" "$DEST"
INSTALLED=1
open -g "$DEST"

swift -e '
import AppKit
let target = URL(fileURLWithPath: "/Applications/Ting.app").standardizedFileURL
for _ in 0..<100 {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    if NSWorkspace.shared.runningApplications.contains(where: {
        $0.bundleURL?.standardizedFileURL == target && !$0.isTerminated
    }) { exit(0) }
}
fputs("The installed Ting did not start.\n", stderr)
exit(1)
'
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist")
echo "INSTALLED_AND_RUNNING: $DEST ($VERSION)"
