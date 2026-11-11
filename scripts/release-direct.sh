#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/Indie Dev Buddy.xcodeproj"
SCHEME="Indie Dev Buddy"
APP_NAME="Indie Dev Buddy"
BUILD_DIR="$ROOT_DIR/.release"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP_PATH="$EXPORT_DIR/$APP_NAME.app"
UPDATES_DIR="$ROOT_DIR/docs/updates"

fail() { printf 'error: %s\n' "$1" >&2; exit 1; }

[[ -n "${DEVELOPER_ID_APPLICATION:-}" ]] || fail "Set DEVELOPER_ID_APPLICATION to your Developer ID Application signing identity."
[[ -n "${NOTARY_PROFILE:-}" ]] || fail "Set NOTARY_PROFILE to the notarytool Keychain profile name."
[[ -n "${SPARKLE_FEED_URL:-}" ]] || fail "Set SPARKLE_FEED_URL to the public appcast.xml URL."
[[ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]] || fail "Set SPARKLE_PUBLIC_ED_KEY to the Sparkle public EdDSA key."
[[ -n "${SPARKLE_DOWNLOAD_BASE_URL:-}" ]] || fail "Set SPARKLE_DOWNLOAD_BASE_URL to the public URL ending in /updates/."
[[ "$SPARKLE_FEED_URL" == https://* ]] || fail "SPARKLE_FEED_URL must use HTTPS."
[[ "$SPARKLE_PUBLIC_ED_KEY" =~ ^[A-Za-z0-9+/=]{40,}$ ]] || fail "SPARKLE_PUBLIC_ED_KEY doesn't look like a base64 Sparkle public key."
[[ "$SPARKLE_DOWNLOAD_BASE_URL" == */ ]] || fail "SPARKLE_DOWNLOAD_BASE_URL must end with a slash."

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/SocialOAuth-Info.plist" 2>/dev/null || true)}"
BUILD_NUMBER="${2:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT_DIR/SocialOAuth-Info.plist" 2>/dev/null || true)}"
[[ -n "$VERSION" ]] || VERSION="1.0"
[[ -n "$BUILD_NUMBER" ]] || BUILD_NUMBER="1"

mkdir -p "$BUILD_DIR" "$UPDATES_DIR"
rm -rf "$ARCHIVE_PATH"
rm -rf "$EXPORT_DIR"

xcodebuild archive \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  CODE_SIGN_STYLE=Automatic \
  SPARKLE_FEED_URL="$SPARKLE_FEED_URL" \
  SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

ARCHIVED_APP_PATH="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
[[ -d "$ARCHIVED_APP_PATH" ]] || fail "Archive did not contain $APP_NAME.app."
mkdir -p "$EXPORT_DIR"
ditto "$ARCHIVED_APP_PATH" "$APP_PATH"
codesign --force --deep --options runtime --timestamp \
  --entitlements "$ROOT_DIR/Indie Dev Buddy.entitlements" \
  --sign "$DEVELOPER_ID_APPLICATION" "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"

PRE_NOTARY_ZIP="$BUILD_DIR/$APP_NAME-$VERSION-notarize.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$PRE_NOTARY_ZIP"
xcrun notarytool submit "$PRE_NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_PATH"

DMG_PATH="$BUILD_DIR/$APP_NAME-$VERSION.dmg"
DMG_STAGE="$BUILD_DIR/dmg-stage"
rm -f "$DMG_PATH"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
ditto "$APP_PATH" "$DMG_STAGE/$APP_NAME.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG_PATH"
rm -rf "$DMG_STAGE"
codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"

UPDATE_ZIP="$UPDATES_DIR/$APP_NAME-$VERSION.zip"
rm -f "$UPDATE_ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$UPDATE_ZIP"

SPARKLE_TOOLS_DIR="${SPARKLE_TOOLS_DIR:-}"
if [[ -z "$SPARKLE_TOOLS_DIR" ]]; then
  SPARKLE_TOOLS_DIR="$(find "$BUILD_DIR/DerivedData/SourcePackages/artifacts" -path '*/Sparkle/bin' -type d -print -quit 2>/dev/null || true)"
fi
[[ -x "$SPARKLE_TOOLS_DIR/generate_appcast" ]] || fail "Can't find Sparkle generate_appcast. Set SPARKLE_TOOLS_DIR or resolve the Sparkle package first."

"$SPARKLE_TOOLS_DIR/generate_appcast" \
  --download-url-prefix "$SPARKLE_DOWNLOAD_BASE_URL" \
  "$UPDATES_DIR"
[[ -f "$UPDATES_DIR/appcast.xml" ]] || fail "generate_appcast did not produce docs/updates/appcast.xml."
cp "$UPDATES_DIR/appcast.xml" "$ROOT_DIR/docs/appcast.xml"

if [[ "${PUBLISH_GITHUB_RELEASE:-0}" == "1" ]]; then
  command -v gh >/dev/null 2>&1 || fail "PUBLISH_GITHUB_RELEASE=1 requires the GitHub CLI (gh)."
  gh release create "v$VERSION" "$DMG_PATH" \
    --title "$APP_NAME $VERSION" \
    --generate-notes
fi

printf '\nRelease artifacts are ready:\n  %s\n  %s\n  %s\n' \
  "$DMG_PATH" "$UPDATE_ZIP" "$ROOT_DIR/docs/appcast.xml"
printf 'Commit and push docs/appcast.xml and docs/updates/ to publish the Sparkle feed through GitHub Pages.\n'
