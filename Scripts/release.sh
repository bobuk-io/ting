#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Adapted from dimillian/skills; see THIRD_PARTY_NOTICES.md for license terms.
#
# Build, sign, notarize, staple and check a universal Ting release, write the
# ZIP, SHA256SUMS.txt and the signed Sparkle appcast to dist/, then install the
# release at /Applications/Ting.app and restart it. Publishing is a separate
# step: Scripts/publish.sh.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
source "$ROOT/version.env"

: "${APP_IDENTITY:?Set APP_IDENTITY to a Developer ID Application signing identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a saved notarytool Keychain profile}"
OUTPUT_DIR=${APP_OUTPUT_DIR:-"$ROOT/dist"}
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)
APP="$OUTPUT_DIR/Ting.app"
ZIP="$OUTPUT_DIR/Ting-${MARKETING_VERSION}-universal.zip"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ting-notary.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# Check credentials and tools before an expensive build. Credentials stay inside Keychain.
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format json >/dev/null
"$ROOT/Scripts/make_appcast.sh" --check

swift test
ARCHES="${ARCHES:-arm64 x86_64}" SIGNING_MODE=developer-id APP_OUTPUT_DIR="$OUTPUT_DIR" \
  "$ROOT/Scripts/package_app.sh" release
codesign --verify --deep --strict --verbose=2 "$APP"
lipo "$APP/Contents/MacOS/Ting" -verify_arch arm64 x86_64
swift "$ROOT/Scripts/check_bundle.swift" "$APP"
swift "$ROOT/Scripts/check_release_privacy.swift" "$APP"

/usr/bin/ditto --norsrc -c -k --keepParent "$APP" "$WORK/Notarize.zip"
xcrun notarytool submit "$WORK/Notarize.zip" --keychain-profile "$NOTARY_PROFILE" \
  --wait --output-format json >"$OUTPUT_DIR/notarization.json"
STATUS=$(/usr/bin/plutil -extract status raw -o - "$OUTPUT_DIR/notarization.json")
if [[ "$STATUS" != "Accepted" ]]; then
  ID=$(/usr/bin/plutil -extract id raw -o - "$OUTPUT_DIR/notarization.json")
  xcrun notarytool log "$ID" --keychain-profile "$NOTARY_PROFILE" \
    >"$OUTPUT_DIR/notarization-log.json" || true
  echo "Notarization was not accepted ($STATUS). See dist/notarization-log.json." >&2
  exit 1
fi

xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=2 "$APP"
swift "$ROOT/Scripts/check_release_privacy.swift" "$APP"
rm -f "$ZIP"
/usr/bin/ditto --norsrc -c -k --keepParent "$APP" "$ZIP"
(cd "$OUTPUT_DIR" && shasum -a 256 "$(basename "$ZIP")" >SHA256SUMS.txt)
# Sign the final archive for Sparkle. Do not modify the ZIP after this point.
"$ROOT/Scripts/make_appcast.sh"
"$ROOT/Scripts/install.sh" "$APP"
echo "RELEASE_READY: $ZIP"
