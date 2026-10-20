#!/bin/zsh
# Packages build/Products.noindex/Download More RAM.app into dist/DownloadMoreRAM-<version>.dmg.
# With DEVELOPER_ID="Developer ID Application: Name (TEAM)" it re-signs the app and its helpers with
# the hardened runtime, and with NOTARY_PROFILE=<keychain profile from `xcrun notarytool
# store-credentials`> it notarizes and staples the DMG. Without them the DMG is fine for testing but
# Gatekeeper will ask (right-click > Open) on other Macs.
#   scripts/make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/Products.noindex/Download More RAM.app"
[[ -d $APP ]] || { echo "build the app first: scripts/build.sh" >&2; exit 1; }
VERSION=$(grep -m1 'let version' Sources/RAMCLI/main.swift | sed -E 's/.*"(.*)".*/\1/')
STAGE=$(mktemp -d)
trap 'rm -rf $STAGE' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
if [[ -n ${DEVELOPER_ID:-} ]]; then
  for f in "$STAGE/Download More RAM.app/Contents/Helpers/ram" "$STAGE/Download More RAM.app/Contents/Helpers/ram-helper" "$STAGE/Download More RAM.app"; do
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$f"
  done
fi
mkdir -p dist
DMG="dist/DownloadMoreRAM-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -quiet -volname "Download More RAM" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
if [[ -n ${DEVELOPER_ID:-} ]]; then codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"; fi
if [[ -n ${NOTARY_PROFILE:-} ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi
shasum -a 256 "$DMG"
echo "dmg: $DMG$([[ -z ${DEVELOPER_ID:-} ]] && echo ' (not Developer ID signed: for testing only)')"
