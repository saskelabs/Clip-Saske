#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP_DIR="$ROOT/.build/Clip Saske.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
ENTITLEMENTS="$ROOT/Resources/ClipSaske.entitlements"

# ── Code signing configuration ──────────────────────────────────────────────
# Set TEAM_ID to your Apple Developer Team ID (10-character string) or pass
# it as an environment variable: TEAM_ID=ABC123DEF4 ./scripts/build_app.sh
TEAM_ID="${TEAM_ID:-}"
# Set SIGN_IDENTITY to your certificate's common name, e.g.:
#   "Developer ID Application: Your Name (XXXXXXXXXX)"
# Leave empty to do an ad-hoc sign (no Hardened Runtime, no notarization).
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
# ────────────────────────────────────────────────────────────────────────────

echo "Running swift build ($CONFIG)..."
swift build -c "$CONFIG" --disable-sandbox

rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"
cp "$ROOT/.build/$CONFIG/ClipSaske"         "$MACOS/ClipSaske"
cp "$ROOT/Resources/Info.plist"             "$CONTENTS/Info.plist"
cp "$ROOT/Resources/ClipSaske.icns"        "$RESOURCES/ClipSaske.icns"
cp "$ROOT/Resources/ClipSaskeIcon.png"     "$RESOURCES/ClipSaskeIcon.png"

# ── Sign the bundle ──────────────────────────────────────────────────────────
if [ -n "$SIGN_IDENTITY" ]; then
    echo "Signing with: $SIGN_IDENTITY"
    codesign \
        --force \
        --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY" \
        --timestamp \
        "$APP_DIR"
    echo "Verifying signature..."
    codesign --verify --deep --strict --verbose=2 "$APP_DIR"
    spctl --assess --type exec --verbose "$APP_DIR" 2>&1 || \
        echo "Note: spctl assess fails before notarization — this is expected."
else
    echo "No SIGN_IDENTITY set — applying ad-hoc signature (development only)."
    codesign \
        --force \
        --entitlements "$ENTITLEMENTS" \
        --sign - \
        "$APP_DIR"
fi

echo ""
echo "Built and signed: $APP_DIR"
echo ""
echo "To notarize for public distribution:"
echo "  xcrun notarytool submit \"$APP_DIR\" \\"
echo "      --apple-id <your@email.com> \\"
echo "      --team-id $TEAM_ID \\"
echo "      --password <app-specific-password> \\"
echo "      --wait"
echo "  xcrun stapler staple \"$APP_DIR\""
