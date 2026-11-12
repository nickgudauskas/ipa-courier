#!/bin/bash
# Builds IPA Courier, signs it, and (by default) notarizes it so it opens
# normally on any Mac.
#
#   scripts/release.sh            Developer ID + notarization (for sharing)
#   scripts/release.sh --local    Apple Development signing (this Mac only)
#
# One-time setup for notarization:
#   1. Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application
#   2. Create an app-specific password at https://account.apple.com (Sign-In and Security)
#   3. xcrun notarytool store-credentials ipa-courier-notary --apple-id <you@example.com> --team-id <TEAMID>
#      (it asks for the app-specific password and saves it in your keychain)
#
# Output: dist/IPA Courier.app and dist/IPA Courier.zip
set -euo pipefail

cd "$(dirname "$0")/.."
MODE="${1:-notarize}"
NOTARY_PROFILE="${NOTARY_PROFILE:-ipa-courier-notary}"
APP_NAME="IPA Courier"
DIST="dist"
APP="$DIST/$APP_NAME.app"

if [[ "$MODE" == "--local" ]]; then
    KIND="Apple Development"
else
    KIND="Developer ID Application"
fi

# Pick the identity by hash: duplicate certificate names are common.
IDENTITY=$(security find-identity -v -p codesigning | awk -v kind="$KIND" '$0 ~ kind { print $2; exit }')
if [[ -z "$IDENTITY" ]]; then
    echo "error: no \"$KIND\" certificate in your keychain." >&2
    if [[ "$KIND" == "Developer ID Application" ]]; then
        echo "Create one in Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application," >&2
        echo "or run 'scripts/release.sh --local' to sign for this Mac only." >&2
    fi
    exit 1
fi
NAME=$(security find-identity -v -p codesigning | awk -v id="$IDENTITY" '$2 == id { sub(/^[^"]*"/, ""); sub(/"$/, ""); print; exit }')
echo "==> Signing identity: $NAME"

if [[ "$MODE" != "--local" ]] && ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "error: no notarization credentials saved as \"$NOTARY_PROFILE\"." >&2
    echo "Run: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple-id> --team-id <team-id>" >&2
    exit 1
fi

echo "==> Building"
if command -v xcodegen >/dev/null; then xcodegen generate --quiet; fi
xcodebuild -project IPACourier.xcodeproj -scheme IPACourier -configuration Release \
    -derivedDataPath build/dd build -quiet

rm -rf "$DIST"
mkdir -p "$DIST"
ditto "build/dd/Build/Products/Release/$APP_NAME.app" "$APP"

echo "==> Signing (hardened runtime, secure timestamp)"
codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"
codesign --verify --strict --deep "$APP"

if [[ "$MODE" != "--local" ]]; then
    echo "==> Notarizing (usually a few minutes)"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/notarize.zip"
    xcrun notarytool submit "$DIST/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    rm "$DIST/notarize.zip"
    echo "==> Stapling ticket"
    xcrun stapler staple "$APP"
    spctl --assess --type execute -vv "$APP"
fi

ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$APP_NAME.zip"
echo "==> Done: $APP and $DIST/$APP_NAME.zip"
