#!/usr/bin/env bash
# Build DXFViewer.app from the SwiftPM target.
# Produces a universal (arm64 + x86_64) .app under dist/.
#
# Env vars:
#   CONFIG       (default: release)    swift build configuration
#   DIST_DIR     (default: dist)       output directory
#   APP_NAME     (default: DXFViewer)  executable + bundle name
#   SIGN_ID      (optional)            codesign identity, e.g.
#                                      "Developer ID Application: Martin Machacek (TEAMID)"
#
# Exit codes: 0 success, non-zero on any failed step.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${CONFIG:-release}"
DIST_DIR="${DIST_DIR:-dist}"
APP_NAME="${APP_NAME:-DXFViewer}"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
ENTITLEMENTS="$ROOT/Resources/DXFViewer.entitlements"

say() { printf "\033[1;36m▸ %s\033[0m\n" "$*"; }

say "Cleaning previous bundle"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

say "Regenerating AppIcon.icns"
bash "$ROOT/tools/make-icon.sh" >/dev/null

# macOS 26 (Tahoe) is Apple-Silicon-only — Intel Mac support was dropped at
# the OS level — so a universal slice would be dead weight. Building arm64.
say "Building release (arm64)"
swift build -c "$CONFIG" --arch arm64

BIN_PATH="$ROOT/.build/arm64-apple-macosx/$CONFIG/$APP_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
    BIN_PATH="$ROOT/.build/$CONFIG/$APP_NAME"
fi
if [[ ! -x "$BIN_PATH" ]]; then
    echo "Could not locate built binary; checked .build/arm64-apple-macosx and .build/$CONFIG" >&2
    exit 1
fi

say "Assembling bundle at $APP_BUNDLE"
cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist"      "$APP_BUNDLE/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns"    "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/Credits.rtf"     "$APP_BUNDLE/Contents/Resources/Credits.rtf"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# Sparkle ships as an xcframework via SPM. For an .app bundle the framework
# must live in Contents/Frameworks, and the executable needs an rpath
# pointing there. Conditionally — keeps the script usable even without Sparkle.
SPARKLE_FW="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ -d "$SPARKLE_FW" ]]; then
    say "Embedding Sparkle.framework"
    mkdir -p "$APP_BUNDLE/Contents/Frameworks"
    cp -R "$SPARKLE_FW" "$APP_BUNDLE/Contents/Frameworks/"
    # Adding the rpath is idempotent-noisy; suppress "already there" errors.
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true
fi

say "Stripping debug symbols"
strip -x "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true

if [[ -n "${SIGN_ID:-}" ]]; then
    say "Code-signing with hardened runtime: $SIGN_ID"
    codesign --force --deep --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_ID" \
        "$APP_BUNDLE"
    say "Verifying signature"
    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
else
    say "SIGN_ID not set — leaving bundle ad-hoc signed (Gatekeeper will reject)"
    codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null
fi

say "Done: $APP_BUNDLE"
lipo -info "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
du -sh "$APP_BUNDLE"
