#!/usr/bin/env bash
# Build + package a DXF Viewer release WITHOUT Apple Developer Program.
#
# Produces:
#   dist/DXFViewer-<version>.dmg   ad-hoc-signed, no Apple notarization
#   dist/DXFViewer-<version>.zip   same .app, easier for Sparkle
#
# Buyers will see Gatekeeper's "can't be opened" dialog on first launch.
# Workaround: System Settings → Privacy & Security → "Open Anyway".
# (macOS 15+ removed the older right-click-Open bypass for ad-hoc bundles.)
#
# Optional env: VERSION  (default: read from Info.plist)
#               DIST_DIR (default: dist)
#
# If you ever do pay for an Apple Dev cert, set SIGN_ID + NOTARY_KEYCHAIN_PROFILE
# and this script will sign + notarize automatically.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DIST_DIR="${DIST_DIR:-dist}"
APP_BUNDLE="$DIST_DIR/DXF Viewer.app"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")}"
# DMG/ZIP keep concatenated filenames — they live in URLs and download
# dialogs where %20-encoded spaces are uglier than the missing space.
DMG_PATH="$DIST_DIR/DXFViewer-$VERSION.dmg"
ZIP_PATH="$DIST_DIR/DXFViewer-$VERSION.zip"

say() { printf "\033[1;36m▸ %s\033[0m\n" "$*"; }

say "Building .app (ad-hoc signed by default)"
SIGN_ID="${SIGN_ID:-}" bash "$ROOT/scripts/build-app.sh"

say "Zipping bundle (for Sparkle + GitHub Releases asset)"
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

say "Building DMG (drag-to-Applications layout)"
rm -f "$DMG_PATH"
TMPDIR_DMG="$(mktemp -d)"
cp -R "$APP_BUNDLE" "$TMPDIR_DMG/"
ln -s /Applications "$TMPDIR_DMG/Applications"
hdiutil create \
    -volname "DXF Viewer $VERSION" \
    -srcfolder "$TMPDIR_DMG" \
    -ov -format UDZO \
    "$DMG_PATH"
rm -rf "$TMPDIR_DMG"

# Optional: if user has paid for Apple Dev and supplied creds, notarize too.
if [[ -n "${SIGN_ID:-}" && -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    say "Apple Developer creds present — signing + notarizing"
    codesign --force --options runtime --timestamp \
        --entitlements "$ROOT/Resources/DXFViewer.entitlements" \
        --sign "$SIGN_ID" "$APP_BUNDLE"
    xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
    xcrun stapler staple "$APP_BUNDLE"

    codesign --force --sign "$SIGN_ID" --timestamp "$DMG_PATH"
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
    say "Notarized."
else
    say "No SIGN_ID / NOTARY_KEYCHAIN_PROFILE → shipping ad-hoc."
    say "Buyers will need: System Settings → Privacy & Security → Open Anyway."
fi

say "Sparkle EdDSA sign step (run manually AFTER the GitHub release is live):"
cat <<EOF
  ⚠️  Do NOT sign $DMG_PATH directly. release.yml rebuilds the DMG on its
      own runner after the tag push and overwrites the asset you uploaded;
      the served bytes differ from the local bytes (UDZO compression nonce,
      codesign timestamp). Sparkle hashes what users download, so a
      signature over the local file ships a broken update.

  After 'git push origin v$VERSION':

      gh run watch
      curl -sSL -o /tmp/DXFViewer-$VERSION.dmg \\
          https://github.com/machacekmartin/dxf-viewer/releases/download/v$VERSION/DXFViewer-$VERSION.dmg
      ./.build/artifacts/sparkle/Sparkle/bin/sign_update /tmp/DXFViewer-$VERSION.dmg

  Paste sparkle:edSignature + length into appcast.xml.
EOF

say "Done"
ls -lh "$DMG_PATH" "$ZIP_PATH"
echo
echo "Upload \"$DMG_PATH\" to Gumroad as the product file."
