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
# Output: dist/IPA Courier.app, dist/IPA Courier.zip and dist/IPA-Courier-<version>.dmg
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

# Check the saved credentials, retrying because Apple's service has flaky spells.
credentials_ok() {
    for attempt in 1 2 3; do
        if check=$(xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" 2>&1); then return 0; fi
        grep -qiE "no keychain password item|could not find" <<< "$check" && return 1
        [[ $attempt -lt 3 ]] && sleep 20
    done
    return 1
}
if [[ "$MODE" != "--local" ]] && ! credentials_ok; then
    if grep -qiE "no keychain password item|could not find|profile" <<< "$check"; then
        echo "error: no notarization credentials saved as \"$NOTARY_PROFILE\"." >&2
        echo "Run: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple-id> --team-id <team-id>" >&2
    else
        echo "error: couldn't reach Apple's notary service; try again later." >&2
        echo "$check" | tail -3 >&2
    fi
    exit 1
fi

# Submits a file for notarization, retrying Apple server errors (they happen).
notarize() {
    local file="$1" output
    for attempt in 1 2 3; do
        output=$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) || true
        echo "$output" | grep -E "status:|Error" >&2 || true
        if grep -q "status: Accepted" <<< "$output"; then return 0; fi
        if grep -qE "status: (Invalid|Rejected)" <<< "$output"; then
            local id
            id=$(grep -m1 -oE "id: [0-9a-f-]{36}" <<< "$output" | cut -d' ' -f2)
            echo "error: Apple rejected $file. Details: xcrun notarytool log $id --keychain-profile $NOTARY_PROFILE" >&2
            return 1
        fi
        [[ $attempt -lt 3 ]] && { echo "Notary service error (attempt $attempt of 3); retrying in 60s…" >&2; sleep 60; }
    done
    echo "error: Apple's notary service kept failing; try again later." >&2
    return 1
}

echo "==> Building"
if command -v xcodegen >/dev/null; then xcodegen generate --quiet; fi
xcodebuild -project IPACourier.xcodeproj -scheme IPACourier -configuration Release \
    -derivedDataPath build/dd build -quiet

# Replace only this script's own outputs; keep everything else in dist/
# (older DMGs, release notes). The DMG is overwritten by hdiutil -ov.
mkdir -p "$DIST"
rm -rf "$APP" "$DIST/$APP_NAME.zip" "$DIST/notarize.zip"
ditto "build/dd/Build/Products/Release/$APP_NAME.app" "$APP"

echo "==> Signing (hardened runtime, secure timestamp)"
codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"
codesign --verify --strict --deep "$APP"

if [[ "$MODE" != "--local" ]]; then
    echo "==> Notarizing (usually a few minutes)"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/notarize.zip"
    notarize "$DIST/notarize.zip"
    rm "$DIST/notarize.zip"
    echo "==> Stapling ticket"
    xcrun stapler staple "$APP"
    spctl --assess --type execute -vv "$APP"
fi

ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$APP_NAME.zip"

echo "==> Making disk image"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="$DIST/IPA-Courier-$VERSION.dmg"
STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGE"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
if [[ "$MODE" != "--local" ]]; then
    notarize "$DMG"
    xcrun stapler staple "$DMG"
fi

echo "==> Done: $APP, $DIST/$APP_NAME.zip and $DMG"
