# Changelog

## 0.4.0 — 2026-11-19

- Encrypt clipboard history, saved clipboard images, notes and AI chats with a key in the macOS Keychain.
- Keep existing chats when a new conversation starts and finish pending archive writes on quit.
- macOS may ask for permission to access the archive key after an update. Keep a pre-upgrade backup of Application Support and its matching Keychain for rollback.

## 0.3.0 — 2026-11-19

- Check for and install signed updates from the Lumen menu in release builds.
- Improve folder matching and preserve the selected result as new search results arrive.
- Toggle and resize the detail pane from the keyboard. Lumen remembers its width and visibility.
- Enable optional AI explicitly in Settings and use your own provider account or local server.
- Validate mite time-booking input and show concise errors for optional CLI integrations.

## 0.2.1 — 2026-11-16

- Fix builds with standalone Apple Command Line Tools when the SDK exports a State macro without its SwiftUIMacros plugin. Settings explicitly uses the SwiftUI State property wrapper.

## 0.2.0 — 2026-11-16

- Configure or remove either launcher hotkey in General Settings; changes persist and apply immediately.
- Report shortcut conflicts without replacing the previous binding.
