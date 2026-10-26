#!/usr/bin/env bash
# Builds OpenLyrics, packs it into OpenLyrics.dmg, and publishes a GitHub release for the version in
# Resources/Info.plist, with that version's CHANGELOG.md section as the notes.
#
# Usage: Scripts/release.sh            (fails if the tag already exists)
#        Scripts/release.sh --dry-run  (builds the DMG, publishes nothing)
#
# Needs a clean, pushed working tree and an authenticated `gh`.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT_DIR/Resources/Info.plist")"
TAG="v$VERSION"
APP="$ROOT_DIR/build/OpenLyrics.app"
DMG="$ROOT_DIR/build/OpenLyrics.dmg"

cd "$ROOT_DIR"
if [[ "$DRY_RUN" -eq 0 ]]; then
    if [[ -n "$(git status --porcelain)" ]]; then
        echo "error: commit your changes first" >&2
        exit 1
    fi
    if git rev-parse "$TAG" >/dev/null 2>&1 || gh release view "$TAG" >/dev/null 2>&1; then
        echo "error: $TAG already exists; bump CFBundleShortVersionString in Resources/Info.plist" >&2
        exit 1
    fi
fi

# This version's notes: the CHANGELOG section from its heading to the next one.
NOTES="$(awk -v version="$VERSION" '
    $0 ~ "^## " version "( |$)" { found = 1; next }
    found && /^## / { exit }
    found { print }
' CHANGELOG.md)"
if [[ -z "${NOTES//[[:space:]]/}" ]]; then
    echo "error: CHANGELOG.md has no section for $VERSION" >&2
    exit 1
fi

echo "==> Testing"
"$ROOT_DIR/Scripts/test.sh" >/dev/null

"$ROOT_DIR/Scripts/build_app.sh" release

echo "==> Packing $DMG"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "OpenLyrics" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "==> Dry run: $DMG is ready; nothing published"
    exit 0
fi

echo "==> Publishing $TAG"
git tag -a "$TAG" -m "OpenLyrics $VERSION"
git push origin "$TAG"
gh release create "$TAG" "$DMG" --title "OpenLyrics $VERSION" --notes "$NOTES"
echo "==> Released $TAG"
