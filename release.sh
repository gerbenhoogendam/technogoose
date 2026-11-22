#!/bin/sh
# Builds a universal Techno Goose.app signed with your Developer ID and zips it for a GitHub release.
# NOTARY_PROFILE=<notarytool keychain profile> also notarises and staples it, so it opens without a Gatekeeper warning.
set -e
cd "$(dirname "$0")"
APP="Techno Goose.app"
SIGN="${SIGN:-Developer ID Application}" UNIVERSAL=1 ./build-app.sh
codesign --verify --strict --verbose=2 "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP"/Contents/Info.plist)
ZIP="TechnoGoose-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
if [ -n "$NOTARY_PROFILE" ]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm "$ZIP" && ditto -c -k --keepParent "$APP" "$ZIP"   # zip again, now with the ticket stapled
  spctl --assess --type execute --verbose "$APP"
fi
echo "$ZIP"
