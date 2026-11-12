#!/usr/bin/env bash
# Publish an already built, notarized and installed release to GitHub Releases.
# Run Scripts/release.sh first. The release is created as a draft, all assets are
# uploaded, and only then is it published, so Sparkle never sees an incomplete release.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
source version.env
REPOSITORY=bobuk-io/ting
TAG="v${MARKETING_VERSION}"
ZIP="dist/Ting-${MARKETING_VERSION}-universal.zip"
SUMS="dist/SHA256SUMS.txt"
APPCAST="dist/appcast.xml"
NOTES="docs/releases/${TAG}.md"

for file in "$ZIP" "$SUMS" "$APPCAST" "$NOTES"; do
  [[ -f "$file" ]] || { echo "Missing $file. Run Scripts/release.sh first." >&2; exit 1; }
done
command -v gh >/dev/null || { echo "The GitHub CLI (gh) is required." >&2; exit 1; }

[[ -z "$(git status --porcelain)" ]] || { echo "Commit changes before publishing." >&2; exit 1; }
COMMIT=$(git rev-parse HEAD)
REMOTE_COMMIT=$(git ls-remote origin refs/heads/main | cut -f1)
[[ "$COMMIT" == "$REMOTE_COMMIT" ]] || { echo "Push the release commit to main before publishing." >&2; exit 1; }
grep -q "sparkle:version>${BUILD_NUMBER}<" "$APPCAST" || { echo "The appcast is not for build ${BUILD_NUMBER}." >&2; exit 1; }
(cd dist && shasum -a 256 -c SHA256SUMS.txt)

# The build number must grow. The first release has no published feed yet.
if gh release view --repo "$REPOSITORY" >/dev/null 2>&1; then
  FEED=$(curl -fsSL --max-time 30 "https://github.com/${REPOSITORY}/releases/latest/download/appcast.xml")
  PUBLISHED=$(printf '%s' "$FEED" | grep -o 'sparkle:version>[0-9]*<' | head -1 | tr -dc '0-9')
  [[ -n "$PUBLISHED" ]] || { echo "Cannot read the published build number." >&2; exit 1; }
  if [[ "$BUILD_NUMBER" -le "$PUBLISHED" ]]; then
    echo "BUILD_NUMBER=$BUILD_NUMBER must be greater than the published $PUBLISHED." >&2
    exit 1
  fi
fi
if gh release view "$TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
  echo "Release $TAG already exists." >&2
  exit 1
fi

gh release create "$TAG" --repo "$REPOSITORY" --target "$COMMIT" --draft \
  --title "Ting ${MARKETING_VERSION}" --notes-file "$NOTES" \
  "$ZIP" "$SUMS" "$APPCAST"
gh release edit "$TAG" --repo "$REPOSITORY" --draft=false --latest
echo "PUBLISHED: $TAG. Sparkle clients read releases/latest/download/appcast.xml."
