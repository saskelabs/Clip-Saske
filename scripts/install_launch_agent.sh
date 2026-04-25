#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$ROOT/.build/Clip Saske.app}"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$PLIST_DIR/com.clipsaske.app.plist"

mkdir -p "$PLIST_DIR"
sed "s#__APP_PATH__#$APP_PATH#g" "$ROOT/Resources/com.clipsaske.app.plist.template" > "$PLIST_PATH"
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"

echo "Installed $PLIST_PATH"
