# Clip Saske

Native macOS clipboard history utility built with Swift, AppKit, SQLite, Keychain, Accessibility, and a CGEvent tap.

🌐 **Website & Download**: [clip.saske.in](https://clip.saske.in)

The app bundle uses the branded command-key style icon from `Resources/ClipSaske.icns`.

## Build

```bash
swift build
```

Build an app bundle:

```bash
./scripts/build_app.sh release
```

Run the app bundle:

```bash
open ".build/Clip Saske.app"
```

## Behavior

- Monitors `NSPasteboard.general` for copied text.
- Stores clipboard items in `~/Library/Application Support/Clip Saske/clipsaske.sqlite3`.
- Shows a menu bar utility via `NSStatusBar`.
- Uses Option + Command + V through `CGEventTap`.
- Swallows Option + Command + V when Clip Saske handles it, preventing duplicate shortcuts in the frontmost app.
- Reads the hotkey from settings and updates the event tap matcher without restarting.
- Shows an `NSPanel` under the cursor when the hotkey is pressed, matching Windows clipboard history behavior.
- Renders popup history with a view-based `NSTableView` over `NSVisualEffectView` material for reusable rows, native keyboard navigation, and a glass-style surface.
- Supports search, pinned items, favorites, clear history, cleanup, and login item installation from settings.
- Applies cleanup and sync setting changes immediately.
- Uses SQLite FTS5 for scalable content/app search.
- Excludes secure fields, concealed pasteboard types, common password manager apps, and token/password-like patterns.
- Offers a database reset path if the local SQLite store cannot be opened.

## Permissions

macOS will require:

- Accessibility, for focus detection and paste insertion.
- Input Monitoring, for the global hotkey event tap.

## Launch Agent

On macOS Ventura and newer, the app uses `SMAppService.mainApp` for login item registration from Settings. The LaunchAgent script remains available for manual installs:

```bash
./scripts/install_launch_agent.sh
```

The settings window can also install or remove `~/Library/LaunchAgents/com.clipsaske.app.plist`.

## Sync

The sync engine is intentionally provider-ready. It has Keychain-backed credential access and a queue boundary, but provider adapters for iCloud/Firebase/Supabase/custom APIs still need to be implemented before cross-device sync is active.
