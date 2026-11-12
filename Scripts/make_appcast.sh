#!/usr/bin/env bash
# Generate a signed Sparkle appcast for one already-notarized release archive.
# The EdDSA private key stays in the login Keychain (account io.bobuk.ting).
# Never export, commit or upload it.
#
#   Scripts/make_appcast.sh          sign dist/Ting-<version>-universal.zip
#   Scripts/make_appcast.sh --check  only verify the tools and the Keychain key
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
source version.env
SPARKLE_BIN=${SPARKLE_BIN:-"$ROOT/.build/sparkle-tools/bin"}
ARCHIVE="$ROOT/dist/Ting-${MARKETING_VERSION}-universal.zip"
NOTES="$ROOT/docs/releases/v${MARKETING_VERSION}.md"
ACCOUNT=io.bobuk.ting
EXPECTED='AJCnH5OGe+uet2nuKtN2kzn5nxrCHoGo85K6b3OabA4='

[[ -x "$SPARKLE_BIN/generate_appcast" && -x "$SPARKLE_BIN/generate_keys" ]] || {
  echo "Sparkle tools missing: set SPARKLE_BIN to the bin directory of the verified Sparkle 2.10.1 release." >&2
  exit 1
}
ACTUAL=$("$SPARKLE_BIN/generate_keys" --account "$ACCOUNT" -p)
[[ "$ACTUAL" == "$EXPECTED" ]] || {
  echo "Sparkle Keychain public key mismatch; refusing to create an unusable appcast." >&2
  exit 1
}
[[ -f "$NOTES" ]] || { echo "Missing release notes $NOTES" >&2; exit 1; }
if [[ ${1:-} == --check ]]; then
  echo "APPCAST_TOOLS_READY"
  exit 0
fi
[[ -f "$ARCHIVE" ]] || { echo "Missing $ARCHIVE" >&2; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/ting-appcast.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
cp "$ARCHIVE" "$TMP/"
# Sparkle shows Markdown notes that share the archive's base name.
cp "$NOTES" "$TMP/$(basename "$ARCHIVE" .zip).md"
"$SPARKLE_BIN/generate_appcast" --account "$ACCOUNT" --maximum-deltas 0 --embed-release-notes \
  --download-url-prefix "https://github.com/bobuk-io/ting/releases/download/v${MARKETING_VERSION}/" \
  --link "https://bobuk-io.github.io/apps/ting/" "$TMP"
[[ -f "$TMP/appcast.xml" ]] || { echo "No appcast was generated." >&2; exit 1; }
grep -q "sparkle:version>${BUILD_NUMBER}<" "$TMP/appcast.xml" || {
  echo "The appcast does not contain build ${BUILD_NUMBER}." >&2
  exit 1
}
cp "$TMP/appcast.xml" "$ROOT/dist/appcast.xml"
echo "APPCAST_READY: $ROOT/dist/appcast.xml"
