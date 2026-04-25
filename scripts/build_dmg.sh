#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# build_dmg.sh — Build a signed, distributable DMG for Clip Saske
#
# Usage:
#   ./scripts/build_dmg.sh [release|debug]
#
# Prerequisites:
#   - Xcode Command Line Tools installed
#   - (Optional) SIGN_IDENTITY set to your "Developer ID Application: …" cert
#   - (Optional) TEAM_ID set to your 10-character Apple Team ID
#
# Output:
#   .build/ClipSaske-<VERSION>.dmg  (ready to upload to clip.saske.in/updates/)
#
# What this script does:
#   1. Builds the .app via build_app.sh (swift build + codesign)
#   2. Creates a read-write DMG staging image
#   3. Copies the .app into the staging image
#   4. Adds an /Applications symlink (drag-to-install UX)
#   5. Converts staging image to a compressed, read-only DMG
#   6. Signs the final DMG (if SIGN_IDENTITY is set)
#   7. Prints the SHA-256 hash for registering with admin_hashes.php
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP_DIR="$ROOT/.build/Clip Saske.app"
VERSION=$(defaults read "$ROOT/Resources/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "1.1.0")
DMG_NAME="ClipSaske-${VERSION}"
DMG_STAGING="/tmp/${DMG_NAME}-staging.dmg"
DMG_FINAL="/tmp/${DMG_NAME}.dmg"
FINAL_OUT="$ROOT/.build/${DMG_NAME}.dmg"
VOLUME_NAME="Clip Saske ${VERSION}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
TEAM_ID="${TEAM_ID:-}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Clip Saske DMG Builder — v${VERSION}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Step 1: Build the .app ────────────────────────────────────────────────────
echo ""
echo "[1/5] Building .app bundle..."
"$ROOT/scripts/build_app.sh" "$CONFIG"

if [ ! -d "$APP_DIR" ]; then
    echo "ERROR: .app not found at: $APP_DIR"
    exit 1
fi

# ── Step 2: Clean previous staging/final DMGs ─────────────────────────────────
echo ""
echo "[2/5] Preparing staging area..."
rm -f "$DMG_STAGING" "$DMG_FINAL" "$FINAL_OUT"

# ── Step 3: Create staging DMG ───────────────────────────────────────────────
# Size: 100 MB (plenty for the .app; adjust if your binary grows)
hdiutil create \
    -size 100m \
    -fs HFS+ \
    -volname "$VOLUME_NAME" \
    -ov \
    "$DMG_STAGING"

# Mount the staging image
MOUNT_DIR=$(hdiutil attach "$DMG_STAGING" -noautoopen -nobrowse | grep -o '/Volumes/.*')
echo "   Mounted at: $MOUNT_DIR"

# Copy .app into the volume
cp -r "$APP_DIR" "$MOUNT_DIR/"

# Create /Applications symlink for drag-to-install
ln -s /Applications "$MOUNT_DIR/Applications"

# Optional: set the window layout with AppleScript (comment out if no Xcode GUI tools)
osascript 2>/dev/null <<APPLESCRIPT || true
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {100, 100, 640, 400}
        set arrangement of icon view options of container window to not arranged
        set icon size of icon view options of container window to 96
        set position of item "Clip Saske.app" of container window to {140, 170}
        set position of item "Applications" of container window to {400, 170}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

# Unmount
hdiutil detach "$MOUNT_DIR" -quiet

# ── Step 4: Convert to compressed read-only DMG ───────────────────────────────
echo ""
echo "[3/5] Converting to compressed DMG..."
hdiutil convert "$DMG_STAGING" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_FINAL"

rm -f "$DMG_STAGING"

# ── Step 5: Sign the DMG ─────────────────────────────────────────────────────
echo ""
echo "[4/5] Signing DMG..."
if [ -n "$SIGN_IDENTITY" ]; then
    codesign \
        --force \
        --sign "$SIGN_IDENTITY" \
        --timestamp \
        "$DMG_FINAL"
    echo "   Signed with: $SIGN_IDENTITY"
    codesign --verify --verbose=1 "$DMG_FINAL"
else
    echo "   No SIGN_IDENTITY — skipping DMG signature (set SIGN_IDENTITY to sign)."
fi

# Move the final DMG to the build directory
mv "$DMG_FINAL" "$FINAL_OUT"
DMG_FINAL="$FINAL_OUT"

# ── Step 6: Print results ─────────────────────────────────────────────────────
DMG_SIZE=$(wc -c < "$DMG_FINAL" | tr -d ' ')
DMG_SHA=$(shasum -a 256 "$DMG_FINAL" | awk '{print $1}')
BIN_SHA=$(shasum -a 256 "$APP_DIR/Contents/MacOS/ClipSaske" | awk '{print $1}')

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "[5/5] Done!"
echo ""
echo "  DMG:       $DMG_FINAL"
echo "  Size:      $DMG_SIZE bytes"
echo "  DMG SHA256: $DMG_SHA"
echo "  Binary SHA256: $BIN_SHA"
echo ""
echo "Next steps:"
echo ""
echo "  # 1. Register the binary hash with your license server:"
echo "  php web/admin_hashes.php --action=add --version=${VERSION} --hash=${BIN_SHA}"
echo ""
echo "  # 2. Upload the DMG:"
echo "  scp '$DMG_FINAL' user@clip.saske.in:/var/www/html/updates/${DMG_NAME}.dmg"
echo ""
if [ -n "$TEAM_ID" ]; then
    echo "  # 3. Notarize (required for Gatekeeper):"
    echo "  xcrun notarytool submit '$DMG_FINAL' \\"
    echo "      --apple-id your@email.com \\"
    echo "      --team-id $TEAM_ID \\"
    echo "      --password <app-specific-password> \\"
    echo "      --wait"
    echo "  xcrun stapler staple '$DMG_FINAL'"
    echo ""
fi
echo "  # 4. Update appcast.xml <enclosure> length to: $DMG_SIZE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
